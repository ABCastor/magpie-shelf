import Foundation
import XCTest
@testable import Magpie

/// A shelf item that is a directory used to walk its whole tree, with no cap,
/// no deadline and no cancellation, once per launch and once per repeated add.
/// These pin every bound, and that an unknown size stays unknown instead of
/// being reported as zero bytes.
final class FolderWalkTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderWalkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_walk_totals_a_nested_tree_within_the_bounds() throws {
        let root = try makeTree(files: 4, nestedFiles: 2)

        XCTAssertEqual(FolderWalk.totalBytes(of: root), .exact(60))
    }

    func test_walk_stops_at_the_entry_cap_and_reports_what_it_had() throws {
        let root = try makeTree(files: 6, nestedFiles: 0)

        let size = FolderWalk.totalBytes(
            of: root,
            limits: .init(maxEntries: 3, deadline: 60)
        )

        XCTAssertEqual(size, .partial(bytes: 30, stop: .entryCap))
    }

    func test_walk_stops_at_the_deadline() throws {
        let root = try makeTree(files: 6, nestedFiles: 0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        // Called once for the start instant, then once per entry: the first
        // entry is inside the deadline, the second is well past it.
        var calls = 0
        let clock: () -> Date = {
            defer { calls += 1 }
            return calls <= 1 ? start : start.addingTimeInterval(30)
        }

        let size = FolderWalk.totalBytes(
            of: root,
            limits: .init(maxEntries: .max, deadline: 1),
            now: clock
        )

        XCTAssertEqual(size, .partial(bytes: 10, stop: .deadline))
    }

    func test_walk_stops_when_cancelled() throws {
        let root = try makeTree(files: 6, nestedFiles: 0)

        let size = FolderWalk.totalBytes(of: root, isCancelled: { true })

        XCTAssertEqual(size, .partial(bytes: 0, stop: .cancelled))
    }

    @MainActor
    func test_repeated_requests_share_one_walk_per_item() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let root = try makeTree(files: 4, nestedFiles: 2)
        let item = ShelfItem(type: .file, fileURL: root, isDirectory: true)
        manager.addItem(item, to: shelfID)

        // The test body owns the main actor, so no walk can finish and clear
        // its slot while these five requests are being made.
        for _ in 0..<5 {
            manager.recomputeFolderSize(itemID: item.id, in: shelfID)
        }

        XCTAssertEqual(manager.inFlightFolderWalkCount, 1)
    }

    @MainActor
    func test_completed_walk_writes_the_total_and_releases_its_slot() async throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let root = try makeTree(files: 4, nestedFiles: 2)
        let item = ShelfItem(type: .file, fileURL: root, isDirectory: true)
        manager.addItem(item, to: shelfID)

        manager.recomputeFolderSize(itemID: item.id, in: shelfID)
        try await settle(manager)

        XCTAssertEqual(manager.items(of: shelfID).first?.cachedFolderBytes, 60)
        XCTAssertEqual(manager.inFlightFolderWalkCount, 0)
    }

    /// A folder the walk could not finish has no size, and "no size" renders as
    /// "Folder". Writing the partial total would render as an exact size that
    /// is simply wrong, and writing zero would read as an empty folder.
    @MainActor
    func test_bounded_walk_leaves_the_size_unknown_rather_than_zero() async throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let root = try makeTree(files: 6, nestedFiles: 0)
        let item = ShelfItem(type: .file, fileURL: root, isDirectory: true)
        manager.addItem(item, to: shelfID)

        manager.recomputeFolderSize(
            itemID: item.id,
            in: shelfID,
            limits: .init(maxEntries: 2, deadline: 60)
        )
        try await settle(manager)

        let updated = try XCTUnwrap(manager.items(of: shelfID).first)
        XCTAssertNil(updated.cachedFolderBytes)
        XCTAssertEqual(updated.displayMeta, "Folder")
        XCTAssertEqual(manager.inFlightFolderWalkCount, 0)
    }

    /// Ten 10-byte files across a root and one subdirectory when both counts
    /// are used, so every total in this file is a multiple of ten.
    private func makeTree(files: Int, nestedFiles: Int) throws -> URL {
        let root = tempDir.appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data(repeating: 7, count: 10)
                .write(to: root.appendingPathComponent("file-\(index).bin"))
        }
        guard nestedFiles > 0 else { return root }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<nestedFiles {
            try Data(repeating: 7, count: 10)
                .write(to: nested.appendingPathComponent("nested-\(index).bin"))
        }
        return root
    }

    @MainActor
    private func settle(_ manager: ShelfManager) async throws {
        let deadline = Date().addingTimeInterval(5)
        while manager.inFlightFolderWalkCount > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func makeManager() -> ShelfManager {
        ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf-\(UUID().uuidString).json")
        ))
    }
}
