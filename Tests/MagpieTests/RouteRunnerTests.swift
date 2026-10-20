import Foundation
import XCTest
@testable import Magpie

/// Real subprocesses, but only tiny local ones: `/bin/cat`, `/bin/sleep`.
/// Nothing here touches the network or reads a large file.
final class RouteRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func route(
        command: String,
        arguments: [String],
        timeout: TimeInterval = 30,
        collectsOutput: Bool = false
    ) -> Route {
        Route(
            id: "test", name: "Test Route", symbol: nil, match: nil,
            command: command, arguments: arguments, workingDirectory: nil,
            secrets: [], timeout: timeout, collectsOutput: collectsOutput,
            isEnabled: true
        )
    }

    /// Proves the whole argv story end to end: a filename containing a space
    /// and a double quote reaches the command as one argument, so `cat` finds
    /// the file and prints its contents.
    func test_a_path_with_a_space_and_a_quote_reaches_the_command_intact() throws {
        let name = #"we ird "quoted" name.txt"#
        let file = tempDir.appendingPathComponent(name)
        try Data("hello from the awkward file".utf8).write(to: file)

        let result = RouteRunner.perform(
            route: route(command: "/bin/cat", arguments: ["{files}"]),
            files: [file],
            outputDirectory: nil,
            secrets: [:],
            executor: RouteRunner.execute,
            isCancelled: { false }
        )

        switch result {
        case .success(let success):
            XCTAssertEqual(success.routeName, "Test Route")
            XCTAssertTrue(success.producedFiles.isEmpty)
        case .failure(let failure):
            XCTFail("expected success, got \(failure)")
        }
    }

    func test_the_input_file_is_still_there_afterwards() throws {
        let file = tempDir.appendingPathComponent("input.txt")
        try Data("keep me".utf8).write(to: file)

        _ = RouteRunner.perform(
            route: route(command: "/bin/cat", arguments: ["{files}"]),
            files: [file], outputDirectory: nil, secrets: [:],
            executor: RouteRunner.execute, isCancelled: { false }
        )

        // ADR 0001 in one assertion: a route reads its inputs and nothing else.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep me".utf8))
    }

    func test_a_non_zero_exit_carries_the_stderr_tail() {
        let missing = tempDir.appendingPathComponent("nope-not-here.txt")
        let result = RouteRunner.perform(
            route: route(command: "/bin/cat", arguments: [missing.path]),
            files: [], outputDirectory: nil, secrets: [:],
            executor: RouteRunner.execute, isCancelled: { false }
        )
        guard case .failure(.exited(let name, let code, let detail)) = result else {
            return XCTFail("expected a non-zero exit, got \(result)")
        }
        XCTAssertEqual(name, "Test Route")
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(detail.contains("nope-not-here"), "stderr tail was: \(detail)")
    }

    func test_a_command_that_will_not_stop_is_timed_out() {
        let started = Date()
        let result = RouteRunner.perform(
            route: route(command: "/bin/sleep", arguments: ["30"], timeout: 0.5),
            files: [], outputDirectory: nil, secrets: [:],
            executor: RouteRunner.execute, isCancelled: { false }
        )
        guard case .failure(.timedOut(let name, _)) = result else {
            return XCTFail("expected a timeout, got \(result)")
        }
        XCTAssertEqual(name, "Test Route")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func test_a_missing_command_is_a_launch_failure_not_a_crash() {
        let result = RouteRunner.perform(
            route: route(command: "/nowhere/does-not-exist", arguments: []),
            files: [], outputDirectory: nil, secrets: [:],
            executor: RouteRunner.execute, isCancelled: { false }
        )
        guard case .failure(.launchFailed(let name, let command)) = result else {
            return XCTFail("expected a launch failure, got \(result)")
        }
        XCTAssertEqual(name, "Test Route")
        XCTAssertEqual(command, "/nowhere/does-not-exist")
    }

    // MARK: - Output collection

    func test_files_left_in_the_output_folder_come_back() throws {
        let output = tempDir.appendingPathComponent("out", isDirectory: true)
        let executor: RouteExecutor = { execution, _ in
            let directory = try XCTUnwrap(execution.environment["MAGPIE_OUTPUT_DIR"])
            for name in ["b.txt", "a.txt"] {
                try Data("x".utf8).write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(name)
                )
            }
            return RouteOutcome(
                exitCode: 0, standardOutput: "", standardError: "", timedOut: false
            )
        }

        let result = RouteRunner.perform(
            route: route(command: "/bin/echo", arguments: [], collectsOutput: true),
            files: [], outputDirectory: output, secrets: [:],
            executor: executor, isCancelled: { false }
        )

        guard case .success(let success) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(success.producedFiles.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }

    func test_produced_files_are_capped() throws {
        let output = tempDir.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for index in 0..<(RouteRunner.maximumProducedFiles + 5) {
            try Data("x".utf8).write(
                to: output.appendingPathComponent(String(format: "%03d.txt", index))
            )
        }
        XCTAssertEqual(
            RouteRunner.producedFiles(in: output).count,
            RouteRunner.maximumProducedFiles
        )
    }

    // MARK: - Secrets

    func test_a_secret_echoed_to_stderr_never_reaches_the_failure() {
        let secret = "sk-live-supersecret-value"
        let executor: RouteExecutor = { _, _ in
            RouteOutcome(
                exitCode: 2,
                standardOutput: "",
                standardError: "auth failed for key \(secret)",
                timedOut: false
            )
        }
        let result = RouteRunner.perform(
            route: route(command: "/bin/echo", arguments: []),
            files: [], outputDirectory: nil, secrets: ["KEY": secret],
            executor: executor, isCancelled: { false }
        )
        guard case .failure(let failure) = result else {
            return XCTFail("expected a failure, got \(result)")
        }
        XCTAssertFalse(failure.detail.contains(secret))
        XCTAssertFalse(failure.displayMessage.contains(secret))
        XCTAssertTrue(failure.detail.contains("•••"))
    }

    func test_a_cancelled_run_reports_cancellation_rather_than_the_exit_code() {
        let executor: RouteExecutor = { _, _ in
            RouteOutcome(
                exitCode: 15, standardOutput: "", standardError: "", timedOut: false
            )
        }
        let result = RouteRunner.perform(
            route: route(command: "/bin/echo", arguments: []),
            files: [], outputDirectory: nil, secrets: [:],
            executor: executor, isCancelled: { true }
        )
        guard case .failure(.cancelled) = result else {
            return XCTFail("expected cancellation, got \(result)")
        }
    }

    func test_every_failure_has_a_sentence_and_the_cancelled_case_has_none() {
        let failures: [RouteFailure] = [
            .launchFailed(route: "R", command: "/bin/x"),
            .missingSecret(route: "R", secret: "KEY"),
            .timedOut(route: "R", seconds: 120),
            .exited(route: "R", code: 2, detail: "boom"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.displayMessage.isEmpty)
            XCTAssertFalse(failure.displayMessage.contains("%"))
            XCTAssertTrue(failure.displayMessage.contains("R"))
        }
        XCTAssertTrue(RouteFailure.cancelled.displayMessage.isEmpty)
    }
}
