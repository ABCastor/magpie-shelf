import AppKit
import XCTest
@testable import Magpie

/// ⌘K existed for a full release and nothing in the app said so — it was
/// reachable only from the key monitor and named only in the README, which a
/// stranger who downloads a DMG never reads. The app already teaches its other
/// shortcuts by writing them on menu rows (Quick Look shows Space, Undo shows
/// ⌘Z), so the palette's shortcut goes on the row the palette is a flattening
/// of: All Actions.
@MainActor
final class PaletteShortcutAdvertisementTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaletteShortcutAdvertisementTests-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func managerWithOneFile() throws -> (ShelfManager, UUID, ShelfItem) {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("advertised.txt")
        try Data("advertised".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))
        return (manager, shelfID, item)
    }

    /// The row must be found (a walk that finds nothing proves nothing), must
    /// advertise ⌘K, and must never appear inside the palette it opens.
    ///
    /// AppKit strips the key equivalent off an action-less submenu parent —
    /// setting `keyEquivalent` on the old row silently displayed nothing, so
    /// the naive fix would have shipped a menu that still taught no shortcut.
    /// The row keeps its equivalent only because it carries a real action,
    /// which is asserted here alongside the display.
    ///
    /// `hasSubmenu` differs by surface, and the difference is the point rather
    /// than an inconsistency. The **shelf** menu's row carries none: it used to
    /// head a drawer holding Get Info, Batch Rename, Create ZIP, Copy Path and
    /// — two levels down — Move to Trash, and those rows now sit with the
    /// actions they belong to, leaving nothing to browse. The **item** menu's
    /// row still heads a real group (Convert, Routes, the image operations), so
    /// it keeps its submenu. Both do the same thing on a click, which is the
    /// part that has to stay consistent.
    private func assertAdvertisesCommandK(
        in menu: NSMenu,
        surface: String,
        hasSubmenu: Bool
    ) throws {
        let row = try XCTUnwrap(
            menu.items.first { $0.title == L("All Actions") },
            "\(surface) no longer carries an All Actions row"
        )
        XCTAssertEqual(
            row.keyEquivalent, "k",
            "\(surface): the All Actions row does not display the palette shortcut — ⌘K is back to being learnable only from the README"
        )
        XCTAssertEqual(
            row.keyEquivalentModifierMask, [.command],
            "\(surface): the shortcut on the row is not plain ⌘K"
        )
        XCTAssertNotNil(
            row.action,
            "\(surface): the All Actions row lost its action — AppKit strips the key equivalent off an action-less submenu parent, so the row displays no shortcut"
        )
        XCTAssertNotNil(
            row.target,
            "\(surface): the All Actions row's action has no target, so clicking it (and ⌘K inside the open menu) does nothing"
        )
        let entries = ShelfActionPalette.entries(in: menu)
        if hasSubmenu {
            let submenu = try XCTUnwrap(row.submenu, "\(surface): the row lost its submenu")
            XCTAssertFalse(submenu.items.isEmpty, "\(surface): the All Actions submenu is empty")
            // The palette still reads rows out of it — a submenu parent is a
            // container to the flattener even when it carries an action, so the
            // palette must reach through the row without listing the row itself.
            XCTAssertTrue(
                entries.contains { $0.path.first == L("All Actions") },
                "\(surface): no palette entry is reached through All Actions — the submenu behaviour broke"
            )
        } else {
            XCTAssertNil(
                row.submenu,
                "\(surface): the All Actions drawer is back — its rows belong beside the actions they are like, not behind one more click"
            )
        }
        // Either way, and this is the half that a submenu used to provide for
        // free: the flattener skips submenu parents, so a row that lost its
        // submenu would start listing itself, offering a palette row whose only
        // effect is to reopen the palette.
        XCTAssertFalse(
            entries.contains { $0.title == L("All Actions") },
            "\(surface): the palette lists All Actions as a runnable row — running it would reopen the palette"
        )
    }

    func test_the_shelf_menu_advertises_command_k_on_all_actions() throws {
        let (manager, shelfID, _) = try managerWithOneFile()
        let menu = ShelfActionMenuBuilder.make(manager: manager, shelfID: shelfID)
        try assertAdvertisesCommandK(in: menu, surface: "shelf menu", hasSubmenu: false)
    }

    func test_the_item_context_menu_advertises_command_k_on_all_actions() throws {
        let (manager, shelfID, item) = try managerWithOneFile()
        let menu = ShelfContextMenu.make(
            for: item,
            selectedItems: [item],
            shelfID: shelfID,
            manager: manager,
            conversionService: nil,
            ocrService: nil,
            routeService: nil
        )
        try assertAdvertisesCommandK(in: menu, surface: "item context menu", hasSubmenu: true)
    }

    /// The advertised key and the implemented key must be the same key. The
    /// row's equivalent is display only — the real path is the key monitor in
    /// `App.swift` — so if the monitor ever moves off "k", a row still showing
    /// ⌘K would be advertising a shortcut that does nothing.
    func test_the_advertised_shortcut_is_the_one_the_key_monitor_implements() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/App.swift"),
            encoding: .utf8
        )
        let beforeSend = try XCTUnwrap(
            app.components(separatedBy: "paletteRequested.send").first,
            "App.swift no longer requests the palette at all"
        )
        let lastCase = try XCTUnwrap(
            beforeSend.components(separatedBy: "case \"").last?.first,
            "could not find the key-monitor case that requests the palette"
        )
        let (manager, shelfID, _) = try managerWithOneFile()
        let menu = ShelfActionMenuBuilder.make(manager: manager, shelfID: shelfID)
        let row = try XCTUnwrap(menu.items.first { $0.title == L("All Actions") })
        XCTAssertEqual(
            row.keyEquivalent, String(lastCase),
            "the menu advertises ⌘\(row.keyEquivalent.uppercased()) but the key monitor implements ⌘\(String(lastCase).uppercased()) — the row is lying about the shortcut"
        )
    }
}
