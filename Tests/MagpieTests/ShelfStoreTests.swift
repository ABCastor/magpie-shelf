import Foundation
import XCTest
@testable import Magpie

final class ShelfStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        storeURL = tempDir.appendingPathComponent("shelf.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_file_round_trip_preserves_identity_type_date_and_resolved_path() throws {
        let fileURL = tempDir.appendingPathComponent("document.bin")
        try Data([1, 2, 3]).write(to: fileURL)
        let itemID = UUID()
        let shelfID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 123_456)
        let store = ShelfStore(storeURL: storeURL)

        store.save(
            shelves: [Shelf(
                id: shelfID,
                items: [ShelfItem(
                    id: itemID,
                    type: .file,
                    fileURL: fileURL,
                    createdAt: createdAt
                )],
                createdAt: createdAt
            )],
            currentShelfID: shelfID
        )

        let loaded = store.load()
        let item = try XCTUnwrap(loaded.shelves.first?.items.first)
        XCTAssertEqual(loaded.currentShelfID, shelfID)
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.type, .file)
        XCTAssertEqual(item.createdAt, createdAt)
        XCTAssertEqual(
            item.fileURL?.resolvingSymlinksInPath().standardizedFileURL.path,
            fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func test_text_round_trip_omits_bookmark_and_restages_original_contents() throws {
        let text = "Shelf snippet \(UUID().uuidString)\nSecond line"
        let originalURL = try XCTUnwrap(ShelfItem.writeTextToTemp(text))
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let itemID = UUID()
        let store = ShelfStore(storeURL: storeURL)

        store.save(
            shelves: [Shelf(items: [ShelfItem(
                id: itemID,
                type: .text,
                fileURL: originalURL,
                textContent: text
            )])],
            currentShelfID: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let shelves = try XCTUnwrap(object["shelves"] as? [[String: Any]])
        let records = try XCTUnwrap(shelves.first?["items"] as? [[String: Any]])
        XCTAssertNil(records.first?["bookmark"])

        let loaded = try XCTUnwrap(store.load().shelves.first?.items.first)
        let restagedURL = try XCTUnwrap(loaded.fileURL)
        XCTAssertEqual(loaded.id, itemID)
        XCTAssertEqual(loaded.type, .text)
        XCTAssertEqual(loaded.textContent, text)
        XCTAssertEqual(try String(contentsOf: restagedURL, encoding: .utf8), text)
    }

    func test_load_retains_unresolved_bookmark_when_backing_file_was_deleted() throws {
        let fileURL = tempDir.appendingPathComponent("deleted-after-save.dat")
        try Data([4, 5, 6]).write(to: fileURL)
        let shelfID = UUID()
        let store = ShelfStore(storeURL: storeURL)
        store.save(
            shelves: [Shelf(
                id: shelfID,
                items: [ShelfItem(type: .file, fileURL: fileURL)]
            )],
            currentShelfID: shelfID
        )
        try FileManager.default.removeItem(at: fileURL)

        let item = try XCTUnwrap(store.load().shelves.first?.items.first)
        XCTAssertNil(item.fileURL)
        XCTAssertNotNil(item.bookmarkData)
        XCTAssertEqual(item.persistedPath, fileURL.path)
    }

    func test_load_keeps_item_when_parent_volume_is_unreachable() throws {
        let simulatedVolume = tempDir.appendingPathComponent("OfflineVolume", isDirectory: true)
        try FileManager.default.createDirectory(
            at: simulatedVolume, withIntermediateDirectories: true
        )
        let fileURL = simulatedVolume.appendingPathComponent("keep.dat")
        try Data([7, 8, 9]).write(to: fileURL)
        let shelfID = UUID()
        let itemID = UUID()
        let store = ShelfStore(storeURL: storeURL)
        store.save(
            shelves: [Shelf(
                id: shelfID,
                items: [ShelfItem(id: itemID, type: .file, fileURL: fileURL)]
            )],
            currentShelfID: shelfID
        )
        try FileManager.default.removeItem(at: simulatedVolume)

        let loaded = store.load()

        let item = try XCTUnwrap(loaded.shelves.first?.items.first)
        XCTAssertEqual(item.id, itemID)
        XCTAssertNil(item.fileURL)
        XCTAssertNotNil(item.bookmarkData)
        XCTAssertEqual(item.persistedPath, fileURL.path)
    }

    func test_newer_schema_is_not_overwritten() throws {
        let shelfID = UUID()
        let futurePayload: [String: Any] = [
            "version": 999,
            "shelves": [[
                "id": shelfID.uuidString,
                "createdAt": Date(timeIntervalSinceReferenceDate: 42)
                    .timeIntervalSinceReferenceDate,
                "items": [[
                    "id": UUID().uuidString,
                    "type": "future-file",
                    "createdAt": Date(timeIntervalSinceReferenceDate: 42)
                        .timeIntervalSinceReferenceDate,
                    "futureLocator": "preserve-me",
                ]],
                "futureShelfField": "preserve-me",
            ]],
            "currentShelfID": shelfID.uuidString,
            "futureTopLevelField": ["also": "preserve-me"],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: futurePayload)
        try originalData.write(to: storeURL)
        let store = ShelfStore(storeURL: storeURL)

        _ = store.load()
        store.save(shelves: [Shelf()], currentShelfID: nil)

        XCTAssertEqual(try Data(contentsOf: storeURL), originalData)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix("shelf.corrupt-") })
    }

    func test_version_two_payload_defaults_name_to_nil_and_pinned_to_false() throws {
        let shelfID = UUID()
        let payload: [String: Any] = [
            "version": 2,
            "shelves": [[
                "id": shelfID.uuidString,
                "createdAt": Date(timeIntervalSinceReferenceDate: 42)
                    .timeIntervalSinceReferenceDate,
                "items": [],
            ]],
            "currentShelfID": shelfID.uuidString,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: storeURL)

        let loaded = ShelfStore(storeURL: storeURL).load()
        let shelf = try XCTUnwrap(loaded.shelves.first)

        XCTAssertEqual(shelf.id, shelfID)
        XCTAssertNil(shelf.name)
        XCTAssertFalse(shelf.pinned)
        XCTAssertEqual(loaded.currentShelfID, shelfID)
    }

    func test_corrupt_json_is_backed_up_before_fresh_store_can_be_saved() throws {
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: storeURL)
        let store = ShelfStore(storeURL: storeURL)

        let loaded = store.load()

        XCTAssertTrue(loaded.shelves.isEmpty)
        XCTAssertNil(loaded.currentShelfID)
        let backups = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("shelf.corrupt-")
                && $0.pathExtension == "json"
        }
        let backupURL = try XCTUnwrap(backups.only)
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        let shelfID = UUID()
        store.save(
            shelves: [Shelf(id: shelfID, items: [ShelfItem(
                type: .text,
                textContent: "after recovery"
            )])],
            currentShelfID: shelfID
        )

        let reloaded = ShelfStore(storeURL: storeURL).load()
        XCTAssertEqual(reloaded.currentShelfID, shelfID)
        XCTAssertEqual(reloaded.shelves.first?.items.first?.textContent, "after recovery")
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
    }

    func test_uninterpretable_record_quarantines_original_before_reduced_save() throws {
        let shelfID = UUID()
        let originalData = try writePayload(shelfID: shelfID, items: [
            record(type: "text", text: "recoverable"),
            record(type: "file"),
        ])

        let loaded = ShelfStore(storeURL: storeURL).load()

        XCTAssertEqual(loaded.shelves.first?.items.map(\.textContent), ["recoverable"])
        let backups = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("shelf.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), originalData)
        XCTAssertEqual(
            ShelfStore(storeURL: storeURL).load().shelves.first?.items.map(\.textContent),
            ["recoverable"]
        )
    }

    func test_version_three_bookmark_only_item_survives_migrate_save_reload() throws {
        let fileURL = tempDir.appendingPathComponent("bookmark-only.dat")
        try Data([9, 8, 7]).write(to: fileURL)
        let bookmark = try fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let shelfID = UUID()
        let itemID = UUID()
        try writeVersionThreePayload(bookmark: bookmark, shelfID: shelfID, itemID: itemID)
        let store = ShelfStore(storeURL: storeURL)

        let migrated = store.load()
        store.save(shelves: migrated.shelves, currentShelfID: migrated.currentShelfID)
        let reloaded = ShelfStore(storeURL: storeURL).load()

        let item = try XCTUnwrap(reloaded.shelves.first?.items.first)
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.type, .file)
        XCTAssertEqual(item.fileURL?.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertNotNil(item.bookmarkData)
    }

    func test_unresolved_version_three_bookmark_is_retained_and_store_stays_writable() throws {
        let fileURL = tempDir.appendingPathComponent("offline-bookmark.dat")
        try Data([1, 3, 5]).write(to: fileURL)
        let bookmark = try fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let shelfID = UUID()
        let itemID = UUID()
        try writeVersionThreePayload(bookmark: bookmark, shelfID: shelfID, itemID: itemID)
        let resolver: ShelfStore.BookmarkResolver = { _ in (nil, false) }
        let store = ShelfStore(storeURL: storeURL, bookmarkResolver: resolver)

        let loaded = store.load()
        let offlineItem = try XCTUnwrap(loaded.shelves.first?.items.first)
        XCTAssertEqual(offlineItem.id, itemID)
        XCTAssertNil(offlineItem.fileURL)
        XCTAssertEqual(offlineItem.bookmarkData, bookmark)

        let addedShelf = Shelf(items: [ShelfItem(type: .text, textContent: "still writable")])
        store.save(
            shelves: loaded.shelves + [addedShelf],
            currentShelfID: addedShelf.id
        )
        let reloaded = ShelfStore(storeURL: storeURL, bookmarkResolver: resolver).load()

        XCTAssertEqual(reloaded.shelves.count, 2)
        XCTAssertEqual(reloaded.shelves.first?.items.first?.id, itemID)
        XCTAssertEqual(reloaded.shelves.first?.items.first?.bookmarkData, bookmark)
        XCTAssertEqual(reloaded.shelves.last?.items.first?.textContent, "still writable")
        XCTAssertEqual(reloaded.currentShelfID, addedShelf.id)
    }

    func test_transient_bookmark_failure_does_not_rebind_stale_path() throws {
        let bookmarkTarget = tempDir.appendingPathComponent("bookmark-target.dat")
        let stalePath = tempDir.appendingPathComponent("reused-path.dat")
        try Data("original".utf8).write(to: bookmarkTarget)
        try Data("different file".utf8).write(to: stalePath)
        let bookmark = try bookmarkTarget.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let shelfID = UUID()
        let itemID = UUID()
        let missingItemID = UUID()
        let missingPath = tempDir.appendingPathComponent("missing-stale-path.dat")
        try writePayload(shelfID: shelfID, items: [
            record(id: itemID, type: "file", bookmark: bookmark, path: stalePath.path),
            record(id: missingItemID, type: "file", bookmark: bookmark, path: missingPath.path),
        ])
        let resolver: ShelfStore.BookmarkResolver = { _ in (nil, false) }
        let store = ShelfStore(storeURL: storeURL, bookmarkResolver: resolver)

        let loaded = store.load()
        let items = try XCTUnwrap(loaded.shelves.first?.items)

        XCTAssertEqual(items.map(\.id), [itemID, missingItemID])
        XCTAssertTrue(items.allSatisfy { $0.fileURL == nil && $0.bookmarkData == bookmark })
        XCTAssertEqual(items.map(\.persistedPath), [stalePath.path, missingPath.path])
        store.save(shelves: loaded.shelves, currentShelfID: shelfID)
        XCTAssertNil(
            ShelfStore(storeURL: storeURL, bookmarkResolver: resolver)
                .load().shelves.first?.items.first?.fileURL
        )
    }

    func test_random_file_text_and_image_mix_round_trips_structurally() throws {
        var generator = SeededGenerator(seed: 0x5EED_CAFE)
        let store = ShelfStore(storeURL: storeURL)

        for iteration in 0..<20 {
            let count = Int.random(in: 1...30, using: &generator)
            var expected: [ShelfItem] = []
            for index in 0..<count {
                let kind = Int.random(in: 0...2, using: &generator)
                let id = UUID()
                switch kind {
                case 0:
                    let url = tempDir.appendingPathComponent("\(iteration)-\(index).bin")
                    try Data([UInt8(truncatingIfNeeded: index)]).write(to: url)
                    expected.append(ShelfItem(id: id, type: .file, fileURL: url))
                case 1:
                    let text = "random-snippet-\(iteration)-\(index)-\(generator.next())"
                    expected.append(ShelfItem(id: id, type: .text, textContent: text))
                default:
                    let url = tempDir.appendingPathComponent("\(iteration)-\(index).png")
                    try Data([UInt8(truncatingIfNeeded: index)]).write(to: url)
                    expected.append(ShelfItem(id: id, type: .image, fileURL: url))
                }
            }
            let shelfID = UUID()
            store.save(
                shelves: [Shelf(id: shelfID, items: expected)],
                currentShelfID: shelfID
            )

            let actual = try XCTUnwrap(store.load().shelves.first).items

            XCTAssertEqual(actual.map(\.id), expected.map(\.id))
            XCTAssertEqual(actual.map(\.type), expected.map(\.type))
            XCTAssertEqual(actual.map(\.textContent), expected.map(\.textContent))
            for item in actual where item.type == .text {
                if let url = item.fileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - What the load has to be able to say out loud

    func test_healthy_load_reports_healthy_and_stays_authoritative() throws {
        let shelfID = UUID()
        try writePayload(shelfID: shelfID, items: [record(type: "text", text: "kept")])

        let loaded = ShelfStore(storeURL: storeURL).load()

        XCTAssertEqual(loaded.outcome, .healthy)
        XCTAssertTrue(loaded.isAuthoritative)
    }

    func test_absent_store_reports_healthy_rather_than_a_failure() {
        let loaded = ShelfStore(storeURL: storeURL).load()

        XCTAssertEqual(loaded.outcome, .healthy)
        XCTAssertTrue(loaded.isAuthoritative)
    }

    /// The alert has to be able to point at the preserved bytes, so the outcome
    /// carries the file rather than only the fact.
    func test_corrupt_store_reports_quarantined_and_names_the_preserved_file() throws {
        try Data("{not-json".utf8).write(to: storeURL)

        let loaded = ShelfStore(storeURL: storeURL).load()

        guard case .quarantined(let preserved) = loaded.outcome else {
            return XCTFail("expected .quarantined, got \(loaded.outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertTrue(preserved.lastPathComponent.hasPrefix("shelf.corrupt-"))
        XCTAssertFalse(loaded.isAuthoritative)
    }

    /// The partial-recovery path: readable shelves came back, the original was
    /// still set aside, and that is what the user has to be told.
    func test_uninterpretable_record_reports_quarantined() throws {
        try writePayload(shelfID: UUID(), items: [
            record(type: "text", text: "recoverable"),
            record(type: "file"),
        ])

        let loaded = ShelfStore(storeURL: storeURL).load()

        guard case .quarantined(let preserved) = loaded.outcome else {
            return XCTFail("expected .quarantined, got \(loaded.outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertFalse(loaded.isAuthoritative)
    }

    /// Nothing will ever save again while this build runs, which is a different
    /// sentence from "your file was damaged" — and it must never be quarantined.
    func test_newer_schema_reports_read_only_and_is_not_quarantined() throws {
        try writePayload(
            version: ShelfStore.currentVersion + 1,
            shelfID: UUID(),
            items: []
        )

        let loaded = ShelfStore(storeURL: storeURL).load()

        XCTAssertEqual(loaded.outcome, .readOnlyNewerSchema)
        XCTAssertFalse(loaded.isAuthoritative)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix("shelf.corrupt-") })
    }

    /// Bytes from a newer build that also do not decode: still the newer-schema
    /// sentence, and still no quarantine, because moving a store this build
    /// cannot interpret is the one thing that would lose the user's shelves.
    func test_undecodable_newer_schema_still_reports_read_only() throws {
        let payload: [String: Any] = [
            "version": ShelfStore.currentVersion + 1,
            "shelves": "not-an-array",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: storeURL)

        let loaded = ShelfStore(storeURL: storeURL).load()

        XCTAssertEqual(loaded.outcome, .readOnlyNewerSchema)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    /// A directory where the store should be: unreadable, and nothing to set
    /// aside. The honest answer is neither "damaged" nor "newer".
    func test_unreadable_store_reports_unreadable() throws {
        try FileManager.default.createDirectory(
            at: storeURL, withIntermediateDirectories: true
        )

        let loaded = ShelfStore(storeURL: storeURL).load()

        XCTAssertEqual(loaded.outcome, .unreadable)
        XCTAssertFalse(loaded.isAuthoritative)
    }

    // MARK: - Speaking once per event, not once per launch

    func test_healthy_outcome_never_speaks() {
        XCTAssertFalse(StoreOutcomeNotice.shouldPresent(.healthy, lastReported: nil))
    }

    /// The nag case. A newer-schema store stays newer forever, so an
    /// unconditional alert would fire at every single login.
    func test_read_only_speaks_once_and_is_silent_at_the_next_launch() {
        let outcome = ShelfStore.LoadOutcome.readOnlyNewerSchema
        XCTAssertTrue(StoreOutcomeNotice.shouldPresent(outcome, lastReported: nil))

        let reported = StoreOutcomeNotice.signature(for: outcome)
        XCTAssertFalse(StoreOutcomeNotice.shouldPresent(outcome, lastReported: reported))
    }

    func test_a_second_different_quarantine_speaks_again() {
        let first = ShelfStore.LoadOutcome.quarantined(
            preservedAt: tempDir.appendingPathComponent("shelf.corrupt-1.json")
        )
        let second = ShelfStore.LoadOutcome.quarantined(
            preservedAt: tempDir.appendingPathComponent("shelf.corrupt-2.json")
        )
        let reported = StoreOutcomeNotice.signature(for: first)

        XCTAssertFalse(StoreOutcomeNotice.shouldPresent(first, lastReported: reported))
        XCTAssertTrue(StoreOutcomeNotice.shouldPresent(second, lastReported: reported))
    }

    /// Two different failures are two different events; the second must not be
    /// swallowed as "already reported".
    func test_a_different_failure_after_one_reported_speaks() {
        let reported = StoreOutcomeNotice.signature(for: .readOnlyNewerSchema)

        XCTAssertTrue(StoreOutcomeNotice.shouldPresent(.unreadable, lastReported: reported))
    }

    private func writeVersionThreePayload(
        bookmark: Data,
        shelfID: UUID,
        itemID: UUID
    ) throws {
        try writePayload(
            version: 3,
            shelfID: shelfID,
            items: [record(id: itemID, type: "file", bookmark: bookmark)]
        )
    }

    @discardableResult
    private func writePayload(
        version: Int = ShelfStore.currentVersion,
        shelfID: UUID,
        items: [[String: Any]]
    ) throws -> Data {
        let createdAt = Date(timeIntervalSinceReferenceDate: 42)
        let payload: [String: Any] = [
            "version": version,
            "shelves": [[
                "id": shelfID.uuidString,
                "createdAt": createdAt.timeIntervalSinceReferenceDate,
                "items": items,
            ]],
            "currentShelfID": shelfID.uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: storeURL)
        return data
    }

    private func record(
        id: UUID = UUID(),
        type: String,
        bookmark: Data? = nil,
        path: String? = nil,
        text: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id.uuidString,
            "type": type,
            "createdAt": Date(timeIntervalSinceReferenceDate: 42).timeIntervalSinceReferenceDate,
        ]
        if let bookmark { value["bookmark"] = bookmark.base64EncodedString() }
        if let path { value["path"] = path }
        if let text { value["text"] = text }
        return value
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
