import Combine
import Foundation
import XCTest
@testable import Magpie

/// Queue behaviour, mirroring `QueueServiceTests` for conversion and OCR. The
/// executor is faked throughout, so no test here starts a real process.
final class RouteServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func route(
        id: String = "r",
        secrets: [String] = [],
        collectsOutput: Bool = false
    ) -> Route {
        Route(
            id: id, name: "Route \(id)", symbol: nil, match: nil,
            command: "/bin/echo", arguments: [], workingDirectory: nil,
            secrets: secrets, timeout: 5, collectsOutput: collectsOutput,
            isEnabled: true
        )
    }


    @MainActor
    func test_enqueue_marks_every_input_then_clears_on_completion() async throws {
        let service = RouteService(
            executor: { _, _ in okOutcome },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        let itemIDs = [UUID(), UUID()]
        let shelfID = UUID()
        let done = expectation(description: "completed")
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, actualShelfID in
            XCTAssertEqual(actualShelfID, shelfID)
            done.fulfill()
        }.store(in: &cancellables)

        service.enqueueRun(
            route: route(), itemIDs: itemIDs, shelfID: shelfID,
            files: [URL(fileURLWithPath: "/tmp/a.txt")]
        )

        XCTAssertEqual(service.progress[itemIDs[0]], 0)
        XCTAssertEqual(service.progress[itemIDs[1]], 0)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertNil(service.progress[itemIDs[0]])
        XCTAssertNil(service.progress[itemIDs[1]])
    }

    @MainActor
    func test_an_empty_file_list_is_a_no_op() {
        let service = RouteService(
            executor: { _, _ in XCTFail("should not run"); return okOutcome },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        service.enqueueRun(route: route(), itemIDs: [UUID()], shelfID: UUID(), files: [])
        XCTAssertTrue(service.progress.isEmpty)
    }

    @MainActor
    func test_runs_complete_in_fifo_order() async throws {
        let service = RouteService(
            executor: { _, _ in
                Thread.sleep(forTimeInterval: 0.05)
                return okOutcome
            },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        let shelfIDs = [UUID(), UUID(), UUID()]
        let done = expectation(description: "all completed")
        done.expectedFulfillmentCount = shelfIDs.count
        var order: [UUID] = []
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, shelfID in
            order.append(shelfID)
            done.fulfill()
        }.store(in: &cancellables)

        for (index, shelfID) in shelfIDs.enumerated() {
            service.enqueueRun(
                route: route(id: "\(index)"), itemIDs: [UUID()], shelfID: shelfID,
                files: [URL(fileURLWithPath: "/tmp/a.txt")]
            )
        }

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(order, shelfIDs)
    }

    @MainActor
    func test_cancel_drops_a_queued_run_before_it_starts() async throws {
        let service = RouteService(
            executor: { _, _ in
                Thread.sleep(forTimeInterval: 0.1)
                return okOutcome
            },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        let runningShelf = UUID()
        let cancelledShelf = UUID()
        let cancelledItem = UUID()
        let ran = expectation(description: "first run completed")
        let cancelledRan = expectation(description: "cancelled run did not complete")
        cancelledRan.isInverted = true
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, shelfID in
            if shelfID == cancelledShelf { cancelledRan.fulfill() }
            if shelfID == runningShelf { ran.fulfill() }
        }.store(in: &cancellables)

        service.enqueueRun(
            route: route(), itemIDs: [UUID()], shelfID: runningShelf,
            files: [URL(fileURLWithPath: "/tmp/a.txt")]
        )
        service.enqueueRun(
            route: route(), itemIDs: [cancelledItem], shelfID: cancelledShelf,
            files: [URL(fileURLWithPath: "/tmp/b.txt")]
        )
        XCTAssertEqual(service.progress[cancelledItem], 0)

        service.cancel(itemID: cancelledItem)

        XCTAssertNil(service.progress[cancelledItem])
        await fulfillment(of: [ran], timeout: 10)
        await fulfillment(of: [cancelledRan], timeout: 0.5)
    }

    @MainActor
    func test_cancelling_one_tile_stops_the_whole_run() async throws {
        let running = expectation(description: "the command started")
        let service = RouteService(
            executor: { _, isCancelled in
                running.fulfill()
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.01) }
                return RouteOutcome(
                    exitCode: 15, standardOutput: "", standardError: "", timedOut: false
                )
            },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        let itemIDs = [UUID(), UUID()]
        let cancelled = expectation(description: "reported as cancelled")
        var cancellables = Set<AnyCancellable>()
        service.failed.sink { failure in
            XCTAssertEqual(failure, .cancelled)
            cancelled.fulfill()
        }.store(in: &cancellables)
        service.completed.sink { _, _ in
            XCTFail("a cancelled run must not complete")
        }.store(in: &cancellables)

        service.enqueueRun(
            route: route(), itemIDs: itemIDs, shelfID: UUID(),
            files: [URL(fileURLWithPath: "/tmp/a.txt")]
        )
        await fulfillment(of: [running], timeout: 5)

        service.cancel(itemID: itemIDs[1])

        XCTAssertNil(service.progress[itemIDs[0]], "the whole run's tiles clear, not just one")
        XCTAssertNil(service.progress[itemIDs[1]])
        await fulfillment(of: [cancelled], timeout: 5)
    }

    @MainActor
    func test_a_missing_secret_fails_before_anything_runs() async throws {
        let service = RouteService(
            executor: { _, _ in
                XCTFail("the command must not start without its secret")
                return okOutcome
            },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        let itemID = UUID()
        let failed = expectation(description: "failed")
        var cancellables = Set<AnyCancellable>()
        service.failed.sink { failure in
            XCTAssertEqual(failure, .missingSecret(route: "Route r", secret: "GEMINI_API_KEY"))
            failed.fulfill()
        }.store(in: &cancellables)

        service.enqueueRun(
            route: route(secrets: ["GEMINI_API_KEY"]), itemIDs: [itemID],
            shelfID: UUID(), files: [URL(fileURLWithPath: "/tmp/a.txt")]
        )

        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(service.progress[itemID])
    }

    @MainActor
    func test_a_stored_secret_reaches_the_command_environment() async throws {
        let seen = SeenEnvironment()
        let service = RouteService(
            executor: { execution, _ in
                seen.record(execution.environment["GEMINI_API_KEY"])
                return okOutcome
            },
            secretProvider: { name in name == "GEMINI_API_KEY" ? "sk-test-1" : nil },
            outputRoot: tempDir
        )
        let done = expectation(description: "completed")
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { _, _ in done.fulfill() }.store(in: &cancellables)

        service.enqueueRun(
            route: route(secrets: ["GEMINI_API_KEY"]), itemIDs: [UUID()],
            shelfID: UUID(), files: [URL(fileURLWithPath: "/tmp/a.txt")]
        )

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(seen.value, "sk-test-1")
    }

    @MainActor
    func test_an_output_folder_is_made_per_run_and_left_empty_when_unused() async throws {
        let service = RouteService(
            executor: { execution, _ in
                XCTAssertNotNil(execution.environment["MAGPIE_OUTPUT_DIR"])
                return okOutcome
            },
            secretProvider: { _ in nil },
            outputRoot: tempDir
        )
        let done = expectation(description: "completed")
        var cancellables = Set<AnyCancellable>()
        service.completed.sink { success, _ in
            XCTAssertTrue(success.producedFiles.isEmpty)
            done.fulfill()
        }.store(in: &cancellables)

        service.enqueueRun(
            route: route(collectsOutput: true), itemIDs: [UUID()],
            shelfID: UUID(), files: [URL(fileURLWithPath: "/tmp/a.txt")]
        )

        await fulfillment(of: [done], timeout: 5)
    }
}

/// A plain success, at file scope so the faked executors capture nothing.
private let okOutcome = RouteOutcome(
    exitCode: 0, standardOutput: "", standardError: "", timedOut: false
)

/// Tiny locked box so a background executor can hand a value back to the test.
private final class SeenEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func record(_ value: String?) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
