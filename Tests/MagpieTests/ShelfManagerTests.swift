import Combine
import Foundation
import XCTest
@testable import Magpie

final class ShelfManagerTests: XCTestCase {
    private var tempDir: URL!
    private var finderDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfManagerTests-\(UUID().uuidString)", isDirectory: true)
        finderDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("ShelfManagerFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: finderDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: finderDir)
    }

    @MainActor
    func test_add_file_appends_and_rejects_duplicate_once() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("dedupe.txt")
        try Data("one".utf8).write(to: fileURL)
        var rejected: [UUID] = []
        let cancellable = manager.duplicateRejected.sink { rejected.append($0) }
        defer { cancellable.cancel() }

        let first = manager.addFile(url: fileURL, to: shelfID)
        let second = manager.addFile(url: fileURL, to: shelfID)

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(manager.items(of: shelfID).count, 1)
        XCTAssertEqual(rejected, [shelfID])
    }

    @MainActor
    func test_rename_item_moves_file_and_updates_url() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let source = tempDir.appendingPathComponent("before.txt")
        let destination = tempDir.appendingPathComponent("after.txt")
        try Data("rename".utf8).write(to: source)
        let item = try XCTUnwrap(manager.addFile(url: source, to: shelfID))

        try manager.renameItem(id: item.id, to: destination, in: shelfID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(manager.items(of: shelfID).first?.fileURL, destination)
    }

    @MainActor
    func test_rename_item_throws_destination_exists_without_moving_source() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let source = tempDir.appendingPathComponent("source.txt")
        let destination = tempDir.appendingPathComponent("occupied.txt")
        try Data("source".utf8).write(to: source)
        try Data("occupied".utf8).write(to: destination)
        let item = try XCTUnwrap(manager.addFile(url: source, to: shelfID))

        XCTAssertThrowsError(
            try manager.renameItem(id: item.id, to: destination, in: shelfID)
        ) { error in
            guard let renameError = error as? ShelfManager.RenameError,
                  case .destinationExists(let url) = renameError else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
            XCTAssertEqual(url, destination)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(manager.items(of: shelfID).first?.fileURL, source)
    }

    @MainActor
    func test_rename_item_throws_source_missing() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let missing = tempDir.appendingPathComponent("missing.txt")
        let destination = tempDir.appendingPathComponent("unused.txt")
        let item = ShelfItem(type: .file, fileURL: missing)
        manager.addItem(item, to: shelfID)

        XCTAssertThrowsError(
            try manager.renameItem(id: item.id, to: destination, in: shelfID)
        ) { error in
            guard let renameError = error as? ShelfManager.RenameError,
                  case .sourceMissing(let url) = renameError else {
                return XCTFail("Expected sourceMissing, got \(error)")
            }
            XCTAssertEqual(url, missing)
        }
    }

    @MainActor
    func test_remove_clear_remove_shelf_and_expiry_delete_nothing_from_disk() throws {
        let store = ShelfStore(storeURL: finderDir.appendingPathComponent("no-delete.json"))
        let manager = ShelfManager(store: store)
        let shelfIDs = [try XCTUnwrap(manager.shelves.first?.id)]
            + (0..<3).map { _ in manager.createShelf() }
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        let files = try (0..<4).map { index -> URL in
            let url = store.managedFilesDirectory.appendingPathComponent("kept-\(index).txt")
            try Data("keep".utf8).write(to: url)
            manager.addItem(ShelfItem(
                type: .file,
                fileURL: url,
                createdAt: Date().addingTimeInterval(-3 * 86_400)
            ), to: shelfIDs[index])
            return url
        }

        manager.removeItem(id: try XCTUnwrap(manager.items(of: shelfIDs[0]).first?.id), from: shelfIDs[0])
        manager.clear(shelfID: shelfIDs[1])
        manager.removeShelf(id: shelfIDs[2])
        XCTAssertEqual(manager.pruneShelves(olderThanDays: 1), [shelfIDs[3]])

        for url in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    @MainActor
    func test_prune_exempts_pinned_shelf_and_its_files() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let ownedURL = tempDir.appendingPathComponent("pinned.txt")
        try Data("pinned".utf8).write(to: ownedURL)
        manager.addItem(
            ShelfItem(
                type: .file,
                fileURL: ownedURL,
                createdAt: Date().addingTimeInterval(-3 * 86_400)
            ),
            to: shelfID
        )
        manager.setShelfPinned(id: shelfID, true)

        XCTAssertTrue(manager.pruneShelves(olderThanDays: 1).isEmpty)
        XCTAssertNotNil(manager.shelf(id: shelfID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @MainActor
    func test_prune_keeps_external_file_that_happens_to_be_in_system_temp() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnrelatedProcess-\(UUID().uuidString).txt")
        try Data("external".utf8).write(to: externalURL)
        defer { try? FileManager.default.removeItem(at: externalURL) }
        manager.addItem(
            ShelfItem(
                type: .file,
                fileURL: externalURL,
                createdAt: Date().addingTimeInterval(-3 * 86_400)
            ),
            to: shelfID
        )

        _ = manager.pruneShelves(olderThanDays: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    @MainActor
    func test_prune_missing_files_keeps_unreachable_volume_item() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let deletedURL = finderDir.appendingPathComponent("deleted.txt")
        try Data("deleted".utf8).write(to: deletedURL)
        let deletedItem = ShelfItem(type: .file, fileURL: deletedURL)
        let offlineItem = ShelfItem(
            type: .file,
            fileURL: URL(fileURLWithPath: "/Volumes/Offline-\(UUID().uuidString)/kept.txt")
        )
        manager.addItem(deletedItem, to: shelfID)
        manager.addItem(offlineItem, to: shelfID)
        try FileManager.default.removeItem(at: deletedURL)

        let removed = manager.pruneMissingFiles()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(manager.items(of: shelfID), [offlineItem])
    }

    @MainActor
    func test_purgeable_file_ingest_is_copied_before_persistence() throws {
        let storeURL = finderDir.appendingPathComponent("persistent-shelf.json")
        let store = ShelfStore(storeURL: storeURL)
        let manager = ShelfManager(store: store)
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Promised-\(UUID().uuidString).txt")
        try Data("promised".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let item = try XCTUnwrap(manager.addFile(url: sourceURL, to: shelfID))
        let managedURL = try XCTUnwrap(item.fileURL)
        XCTAssertNil(manager.addFile(url: sourceURL, to: shelfID))
        store.save(shelves: manager.shelves, currentShelfID: shelfID)
        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertEqual(managedURL.deletingLastPathComponent(), store.managedFilesDirectory)
        XCTAssertEqual(store.managedFilesDirectory.lastPathComponent, "ManagedFiles")
        XCTAssertEqual(try Data(contentsOf: managedURL), Data("promised".utf8))
        let loadedItem = try XCTUnwrap(ShelfStore(storeURL: storeURL).load().shelves.first?.items.first)
        XCTAssertEqual(loadedItem.fileURL?.standardizedFileURL, managedURL.standardizedFileURL)
    }

    @MainActor
    func test_eviction_removes_oldest_unreferenced_but_nothing_outside_or_referenced() throws {
        let store = ShelfStore(storeURL: finderDir.appendingPathComponent("eviction-safety.json"))
        let manager = ShelfManager(store: store)
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        let referenced = store.managedFilesDirectory.appendingPathComponent("referenced.bin")
        let unresolved = store.managedFilesDirectory.appendingPathComponent("unresolved.bin")
        let oldest = store.managedFilesDirectory.appendingPathComponent("oldest.bin")
        let newer = store.managedFilesDirectory.appendingPathComponent("newer.bin")
        let outside = finderDir.appendingPathComponent("outside.bin")
        for url in [referenced, unresolved, oldest, newer] {
            try Data(repeating: 1, count: 6).write(to: url)
        }
        try Data(repeating: 3, count: 8).write(to: outside)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: newer.path
        )
        let link = store.managedFilesDirectory.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        manager.addItem(ShelfItem(type: .file, fileURL: referenced), to: shelfID)
        manager.addItem(ShelfItem(
            type: .file,
            bookmarkData: Data([1]),
            persistedPath: unresolved.path
        ), to: shelfID)

        manager.evictManagedCacheIfNeeded(budgetBytes: 18)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unresolved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))

        let symlinkParent = finderDir.appendingPathComponent("symlink-case", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkParent, withIntermediateDirectories: true
        )
        let symlinkStore = ShelfStore(
            storeURL: symlinkParent.appendingPathComponent("symlink-root.json")
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkStore.managedFilesDirectory,
            withDestinationURL: finderDir
        )
        let symlinkManager = ShelfManager(store: symlinkStore)
        symlinkManager.evictManagedCacheIfNeeded(budgetBytes: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    @MainActor
    func test_eviction_is_noop_after_non_authoritative_store_load() throws {
        let storeURL = finderDir.appendingPathComponent("failed-load.json")
        let store = ShelfStore(storeURL: storeURL)
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        let managedFile = store.managedFilesDirectory.appendingPathComponent("referenced.bin")
        let original = Data("still referenced".utf8)
        try original.write(to: managedFile)
        let shelfID = UUID()
        let payload: [String: Any] = [
            "version": ShelfStore.currentVersion,
            "shelves": [[
                "id": shelfID.uuidString,
                "createdAt": 0,
                "items": [
                    [
                        "id": UUID().uuidString,
                        "type": "file",
                        "path": managedFile.path,
                        "createdAt": 0,
                    ],
                    ["type": "file", "createdAt": 0],
                ],
            ]],
            "currentShelfID": shelfID.uuidString,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: storeURL)

        let manager = ShelfManager(store: store)
        manager.evictManagedCacheIfNeeded(budgetBytes: 0)

        XCTAssertEqual(try Data(contentsOf: managedFile), original)
    }

    /// Clear Cache in Settings. The scheduled eviction only fires past the
    /// 500 MB budget, so a Clear that merely re-ran it with the default budget
    /// would remove nothing and the button would be a lie — these files are a
    /// few bytes. And it must refuse exactly what the eviction refuses: the
    /// referenced copy, anything outside ManagedFiles, the symlink.
    @MainActor
    func test_clear_cache_removes_unreferenced_copies_under_budget_but_nothing_else() throws {
        let store = ShelfStore(storeURL: finderDir.appendingPathComponent("clear-cache.json"))
        let manager = ShelfManager(store: store)
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        let referenced = store.managedFilesDirectory.appendingPathComponent("still-shown.bin")
        let unreferenced = store.managedFilesDirectory.appendingPathComponent("stale-copy.bin")
        let outside = finderDir.appendingPathComponent("users-own.bin")
        for url in [referenced, unreferenced, outside] {
            try Data(repeating: 7, count: 6).write(to: url)
        }
        let link = store.managedFilesDirectory.appendingPathComponent("link-to-users-own")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        manager.addItem(ShelfItem(type: .file, fileURL: referenced), to: shelfID)

        manager.clearManagedCache()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unreferenced.path),
            "Clear Cache left an unreferenced managed copy behind — under the budget the button does nothing"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: referenced.path),
            "Clear Cache deleted a copy a shelf still shows"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path),
            "Clear Cache reached a file outside ManagedFiles"
        )
        XCTAssertTrue(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
            "Clear Cache followed or removed a symlink inside ManagedFiles"
        )
    }

    /// ADR 0001 §2: the eviction fails closed unless the store loaded an
    /// authoritative model, and Clear Cache is that same eviction, so a store
    /// this build could not interpret makes the button a no-op.
    @MainActor
    func test_clear_cache_is_a_noop_after_non_authoritative_store_load() throws {
        let storeURL = finderDir.appendingPathComponent("clear-failed-load.json")
        let store = ShelfStore(storeURL: storeURL)
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        let orphan = store.managedFilesDirectory.appendingPathComponent("orphan.bin")
        try Data("kept because the model is untrusted".utf8).write(to: orphan)
        try Data("not json".utf8).write(to: storeURL)

        let manager = ShelfManager(store: store)
        manager.clearManagedCache()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphan.path),
            "Clear Cache deleted from a cache whose reference set could not be trusted"
        )
    }

    /// The size Settings displays must count exactly the set the eviction
    /// governs: regular files directly inside ManagedFiles — not symlinks,
    /// not subdirectories, not anything outside.
    @MainActor
    func test_managed_cache_bytes_counts_exactly_what_eviction_governs() throws {
        let store = ShelfStore(storeURL: finderDir.appendingPathComponent("cache-size.json"))
        let manager = ShelfManager(store: store)
        try FileManager.default.createDirectory(
            at: store.managedFilesDirectory, withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 6).write(
            to: store.managedFilesDirectory.appendingPathComponent("a.bin")
        )
        try Data(repeating: 2, count: 8).write(
            to: store.managedFilesDirectory.appendingPathComponent("b.bin")
        )
        let outside = finderDir.appendingPathComponent("outside-size.bin")
        try Data(repeating: 3, count: 32).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: store.managedFilesDirectory.appendingPathComponent("size-link"),
            withDestinationURL: outside
        )
        let subdir = store.managedFilesDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 64).write(to: subdir.appendingPathComponent("deep.bin"))

        XCTAssertEqual(
            manager.managedCacheBytes(), 14,
            "the displayed cache size counts something the eviction does not govern"
        )

        manager.clearManagedCache()
        XCTAssertEqual(
            manager.managedCacheBytes(), 0,
            "after a clear with nothing referenced the display must read empty"
        )
    }

    @MainActor
    func test_reingest_changed_purgeable_source_refreshes_one_managed_copy() throws {
        let storeURL = finderDir.appendingPathComponent("managed-refresh.json")
        let store = ShelfStore(storeURL: storeURL)
        let manager = ShelfManager(store: store)
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedRefresh-\(UUID().uuidString).txt")
        try Data("version-1".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let firstItem = try XCTUnwrap(manager.addFile(url: sourceURL, to: shelfID))
        let managedURL = try XCTUnwrap(firstItem.fileURL)

        for version in 2...5 {
            let expected = Data("version-\(version)".utf8)
            try expected.write(to: sourceURL, options: .atomic)
            XCTAssertNil(manager.addFile(url: sourceURL, to: shelfID))
            XCTAssertEqual(try Data(contentsOf: managedURL), expected)
        }

        XCTAssertEqual(manager.items(of: shelfID).map(\.id), [firstItem.id])
        XCTAssertEqual(manager.items(of: shelfID).first?.fileURL, managedURL)
        let regularFiles = try FileManager.default.contentsOfDirectory(
            at: store.managedFilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        XCTAssertEqual(regularFiles.count, 1)
    }

    @MainActor
    func test_flush_pending_save_persists_latest_change_synchronously() throws {
        let storeURL = tempDir.appendingPathComponent("flush-shelf.json")
        let store = ShelfStore(storeURL: storeURL)
        let manager = ShelfManager(store: store)
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let item = ShelfItem(type: .text, textContent: "last-second change")
        manager.addItem(item, to: shelfID)

        manager.flushPendingSave()

        let loaded = ShelfStore(storeURL: storeURL).load()
        XCTAssertEqual(loaded.shelves.first?.items.first?.id, item.id)
        XCTAssertEqual(loaded.shelves.first?.items.first?.textContent, "last-second change")
    }

    @MainActor
    func test_application_will_terminate_invokes_flush_hook_once() {
        let manager = makeManager()
        var flushCount = 0
        let delegate = AppDelegate(
            manager: manager,
            flushOnTermination: { flushCount += 1 }
        )

        delegate.applicationWillTerminate(Notification(
            name: Notification.Name("ShelfManagerTests.applicationWillTerminate")
        ))

        XCTAssertEqual(flushCount, 1)
    }

    @MainActor
    func test_init_restores_persisted_current_shelf_instead_of_last_shelf() throws {
        let storeURL = tempDir.appendingPathComponent("active-shelf.json")
        let store = ShelfStore(storeURL: storeURL)
        let first = Shelf(name: "Active")
        let second = Shelf(name: "Last")
        store.save(shelves: [first, second], currentShelfID: first.id)

        let manager = ShelfManager(store: store)
        manager.renameShelf(id: second.id, to: "Changed")
        manager.flushPendingSave()

        XCTAssertEqual(manager.currentShelfID, first.id)
        XCTAssertEqual(ShelfStore(storeURL: storeURL).load().currentShelfID, first.id)
    }

    @MainActor
    func test_clear_then_undo_restores_items() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let items = [
            ShelfItem(type: .file),
            ShelfItem(type: .text, textContent: "undo text"),
        ]
        items.forEach { manager.addItem($0, to: shelfID) }

        manager.clear(shelfID: shelfID)
        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
        XCTAssertTrue(manager.canUndo)

        manager.performUndo()

        XCTAssertEqual(manager.items(of: shelfID), items)
        XCTAssertFalse(manager.canUndo)
    }

    @MainActor
    func test_move_to_trash_success_removes_row_and_undo_restores_file_and_item() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let originalURL = tempDir.appendingPathComponent("restore-me.txt")
        let trashedURL = tempDir.appendingPathComponent("simulated-trash.txt")
        try Data("restore".utf8).write(to: originalURL)
        let item = ShelfItem(type: .file, fileURL: originalURL)
        manager.addItem(item, to: shelfID)
        try FileManager.default.moveItem(at: originalURL, to: trashedURL)
        XCTAssertNil(manager.finishMoveToTrash(
            items: [item],
            trashedURLs: [originalURL: trashedURL],
            error: nil,
            in: shelfID
        ))
        XCTAssertTrue(manager.items(of: shelfID).isEmpty)

        manager.performUndo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashedURL.path))
        XCTAssertEqual(manager.items(of: shelfID), [item])
        XCTAssertFalse(manager.canUndo)
    }

    @MainActor
    func test_move_to_trash_partial_failure_keeps_failed_file_and_row() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let movedURL = tempDir.appendingPathComponent("trash-success.txt")
        let failedURL = tempDir.appendingPathComponent("trash-failure.txt")
        let trashURL = tempDir.appendingPathComponent("simulated-partial-trash.txt")
        try Data("move".utf8).write(to: movedURL)
        try Data("keep".utf8).write(to: failedURL)
        let moved = ShelfItem(type: .file, fileURL: movedURL)
        let failed = ShelfItem(type: .file, fileURL: failedURL)
        manager.addItem(moved, to: shelfID)
        manager.addItem(failed, to: shelfID)
        try FileManager.default.moveItem(at: movedURL, to: trashURL)

        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertNotNil(manager.finishMoveToTrash(
            items: [moved, failed],
            trashedURLs: [movedURL: trashURL],
            error: error,
            in: shelfID
        ))

        XCTAssertEqual(manager.items(of: shelfID), [failed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    /// A destination that really moved a file leaves a card pointing at
    /// nothing. Every drag surface — grid, list, and the collapsed stack that
    /// drags the whole shelf at once — funnels through this one door.
    @MainActor
    func test_moved_out_files_lose_their_cards_and_nothing_else_does() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let moved = tempDir.appendingPathComponent("moved.txt")
        let stayed = tempDir.appendingPathComponent("stayed.txt")
        try Data("moved".utf8).write(to: moved)
        try Data("stayed".utf8).write(to: stayed)
        XCTAssertNotNil(manager.addFile(url: moved, to: shelfID))
        XCTAssertNotNil(manager.addFile(url: stayed, to: shelfID))

        manager.removeItems(withFileURLs: [moved], from: shelfID)

        XCTAssertEqual(
            manager.items(of: shelfID).compactMap { $0.fileURL?.lastPathComponent },
            ["stayed.txt"],
            "the shelf did not drop the card for the file that left, or dropped one that stayed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stayed.path),
            "removing a card touched a file on disk — ADR 0001"
        )
    }

    @MainActor
    private func makeManager() -> ShelfManager {
        ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf-\(UUID().uuidString).json")
        ))
    }

    // MARK: - Undoable single-card removal

    /// ⌫ on a focused card became undoable when the keyboard model landed, but
    /// the tile's ✕ and the context-menu row did not, so ⌘Z meant different
    /// things depending on how the card was removed. Every deliberate
    /// single-card removal now goes through one door.
    @MainActor
    func test_removing_one_card_deliberately_is_undoable() throws {
        let manager = makeManager()
        let shelfID = manager.createShelf()
        let item = try XCTUnwrap(manager.addText("keep me", to: shelfID))
        XCTAssertEqual(manager.items(of: shelfID).count, 1)

        manager.removeItemUndoably(id: item.id, from: shelfID)
        XCTAssertTrue(manager.items(of: shelfID).isEmpty, "the card should be gone")

        manager.performUndo()
        XCTAssertEqual(
            manager.items(of: shelfID).map(\.id), [item.id],
            "⌘Z should put the card back, whichever way it was removed"
        )
    }

    /// The drag-out path is deliberately NOT undoable: after a real move the
    /// source file no longer exists, so restoring the card would restore a
    /// broken one pointing at a path that holds nothing.
    @MainActor
    func test_a_card_removed_because_its_file_moved_is_not_undoable() throws {
        let manager = makeManager()
        let shelfID = manager.createShelf()
        let item = try XCTUnwrap(manager.addText("moved away", to: shelfID))

        manager.removeItem(id: item.id, from: shelfID)
        manager.performUndo()
        XCTAssertTrue(
            manager.items(of: shelfID).isEmpty,
            "the plain primitive must not resurrect a card whose file has moved"
        )
    }

    // MARK: - Undo cannot resurrect a dead path

    /// A browser download lives in a purgeable temp dir, so ingest copies it
    /// into the managed cache. Clearing the shelf leaves that copy referenced
    /// only by the undo snapshot — which the eviction sweep does not count — so
    /// the next ingest over budget deletes it. ⌘Z must not put the card back
    /// pointing at a path that no longer resolves: drag-out, Open and Quick
    /// Look would all silently fail, and the next `pruneMissingFiles` sweep
    /// would delete the card a second time with no explanation.
    @MainActor
    func test_undo_does_not_restore_a_card_whose_managed_copy_was_evicted() throws {
        // The store lives outside the temp dir so ingest really makes a copy;
        // a source already inside the store directory is referenced in place.
        let manager = ShelfManager(store: ShelfStore(
            storeURL: finderDir.appendingPathComponent("shelf-\(UUID().uuidString).json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let downloaded = tempDir.appendingPathComponent("download.bin")
        try Data("payload".utf8).write(to: downloaded)
        let item = try XCTUnwrap(manager.addFile(url: downloaded, to: shelfID))
        let managedCopy = try XCTUnwrap(item.fileURL)
        XCTAssertNotEqual(
            managedCopy.path, downloaded.path, "ingest should have made a managed copy"
        )

        manager.clear(shelfID: shelfID)
        manager.evictManagedCacheIfNeeded(budgetBytes: 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: managedCopy.path),
            "a cleared shelf leaves the managed copy unreferenced, so eviction takes it"
        )

        manager.performUndo()

        XCTAssertTrue(
            manager.items(of: shelfID).isEmpty,
            "⌘Z resurrected a card pointing at \(managedCopy.path), which no longer exists"
        )
    }

    /// The snapshot names the shelf it restores into, so once that shelf is
    /// gone the undo can never land. The menu row stayed enabled and still read
    /// "Undo Clear Shelf", and pressing ⌘Z did nothing at all.
    @MainActor
    func test_undo_is_dropped_when_its_shelf_is_removed() throws {
        let manager = makeManager()
        let shelfID = manager.createShelf()
        manager.addItem(ShelfItem(type: .text, textContent: "gone"), to: shelfID)
        manager.clear(shelfID: shelfID)
        XCTAssertTrue(manager.canUndo)

        manager.removeShelf(id: shelfID)

        XCTAssertFalse(
            manager.canUndo,
            "the menu still offers an undo whose shelf no longer exists"
        )
        manager.performUndo()
        XCTAssertNil(manager.shelf(id: shelfID), "undo must not recreate a deleted shelf")
    }

    /// Same hole via the other door: shelf expiry.
    @MainActor
    func test_undo_is_dropped_when_its_shelf_expires() throws {
        let storeURL = tempDir.appendingPathComponent("expiry-\(UUID().uuidString).json")
        let store = ShelfStore(storeURL: storeURL)
        let stale = Shelf(createdAt: Date().addingTimeInterval(-10 * 86_400))
        store.save(shelves: [stale], currentShelfID: stale.id)
        let manager = ShelfManager(store: store)
        manager.addItem(ShelfItem(type: .text, textContent: "gone"), to: stale.id)
        manager.clear(shelfID: stale.id)
        XCTAssertTrue(manager.canUndo)

        XCTAssertEqual(manager.pruneShelves(olderThanDays: 7), [stale.id])

        XCTAssertFalse(
            manager.canUndo,
            "the menu still offers an undo whose shelf was expired away"
        )
    }

    // MARK: - Undo depth

    /// One snapshot meant a run of ✕ clicks left only the last one reversible.
    /// The stack is capped at three on purpose: ⌘Z is global across shelves, so
    /// a deep history means firing blind into a shelf that may not be on screen.
    @MainActor
    func test_the_last_three_removals_undo_in_reverse_order_and_no_more() throws {
        let manager = makeManager()
        let shelfID = manager.createShelf()
        let cards = try (0..<4).map { i in
            try XCTUnwrap(manager.addText("card \(i)", to: shelfID))
        }
        cards.forEach { manager.removeItemUndoably(id: $0.id, from: shelfID) }
        XCTAssertTrue(manager.items(of: shelfID).isEmpty)

        manager.performUndo()
        manager.performUndo()
        manager.performUndo()

        XCTAssertEqual(
            manager.items(of: shelfID).map(\.id),
            [cards[3].id, cards[2].id, cards[1].id],
            "three ⌘Z presses should return the last three cards, most recent first"
        )
        XCTAssertFalse(manager.canUndo, "the stack must not hold a fourth")
        manager.performUndo()
        XCTAssertEqual(
            manager.items(of: shelfID).count, 3, "a fourth ⌘Z must do nothing"
        )
    }

    // MARK: - Clear All Shelves (undoable)

    /// "Clear Recent Shelves" used to be the one action that was both
    /// unconfirmed and unrecoverable: it removed every unpinned shelf, and
    /// `removeShelf` purged the very undo entries that could have brought the
    /// contents back. The bulk clear now records one whole-shelf snapshot, so
    /// ⌘Z restores the shelves themselves — items, names, accents and all.
    @MainActor
    func test_clear_all_removes_unpinned_only_and_undo_restores_them_whole() throws {
        let manager = makeManager()
        let keepID = manager.createShelf()
        manager.setShelfPinned(id: keepID, true)
        let goneID = manager.createShelf()
        manager.renameShelf(id: goneID, to: "Receipts")
        manager.setShelfAccent(id: goneID, .emoji("🧾"))
        let card = try XCTUnwrap(manager.addText("kept text", to: goneID))
        manager.setCurrentShelf(id: goneID)
        let firstShelfID = try XCTUnwrap(manager.shelves.first?.id)

        let removed = manager.clearAllUnpinnedShelvesUndoably()

        XCTAssertEqual(Set(removed), [firstShelfID, goneID])
        XCTAssertEqual(manager.shelves.map(\.id), [keepID], "pinned shelves must survive a bulk clear")
        XCTAssertTrue(manager.canUndo, "the bulk clear must leave a way back")
        XCTAssertEqual(
            manager.undoSnapshot?.menuTitle, L("undo.clear-all-shelves"),
            "⌘Z must say it reverses the bulk clear, not some older action"
        )

        manager.performUndo()

        let restored = try XCTUnwrap(manager.shelf(id: goneID), "undo must restore the removed shelf itself")
        XCTAssertEqual(restored.name, "Receipts", "the shelf must come back with its name")
        XCTAssertEqual(restored.accent, .emoji("🧾"), "the shelf must come back with its accent")
        XCTAssertEqual(restored.items.map(\.id), [card.id], "the shelf must come back with its items")
        XCTAssertNotNil(manager.shelf(id: firstShelfID))
        XCTAssertEqual(
            manager.currentShelfID, goneID,
            "undo must also restore which shelf was current"
        )
    }

    /// The whole-shelf snapshot survives `removeShelf`'s per-shelf purge on
    /// purpose: it restores its shelves rather than into them, so it depends
    /// on no live shelf. Purging it alongside the per-shelf entries would
    /// recreate the original bug with one extra step.
    @MainActor
    func test_clear_all_undo_entry_replaces_the_per_shelf_entries_it_orphans() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        manager.addItem(ShelfItem(type: .text, textContent: "cleared"), to: shelfID)
        manager.clear(shelfID: shelfID)
        XCTAssertEqual(manager.undoStack.count, 1, "precondition: a per-shelf entry exists")

        manager.clearAllUnpinnedShelvesUndoably()

        XCTAssertEqual(
            manager.undoStack.count, 1,
            "the orphaned per-shelf entry must be gone and only the bulk entry remain"
        )
        XCTAssertEqual(manager.undoSnapshot?.menuTitle, L("undo.clear-all-shelves"))
    }

    /// Same rule as every other restore: a card whose backing file vanished
    /// while the shelves were gone must not come back live-but-broken — but
    /// the shelf itself still returns, because the shelf was the thing removed.
    @MainActor
    func test_clear_all_undo_drops_cards_whose_file_is_gone_but_keeps_the_shelf() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = finderDir.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: fileURL)
        _ = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))

        manager.clearAllUnpinnedShelvesUndoably()
        let backing = try XCTUnwrap(
            manager.undoSnapshot?.items.first?.fileURL,
            "the snapshot must carry the card's resolved URL"
        )
        try FileManager.default.removeItem(at: backing)

        manager.performUndo()

        let restored = try XCTUnwrap(manager.shelf(id: shelfID))
        XCTAssertTrue(
            restored.items.isEmpty,
            "a restored card would point at \(backing.path), which no longer exists"
        )
    }

    /// Nothing unpinned means nothing to clear: no removal, and no undo entry
    /// claiming something happened.
    @MainActor
    func test_clear_all_with_only_pinned_shelves_is_a_no_op() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        manager.setShelfPinned(id: shelfID, true)

        XCTAssertEqual(manager.clearAllUnpinnedShelvesUndoably(), [])

        XCTAssertEqual(manager.shelves.map(\.id), [shelfID])
        XCTAssertFalse(manager.canUndo, "an action that removed nothing must not offer an undo")
    }
}
