import AppKit
import XCTest
@testable import Magpie

/// "Send to Claude for Filing" used to appear for everyone with files on a
/// shelf, whether or not Claude was installed. For a stranger without it the
/// row was a dead end naming a product they may not have — and clicking it
/// staged a copy of their files into a drop folder before discovering there
/// was nowhere to send them. The row is now gated on availability by a pure
/// predicate both menu surfaces call.
@MainActor
final class HandoffMenuTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandoffMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The predicate

    func test_no_claude_means_no_row_even_with_files_to_send() {
        XCTAssertEqual(
            HandoffMenu.row(claudeInstalled: false, hasSendableFiles: true), .absent,
            "the row names a product that is not on this Mac"
        )
        XCTAssertEqual(
            HandoffMenu.row(claudeInstalled: false, hasSendableFiles: false), .absent
        )
    }

    func test_claude_with_nothing_sendable_greys_the_row_rather_than_hiding_it() {
        XCTAssertEqual(
            HandoffMenu.row(claudeInstalled: true, hasSendableFiles: false), .disabled,
            "an installed Claude with an empty shelf should keep the action learnable"
        )
    }

    func test_claude_with_files_enables_the_row() {
        XCTAssertEqual(
            HandoffMenu.row(claudeInstalled: true, hasSendableFiles: true), .enabled
        )
    }

    // MARK: - The builders obey it

    private func managerWithOneFile() throws -> (ShelfManager, UUID, ShelfItem) {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("handoff.txt")
        try Data("handoff".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))
        return (manager, shelfID, item)
    }

    /// The row lives at the shelf menu's top level and inside the context
    /// menu's All Actions submenu, so the walk covers both by flattening.
    private func handoffEntry(in menu: NSMenu) -> ShelfActionPalette.Entry? {
        ShelfActionPalette.entries(in: menu).first { $0.title == L("handoff.ingest") }
    }

    func test_the_shelf_menu_drops_the_row_when_claude_is_missing() throws {
        let (manager, shelfID, _) = try managerWithOneFile()
        let with = ShelfActionMenuBuilder.make(
            manager: manager, shelfID: shelfID, claudeInstalled: true
        )
        XCTAssertNotNil(
            handoffEntry(in: with),
            "with Claude installed and a file on the shelf, the row must exist — if this fails, the walk is looking in the wrong place and the absence test below proves nothing"
        )
        let without = ShelfActionMenuBuilder.make(
            manager: manager, shelfID: shelfID, claudeInstalled: false
        )
        XCTAssertNil(
            handoffEntry(in: without),
            "the shelf menu still offers Send to Claude on a Mac without Claude — a dead-end row that stages the user's files before failing"
        )
    }

    func test_the_item_context_menu_drops_the_row_when_claude_is_missing() throws {
        let (manager, shelfID, item) = try managerWithOneFile()
        func build(claudeInstalled: Bool) -> NSMenu {
            ShelfContextMenu.make(
                for: item,
                selectedItems: [item],
                shelfID: shelfID,
                manager: manager,
                conversionService: nil,
                ocrService: nil,
                routeService: nil,
                claudeInstalled: claudeInstalled
            )
        }
        XCTAssertNotNil(
            handoffEntry(in: build(claudeInstalled: true)),
            "with Claude installed and a real file selected, the row must exist — otherwise the absence assertion below is vacuous"
        )
        XCTAssertNil(
            handoffEntry(in: build(claudeInstalled: false)),
            "the context menu still offers Send to Claude on a Mac without Claude"
        )
    }

    /// The empty-shelf case: Claude present, nothing to send. The row stays,
    /// greyed — same teaching behaviour as Show in Finder on an empty shelf.
    func test_an_empty_shelf_keeps_the_row_but_disables_it() throws {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("empty.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let menu = ShelfActionMenuBuilder.make(
            manager: manager, shelfID: shelfID, claudeInstalled: true
        )
        let entry = try XCTUnwrap(
            handoffEntry(in: menu),
            "an empty shelf with Claude installed lost the row entirely — it should be present and greyed"
        )
        XCTAssertFalse(
            entry.isEnabled,
            "the row is clickable with nothing on the shelf to send"
        )
    }
}
