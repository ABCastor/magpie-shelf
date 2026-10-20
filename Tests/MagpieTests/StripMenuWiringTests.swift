import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// **The menu a real right-click on a real row actually gets**, and the files
/// Quick Look would really show.
///
/// `StripMenuClaimTests` walks every selection state through the builder. That
/// proves the builder honours a pick; it cannot prove the strip hands one over —
/// and handing over nothing is precisely what the strip used to do. So this
/// hosts the collapsed shelf in a real `NSPanel`, narrows it by clicking a row
/// the way a user would, and asks the row's own AppKit view for its menu.
///
/// It asks with `menu(for:)` rather than by popping anything: a real context
/// menu enters AppKit's modal tracking loop and blocks for the better part of a
/// minute, which is where an earlier attempt at this stalled. `menu(for:)` is
/// the exact call AppKit makes on the way to that loop, and it returns before it.
@MainActor
final class StripMenuWiringTests: XCTestCase {

    private var scratch: URL!
    private var manager: ShelfManager!
    private var shelfID: UUID!
    private var items: [ShelfItem] = []

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("strip-menu-wiring-\(UUID().uuidString)", isDirectory: true)
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
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A collapsed shelf hosted the way the app hosts one, left in the state a
    /// summoned shelf starts in.
    private func hostCollapsedShelf() -> (NSPanel, NSSize) {
        let size = ShelfLayout.collapsedSize(itemCount: items.count)
        let host = NSHostingView(
            rootView: ShelfContainerView(
                manager: manager,
                conversionService: ConversionService(),
                ocrService: OCRService(),
                routeService: RouteService(),
                shelfID: shelfID
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

    /// The middle of a row, in window coordinates. Newest first, so row 0 is the
    /// last file added.
    private func rowPoint(_ index: Int, size: NSSize) -> NSPoint {
        let fromTop = ShelfLayout.margin
            + ShelfLayout.stripHeaderHeight
            + ShelfLayout.stripHeaderGap
            + ShelfLayout.rowHeight / 2
            + CGFloat(index) * (ShelfLayout.rowHeight + ShelfLayout.rowSpacing)
        return NSPoint(x: size.width / 2, y: size.height - fromTop)
    }

    private func clickRow(_ index: Int, in panel: NSPanel, size: NSSize) {
        let point = rowPoint(index, size: size)
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

    private func dragInitiators(in view: NSView) -> [DragInitiatorView] {
        (view as? DragInitiatorView).map { [$0] } ?? []
            + view.subviews.flatMap { dragInitiators(in: $0) }
    }

    /// The menu the row under `point` would put up, obtained the way AppKit
    /// obtains it and without entering its tracking loop.
    private func menuFromRow(
        at index: Int, in panel: NSPanel, size: NSSize
    ) throws -> ShelfActionTargets {
        let point = rowPoint(index, size: size)
        let content = try XCTUnwrap(panel.contentView)
        let row = try XCTUnwrap(
            dragInitiators(in: content).first {
                $0.convert($0.bounds, to: nil).contains(point)
            },
            "no row view under the point a right-click would land on — the strip's rows are not where the test believes they are"
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(
            row.menu(for: event) as? ShelfActionNSMenu,
            "a right-click on a strip row offers no menu at all"
        )
        return try XCTUnwrap(menu.targets)
    }

    // MARK: - The menu a row hands out

    /// **The whole defect, driven.** Pick one row of three, right-click it, and
    /// read what the menu's rows would act on. It used to be three: the row
    /// carried the shelf's menu, built with no selection at all, so Move to
    /// Trash recycled the two files the header said were not in play.
    func test_a_right_click_on_a_picked_row_offers_a_menu_scoped_to_the_pick() throws {
        let (panel, size) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        clickRow(0, in: panel, size: size)
        let targets = try menuFromRow(at: 0, in: panel, size: size)

        XCTAssertEqual(
            targets.items.map(\.displayName), ["three.txt"],
            "the strip narrowed to one row still opens a menu whose every action takes the whole shelf — with Move to Trash on it, that is the user's files"
        )
    }

    /// And nothing is taken from the default state: an untouched strip offers
    /// the menu it always did, over the whole shelf.
    func test_a_right_click_on_an_untouched_strip_still_offers_the_whole_shelf() throws {
        let (panel, size) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        let targets = try menuFromRow(at: 1, in: panel, size: size)
        XCTAssertEqual(
            Set(targets.items.map(\.displayName)), ["one.txt", "two.txt", "three.txt"],
            "a right-click on a shelf nobody has narrowed no longer offers the shelf — the effortless default is gone"
        )
    }

    // MARK: - Quick Look

    /// Space and ⌘Y reach `QuickLookController` through the responder chain, and
    /// its URL provider lives on the app delegate, which cannot see a view's
    /// `@State`. It previewed the whole shelf over a header reading `1 of 3`.
    /// This is the door that provider now reads, driven from a real click.
    func test_quick_look_previews_the_pick() throws {
        let (panel, size) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        clickRow(0, in: panel, size: size)

        XCTAssertEqual(
            manager.carriedItemsOnStrip(of: shelfID).map(\.displayName), ["three.txt"],
            "Quick Look opens on the whole shelf after the user has narrowed the strip to one row — the preview and the header disagree about what \"this\" is"
        )
    }

    func test_quick_look_previews_the_whole_shelf_when_nothing_is_picked() throws {
        let (panel, _) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        XCTAssertEqual(
            manager.carriedItemsOnStrip(of: shelfID).count, 3,
            "the space bar on an untouched shelf previews less than the shelf"
        )
    }

    /// The one thing that cannot be reached from a test: the provider itself is
    /// installed on the app delegate at launch. So the call it makes is read.
    func test_the_quick_look_provider_asks_for_the_carried_set() throws {
        let app = magpieCodeOnly(try source("Sources/Magpie/App.swift"))
        let provider = try XCTUnwrap(
            app.components(separatedBy: "private func urlsForKeyPanel()").last,
            "the Quick Look provider is gone"
        )
        XCTAssertTrue(
            provider.contains("carriedItemsOnStrip("),
            "Quick Look's URLs are read straight off the shelf again, so the preview ignores what the strip's header says is in play"
        )
    }

    // MARK: - One published fact, not two

    /// The key monitor's "is there anything for Escape to clear" and Quick
    /// Look's "what is picked" are the same fact and must stay one value. They
    /// were separately maintained flags for about an hour; a pick that grew from
    /// one row to two would have left the second one stale.
    func test_the_narrowing_the_monitor_sees_is_the_pick_quick_look_sees() throws {
        let (panel, size) = hostCollapsedShelf()
        defer { panel.orderOut(nil) }

        XCTAssertFalse(
            manager.shelvesWithNarrowedSelection.contains(shelfID),
            "a resting strip claims a narrowing, so Escape is swallowed where it should fall through"
        )

        clickRow(0, in: panel, size: size)
        XCTAssertTrue(
            manager.shelvesWithNarrowedSelection.contains(shelfID),
            "the strip is narrowed and nothing told the key monitor, so Escape has no way back to the whole shelf"
        )
        XCTAssertEqual(
            manager.stripSelections[shelfID]?.count, 1,
            "the published pick is not the one on screen"
        )

        // Growing the pick is the case a boolean could not see.
        clickRow(1, in: panel, size: size)
        settle()
        XCTAssertEqual(
            manager.carriedItemsOnStrip(of: shelfID).map(\.displayName), ["two.txt"],
            "the published pick did not follow the second click — it is only refreshed when the shelf goes from unpicked to picked, so every later change is invisible outside the view"
        )
    }

    /// The row overlays own the shelf menu. The hosting view owns the gaps and
    /// chrome, and must explicitly return no menu so the app-wide Edit menu
    /// cannot be synthesised there as a one-row `Paste` popup.
    func test_the_strip_host_explicitly_suppresses_responder_edit_menus() throws {
        let source = try source("Sources/Magpie/FloatingPanel.swift")
        let hosting = try XCTUnwrap(
            source.components(separatedBy: "private final class FirstMouseHostingView").last,
            "the strip's hosting view disappeared"
        )
        XCTAssertTrue(
            hosting.contains("override func menu(for event: NSEvent) -> NSMenu? { nil }"),
            "the strip's hosting view leaves its gaps and chrome to the responder chain, so MainMenu's paste: action can become a stray Paste popup"
        )
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
