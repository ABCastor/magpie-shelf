import AppKit
import XCTest
@testable import Magpie

/// The ⌘K palette has no list of actions of its own — it flattens the very menu
/// the pointer gets. These tests cover both halves of that: the flattening and
/// ranking, which are pure, and the claim that matters most, which is that the
/// rows really do come out of `ShelfContextMenu` and `ShelfActionMenuBuilder`
/// rather than out of a second table that would drift away from them.
final class ShelfActionPaletteTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfActionPaletteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Flattening

    @MainActor
    private func fixture() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(row("Show in Finder", enabled: true))
        menu.addItem(row("Quick Look", enabled: false))
        menu.addItem(.separator())
        menu.addItem(header("Image Actions"))
        menu.addItem(row("Create PDF", enabled: true))

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(row("PNG", enabled: true))
        submenu.addItem(row("JPEG", enabled: true))
        let container = NSMenuItem(title: "Convert to", action: nil, keyEquivalent: "")
        container.submenu = submenu
        menu.addItem(container)

        return menu
    }

    private func row(_ title: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.isEnabled = enabled
        return item
    }

    /// The builders mark a section header disabled and give it no action, which
    /// is exactly how the flattener recognises it.
    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @MainActor
    func test_flattening_keeps_runnable_rows_in_menu_order() {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertEqual(
            entries.map(\.title),
            ["Show in Finder", "Quick Look", "Create PDF", "PNG", "JPEG"]
        )
        XCTAssertEqual(entries.map(\.id), [0, 1, 2, 3, 4])
    }

    @MainActor
    func test_flattening_drops_separators_and_section_headers() {
        let titles = ShelfActionPalette.entries(in: fixture()).map(\.title)
        XCTAssertFalse(titles.contains("Image Actions"), "a section header is not a runnable row")
        XCTAssertFalse(titles.contains(""), "a separator is not a runnable row")
    }

    /// A row carrying a submenu is a container, not an action: it names the
    /// path its children are reached by and contributes nothing itself.
    @MainActor
    func test_a_submenu_row_becomes_a_breadcrumb_not_an_action() throws {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertFalse(entries.map(\.title).contains("Convert to"))
        let png = try XCTUnwrap(entries.first { $0.title == "PNG" })
        XCTAssertEqual(png.path, ["Convert to"])
        XCTAssertEqual(png.breadcrumb, "Convert to")
        XCTAssertEqual(entries.first?.breadcrumb, "", "a top-level row has no breadcrumb")
    }

    @MainActor
    func test_flattening_carries_the_enablement_the_builder_computed() {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertEqual(entries.first { $0.title == "Show in Finder" }?.isEnabled, true)
        XCTAssertEqual(entries.first { $0.title == "Quick Look" }?.isEnabled, false)
    }

    // MARK: - Filtering

    /// A menu shows a disabled row so the user learns the action exists. A
    /// palette is a list of what can run right now, so a row that cannot is
    /// noise between the query and the row that can.
    @MainActor
    func test_an_empty_query_lists_every_available_row_in_menu_order() {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertEqual(
            ShelfActionPalette.filter(entries, query: "").map(\.title),
            ["Show in Finder", "Create PDF", "PNG", "JPEG"]
        )
        XCTAssertEqual(
            ShelfActionPalette.filter(entries, query: "   ").map(\.title),
            ["Show in Finder", "Create PDF", "PNG", "JPEG"]
        )
    }

    @MainActor
    func test_a_disabled_row_never_reaches_the_palette() {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertTrue(ShelfActionPalette.filter(entries, query: "quick").isEmpty)
    }

    @MainActor
    func test_a_prefix_of_the_rows_own_name_outranks_a_match_anywhere_else() {
        let entries = ShelfActionPalette.entries(in: fixture())
        // "p" starts PNG, and appears inside "Create PDF" and "Show in Finder".
        XCTAssertEqual(ShelfActionPalette.filter(entries, query: "p").first?.title, "PNG")
    }

    @MainActor
    func test_every_token_has_to_match_and_order_does_not_matter() {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertEqual(ShelfActionPalette.filter(entries, query: "conv png").map(\.title), ["PNG"])
        XCTAssertEqual(ShelfActionPalette.filter(entries, query: "png conv").map(\.title), ["PNG"])
        XCTAssertTrue(ShelfActionPalette.filter(entries, query: "png zzzz").isEmpty)
    }

    @MainActor
    func test_a_query_matching_nothing_returns_nothing() {
        let entries = ShelfActionPalette.entries(in: fixture())
        XCTAssertTrue(ShelfActionPalette.filter(entries, query: "xylophone").isEmpty)
    }

    /// The thing that makes a palette worth typing into rather than scrolling.
    func test_subsequence_matching_reaches_across_words() {
        XCTAssertTrue(ShelfActionPalette.isSubsequence("cpdf", of: "create pdf"))
        XCTAssertTrue(ShelfActionPalette.isSubsequence("sif", of: "show in finder"))
        XCTAssertTrue(ShelfActionPalette.isSubsequence("", of: "anything"))
        XCTAssertFalse(ShelfActionPalette.isSubsequence("fdp", of: "create pdf"), "order matters")
        XCTAssertFalse(ShelfActionPalette.isSubsequence("pdfx", of: "create pdf"))
    }

    @MainActor
    func test_a_subsequence_only_match_ranks_below_every_literal_one() {
        let entries = ShelfActionPalette.entries(in: fixture())
        let ranked = ShelfActionPalette.filter(entries, query: "cpdf")
        XCTAssertEqual(ranked.map(\.title), ["Create PDF"])
    }

    // MARK: - The seam

    /// The claim the whole design rests on: these rows are the context menu's
    /// rows. Not a copy of them, not a registry that has to be kept level with
    /// them — the same `NSMenu` the right-click builds, read.
    @MainActor
    func test_the_palette_is_flattened_out_of_the_real_item_menu() throws {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("palette.txt")
        try Data("palette".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))

        let menu = ShelfContextMenu.make(
            for: item,
            selectedItems: [item],
            shelfID: shelfID,
            manager: manager,
            conversionService: nil,
            ocrService: nil,
            routeService: nil
        )
        let entries = ShelfActionPalette.entries(in: menu)
        let titles = entries.map(\.title)

        for expected in [L("Show in Finder"), L("Copy"), L("Move to Trash"), L("Rename…")] {
            XCTAssertTrue(titles.contains(expected), "the palette lost the menu row \(expected)")
        }
        // A row that lives one level down comes through carrying where it lives.
        let remove = try XCTUnwrap(entries.first { $0.title == L("Remove from Shelf") })
        XCTAssertEqual(remove.path, [L("All Actions")])
        // And every row still points at the object the builder wired it to, so
        // running one from the palette is the same call a click makes.
        XCTAssertTrue(entries.allSatisfy { $0.menuItem.action != nil })
        XCTAssertNotNil(remove.menuItem.target)
    }

    /// The other builder, for when nothing is focused or selected.
    @MainActor
    func test_the_palette_is_flattened_out_of_the_real_shelf_menu_too() throws {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf-level.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("shelf-level.txt")
        try Data("shelf".utf8).write(to: fileURL)
        _ = manager.addFile(url: fileURL, to: shelfID)

        let menu = ShelfActionMenuBuilder.make(manager: manager, shelfID: shelfID)
        let titles = ShelfActionPalette.entries(in: menu).map(\.title)

        for expected in [L("Show in Finder"), L("AirDrop"), L("Add From Clipboard"), L("Clear Shelf")] {
            XCTAssertTrue(titles.contains(expected), "the palette lost the shelf-menu row \(expected)")
        }
        XCTAssertTrue(
            titles.contains(L("Get Info")),
            "a row inside All Actions ▸ should still be reachable from the palette"
        )
    }
}
