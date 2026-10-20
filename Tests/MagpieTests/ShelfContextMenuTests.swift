import AppKit
import Foundation
import XCTest
@testable import Magpie

@MainActor
final class ShelfContextMenuTests: XCTestCase {
    func test_item_menu_subject_follows_finders_inside_outside_rule() {
        let first = ShelfItem(type: .file)
        let second = ShelfItem(type: .file)
        let third = ShelfItem(type: .file)
        let items = [first, second, third]

        XCTAssertEqual(
            ShelfSelection.itemMenuSubject(
                rightClicked: second.id,
                explicit: [first.id, second.id],
                items: items
            ).map(\.id),
            [first.id, second.id],
            "a right-click inside the selection dropped the other selected row"
        )
        XCTAssertEqual(
            ShelfSelection.itemMenuSubject(
                rightClicked: third.id,
                explicit: [first.id, second.id],
                items: items
            ).map(\.id),
            [third.id],
            "a right-click outside the selection expanded to the selected rows"
        )
        XCTAssertEqual(
            ShelfSelection.itemMenuSubject(
                rightClicked: first.id,
                explicit: [],
                items: items
            ).map(\.id),
            [first.id],
            "an empty expanded-browser selection was treated as the whole shelf"
        )
    }

    @MainActor
    func test_item_menu_rows_share_the_finder_subject_and_name_trash_scope() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfContextMenuScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let items = try ["one.txt", "two.txt", "three.txt"].map { name -> ShelfItem in
            let url = tempDir.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return try XCTUnwrap(manager.addFile(url: url, to: shelfID))
        }
        let selected = [items[0], items[1]]
        let menu = ShelfContextMenu.make(
            for: items[1],
            selectedItems: selected,
            shelfID: shelfID,
            manager: manager,
            conversionService: nil,
            ocrService: nil,
            routeService: nil,
            claudeInstalled: true
        )
        let shelfMenu = try XCTUnwrap(menu as? ShelfMenu)
        let actions = try XCTUnwrap(shelfMenu.actions)
        XCTAssertEqual(
            Set(actions.selectedItems.map(\.id)),
            Set(selected.map(\.id)),
            "the menu target lost the Finder subject before any row could use it"
        )

        let rows = menuRows(in: menu)
        let trash = try XCTUnwrap(
            rows.first { $0.action == #selector(ShelfItemActions.moveToTrash) },
            "the item menu lost its Trash row"
        )
        let handoff = try XCTUnwrap(
            rows.first { $0.action == #selector(ShelfItemActions.sendToClaude) },
            "the item menu lost its Send to Claude row"
        )
        XCTAssertTrue(trash.target === actions, "Trash is no longer attached to the menu subject")
        XCTAssertTrue(handoff.target === actions, "Send to Claude is no longer attached to the menu subject")
        XCTAssertEqual(
            trash.title,
            String(format: L("menu.trash-count"), selected.count),
            "the Trash row does not name the selected files it would recycle"
        )
    }

    func test_item_menu_trash_action_is_set_scoped_not_clicked_item_scoped() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfContextMenu.swift"),
            encoding: .utf8
        )
        let action = try XCTUnwrap(
            source.components(separatedBy: "@objc func moveToTrash()").dropFirst().first?
                .components(separatedBy: "@objc func rename()").first,
            "could not find the item-menu Trash action"
        )
        XCTAssertTrue(
            action.contains("selectedItems"),
            "Move to Trash reads the clicked item instead of the Finder subject shared with Send to Claude"
        )
        XCTAssertFalse(
            action.contains("recycle([url])"),
            "Move to Trash still recycles only the right-clicked item"
        )
    }

    private func menuRows(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map { menuRows(in: $0) } ?? [])
        }
    }

    func test_quick_look_selection_accounts_for_missing_earlier_url() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfContextMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missing = tempDir.appendingPathComponent("missing.txt")
        let selected = tempDir.appendingPathComponent("selected.txt")
        let later = tempDir.appendingPathComponent("later.txt")
        try Data("selected".utf8).write(to: selected)
        try Data("later".utf8).write(to: later)
        let urls = [missing, selected, later]

        let start = ShelfItemActions.quickLookStartIndex(for: selected, in: urls)
        let previewURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertEqual(previewURLs[start], selected)
    }
}
