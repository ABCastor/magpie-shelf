import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// **⌘C from the state a shelf is actually in.**
///
/// The key monitor sends `copyRequested` and swallows the press whenever a
/// shelf panel is key, and the only subscriber was `ExpandedShelfView` — which
/// is not in the tree while the shelf is collapsed. So on a collapsed strip ⌘C
/// was a key that ate itself: nothing copied, and nothing else got the press
/// either. That is precisely the failure AGENTS.md names ("a shortcut that was
/// dead for a whole release because no test asked whether it was reachable from
/// the state the app is actually in"), and it is why this test drives the
/// request at a real, collapsed container rather than at a function.
///
/// What it copies is `ShelfSelection.effective` — the same answer `beginDrag`
/// carries and the header states in words — so ⌘C and a drag can never disagree
/// about what "this" means.
@MainActor
final class StripCopyTests: XCTestCase {

    private var scratch: URL!
    private var manager: ShelfManager!
    private var shelfID: UUID!
    private var items: [ShelfItem] = []
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("strip-copy-\(UUID().uuidString)", isDirectory: true)
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
        pasteboard = NSPasteboard(name: .init("StripCopyTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A collapsed shelf in a real panel, hosted the way the app hosts one and
    /// left in its default state — which is the state a summoned shelf starts
    /// in. A real panel, because the narrowing test below picks a row by
    /// clicking it rather than by reaching into the view's state.
    private func hostCollapsedShelf() -> (NSPanel, NSSize) {
        let size = ShelfLayout.collapsedSize(itemCount: items.count)
        let host = NSHostingView(
            rootView: ShelfContainerView(
                manager: manager,
                conversionService: ConversionService(),
                ocrService: OCRService(),
                routeService: RouteService(),
                shelfID: shelfID,
                copyPasteboard: pasteboard
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

    private func copiedURLs() -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    /// Clicks the middle of a row, in window coordinates.
    private func clickRow(_ index: Int, in panel: NSPanel, size: NSSize) {
        let fromTop = ShelfLayout.margin
            + ShelfLayout.stripHeaderHeight
            + ShelfLayout.stripHeaderGap
            + ShelfLayout.rowHeight / 2
            + CGFloat(index) * (ShelfLayout.rowHeight + ShelfLayout.rowSpacing)
        let point = NSPoint(x: size.width / 2, y: size.height - fromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            panel.sendEvent(event)
            settle(0.1)
        }
        settle()
    }

    func test_copy_from_a_collapsed_shelf_puts_its_files_on_the_pasteboard() {
        let (panel, _) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        manager.copyRequested.send(shelfID)
        settle()

        XCTAssertEqual(
            Set(copiedURLs().map(\.lastPathComponent)),
            ["one.txt", "two.txt", "three.txt"],
            "⌘C on a collapsed shelf copies nothing — the press is swallowed by the key monitor and no view answers it, so the key is dead in the state a shelf spends most of its life in"
        )
    }

    /// **And it copies what the header says, not what the shelf holds.** The
    /// strip's whole point is picking a subset out of the set; a ⌘C that
    /// ignored the pick would put files on the clipboard the user can see are
    /// not selected. The row is picked by clicking it, so the selection under
    /// test is the one a user would actually have made.
    func test_copy_after_picking_one_row_copies_only_that_row() {
        let (panel, size) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        // Newest first: row 0 is the last file added.
        clickRow(0, in: panel, size: size)
        manager.copyRequested.send(shelfID)
        settle()

        XCTAssertEqual(
            copiedURLs().map(\.lastPathComponent), ["three.txt"],
            "⌘C copies the whole shelf after the user has narrowed it to one row, so the clipboard and the header disagree about what \"this\" is"
        )
    }
}

/// **The Reveal in Finder pill's subject.**
///
/// It revealed every file on the shelf whatever the user had selected, so the
/// one control on the expanded panel that names a set ignored the set. Pure
/// here because the alternative is watching a Finder window open.
final class ShelfRevealTests: XCTestCase {

    private let a = URL(fileURLWithPath: "/tmp/a.txt")
    private let b = URL(fileURLWithPath: "/tmp/b.txt")
    private let c = URL(fileURLWithPath: "/tmp/c.txt")

    func test_a_pick_is_what_gets_revealed() {
        XCTAssertEqual(
            ShelfReveal.urls(picked: [a, b], fallback: [a, b, c]), [a, b],
            "revealing with two of three files picked hands Finder all three, so the pill ignores the selection"
        )
    }

    /// Nothing picked is the whole shelf, which is the same reading the strip's
    /// default already has — and the behaviour that must not be lost.
    func test_nothing_picked_still_reveals_the_shelf() {
        XCTAssertEqual(
            ShelfReveal.urls(picked: [], fallback: [a, b, c]), [a, b, c],
            "revealing an unpicked shelf now opens Finder on nothing at all"
        )
    }
}
