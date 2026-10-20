import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// Offscreen renders of the real shelf views, in both appearances, written to
/// disk as PNGs.
///
/// This exists because Magpie is an `LSUIElement` accessory whose only surface
/// is a floating panel summoned by a hotkey. Nothing in the harness can see it:
/// the app is absent from every application enumeration, a full-screen app
/// hides the menu bar so screen capture returns black, and the one inbound URL
/// verb is `add`, which mutates a real shelf. So every appearance claim about
/// this app has been INFERENCE — including the whole UX audit, which was
/// written without ever launching it.
///
/// It is **not** in the gate: without `MAGPIE_RENDER_SNAPSHOTS=1` every test
/// here returns immediately. It renders SwiftUI content over an approximated
/// panel ground, so it is accurate for colour, contrast, type and hierarchy,
/// and **not** for the `NSVisualEffectView` blur behind the real panel. Judge
/// material from a real screenshot; judge everything else here.
///
///     MAGPIE_RENDER_SNAPSHOTS=1 swift test --filter RenderSnapshots
///
/// Output: `$TMPDIR/magpie-snapshots/` (override with `MAGPIE_SNAPSHOT_DIR`).
@MainActor
final class RenderSnapshots: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["MAGPIE_RENDER_SNAPSHOTS"] == "1"
    }

    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MAGPIE_SNAPSHOT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-snapshots", isDirectory: true)
    }

    // MARK: - Fixture

    /// A shelf built through the real ingest path (`addFile`), so items carry
    /// the same names, sizes and kinds they would in production.
    ///
    /// `extra` pads the shelf out with plausible filenames. "Does a full shelf
    /// look full" is the whole point of the vertical strip and cannot be
    /// judged from a three-item fixture.
    private func makeFixture(extra: Int = 0) throws -> (manager: ShelfManager, shelfID: UUID, scratch: URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-snapshot-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let notes = scratch.appendingPathComponent("Meeting notes.txt")
        try """
        Shipping notes for the appearance pass.

        The panel follows the system now, and the ink ladder resolves per
        appearance instead of being white at thirteen opacities.
        """.write(to: notes, atomically: true, encoding: .utf8)

        let report = scratch.appendingPathComponent("Quarterly report.md")
        try "# Quarterly report\n\nA second text card so the stack has depth.\n"
            .write(to: report, atomically: true, encoding: .utf8)

        let archive = scratch.appendingPathComponent("assets-bundle.zip")
        try Data(repeating: 0x50, count: 48_000).write(to: archive)

        var urls = [notes, report, archive]
        let padding = [
            "Invoice 2026-07.pdf", "Screenshot at 14.02.png", "keynote-draft.key",
            "budget.numbers", "onboarding-checklist.md", "logo-mark@2x.svg",
            "contract-signed.pdf", "release-notes.txt", "avatar.heic",
        ]
        for index in 0..<extra {
            let url = scratch.appendingPathComponent(padding[index % padding.count])
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(repeating: 0x41, count: 12_000 + index * 900).write(to: url)
                urls.append(url)
            }
        }

        let store = ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        let manager = ShelfManager(store: store)
        let shelfID = manager.createShelf()
        for url in urls {
            _ = manager.addFile(url: url, to: shelfID)
        }
        return (manager, shelfID, scratch)
    }

    // MARK: - Rendering

    /// Renders `view` at `size` under `appearance`, composited over `ground`
    /// (a stand-in for the panel's visual-effect material).
    private func render<V: View>(
        _ view: V,
        size: NSSize,
        appearance appearanceName: NSAppearance.Name,
        ground: NSColor,
        to fileName: String
    ) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))

        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance

        // A container so the content composites over an opaque ground rather
        // than onto transparency, which is what the real panel does.
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.appearance = appearance
        container.layer?.backgroundColor = ground.cgColor
        container.layer?.cornerRadius = Design.Radius.panel
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(host)

        // Let SwiftUI settle and async thumbnail work land before capture.
        container.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent(fileName))
    }

    /// The ground each appearance's panel material reads as, close enough to
    /// judge foreground contrast against.
    private func ground(for appearanceName: NSAppearance.Name) -> NSColor {
        appearanceName == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1)
            : NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    // MARK: - Tests

    /// The shelf at three sizes, because the panel is now a function of what
    /// is on it: one file, a small handful, and more than the strip can show
    /// at once. A single fixture cannot answer "does a full shelf look full".
    func testCollapsedShelfAtEveryFullnessInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        for (extra, count) in [(-2, 1), (0, 3), (9, 12)] {
            let fixture = try makeFixture(extra: max(extra, 0))
            defer { try? FileManager.default.removeItem(at: fixture.scratch) }
            // The 1-item case drops the two text cards so the strip has a
            // single row, which is the shape a just-dropped shelf has.
            if count == 1 {
                for item in fixture.manager.items(of: fixture.shelfID).dropLast() {
                    fixture.manager.removeItem(id: item.id, from: fixture.shelfID)
                }
            }
            let items = fixture.manager.items(of: fixture.shelfID).count
            let size = ShelfLayout.collapsedSize(itemCount: items)
            for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
                try render(
                    CollapsedShelfHost(manager: fixture.manager, shelfID: fixture.shelfID)
                        .padding(ShelfLayout.margin),
                    size: size,
                    appearance: name,
                    ground: ground(for: name),
                    to: "strip-\(items)-\(label).png"
                )
            }
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// **The selection states of the strip.** ADR 0012 first made the shelf's
    /// default "everything, and you can see it" — every row filled at rest. The
    /// owner looked at exactly these images and rejected them: five files were
    /// five solid bars of accent. The default is quiet now and the header
    /// carries the claim in words, and **whether that reads as calm is the
    /// acceptance criterion**, which is a claim only these pictures can settle.
    func testTheStripInEverySelectionStateInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let fixture = try makeFixture(extra: 2)
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let displayed = ShelfDisplayOrder.displayed(fixture.manager.items(of: fixture.shelfID))
        let items = displayed.count
        let states: [(String, Set<UUID>, ControlActiveState)] = [
            // No explicit narrowing — which IS the whole shelf, drawn with no
            // fill at all. The header says "5 Files"; this is what "calm" has
            // to look like.
            ("default", ShelfSelection.wholeShelf, .key),
            // The same state on a panel the user has not clicked, which is what
            // a freshly summoned non-activating shelf actually is.
            ("default-not-key", ShelfSelection.wholeShelf, .inactive),
            ("one", [displayed[1].id], .key),
            ("several", Set(displayed.prefix(3).map(\.id)), .key),
        ]
        for (state, selection, active) in states {
            for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
                try render(
                    CollapsedShelfHost(
                        manager: fixture.manager,
                        shelfID: fixture.shelfID,
                        selection: selection
                    )
                    .padding(ShelfLayout.margin)
                    .environment(\.controlActiveState, active),
                    size: ShelfLayout.collapsedSize(itemCount: items),
                    appearance: name,
                    ground: ground(for: name),
                    to: "strip-selection-\(state)-\(label).png"
                )
            }
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// One grid card, at the size the expanded browser draws it. ADR 0010 took
    /// the paper face away; this is the only way to see what replaced it.
    func testGridCardInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let item = try XCTUnwrap(fixture.manager.items(of: fixture.shelfID).first)

        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            try render(
                DocumentGridItem(
                    item: item,
                    manager: fixture.manager,
                    shelfID: fixture.shelfID,
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
                .environmentObject(RouteService()),
                size: NSSize(
                    width: ShelfLayout.gridColumnMaximum,
                    height: ShelfLayout.tileHeight
                ),
                appearance: name,
                ground: ground(for: name),
                to: "grid-card-\(label).png"
            )
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// The empty state — the surface that teaches the summon triggers. A
    /// fresh shelf with nothing on it, so what renders is the trigger-aware
    /// hint from `EmptyShelfHint`, not the document stack.
    func testEmptyCollapsedShelfInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("magpie-snapshot-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        let manager = ShelfManager(store: store)
        let shelfID = manager.createShelf()

        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            try render(
                CollapsedShelfHost(manager: manager, shelfID: shelfID)
                    .padding(ShelfLayout.margin),
                size: ShelfLayout.collapsedSize(itemCount: 0),
                appearance: name,
                ground: ground(for: name),
                to: "strip-empty-\(label).png"
            )
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// The drag-out mode indicator, in both modes and both appearances, at the
    /// width of a real collapsed panel. The owner asked to be able to *see*
    /// that ⌘ landed; `AppearanceTests` measures the contrast, and this is the
    /// only thing in the toolchain that can show what it looks like.
    func testDragModeHintInBothModesAndAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            for (intent, mode) in [(DragIntent.copy, "copy"), (DragIntent.move, "move")] {
                try render(
                    DragModeBar(intent: intent, visible: true)
                        .frame(maxWidth: .infinity, alignment: .top),
                    size: NSSize(width: ShelfLayout.stripWidth, height: 28),
                    appearance: name,
                    ground: ground(for: name),
                    to: "drag-hint-\(mode)-\(label).png"
                )
            }
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// **The shelf mid-drag, which is the thing the owner actually looks at.**
    ///
    /// `testDragModeHintInBothModesAndAppearances` renders the pill on an empty
    /// ground, which is why two rounds of work never showed that it sits on top
    /// of the rows. This composes it exactly as `ShelfContainerView` does — the
    /// collapsed strip with `isDragging` true, the hint overlaid on the same
    /// alignment — so "can you still see what you are dragging" is a question a
    /// picture can answer.
    func testTheShelfWhileADragIsInFlight() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let items = fixture.manager.items(of: fixture.shelfID).count
        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            for (intent, mode) in [(DragIntent.copy, "copy"), (DragIntent.move, "move")] {
                try render(
                    DraggingShelfHost(
                        manager: fixture.manager,
                        shelfID: fixture.shelfID,
                        intent: intent
                    ),
                    size: ShelfLayout.collapsedSize(itemCount: items),
                    appearance: name,
                    ground: ground(for: name),
                    to: "strip-dragging-\(mode)-\(label).png"
                )
            }
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// **A drag that is taking one file off a five-file shelf.**
    ///
    /// The strip is quiet at rest now, so the selection fill has exactly one
    /// job left and this is it: for the length of a drag, and before the drop,
    /// the rows travelling light up and the rows staying do not. If these
    /// images do not read as "one of these is leaving" at a glance, the fill is
    /// not paying for itself and neither is the reversal.
    func testTheShelfWhileOneRowIsBeingDragged() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let fixture = try makeFixture(extra: 2)
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let displayed = ShelfDisplayOrder.displayed(fixture.manager.items(of: fixture.shelfID))
        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            try render(
                DraggingShelfHost(
                    manager: fixture.manager,
                    shelfID: fixture.shelfID,
                    intent: .copy,
                    selection: [displayed[1].id]
                ),
                size: ShelfLayout.collapsedSize(itemCount: displayed.count),
                appearance: name,
                ground: ground(for: name),
                to: "strip-dragging-one-\(label).png"
            )
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// The other half of the brand: the ring the panel wears while files are
    /// being dropped onto it. Coral says a card is leaving under ⌘, Klein blue
    /// says a file is arriving, and the only way to check that those two read
    /// as opposites rather than as a matched pair is to look at them.
    func testDropTargetRingInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            for (active, state) in [(true, "active"), (false, "rest")] {
                try render(
                    DropTargetOverlay(active: active)
                        .frame(maxWidth: .infinity, maxHeight: .infinity),
                    size: NSSize(width: ShelfLayout.stripWidth, height: 150),
                    appearance: name,
                    ground: ground(for: name),
                    to: "drop-target-\(state)-\(label).png"
                )
            }
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// The toast, at the size `ToastMetrics` asks for, for a short message and
    /// a long one. The owner's report was about its *shape* — "a full-width
    /// block of text over a large empty region" where a small pop-up belongs —
    /// which is a claim about proportions that only a render can settle.
    func testToastInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let messages = [
            ("short", "OCR cancelled."),
            ("long", "One or more items is\nalready present in the shelf"),
        ]
        for (label, message) in messages {
            let size = ToastMetrics.panelSize(for: message)
            for (name, appearance) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
                try render(
                    ToastView(
                        message: ToastMetrics.normalized(message),
                        symbol: "exclamationmark.circle.fill"
                    ),
                    size: size,
                    appearance: name,
                    ground: ground(for: name),
                    to: "toast-\(label)-\(appearance).png"
                )
            }
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    /// The shelf over the ground Reduce Transparency swaps in — the resolved
    /// `Design.Transparency.opaquePanelGround` rather than the material
    /// approximation, because in that mode this IS the panel, exactly.
    func testShelfContainerOverReduceTransparencyGround() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var ground: NSColor = .windowBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                ground = Design.Transparency.opaquePanelGround.usingColorSpace(.sRGB) ?? ground
            }
            try render(
                ShelfContainerView(
                    manager: fixture.manager,
                    conversionService: ConversionService(),
                    ocrService: OCRService(),
                    routeService: RouteService(),
                    shelfID: fixture.shelfID
                ),
                size: ShelfLayout.collapsedSize(itemCount: 3),
                appearance: name,
                ground: ground,
                to: "container-reduced-transparency-\(label).png"
            )
        }
        print("snapshots written to \(outputDirectory.path)")
    }

    func testShelfContainerInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            try render(
                ShelfContainerView(
                    manager: fixture.manager,
                    conversionService: ConversionService(),
                    ocrService: OCRService(),
                    routeService: RouteService(),
                    shelfID: fixture.shelfID
                ),
                size: ShelfLayout.collapsedSize(itemCount: 3),
                appearance: name,
                ground: ground(for: name),
                to: "container-\(label).png"
            )
        }
        print("snapshots written to \(outputDirectory.path)")
    }
}

/// `CollapsedShelfView` needs a `Namespace.ID`, which only a `View` can vend.
private struct DraggingShelfHost: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    let intent: DragIntent
    /// Empty is the whole shelf, so this renders a drag that is taking
    /// everything unless a test asks for a narrowing.
    var selection: Set<UUID> = ShelfSelection.wholeShelf
    @Namespace private var ns

    var body: some View {
        CollapsedShelfView(
            namespace: ns,
            manager: manager,
            shelfID: shelfID,
            items: manager.items(of: shelfID),
            isDragging: true,
            dragIntent: intent,
            selection: selection
        )
        .padding(ShelfLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CollapsedShelfHost: View {
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    /// Empty is the default and means the whole shelf, so this renders the
    /// resting strip unless a test asks for a narrowing.
    var selection: Set<UUID> = ShelfSelection.wholeShelf
    @Namespace private var ns

    var body: some View {
        CollapsedShelfView(
            namespace: ns,
            manager: manager,
            shelfID: shelfID,
            items: manager.items(of: shelfID),
            selection: selection
        )
    }
}

/// Renders the menu-bar mark at real size and at 12x, so the silhouette can be
/// judged at the size it is actually seen.
@MainActor
final class StatusIconSnapshots: XCTestCase {
    func testRenderStatusIconStates() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAGPIE_RENDER_SNAPSHOTS"] == "1",
            "set MAGPIE_RENDER_SNAPSHOTS=1 to render"
        )
        let dir = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["MAGPIE_SNAPSHOT_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("magpie-snapshots").path,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // One sheet: each state at 1x and at 12x, on a bar-like ground.
        let states: [(String, Bool, Bool)] = [("rest", false, false), ("drop", true, false), ("awake", false, true)]
        let scale: CGFloat = 12
        let side = StatusIcon.side
        let sheet = NSImage(
            size: NSSize(width: side * scale * CGFloat(states.count) + 40, height: side * scale + 60)
        )
        sheet.lockFocus()
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: sheet.size)).fill()
        for (index, state) in states.enumerated() {
            let image = StatusIcon.image(dropping: state.1, awake: state.2)
            // Template images draw black; paint them white for a dark bar.
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.white.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            let x = 20 + CGFloat(index) * side * scale
            tinted.draw(in: NSRect(x: x, y: 40, width: side * scale, height: side * scale))
            tinted.draw(in: NSRect(x: x, y: 12, width: side, height: side))
        }
        sheet.unlockFocus()

        let tiff = try XCTUnwrap(sheet.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("status-icon.png"))
        print("status icon written to \(dir.path)")
    }
}

/// Settings is the one surface the owner judged by eye and called "all messed
/// up". Rendering it here is how that gets checked rather than asserted.
@MainActor
final class SettingsSnapshots: XCTestCase {
    func testRenderSettingsInBothAppearances() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAGPIE_RENDER_SNAPSHOTS"] == "1",
            "set MAGPIE_RENDER_SNAPSHOTS=1 to render"
        )
        let dir = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["MAGPIE_SNAPSHOT_DIR"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("magpie-snapshots").path,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, label) in [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let size = NSSize(width: 620, height: 900)
            let host = NSHostingView(rootView: SettingsView().frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = appearance
            let container = NSView(frame: host.frame)
            container.wantsLayer = true
            container.appearance = appearance
            container.layer?.backgroundColor = (name == .darkAqua
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : NSColor(calibratedWhite: 0.96, alpha: 1)).cgColor
            container.addSubview(host)
            container.layoutSubtreeIfNeeded()
            for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }

            let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("settings-\(label).png"))
        }
        print("settings snapshots written to \(dir.path)")
    }
}
