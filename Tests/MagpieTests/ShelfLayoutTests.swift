import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// Panel geometry had two owners. `App.swift` carried `let chrome: CGFloat =
/// 130` and its own copy of the grid's column arithmetic; `ExpandedShelfView`
/// carried the spacings and the card sizes that number was supposed to
/// describe. Nothing held them together, so the shelf's rhythm could not be
/// changed without silently sizing the window for a layout that no longer
/// existed.
///
/// These tests are the thing that holds them together now: they measure what
/// the views actually render and compare it against what the window was sized
/// for.
@MainActor
final class ShelfLayoutTests: XCTestCase {

    // MARK: - Fixture

    private func makeItem() throws -> (item: ShelfItem, scratch: URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("Quarterly report.pdf")
        try Data(repeating: 0x25, count: 4_096).write(to: file)

        let store = ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        let manager = ShelfManager(store: store)
        let shelfID = manager.createShelf()
        _ = manager.addFile(url: file, to: shelfID)
        let item = try XCTUnwrap(manager.items(of: shelfID).first)
        return (item, scratch)
    }

    /// The height SwiftUI actually gives a view, laid out for real.
    private func renderedHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The tile the panel is sized for

    /// The defect, pinned: `ShelfLayout.tileHeight` is what a row of the
    /// expanded panel is assumed to cost, and `DocumentGridItem` is what
    /// actually draws it. Retune the tile's padding and this goes red.
    func test_a_grid_tile_is_as_tall_as_the_panel_maths_assumes() throws {
        let fixture = try makeItem()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        let tile = DocumentGridItem(
            item: fixture.item,
            manager: ShelfManager(store: ShelfStore(storeURL: fixture.scratch
                .appendingPathComponent("unused.json"))),
            shelfID: UUID(),
            isSelected: false,
            isFocused: false,
            isBeingDragged: false,
            selectedURLsProvider: { [] },
            contextMenuBuilder: { NSMenu() },
            onRemove: {},
            onClick: { _ in },
            onDragStart: {},
            onDragEnd: {},
            onMovedOut: { _ in },
            onNavigateInto: {}
        )
        .environmentObject(ConversionService())
        .environmentObject(OCRService())
        .environmentObject(RouteService())

        let measured = renderedHeight(of: tile, width: ShelfLayout.gridColumnMaximum)
        XCTAssertEqual(
            measured, ShelfLayout.tileHeight, accuracy: 1.0,
            """
            a grid tile renders \(measured)pt tall but the panel is sized for \
            \(ShelfLayout.tileHeight)pt per row — the window and the grid have \
            come apart again
            """
        )
    }

    /// The same guarantee for the strip: `ShelfLayout.rowHeight` is what one
    /// file on the shelf is assumed to cost, and `ShelfStripRow` is what draws
    /// it. The panel's whole height is a multiple of this number.
    func test_a_strip_row_is_as_tall_as_the_panel_maths_assumes() throws {
        let fixture = try makeItem()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        let measured = renderedHeight(
            of: ShelfStripRow(item: fixture.item), width: ShelfLayout.stripWidth
        )
        XCTAssertEqual(
            measured, ShelfLayout.rowHeight, accuracy: 0.5,
            """
            a strip row renders \(measured)pt tall but the panel is sized for \
            \(ShelfLayout.rowHeight)pt per file
            """
        )
    }

    // MARK: - The shelf is the shape of what is on it

    /// The design claim, in numbers: the panel is a **narrow vertical strip**,
    /// not a square with the contents floating in the middle of it. A full
    /// shelf is taller than it is wide, and a shelf with one file on it is not
    /// the same size as a shelf with eight.
    func test_the_collapsed_shelf_is_a_strip_shaped_by_its_contents() {
        let one = ShelfLayout.collapsedSize(itemCount: 1)
        let few = ShelfLayout.collapsedSize(itemCount: 3)
        let full = ShelfLayout.collapsedSize(itemCount: ShelfLayout.maxVisibleRows)

        XCTAssertGreaterThan(few.height, one.height, "a second file did not make the shelf taller")
        XCTAssertGreaterThan(full.height, few.height)
        XCTAssertGreaterThan(
            full.height, full.width,
            "a full shelf is not vertical — it is \(full.width)×\(full.height)"
        )
        XCTAssertEqual(one.width, full.width, "the strip changes height, never width")
        // The bound was "under the 210pt square it replaced" until the owner
        // asked for a bigger strip (2026-10-20). What it protected is that the
        // collapsed shelf stays a strip: clearly narrower than the expanded
        // browser, and half again as tall as it is wide when full.
        XCTAssertLessThan(
            full.width, ShelfLayout.expandedWidth * 0.75,
            "the strip is wide enough to be mistaken for the expanded browser"
        )
        XCTAssertGreaterThanOrEqual(
            full.height, full.width * 1.5,
            "a full strip is \(full.width)×\(full.height), which reads as a box rather than a column"
        )
    }

    /// Past the visible-row cap the strip stops growing and scrolls, so a
    /// forty-file shelf cannot become a panel the height of the screen.
    func test_the_strip_stops_growing_and_starts_scrolling() {
        let full = ShelfLayout.collapsedSize(itemCount: ShelfLayout.maxVisibleRows)
        let overfull = ShelfLayout.collapsedSize(itemCount: ShelfLayout.maxVisibleRows + 30)
        XCTAssertEqual(overfull, full, "the strip grew past its visible-row cap")
    }

    /// An empty shelf is a strip with a hint in it, not a collapsed sliver.
    func test_an_empty_shelf_still_has_room_for_its_hint() {
        let empty = ShelfLayout.collapsedSize(itemCount: 0)
        XCTAssertEqual(empty.width, ShelfLayout.stripWidth)
        XCTAssertGreaterThanOrEqual(
            ShelfLayout.stripBodyHeight(itemCount: 0), ShelfLayout.stripEmptyBodyHeight
        )
    }

    // MARK: - One expression of "how many columns"

    /// The panel's own column count and the one the ↓ key moves by must be the
    /// same number, computed once. They were two: `App.swift` inlined
    /// `(available + 16) / (96 + 16)` while `ExpandedShelfView` called
    /// `ShelfFocus.columnCount`.
    func test_the_panel_and_the_keyboard_count_the_same_columns() {
        XCTAssertEqual(
            ShelfLayout.expandedColumnCount,
            ShelfFocus.columnCount(
                availableWidth: ShelfLayout.expandedWidth - ShelfLayout.margin * 2,
                minimum: ShelfLayout.gridColumnMinimum,
                spacing: ShelfLayout.gridColumnSpacing
            )
        )
        XCTAssertGreaterThan(ShelfLayout.expandedColumnCount, 1)
    }

    /// The content width the columns are packed into is the panel minus its
    /// own margins — not the panel, and not a hand-written "minus 20".
    func test_the_grid_is_measured_inside_the_panels_margins() {
        XCTAssertEqual(
            ShelfLayout.expandedContentWidth,
            ShelfLayout.expandedWidth - ShelfLayout.margin * 2
        )
    }

    // MARK: - Panel height as a function of the shelf

    func test_the_expanded_panel_grows_with_the_shelf_and_is_capped() {
        let columns = ShelfLayout.expandedColumnCount
        let oneRow = ShelfLayout.expandedSize(itemCount: 1).height
        let twoRows = ShelfLayout.expandedSize(itemCount: columns + 1).height
        let manyRows = ShelfLayout.expandedSize(itemCount: columns * 40).height

        XCTAssertGreaterThan(twoRows, oneRow, "a second row did not make the panel taller")
        XCTAssertEqual(manyRows, ShelfLayout.expandedMaxHeight, "the cap is not applied")
        XCTAssertGreaterThanOrEqual(oneRow, ShelfLayout.expandedMinHeight)
        XCTAssertEqual(ShelfLayout.expandedSize(itemCount: 0).width, ShelfLayout.expandedWidth)
    }

    /// An empty shelf still asks for a panel, and it must be the same one a
    /// single card gets rather than a degenerate zero-row size.
    func test_an_empty_shelf_is_sized_like_a_one_card_shelf() {
        XCTAssertEqual(
            ShelfLayout.expandedSize(itemCount: 0),
            ShelfLayout.expandedSize(itemCount: 1)
        )
    }

    /// Chrome is the sum of its named parts, so retuning any one of them moves
    /// the panel. It used to be the literal 130 and nothing else.
    func test_chrome_is_the_sum_of_the_parts_it_is_made_of() {
        XCTAssertEqual(
            ShelfLayout.expandedChrome,
            ShelfLayout.margin * 2
                + ShelfLayout.expandedHeaderHeight
                + ShelfLayout.expandedOuterSpacing * 2
                + ShelfLayout.expandedFooterHeight
                + ShelfLayout.gridVerticalInset * 2
        )
    }

    // MARK: - Nothing keeps a second copy

    /// The window's size must be *asked for*, never re-derived. A source scan
    /// because the failure is a number reappearing in a file, which no value
    /// test can see.
    func test_the_app_delegate_keeps_no_geometry_of_its_own() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/App.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("expandedSize(for:"), "read the wrong file")
        XCTAssertTrue(
            source.contains("ShelfLayout."),
            "App.swift no longer asks ShelfLayout how big a panel is"
        )
        for leak in ["let chrome:", "cellHeight", "let rowSpacing:", "expandedMinHeight"] {
            XCTAssertFalse(
                source.contains(leak),
                "App.swift has its own copy of `\(leak)` again — panel geometry has two owners"
            )
        }
    }
}
