import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// **The expanded browser's clear-on-click, driven as real clicks at real tiles.**
///
/// ADR 0012's amendment recorded that the collapsed strip's "click anywhere to
/// clear" gesture was written as an ancestor of the rows, that a row's
/// `DragInitiatorView` does *not* stop an ancestor `TapGesture` from also
/// recognising, and that the same pattern in `ExpandedShelfView` was "very
/// likely to carry the same defect". It did.
///
/// Measured before the fix, by instrumenting the selection *binding* so every
/// write is visible rather than only the value SwiftUI settles on: a single
/// click on a tile wrote the selection twice, `[]` then `[tile]`. A plain click
/// survived that by luck — the clear runs first and the pick overwrites it — but
/// a ⌘-click did not, because the clear wiped the selection the toggle was
/// supposed to add to. **A second file could not be added to a selection with
/// the pointer at all.**
///
/// The binding is the instrument on purpose. Two writes inside one update cycle
/// collapse into a single `onChange`, so a test watching the settled value
/// cannot tell "cleared, then picked" from "picked" — which is exactly how this
/// survived until now.
@MainActor
final class ExpandedTileClickTests: XCTestCase {

    private var scratch: URL!
    private var manager: ShelfManager!
    private var shelfID: UUID!
    private var items: [ShelfItem] = []

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("expanded-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        manager = ShelfManager(
            store: ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        )
        shelfID = manager.createShelf()
        for name in ["one.txt", "two.txt", "three.txt"] {
            let url = scratch.appendingPathComponent(name)
            try Data("payload".utf8).write(to: url)
            _ = manager.addFile(url: url, to: shelfID)
        }
        items = manager.items(of: shelfID)
        XCTAssertEqual(items.count, 3)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Every write through the selection binding, in order.
    private final class Writes {
        var sizes: [Int] = []
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func hostedPanel(_ writes: Writes) -> (NSPanel, NSHostingView<some View>, NSSize) {
        let size = ShelfLayout.expandedSize(itemCount: items.count)
        let host = NSHostingView(
            rootView: ExpandedHost(
                manager: manager,
                shelfID: shelfID,
                onWrite: { writes.sizes.append($0.count) }
            ).frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        settle(0.45)
        return (panel, host, size)
    }

    /// The tiles' own AppKit overlays, in the order AppKit laid them out.
    private func tileRects(in host: NSView) -> [NSRect] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view is DragInitiatorView { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found.map { $0.convert($0.bounds, to: nil) }
    }

    private func click(
        _ panel: NSPanel, at point: NSPoint, flags: NSEvent.ModifierFlags = []
    ) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            panel.sendEvent(event)
            settle(0.07)
        }
        settle(0.2)
    }

    // MARK: -

    /// A click on a tile picks it, and picks it **once**. A second write in the
    /// same click is the clear firing, and it is what breaks ⌘-click below.
    func test_a_click_on_a_tile_writes_the_selection_exactly_once() throws {
        let writes = Writes()
        let (panel, host, _) = hostedPanel(writes)
        defer { panel.orderOut(nil) }
        let rects = tileRects(in: host)
        XCTAssertEqual(rects.count, 3, "the expanded grid did not lay out three tiles")

        writes.sizes.removeAll()
        click(panel, at: NSPoint(x: rects[0].midX, y: rects[0].midY))

        XCTAssertEqual(
            writes.sizes, [1],
            "a click on a tile writes the selection more than once — the panel's clear gesture is firing on the same click as the tile's own handler, which is the ancestor-gesture defect ADR 0012 already had to fix for the strip"
        )
    }

    /// **The defect this exists for.** Pick one tile, then ⌘-click a second: the
    /// selection has to grow to two. It could not, because the ancestor clear
    /// emptied it before the toggle ran.
    func test_a_command_click_adds_a_second_tile_to_the_selection() throws {
        let writes = Writes()
        let (panel, host, _) = hostedPanel(writes)
        defer { panel.orderOut(nil) }
        let rects = tileRects(in: host)
        XCTAssertEqual(rects.count, 3)

        click(panel, at: NSPoint(x: rects[0].midX, y: rects[0].midY))
        writes.sizes.removeAll()
        click(panel, at: NSPoint(x: rects[1].midX, y: rects[1].midY), flags: [.command])

        XCTAssertEqual(
            writes.sizes, [2],
            "⌘-clicking a second tile does not produce a two-file selection — the panel's clear gesture wipes the first pick before the toggle runs, so the expanded browser cannot be multi-selected with the pointer at all"
        )
    }

    /// The half that keeps the fix honest: moving the gesture off the ancestor
    /// must not take "click the empty space to deselect" with it.
    func test_a_click_on_empty_space_still_clears_the_selection() throws {
        let writes = Writes()
        let (panel, host, size) = hostedPanel(writes)
        defer { panel.orderOut(nil) }
        let rects = tileRects(in: host)
        XCTAssertEqual(rects.count, 3)

        click(panel, at: NSPoint(x: rects[0].midX, y: rects[0].midY))
        writes.sizes.removeAll()
        // Directly under the bottom edge of the tiles and above the footer row:
        // panel space that belongs to no control.
        let empty = NSPoint(x: size.width / 2, y: rects[0].minY - 12)
        click(panel, at: empty)

        XCTAssertEqual(
            writes.sizes, [0],
            "clicking the empty space of the expanded panel no longer clears the selection — the way back from a pick made by accident is gone"
        )
    }
}

/// The expanded browser, wired the way `ShelfContainerView` wires it, with a
/// binding that reports **every** write rather than only what SwiftUI settles
/// on.
private struct ExpandedHost: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    let onWrite: (Set<UUID>) -> Void
    @Namespace private var ns
    @State private var selection: Set<UUID> = []
    @State private var palettePending = false

    var body: some View {
        ExpandedShelfView(
            namespace: ns,
            manager: manager,
            shelfID: shelfID,
            selection: Binding(
                get: { selection },
                set: { selection = $0; onWrite($0) }
            ),
            palettePending: $palettePending,
            onCollapse: {},
            onClose: {},
            onDock: {}
        )
        .padding(ShelfLayout.margin)
        .environmentObject(ConversionService())
        .environmentObject(OCRService())
        .environmentObject(RouteService())
    }
}
