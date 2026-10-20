import Combine
import Foundation
import XCTest
@testable import Magpie

/// The app sits idle on a laptop all day. A sweep that republishes the model
/// when it removed nothing, a save that re-decodes the store to ask whether it
/// may write, and a bookmark minted per item per save all turn "idle" into a
/// permanent write loop. These pin the absence of each.
final class IdleWriteEconomyTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdleWriteEconomyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("shelf.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The sweep

    func test_pruning_returns_nil_when_nothing_is_missing() {
        let shelves = [Shelf(items: [
            ShelfItem(type: .file, fileURL: tempDir.appendingPathComponent("a.txt")),
            ShelfItem(type: .text, textContent: "no file at all"),
        ])]

        XCTAssertNil(ShelfManager.pruningMissingFiles(from: shelves, isMissing: { _ in false }))
    }

    func test_pruning_drops_only_the_missing_and_always_keeps_text() throws {
        let goneURL = tempDir.appendingPathComponent("gone.txt")
        let keptURL = tempDir.appendingPathComponent("kept.txt")
        let text = ShelfItem(type: .text, textContent: "kept")
        let shelves = [Shelf(items: [
            ShelfItem(type: .file, fileURL: goneURL),
            ShelfItem(type: .file, fileURL: keptURL),
            text,
        ])]

        let result = try XCTUnwrap(ShelfManager.pruningMissingFiles(from: shelves) {
            $0.path == goneURL.path
        })

        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.shelves.first?.items.map(\.fileURL), [keptURL, nil])
        XCTAssertEqual(result.shelves.first?.items.last?.id, text.id)
    }

    @MainActor
    func test_sweep_republishes_the_model_only_when_it_removed_something() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("present.txt")
        try Data("present".utf8).write(to: fileURL)
        manager.addItem(ShelfItem(type: .file, fileURL: fileURL), to: shelfID)

        var publishes = 0
        let cancellable = manager.$shelves.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        // Ten idle ticks over a shelf whose files are all still there.
        for _ in 0..<10 {
            XCTAssertEqual(manager.pruneMissingFiles(), 0)
        }
        XCTAssertEqual(publishes, 0, "an idle sweep republished the model")

        try FileManager.default.removeItem(at: fileURL)

        XCTAssertEqual(manager.pruneMissingFiles(), 1)
        XCTAssertEqual(publishes, 1)
        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
    }

    // MARK: - The save path

    func test_saves_after_a_load_never_re_read_and_decode_the_store() throws {
        let shelfID = UUID()
        ShelfStore(storeURL: storeURL).save(shelves: [Shelf(id: shelfID)], currentShelfID: shelfID)
        let store = ShelfStore(storeURL: storeURL)

        _ = store.load()
        XCTAssertEqual(store.storeInspectionCount, 0, "load did not record what it learned")
        for index in 0..<10 {
            store.save(
                shelves: [Shelf(id: shelfID, items: [
                    ShelfItem(type: .text, textContent: "write \(index)"),
                ])],
                currentShelfID: shelfID
            )
        }

        XCTAssertEqual(store.storeInspectionCount, 0, "the save path re-decoded the store")
        XCTAssertEqual(
            ShelfStore(storeURL: storeURL).load().shelves.first?.items.first?.textContent,
            "write 9"
        )
    }

    /// The cached verdict must not become a way to clobber a store this build
    /// cannot interpret. A newer schema appearing *after* the load — which is
    /// the only way one can appear at all, since it comes from another process
    /// — is still refused.
    func test_newer_schema_written_after_load_is_still_not_overwritten() throws {
        let store = ShelfStore(storeURL: storeURL)
        _ = store.load()
        store.save(shelves: [Shelf(items: [
            ShelfItem(type: .text, textContent: "ours"),
        ])], currentShelfID: nil)
        let futureData = try JSONSerialization.data(withJSONObject: [
            "version": ShelfStore.currentVersion + 1,
            "shelves": [],
            "currentShelfID": NSNull(),
            "futureTopLevelField": "preserve-me",
        ])
        try futureData.write(to: storeURL)

        store.save(shelves: [Shelf(items: [
            ShelfItem(type: .text, textContent: "must not land"),
        ])], currentShelfID: nil)

        XCTAssertEqual(try Data(contentsOf: storeURL), futureData)
    }

    // MARK: - Bookmarks

    func test_bookmark_is_minted_once_per_item_across_repeated_saves() throws {
        let fileURL = tempDir.appendingPathComponent("stable.dat")
        try Data([1, 2, 3]).write(to: fileURL)
        var minted: [String] = []
        let store = ShelfStore(storeURL: storeURL, bookmarkMaker: { url in
            minted.append(url.path)
            return Data("bookmark-for-\(url.path)".utf8)
        })
        let item = ShelfItem(type: .file, fileURL: fileURL)
        let shelfID = UUID()

        for _ in 0..<5 {
            store.save(shelves: [Shelf(id: shelfID, items: [item])], currentShelfID: shelfID)
        }

        XCTAssertEqual(minted, [fileURL.path])
    }

    func test_bookmark_is_minted_again_when_the_item_moves() throws {
        let firstURL = tempDir.appendingPathComponent("before.dat")
        let secondURL = tempDir.appendingPathComponent("after.dat")
        try Data([1]).write(to: firstURL)
        try Data([2]).write(to: secondURL)
        var minted: [String] = []
        let store = ShelfStore(storeURL: storeURL, bookmarkMaker: { url in
            minted.append(url.path)
            return Data("bookmark-for-\(url.path)".utf8)
        })
        let itemID = UUID()
        let shelfID = UUID()

        store.save(
            shelves: [Shelf(id: shelfID, items: [
                ShelfItem(id: itemID, type: .file, fileURL: firstURL),
            ])],
            currentShelfID: shelfID
        )
        // What `renameItem` produces: a new location with the old bookmark cleared.
        store.save(
            shelves: [Shelf(id: shelfID, items: [
                ShelfItem(id: itemID, type: .file, fileURL: secondURL),
            ])],
            currentShelfID: shelfID
        )

        XCTAssertEqual(minted, [firstURL.path, secondURL.path])
    }

    @MainActor
    private func makeManager() -> ShelfManager {
        ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("manager-\(UUID().uuidString).json")
        ))
    }
}
