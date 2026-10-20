import AppKit
import SwiftUI

/// Keeps a restored panel frame on a screen that still exists. Pure, because
/// the failure it guards is invisible in a unit test any other way: unplug a
/// monitor while a shelf is docked, undock, and the saved pre-dock frame names
/// coordinates no screen has any more — and an LSUIElement app has no dock
/// icon and no window menu, so a panel parked off-screen is unrecoverable
/// from inside the app.
enum PanelFrameClamp {
    /// Returns `frame` moved — never resized — so it sits inside one of the
    /// given screen rects. A frame already fully inside a screen comes back
    /// verbatim. The screen with the largest overlap wins; a frame off every
    /// screen goes to the one whose center is nearest. An empty `screens`
    /// (headless edge case) returns the frame unchanged, because there is
    /// nowhere better to put it.
    static func clamp(_ frame: NSRect, into screens: [NSRect]) -> NSRect {
        guard !screens.isEmpty else { return frame }
        let overlaps = screens.map { $0.intersection(frame) }
        let target: NSRect
        if let best = overlaps.indices.max(by: { area(overlaps[$0]) < area(overlaps[$1]) }),
           area(overlaps[best]) > 0 {
            target = screens[best]
        } else {
            let center = NSPoint(x: frame.midX, y: frame.midY)
            target = screens.min(by: {
                distanceSquared(from: center, to: $0) < distanceSquared(from: center, to: $1)
            })!
        }
        var origin = frame.origin
        // min before max: a frame larger than the screen pins to the
        // screen's near edge instead of drifting past the far one.
        origin.x = max(min(origin.x, target.maxX - frame.width), target.minX)
        origin.y = max(min(origin.y, target.maxY - frame.height), target.minY)
        return NSRect(origin: origin, size: frame.size)
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}

final class FloatingPanel<Content: View>: NSPanel {
    /// The panel's two possible grounds, exposed so tests can assert which one
    /// is live. Exactly one is visible at a time — see `applyReduceTransparency`.
    let materialView = NSVisualEffectView()
    let opaqueGround = OpaquePanelGroundView()
    /// The glass: a coat of the window ground over the blur, as thick as the
    /// Settings slider says (`ShelfGlass`). Hidden under Reduce Transparency,
    /// where `opaqueGround` stands in for both.
    let frostView = OpaquePanelGroundView()
    private var transparencyObserver: NSObjectProtocol?
    private var glassObserver: NSObjectProtocol?

    /// The notch island: black, flush with the top of the screen, rounded
    /// only at the bottom. Whatever the appearance, so the island reads as the
    /// notch grown down rather than as a window.
    var isIsland = false {
        didSet {
            guard isIsland != oldValue else { return }
            applyGround()
        }
    }

    init(contentRect: NSRect, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        let root = FloatingPanelRootView(frame: contentRect)
        root.wantsLayer = true
        root.layer?.cornerRadius = Design.Radius.panel
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true

        // The panel's ground. `.popover` is the material macOS uses for
        // transient floating surfaces, which is exactly what a summoned shelf
        // is; `.sidebar` is tinted for a surface docked inside a window and
        // read as a bespoke slab here.
        //
        // The appearance is NOT forced. It was pinned to `.vibrantDark`, which
        // gave the app two appearance models at once — the panel always dark
        // while Settings followed the system — and made every `Color.white`
        // token in `Design` look deliberate when it was only unexamined.
        // Following the system is the decision recorded in the build ledger on
        // 2026-07-28.
        let blur = materialView
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.isEmphasized = false
        blur.translatesAutoresizingMaskIntoConstraints = false

        // The Reduce Transparency stand-in: same frame as the material, and
        // exactly one of the two is ever visible. An opaque view rather than a
        // repainted material because the setting's promise is "nothing behind
        // the window shows through", and a material keeps its own counsel
        // about that.
        let opaque = opaqueGround
        opaque.translatesAutoresizingMaskIntoConstraints = false

        let hosting = FirstMouseHostingView(
            rootView: FloatingPanelContent(content: content)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let frost = frostView
        frost.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(opaque)
        root.addSubview(blur)
        root.addSubview(frost)
        root.addSubview(hosting)

        NSLayoutConstraint.activate([
            opaque.topAnchor.constraint(equalTo: root.topAnchor),
            opaque.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            opaque.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            opaque.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            frost.topAnchor.constraint(equalTo: root.topAnchor),
            frost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            frost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            frost.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            hosting.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        contentView = root

        applyReduceTransparency(Design.Transparency.isReduced)
        // The glass slider writes to user defaults; every panel on screen
        // follows it as it moves.
        glassObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyGround() }
        }
        // Same live-update contract as Reduce Motion: the user flips the
        // setting and every panel already on screen follows, no relaunch.
        transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyReduceTransparency(Design.Transparency.isReduced)
            }
        }
    }

    deinit {
        if let transparencyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver)
        }
        if let glassObserver {
            NotificationCenter.default.removeObserver(glassObserver)
        }
    }

    /// When Reduce Transparency is on, the panel trades its material for an
    /// opaque semantic ground. `Design.Transparency.opaquePanelGround` keeps
    /// the contrast floors ADR 0006 established, in both appearances —
    /// asserted by `AppearanceTests`, not eyeballed.
    func applyReduceTransparency(_ reduced: Bool) {
        materialView.isHidden = reduced
        opaqueGround.isHidden = !reduced
        applyGround()
    }

    /// The coat over the blur, from the glass slider; and the island's black.
    func applyGround() {
        let reduced = materialView.isHidden
        frostView.isHidden = reduced && !isIsland
        frostView.fill = isIsland ? .black : nil
        frostView.alphaValue = isIsland ? 1 : ShelfGlass.groundAlpha(ShelfGlass.current)
        if isIsland {
            frostView.isHidden = false
            appearance = NSAppearance(named: .darkAqua)
        } else if appearance?.name == .darkAqua, islandForcedAppearance {
            appearance = nil
        }
        islandForcedAppearance = isIsland
        if let layer = contentView?.layer {
            layer.maskedCorners = isIsland
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        frostView.needsDisplay = true
    }

    private var islandForcedAppearance = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// An opaque stand-in for the panel material under Reduce Transparency.
/// `updateLayer` runs with the view's effective appearance current, so the
/// semantic colour resolves per appearance and re-resolves when it changes.
final class OpaquePanelGroundView: NSView {
    /// A fixed colour in place of the semantic ground (the notch island).
    var fill: NSColor? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (fill ?? Design.Transparency.opaquePanelGround).cgColor
    }
}

/// Hosting view that delivers the first click even when the panel isn't key.
/// Without this, clicks on a non-key `.nonactivatingPanel` only bring the panel
/// to key state and the underlying SwiftUI view never sees the event.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The strip's row overlays own their context menus. The hosting view owns
    /// the gaps and chrome, which must have no context menu of their own. If it
    /// leaves this to AppKit, the app-wide Edit menu can be synthesised from
    /// the responder chain as a one-row `Paste` popup.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// Injects `QuickLookController.shared` into the shelf panel's responder chain
/// so QLPreviewPanel can discover a controller and the space key is routed to it.
private final class FloatingPanelRootView: NSView {
    override var nextResponder: NSResponder? {
        get {
            QuickLookController.shared.nextResponder = super.nextResponder
            return QuickLookController.shared
        }
        set { super.nextResponder = newValue }
    }

    override var acceptsFirstResponder: Bool { true }
}

private struct FloatingPanelContent<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Flat darkening wash — uniform top to bottom.
            Design.Surface.panelWash
                .allowsHitTesting(false)

            // Subtle even stroke — no top-weighted gradient.
            RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                .strokeBorder(Design.Line.panel, lineWidth: Design.Line.panelWidth)
                .allowsHitTesting(false)

            // No padding here — each shelf view applies its own margin so
            // that compact states (e.g. docked) can fill the panel edge-to-
            // edge and accept drops across the full visible surface.
            content
        }
        .ignoresSafeArea()
    }
}
