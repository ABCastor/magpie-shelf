import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// **What a click on a shelf cell does, driven as a real click.**
///
/// Three separate defects in this area have now been invisible to every form of
/// source inspection and caught only by pushing real `NSEvent`s through a real
/// `NSPanel` — the method `StripClearOnClickTests` established. These are the
/// rest of them, and each assertion below was watched to fail against the code
/// as it shipped:
///
/// - a second quick click was handed to a double-click closure the strip does
///   not wire, so it went nowhere and the ⇧-click never extended anything;
/// - a ⌃-click, where a cell offers no context menu, was read as a plain click
///   and silently threw the selection away;
/// - the view never accepted first mouse, so the click that reaches for a row
///   on a shelf that is not the key window was spent making the panel key.
@MainActor
final class CellClickTests: XCTestCase {

    final class Log {
        var clicks: [NSEvent.ModifierFlags] = []
        var opens = 0
    }

    private func settle(_ seconds: TimeInterval = 0.12) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// One cell's drag overlay, hosted the way a shelf hosts one: in a
    /// borderless non-activating panel that drags by its own background.
    ///
    /// The menu builder records rather than returns a menu. A real menu here
    /// would put AppKit into its own modal tracking loop and the test would
    /// never come back — which is itself the measurement that a ⌃-click opens
    /// one.
    private func hosted(
        log: Log,
        offersOpen: Bool = true,
        offersMenu: Bool = true
    ) -> NSPanel {
        let size = NSSize(width: 200, height: 100)
        let overlay = ShelfDragOverlay(
            provider: { [URL(fileURLWithPath: "/etc/hosts")] },
            onStart: {},
            onEnd: {},
            menuBuilder: offersMenu ? { nil } : nil,
            onClick: { log.clicks.append($0.intersection(.deviceIndependentFlagsMask)) },
            onDoubleClick: offersOpen ? { log.opens += 1 } : nil
        )
        let host = NSHostingView(
            rootView: Color.clear.overlay(overlay).frame(width: size.width, height: size.height)
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
        settle(0.3)
        return panel
    }

    /// One full click at the middle of the cell, at a given click count.
    private func click(
        _ panel: NSPanel,
        flags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) {
        let point = NSPoint(x: 100, y: 50)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            panel.sendEvent(event)
            settle(0.06)
        }
        settle(0.1)
    }

    // MARK: - The swallowed second click

    /// **The owner's intermittency, reproduced.** *"Many times it doesn't work…
    /// sometimes it does work."* A strip row wires no double-click closure, so
    /// every click the window server counted as the second of a pair was handed
    /// to nothing at all — and whether a click is counted as a second one is a
    /// question of how fast the user clicked and how close the two rows are.
    func test_a_quick_second_shift_click_still_extends_the_selection() {
        let log = Log()
        let panel = hosted(log: log, offersOpen: false)
        defer { panel.orderOut(nil) }

        click(panel, flags: [.shift], clickCount: 2)

        XCTAssertEqual(
            log.clicks, [[.shift]],
            "a ⇧-click that the window server counted as the second of a pair reaches nothing — so extending a selection works or fails depending on how fast the user clicks, which is exactly the report"
        )
    }

    /// The same failure with ⌘, on a cell that *does* offer opening: the
    /// expanded browser's tiles. There a lost click was worse than lost — it
    /// opened the file in another app instead of adding it to the selection.
    func test_a_quick_second_command_click_selects_rather_than_opening() {
        let log = Log()
        let panel = hosted(log: log, offersOpen: true)
        defer { panel.orderOut(nil) }

        click(panel, flags: [.command], clickCount: 2)

        XCTAssertEqual(
            log.opens, 0,
            "building a multi-selection quickly opens the file in its default app instead of selecting it"
        )
        XCTAssertEqual(
            log.clicks, [[.command]],
            "the ⌘-click never reached the selection"
        )
    }

    /// The half that keeps the other half honest: an unmodified double-click on
    /// a cell that offers opening must still open.
    func test_a_plain_double_click_still_opens() {
        let log = Log()
        let panel = hosted(log: log, offersOpen: true)
        defer { panel.orderOut(nil) }

        click(panel, clickCount: 2)

        XCTAssertEqual(log.opens, 1, "double-click no longer opens the file")
        XCTAssertTrue(log.clicks.isEmpty, "a double-click also changed the selection")
    }

    // MARK: - ⌃ is the secondary click

    /// macOS routes ⌃-click to the context menu. Where a cell offers one AppKit
    /// takes the event before `mouseDown` ever runs; where a cell offers none —
    /// the folder browser's cells wire no menu builder — it used to arrive here
    /// and be read as a plain click, so reaching for a menu that does not exist
    /// silently threw away everything the user had picked.
    func test_a_control_click_never_reaches_the_selection() {
        let log = Log()
        let panel = hosted(log: log, offersMenu: false)
        defer { panel.orderOut(nil) }

        click(panel, flags: [.control])

        XCTAssertTrue(
            log.clicks.isEmpty,
            "a ⌃-click is read as a selection click, so macOS's secondary click silently replaces what the user picked"
        )
    }

    // MARK: - First mouse

    /// **A shelf is nearly always clicked while it is not key.** It is summoned
    /// over another app and does not activate, so the click that reaches for a
    /// row is the first click that panel has seen. Without this AppKit spends it
    /// on making the panel key and the row never sees it.
    ///
    /// Asked of the view a click on a real strip row actually lands on, not of
    /// the class in the abstract — a `hitTest` that stopped returning this view
    /// would make the question meaningless, and this way it fails instead.
    func test_the_view_a_row_click_lands_on_accepts_first_mouse() throws {
        let log = Log()
        let panel = hosted(log: log)
        defer { panel.orderOut(nil) }

        let hit = try XCTUnwrap(
            panel.contentView?.hitTest(NSPoint(x: 100, y: 50)),
            "nothing answers a click in the middle of a cell"
        )
        XCTAssertTrue(
            hit is DragInitiatorView,
            "a click in the middle of a cell is not answered by the cell's own overlay"
        )
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 50),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        XCTAssertTrue(
            hit.acceptsFirstMouse(for: down),
            "the row refuses the first click on a panel that is not key, so clicking a file on a freshly summoned shelf does nothing but focus the window — the owner's \"it just clicked on the whole app\""
        )
    }

    // MARK: - The rule itself

    /// The pure rule the handler is built from, at every combination that
    /// decides something. Driven above; stated here.
    func test_the_click_rule() {
        XCTAssertEqual(
            CellClick.intent(modifiers: [], clickCount: 1, offersOpen: true),
            .select([])
        )
        XCTAssertEqual(
            CellClick.intent(modifiers: [], clickCount: 2, offersOpen: true),
            .open
        )
        XCTAssertEqual(
            CellClick.intent(modifiers: [], clickCount: 2, offersOpen: false),
            .select([]),
            "a cell that cannot be opened drops the click instead of selecting"
        )
        XCTAssertEqual(
            CellClick.intent(modifiers: [.shift], clickCount: 2, offersOpen: true),
            .select([.shift]),
            "a ⇧-click stops extending as soon as the user clicks quickly"
        )
        XCTAssertEqual(
            CellClick.intent(modifiers: [.command], clickCount: 3, offersOpen: true),
            .select([.command])
        )
        for count in 1...2 {
            XCTAssertEqual(
                CellClick.intent(modifiers: [.control], clickCount: count, offersOpen: true),
                .secondary,
                "⌃ is read as a selection modifier at click count \(count)"
            )
        }
        XCTAssertEqual(
            CellClick.intent(modifiers: [.option], clickCount: 1, offersOpen: true),
            .select([.option]),
            "⌥ stopped reaching the selection, where it has always been read as a plain click"
        )
    }
}
