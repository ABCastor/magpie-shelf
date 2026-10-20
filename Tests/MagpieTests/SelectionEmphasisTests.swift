import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// Selection used to look identical whether the shelf panel was key or not.
/// With two shelves open there was nothing on screen to say which one the
/// next keystroke would hit — and this app is keyboard-driven with no title
/// bars to carry that signal. `SelectionColor` now answers `emphasized:` and
/// every cell resolves it from `controlActiveState`.
@MainActor
final class SelectionEmphasisTests: XCTestCase {

    // MARK: - Colour maths (same conventions as AppearanceTests)

    private func resolve(_ color: Color, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }

    private func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let a = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
            green: top.greenComponent * a + bottom.greenComponent * (1 - a),
            blue: top.blueComponent * a + bottom.blueComponent * (1 - a),
            alpha: 1
        )
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func panelGround(_ name: NSAppearance.Name) -> NSColor {
        name == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
            : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    }

    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    // MARK: - The pairs themselves

    /// Both selection pairs stay readable, in both appearances. The active
    /// pair was asserted only in a comment until now.
    func test_both_selection_pairs_clear_body_text_contrast() throws {
        for name in appearances {
            for emphasized in [true, false] {
                let ground = panelGround(name)
                let fill = composite(try resolve(SelectionColor.fill(emphasized: emphasized), in: name), over: ground)
                let text = composite(try resolve(SelectionColor.text(emphasized: emphasized), in: name), over: fill)
                XCTAssertGreaterThanOrEqual(
                    contrast(text, fill), 4.5,
                    "the \(emphasized ? "active" : "unemphasized") selection pair is under 4.5:1 in \(name.rawValue)"
                )
            }
        }
    }

    /// The two fills must be visibly different, or key and non-key shelves
    /// look the same and the signal this change exists for does not exist.
    func test_active_and_unemphasized_fills_are_visibly_different() throws {
        for name in appearances {
            let ground = panelGround(name)
            let active = composite(try resolve(SelectionColor.fill(emphasized: true), in: name), over: ground)
            let unemphasized = composite(try resolve(SelectionColor.fill(emphasized: false), in: name), over: ground)
            XCTAssertGreaterThanOrEqual(
                contrast(active, unemphasized), 1.2,
                "active and unemphasized selection fills are indistinguishable in \(name.rawValue) — a non-key shelf's selection reads as key"
            )
        }
    }

    /// An unemphasized selection must still be *visible*: losing key status
    /// may not erase which items are selected.
    func test_unemphasized_fill_is_still_visible_against_the_panel() throws {
        for name in appearances {
            let ground = panelGround(name)
            let fill = composite(try resolve(SelectionColor.fill(emphasized: false), in: name), over: ground)
            XCTAssertGreaterThan(
                contrast(fill, ground), 1.06,
                "the unemphasized selection fill vanishes against the panel in \(name.rawValue)"
            )
        }
    }

    // MARK: - The cells actually consult the window state

    private var scratch: URL!
    private var manager: ShelfManager!
    private var shelfID: UUID!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-emphasis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        manager = ShelfManager(store: ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json")))
        shelfID = manager.createShelf()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Renders `view` offscreen over an opaque ground and returns the PNG
    /// bytes. No runloop is spun, so nothing asynchronous (Quick Look
    /// thumbnails) can land between two renders and fake a difference.
    private func png<V: View>(_ view: V, size: NSSize) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.appearance = NSAppearance(named: .darkAqua)
        container.layer?.backgroundColor = panelGround(.darkAqua).cgColor
        container.addSubview(host)
        container.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The four selectable cells, each rendered selected. Real views, not
    /// probes: a cell that stops reading `controlActiveState` fails here no
    /// matter what `SelectionColor` itself does.
    private func selectableCells(selected: Bool) -> [(String, AnyView, NSSize)] {
        let entry = FolderEntry(
            url: URL(fileURLWithPath: "/nonexistent/selection-probe.txt"),
            isDirectory: false,
            displayName: "selection probe",
            byteSize: 1_234
        )
        let item = ShelfItem(type: .text, textContent: "selection probe snippet")
        let noFlags: (NSEvent.ModifierFlags) -> Void = { _ in }
        return [
            (
                "FolderEntryGridCell",
                AnyView(FolderEntryGridCell(
                    entry: entry, isSelected: selected, isFocused: false,
                    onClick: noFlags, onDoubleClick: {}, onNavigateInto: {},
                    urlsProvider: { [] }
                )),
                NSSize(width: 140, height: 180)
            ),
            (
                "FolderEntryListItem",
                AnyView(FolderEntryListItem(
                    entry: entry, isSelected: selected, isFocused: false,
                    onClick: noFlags, onDoubleClick: {}, onNavigateInto: {},
                    urlsProvider: { [] }
                )),
                NSSize(width: 300, height: 32)
            ),
            (
                "DocumentGridItem",
                AnyView(DocumentGridItem(
                    item: item, manager: manager, shelfID: shelfID,
                    isSelected: selected, isFocused: false, isBeingDragged: false,
                    selectedURLsProvider: { [] }, contextMenuBuilder: { NSMenu() },
                    onRemove: {}, onClick: noFlags, onDragStart: {}, onDragEnd: {},
                    onMovedOut: { _ in }, onNavigateInto: {}
                )
                .environmentObject(ConversionService())
                .environmentObject(OCRService())
                .environmentObject(RouteService())),
                NSSize(width: 140, height: 200)
            ),
            (
                "DocumentListItem",
                AnyView(DocumentListItem(
                    item: item, manager: manager, shelfID: shelfID,
                    isSelected: selected, isFocused: false, isBeingDragged: false,
                    selectedURLsProvider: { [] }, contextMenuBuilder: { NSMenu() },
                    onRemove: {}, onClick: noFlags, onDragStart: {}, onDragEnd: {},
                    onMovedOut: { _ in }, onNavigateInto: {}
                )
                .environmentObject(ConversionService())
                .environmentObject(OCRService())
                .environmentObject(RouteService())),
                NSSize(width: 300, height: 32)
            ),
            // The collapsed strip's row. It had no selection state at all until
            // ADR 0012 — a drag off any row carried the whole shelf — so it is
            // in this list precisely because it is the newest thing that could
            // forget to answer the question the other four already answer.
            (
                "ShelfStripRow",
                AnyView(ShelfStripRow(item: item, isSelected: selected)),
                NSSize(width: ShelfLayout.stripWidth, height: ShelfLayout.rowHeight)
            ),
        ]
    }

    /// A selected cell must render differently when its panel is key than
    /// when it is not — this is the entire user-visible point.
    func test_every_selectable_cell_shows_whether_its_panel_is_key() throws {
        for (label, view, size) in selectableCells(selected: true) {
            let key = try png(view.environment(\.controlActiveState, .key), size: size)
            let inactive = try png(view.environment(\.controlActiveState, .inactive), size: size)
            XCTAssertNotEqual(
                key, inactive,
                "\(label) renders its selection identically whether the panel is key or not — with two shelves open nothing says which one the keyboard will hit"
            )
        }
    }

    /// The assertion under all the others: **a selected cell is actually
    /// filled.** Four cells went without it, and then ADR 0012 made a fifth one
    /// selectable — the collapsed strip's row, which had no selected state at
    /// all while a drag off it carried the whole shelf regardless.
    ///
    /// A "renders differently" check is not enough: a cell that only changed
    /// its text tone would pass one while the thing the user reads at a glance,
    /// the bar of colour, was missing. This measures the bar.
    func test_a_selected_cell_is_visibly_filled_with_the_selection_colour() throws {
        let expected = try resolve(SelectionColor.fill(emphasized: true), in: .darkAqua)
        let selected = selectableCells(selected: true)
        let unselected = selectableCells(selected: false)
        for index in selected.indices {
            let (label, view, size) = selected[index]
            let (_, plainView, _) = unselected[index]
            let filled = try fillCoverage(
                in: view.environment(\.controlActiveState, .key), size: size, matching: expected
            )
            let plain = try fillCoverage(
                in: plainView.environment(\.controlActiveState, .key), size: size, matching: expected
            )
            XCTAssertGreaterThan(
                filled, 0.25,
                "\(label): selecting it paints \(Int(filled * 100))% of the cell in the selection fill — nothing on screen says what a drag would take"
            )
            XCTAssertLessThan(
                plain, filled / 3,
                "\(label): an unselected cell is already most of the way to looking selected"
            )
        }
    }

    /// Losing key status must not erase the selection itself. Not a "renders
    /// differ" check — an incidental text-tone difference could satisfy that
    /// while the fill is gone — but a count of pixels actually painted in the
    /// unemphasized fill colour.
    func test_selection_stays_visible_when_the_panel_is_not_key() throws {
        let expectedFill = try resolve(SelectionColor.fill(emphasized: false), in: .darkAqua)
        let selected = selectableCells(selected: true)
        let unselected = selectableCells(selected: false)
        for index in selected.indices {
            let (label, view, size) = selected[index]
            let (_, plainView, _) = unselected[index]
            let selectedCount = try fillPixelCount(
                in: view.environment(\.controlActiveState, .inactive), size: size, matching: expectedFill
            )
            let plainCount = try fillPixelCount(
                in: plainView.environment(\.controlActiveState, .inactive), size: size, matching: expectedFill
            )
            let total = Int(size.width * size.height)
            XCTAssertGreaterThan(
                selectedCount, total / 20,
                "\(label): with the panel not key, the unemphasized selection fill is not drawn — the selection disappears the moment focus moves away"
            )
            XCTAssertLessThan(
                plainCount, max(selectedCount / 4, 1),
                "\(label): an unselected cell is painted in the selection fill colour"
            )
        }
    }

    /// The share of the rendered cell painted in `target`. A fraction rather
    /// than a count so it is scale-free: `cacheDisplay` renders at the screen's
    /// backing factor, and a threshold in points against a count in pixels is a
    /// threshold that means something different on two Macs.
    private func fillCoverage<V: View>(
        in view: V, size: NSSize, matching target: NSColor
    ) throws -> Double {
        let matches = try fillPixelCount(in: view, size: size, matching: target)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        let total = rep.pixelsWide * rep.pixelsHigh
        guard total > 0 else { return 0 }
        return Double(matches) / Double(total)
    }

    /// Pixels within a small per-channel tolerance of `target`, rendered the
    /// same way `png(_:size:)` renders.
    private func fillPixelCount<V: View>(
        in view: V, size: NSSize, matching target: NSColor
    ) throws -> Int {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.appearance = NSAppearance(named: .darkAqua)
        container.layer?.backgroundColor = panelGround(.darkAqua).cgColor
        container.addSubview(host)
        container.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)

        var matches = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.redComponent - target.redComponent) < 0.03,
                   abs(pixel.greenComponent - target.greenComponent) < 0.03,
                   abs(pixel.blueComponent - target.blueComponent) < 0.03 {
                    matches += 1
                }
            }
        }
        return matches
    }
}
