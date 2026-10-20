import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// **The way back from `1 of 5` to `5 Files`, driven as a real click.**
///
/// The strip is quiet at rest and says what a drag will take in its header, so
/// a row picked by accident has to be undoable without thinking. Escape is one
/// route and `ShelfSelectionTests` pins it; this is the other — a click on the
/// header, or on any part of the panel that is not a row.
///
/// It is driven through a real `NSPanel` rather than asserted from source, for
/// two reasons that are both failures this repo has already paid for. A
/// grep proves a closure is passed, not that anything ever calls it. And the
/// shelf's panel is `isMovableByWindowBackground` (`FloatingPanel`), which is
/// AppKit's other claim on a background click — if that claim won, this
/// gesture would be dead in the shipped app and green in every unit test.
@MainActor
final class StripClearOnClickTests: XCTestCase {

    private var scratch: URL!
    private var manager: ShelfManager!
    private var shelfID: UUID!
    private var items: [ShelfItem] = []

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("strip-clear-\(UUID().uuidString)", isDirectory: true)
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

    /// A panel built the way `FloatingPanel` builds one — the same style mask
    /// and the same background-drag behaviour — hosting the real strip.
    private func hostedStrip(
        selection: Set<UUID>,
        onClear: @escaping () -> Void,
        onSelectRow: @escaping (UUID, NSEvent.ModifierFlags) -> Void = { _, _ in },
        onClose: @escaping () -> Void = {}
    ) -> (panel: NSPanel, size: NSSize) {
        let size = ShelfLayout.collapsedSize(itemCount: items.count)
        let host = NSHostingView(
            rootView: StripHost(
                manager: manager,
                shelfID: shelfID,
                items: items,
                selection: selection,
                onClear: onClear,
                onSelectRow: onSelectRow,
                onClose: onClose
            )
            .frame(width: size.width, height: size.height)
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
        settle()
        return (panel, size)
    }

    private func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// One full click at `point`, in window coordinates (origin bottom-left).
    private func click(_ panel: NSPanel, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            panel.sendEvent(event)
            settle(0.1)
        }
        settle()
    }

    /// The middle of the header line, in window coordinates. Clear of the close
    /// button on the left and the three glyphs on the right, which are Buttons
    /// and answer their own clicks.
    private func headerPoint(in size: NSSize) -> NSPoint {
        NSPoint(
            x: size.width / 2,
            y: size.height - ShelfLayout.margin - ShelfLayout.stripHeaderHeight / 2
        )
    }

    /// The middle of the top row.
    private func firstRowPoint(in size: NSSize) -> NSPoint {
        let fromTop = ShelfLayout.margin
            + ShelfLayout.stripHeaderHeight
            + ShelfLayout.stripHeaderGap
            + ShelfLayout.rowHeight / 2
        return NSPoint(x: size.width / 2, y: size.height - fromTop)
    }

    // MARK: -

    func test_a_click_on_the_header_clears_the_pick() {
        var cleared = 0
        let hosted = hostedStrip(selection: [items[0].id], onClear: { cleared += 1 })
        defer { hosted.panel.orderOut(nil) }

        click(hosted.panel, at: headerPoint(in: hosted.size))

        XCTAssertEqual(
            cleared, 1,
            "clicking the header of a narrowed strip does nothing — the line the user is reading to find out what a drag will take is not something they can click to put it back, and AppKit's window-background drag may be eating the click"
        )
    }

    /// The half that makes the other half safe. A row's own `DragInitiatorView`
    /// has to claim its clicks first, or "click anywhere to clear" would undo
    /// the pick the same click just made — every click would be a no-op.
    func test_a_click_on_a_row_picks_it_and_does_not_clear() {
        var cleared = 0
        var picked: [UUID] = []
        let hosted = hostedStrip(
            selection: ShelfSelection.wholeShelf,
            onClear: { cleared += 1 },
            onSelectRow: { id, _ in picked.append(id) }
        )
        defer { hosted.panel.orderOut(nil) }

        click(hosted.panel, at: firstRowPoint(in: hosted.size))

        XCTAssertEqual(
            picked.count, 1,
            "a click on a row does not reach the selection model, so picking one file out of the shelf is unreachable with the pointer"
        )
        XCTAssertEqual(
            cleared, 0,
            "a click on a row also fires the panel's clear, so picking a row immediately un-picks it and the strip can never be narrowed at all"
        )
    }

    /// The header now answers clicks, and it is also where the close button
    /// lives. A gesture on the line that swallowed the X would take the only
    /// way to dismiss a shelf with it.
    func test_the_close_button_still_closes_rather_than_clearing() {
        var cleared = 0
        var closed = 0
        let hosted = hostedStrip(
            selection: [items[0].id],
            onClear: { cleared += 1 },
            onClose: { closed += 1 }
        )
        defer { hosted.panel.orderOut(nil) }

        let header = headerPoint(in: hosted.size)
        click(
            hosted.panel,
            at: NSPoint(
                x: ShelfLayout.margin + Design.Size.chromeButton / 2,
                y: header.y
            )
        )

        XCTAssertEqual(
            closed, 1,
            "the header's clear gesture swallowed the close button, so a shelf can no longer be dismissed from the strip"
        )
        XCTAssertEqual(
            cleared, 0,
            "closing the shelf also fired the clear — the button and the line it sits on are answering the same click"
        )
    }
}

/// The real collapsed strip, wired the way `ShelfContainerView` wires it.
private struct StripHost: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    let items: [ShelfItem]
    let selection: Set<UUID>
    let onClear: () -> Void
    let onSelectRow: (UUID, NSEvent.ModifierFlags) -> Void
    let onClose: () -> Void
    @Namespace private var ns

    var body: some View {
        CollapsedShelfView(
            namespace: ns,
            manager: manager,
            shelfID: shelfID,
            items: items,
            selection: selection,
            onClose: onClose,
            onSelectRow: onSelectRow,
            onClearSelection: onClear
        )
        .padding(ShelfLayout.margin)
    }
}
