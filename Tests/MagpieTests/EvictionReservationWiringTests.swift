import XCTest
@testable import Magpie

/// The reservation set only protects an in-flight ingest if the callers that
/// *actually run* pass it along.
///
/// Two of them take no `reserving:` argument at all: the launch-time and
/// per-add sweeps go through `evictManagedCacheIfNeeded(budgetBytes:)`, and
/// Settings' Clear Cache calls it with a budget of zero. Both forward to the
/// reserving overload, and nothing pinned that forwarding — the existing
/// reservation test calls the reserving overload directly, so it stays green
/// while the default overload reserves nothing.
///
/// That gap is not cosmetic. Clear Cache with a zero budget removes every
/// unreferenced file in `ManagedFiles`, and a file being written by an ingest
/// is unreferenced by definition: no card points at a copy that has not landed
/// yet. Deleting it mid-write loses the file the user just dropped.
@MainActor
final class EvictionReservationWiringTests: XCTestCase {

    private func makeManager() throws -> (ShelfManager, ShelfStore, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-evict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        let manager = ShelfManager(store: store)
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        return (manager, store, scratch)
    }

    /// Drives the real ingest path so the reservation is populated the way it
    /// is in life, rather than handed in by the test.
    private func startIngest(
        _ manager: ShelfManager, into shelfID: UUID, from scratch: URL
    ) throws -> URL {
        let source = scratch.appendingPathComponent("dropped.bin")
        try Data(repeating: 7, count: 2_048).write(to: source)
        manager.addFiles([source], to: shelfID)
        return source
    }

    func test_clear_cache_does_not_reclaim_a_file_an_ingest_is_writing() throws {
        let (manager, store, scratch) = try makeManager()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let shelfID = manager.createShelf()
        _ = try startIngest(manager, into: shelfID, from: scratch)

        // Stand in for the staging file the running ingest holds: it exists on
        // disk, no card references it, and it is exactly what Clear Cache
        // would sweep if the reservation were dropped on the way through.
        guard let reserved = manager.reservedIngestPathsForTesting.first else {
            return XCTFail(
                "the ingest reserved nothing, so this test cannot say whether the "
                + "reservation survives the call — the fixture is broken, not the code"
            )
        }
        let reservedURL = URL(fileURLWithPath: reserved)
        try Data(repeating: 3, count: 4_096).write(to: reservedURL)
        let orphan = store.managedFilesDirectory.appendingPathComponent("nobody-wants-this.bin")
        try Data(repeating: 2, count: 4_096).write(to: orphan)

        manager.clearManagedCache()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: reservedURL.path),
            "Clear Cache deleted the staging file of an ingest that was still running — "
            + "the reservation was not forwarded, and the dropped file is lost."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "Clear Cache removed nothing at all, so the assertion above passed for the "
            + "wrong reason."
        )
    }

    func test_the_budgeted_sweep_forwards_the_reservation_too() throws {
        let (manager, store, scratch) = try makeManager()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let shelfID = manager.createShelf()
        _ = try startIngest(manager, into: shelfID, from: scratch)

        guard let reserved = manager.reservedIngestPathsForTesting.first else {
            return XCTFail("the ingest reserved nothing — the fixture is broken, not the code")
        }
        let reservedURL = URL(fileURLWithPath: reserved)
        try Data(repeating: 3, count: 4_096).write(to: reservedURL)
        let orphan = store.managedFilesDirectory.appendingPathComponent("orphan.bin")
        try Data(repeating: 2, count: 4_096).write(to: orphan)

        // The launch-time and per-add sweeps take this shape: a budget, no
        // explicit reservation.
        manager.evictManagedCacheIfNeeded(budgetBytes: 1)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: reservedURL.path),
            "the budgeted sweep reclaimed a file an ingest was still writing — a drop "
            + "big enough to cross the budget can now destroy its own staging file."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "the sweep removed nothing, so the assertion above passed for the wrong reason."
        )
    }
}
