import AppKit
import Combine
import Foundation
import XCTest
@testable import Magpie

/// A drop used to run inline on the main thread: a copy and a full byte-by-byte
/// duplicate comparison per file, with the panel frozen for the duration and no
/// way to stop it. These pin the three properties that replaced that — the work
/// is off the main thread, it can be stopped, and stopping it leaves the shelf
/// coherent rather than half-filled.
final class AsyncIngestTests: XCTestCase {
    private var tempDir: URL!
    /// Off the purgeable roots on purpose: a store sited under system temp would
    /// make every source file "inside the store directory" and skip the managed
    /// copy this suite is about.
    private var storeDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsyncIngestTests-\(UUID().uuidString)", isDirectory: true)
        storeDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("AsyncIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: storeDir)
    }

    @MainActor
    private func makeManager() -> (ShelfManager, ShelfStore) {
        let store = ShelfStore(storeURL: storeDir.appendingPathComponent("shelf.json"))
        return (ShelfManager(store: store), store)
    }

    /// Written into the real system temp so `ManagedIngest` treats them as
    /// purgeable and actually copies them — which is where the cost lives.
    private func purgeableFiles(_ count: Int, bytes: Int = 32) throws -> [URL] {
        try (0..<count).map { index in
            let url = tempDir.appendingPathComponent("drop-\(index)-\(UUID().uuidString).bin")
            try Data(repeating: UInt8(index % 251), count: bytes).write(to: url)
            return url
        }
    }

    // MARK: - Off the main thread

    /// The property the whole batch exists for. `addFiles` returns having done
    /// none of the work: the test holds the main actor for the length of the
    /// assertion below, so a card appearing there could only have been made
    /// inline, which is the freeze this replaced.
    @MainActor
    func test_a_dropped_pile_does_not_land_on_the_main_thread() async throws {
        let (manager, _) = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let urls = try purgeableFiles(5)

        manager.addFiles(urls, to: shelfID)

        XCTAssertTrue(
            manager.items(of: shelfID).isEmpty,
            "the drop was taken in on the main thread — this is the beachball"
        )
        XCTAssertTrue(manager.isIngesting(shelfID: shelfID))

        await manager.awaitIngest()

        XCTAssertEqual(manager.items(of: shelfID).count, urls.count)
        XCTAssertFalse(manager.isIngesting(shelfID: shelfID))
    }

    /// Every card still points into the managed cache, and its file is whole.
    /// Going asynchronous must not change what an ingested file *is*.
    @MainActor
    func test_a_dropped_purgeable_file_still_becomes_a_whole_managed_copy() async throws {
        let (manager, store) = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let source = tempDir.appendingPathComponent("payload.bin")
        let payload = Data(repeating: 0x7F, count: 5_000)
        try payload.write(to: source)

        manager.addFiles([source], to: shelfID)
        await manager.awaitIngest()

        let item = try XCTUnwrap(manager.items(of: shelfID).first)
        let managedURL = try XCTUnwrap(item.fileURL)
        XCTAssertEqual(managedURL.deletingLastPathComponent(), store.managedFilesDirectory)
        XCTAssertEqual(try Data(contentsOf: managedURL), payload)
    }

    /// A second drop while one is still landing joins the queue. Cancelling the
    /// running one would throw away files the user had just dropped.
    @MainActor
    func test_a_second_drop_joins_the_one_already_landing() async throws {
        let (manager, _) = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)

        // Three, not two: the first drop empties the queue on its way into the
        // task, so only the second and third are ever in it together — which is
        // the only arrangement that can tell "joins" from "replaces" apart.
        manager.addFiles(try purgeableFiles(3), to: shelfID)
        manager.addFiles(try purgeableFiles(2), to: shelfID)
        manager.addFiles(try purgeableFiles(2), to: shelfID)
        await manager.awaitIngest()

        XCTAssertEqual(
            manager.items(of: shelfID).count, 7,
            "a drop that arrived while another was landing was thrown away"
        )
    }

    // MARK: - Cancelling

    /// A cancelled drop is a fully absent item, never a half-copied card. The
    /// managed cache is checked too: a partial file under the name a card would
    /// point at is the same defect one layer down.
    @MainActor
    func test_a_cancelled_drop_adds_no_card_and_leaves_no_managed_file() async throws {
        let (manager, store) = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)

        manager.addFiles(try purgeableFiles(6), to: shelfID)
        manager.cancelIngest(shelfID: shelfID)
        await manager.awaitIngest()

        XCTAssertTrue(
            manager.items(of: shelfID).isEmpty,
            "a cancelled drop still put cards on the shelf"
        )
        XCTAssertNil(manager.ingestProgress[shelfID])
        let managed = (try? FileManager.default.contentsOfDirectory(
            atPath: store.managedFilesDirectory.path
        )) ?? []
        XCTAssertEqual(managed, [], "a cancelled drop left files in the managed cache")
    }

    /// Cancelling one shelf's drop must not touch another's.
    @MainActor
    func test_cancelling_one_shelf_leaves_the_other_shelf_landing() async throws {
        let (manager, _) = makeManager()
        let first = try XCTUnwrap(manager.shelves.first?.id)
        let second = manager.createShelf()

        manager.addFiles(try purgeableFiles(3), to: first)
        manager.addFiles(try purgeableFiles(3), to: second)
        manager.cancelIngest(shelfID: first)
        await manager.awaitIngest()

        XCTAssertTrue(manager.items(of: first).isEmpty)
        XCTAssertEqual(manager.items(of: second).count, 3)
    }

    // MARK: - The bar

    @MainActor
    func test_a_big_drop_reports_progress_while_it_is_still_landing() async throws {
        let (manager, _) = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        var seen: [Double] = []
        let cancellable = manager.$ingestProgress.sink { progress in
            if let value = progress[shelfID] { seen.append(value) }
        }
        defer { cancellable.cancel() }

        manager.addFiles(try purgeableFiles(IngestProgressPolicy.visibleBatchSize + 4), to: shelfID)
        await manager.awaitIngest()

        XCTAssertFalse(seen.isEmpty, "a drop worth waiting for reported no progress at all")
        XCTAssertEqual(seen, seen.sorted(), "progress went backwards")
    }

    /// A bar left up over a panel with nothing arriving is a broken app that
    /// looks broken. The shelf has to forget the drop when it ends.
    @MainActor
    func test_a_finished_drop_leaves_no_bar_behind() async throws {
        let (manager, _) = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)

        manager.addFiles(try purgeableFiles(IngestProgressPolicy.visibleBatchSize + 2), to: shelfID)
        await manager.awaitIngest()

        XCTAssertNil(
            manager.ingestProgress[shelfID],
            "the progress bar stayed up after the drop finished"
        )
    }

    // MARK: - Eviction

    /// The managed cache is reclaimed by an eviction that skips anything a card
    /// references. A file being written *right now* is referenced by nothing —
    /// so without an explicit reservation, a drop big enough to blow the budget
    /// can reclaim the very bytes it is in the middle of writing.
    @MainActor
    func test_eviction_never_reclaims_a_file_an_ingest_is_writing() throws {
        let (manager, store) = makeManager()
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        let inFlight = store.managedFilesDirectory.appendingPathComponent("ingest-in-progress")
        let orphan = store.managedFilesDirectory.appendingPathComponent("nobody-wants-this.bin")
        try Data(repeating: 1, count: 4_096).write(to: inFlight)
        try Data(repeating: 2, count: 4_096).write(to: orphan)

        manager.evictManagedCacheIfNeeded(
            budgetBytes: 1,
            reserving: [inFlight.resolvingSymlinksInPath().standardizedFileURL.path]
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inFlight.path),
            "eviction reclaimed a file an ingest was still writing"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "eviction stopped working — this test would pass for the wrong reason"
        )
    }
}

/// Escape has to reach the cancel from the state a drop actually lands in.
/// Files land on a collapsed pill far more often than on an expanded panel, and
/// the app's other Escape (`ShelfKey.command` → `.exit`) is only ever consulted
/// for an expanded one — which is how this repo previously shipped a shortcut
/// that was dead for a whole release.
final class IngestCancelKeyTests: XCTestCase {
    func test_escape_cancels_a_drop_that_is_still_landing() {
        XCTAssertTrue(ShelfKey.cancelsIngest(
            keyCode: ShelfKey.Code.escape, modifiers: [], isIngesting: true
        ))
    }

    /// Escape means "collapse the shelf" when nothing is arriving, so claiming
    /// it unconditionally would swallow the key everywhere.
    func test_escape_with_nothing_landing_is_left_alone() {
        XCTAssertFalse(ShelfKey.cancelsIngest(
            keyCode: ShelfKey.Code.escape, modifiers: [], isIngesting: false
        ))
    }

    func test_another_key_never_cancels_a_drop() {
        XCTAssertFalse(ShelfKey.cancelsIngest(
            keyCode: ShelfKey.Code.delete, modifiers: [], isIngesting: true
        ))
    }

    /// Caps Lock and the like ride along on every event, so only the four
    /// modifiers the app reads may disqualify the press.
    func test_a_modified_escape_is_not_the_cancel() {
        XCTAssertFalse(ShelfKey.cancelsIngest(
            keyCode: ShelfKey.Code.escape, modifiers: [.command], isIngesting: true
        ))
        XCTAssertTrue(ShelfKey.cancelsIngest(
            keyCode: ShelfKey.Code.escape, modifiers: [.capsLock], isIngesting: true
        ))
    }
}

/// One missing semicolon makes a whole `.strings` file fail to parse and every
/// string in that language falls back to its raw key — here, a panel-wide
/// overlay reading "ingest.importing" over the user's shelf.
final class IngestLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    func test_every_language_defines_the_ingest_string() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        for language in Self.languages {
            let strings = try XCTUnwrap(
                NSDictionary(contentsOf: resources
                    .appendingPathComponent("\(language).lproj")
                    .appendingPathComponent("Localizable.strings")) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            // `Cancel` is the overlay's other string and is keyed by its own
            // English text, so only the dotted key can be checked for having
            // been left as its key name.
            for key in ["ingest.importing", "Cancel"] {
                let value = strings[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
            XCTAssertNotEqual(
                strings["ingest.importing"], "ingest.importing",
                "\(language) left ingest.importing untranslated"
            )
        }
    }
}
