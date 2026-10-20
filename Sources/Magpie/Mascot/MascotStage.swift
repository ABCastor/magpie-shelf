import AppKit
import QuartzCore

/// Where the magpie stands, in a shelf window's own terms.
///
/// The bird is not part of the shelf panel. It stands on the panel's bottom
/// edge with its tail hanging over it, and it flies between the shelf and the
/// docked tab, so it draws outside the panel's rounded clip; it lives in its
/// own transparent windows beside the panel instead. This is the arithmetic
/// that ties the two together, kept pure so a test can hold it.
enum MascotPlacement {
    /// The box's left edge sits this far in from the shelf's right edge (the
    /// page's `home`: `r.right - 74`), which puts the feet 45 points in.
    static let inset: CGFloat = 74

    /// The rest window around the feet: room for the box, the tail below the
    /// edge, the pet X above and to the right, and the hop and the lean.
    static let restWindowSize = CGSize(width: 98, height: 110)
    /// Where the feet are inside the rest window, from its top-left, y-down.
    static let restFeet = CGPoint(x: 41, y: 80)

    /// The pet X, relative to the bird's box (`right:-14px; top:-9px`, 14 × 14).
    static let petX = CGRect(x: 58, y: -9, width: 14, height: 14)

    /// Where the feet stand on a shelf, in screen coordinates (y-up).
    static func perchedFeet(onShelf frame: NSRect) -> NSPoint {
        NSPoint(x: frame.maxX - inset + MascotDrawing.size.width / 2, y: frame.minY)
    }

    /// Where the feet stand inside a docked tab: centred in the part of the
    /// tab that is on screen, on its bottom edge. The tab keeps its size; the
    /// bird shrinks to `MascotFlight.dockScale` to fit.
    static func dockedFeet(onTab frame: NSRect, screen: NSRect) -> NSPoint {
        let visible = frame.intersection(screen)
        let midX = visible.isNull ? frame.midX : visible.midX
        return NSPoint(x: midX, y: frame.minY)
    }

    /// The rest window's frame for feet at `feet` (screen, y-up).
    static func restFrame(feet: NSPoint) -> NSRect {
        NSRect(
            x: feet.x - restFeet.x,
            y: feet.y - (restWindowSize.height - restFeet.y),
            width: restWindowSize.width,
            height: restWindowSize.height
        )
    }

    /// The box position inside the rest window that stands the feet on
    /// `restFeet`.
    static var restBox: CGPoint { MascotGeometry.standing(feetAt: restFeet) }

    /// The centre of the shelf's own close X in screen coordinates: the first
    /// control in the strip's header, one margin in from the top-left.
    static func closeX(onShelf frame: NSRect) -> NSPoint {
        let half = Design.Size.chromeButton / 2
        return NSPoint(
            x: frame.minX + ShelfLayout.margin + half,
            y: frame.maxY - ShelfLayout.margin - half
        )
    }
}

/// A y-down coordinate space over every screen, so flight maths written for
/// the page can run unchanged: the page's y grows downward.
struct MascotSpace {
    /// The top of the primary screen, the line AppKit's y counts up from.
    let top: CGFloat

    static var current: MascotSpace {
        MascotSpace(top: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    func down(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: top - p.y) }
    func up(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: top - p.y) }
    func down(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height) }

    /// The box position that stands the feet on `feet` (screen, y-up).
    func box(feet: NSPoint) -> CGPoint { MascotGeometry.standing(feetAt: down(feet)) }
}

/// A borderless, see-through window that never takes key status.
final class MascotWindow: NSPanel {
    init(interactive: Bool) {
        super.init(
            contentRect: NSRect(origin: .zero, size: MascotPlacement.restWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // The flight window is pure picture. The rest window is left at the
        // window server's default, which passes a click on a transparent
        // pixel through to whatever is below: the bird catches the pointer,
        // the air around it does not.
        if !interactive { ignoresMouseEvents = true }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The view the perched bird lives in: it hovers, takes a click, shows the
/// pet X, and hands any file dragged onto it to the shelf it is standing on.
final class MascotRestView: MascotCanvasView {
    var bird: MascotLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let bird { layer?.insertSublayer(bird, below: xLayer) }
        }
    }
    var onHover: (Bool) -> Void = { _ in }
    var onClickBird: () -> Void = {}
    var onClickX: () -> Void = {}
    /// The shelf's drop view, to forward drops to. Weak: the shelf owns it.
    weak var dropForward: NSView?
    /// Docked: the bird is decoration inside the tab, and a click on it is a
    /// click on the tab.
    var isDocked = false
    var onDockedClick: () -> Void = {}

    private let xLayer = CATextLayer()
    private let xHit = CALayer()
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        xHit.backgroundColor = NSColor(white: 1, alpha: 0.01).cgColor
        xHit.opacity = 0
        layer?.addSublayer(xHit)
        xLayer.string = "×"
        xLayer.alignmentMode = .center
        xLayer.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        xLayer.fontSize = 15
        xLayer.opacity = 0
        layer?.addSublayer(xLayer)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .tiff, .png, .string]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:)))
        registerForDraggedTypes(types)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("mascot.a11y.name"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The bird's box and the X, in this view's coordinates.
    var boxRect: CGRect {
        guard let bird else { return .zero }
        let p = bird.pose
        let size = MascotDrawing.size
        let o = MascotGeometry.origin
        let w = size.width * p.k, h = size.height * p.k
        return CGRect(x: p.x + o.x - o.x * p.k, y: p.y + o.y - o.y * p.k, width: w, height: h)
    }

    var xRect: CGRect {
        let b = boxRect
        guard b != .zero else { return .zero }
        return MascotPlacement.petX.offsetBy(dx: b.minX, dy: b.minY)
    }

    func layoutX(dark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = xRect
        xLayer.frame = r.insetBy(dx: -2, dy: -2)
        xLayer.contentsScale = window?.backingScaleFactor ?? 2
        xLayer.foregroundColor = (dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.62)).cgColor
        xHit.frame = r.insetBy(dx: -3, dy: -3)
        CATransaction.commit()
    }

    func setXVisible(_ visible: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        xLayer.opacity = visible ? 1 : 0
        xLayer.transform = visible ? CATransform3DIdentity : CATransform3DMakeScale(0.8, 0.8, 1)
        xHit.opacity = visible ? 1 : 0
        CATransaction.commit()
        updateAccessibilityChildren(xVisible: visible)
    }

    /// Keeps the X where it is while the bird flies to it ("the X stays").
    func pinX() { xHit.opacity = 0 }
    func hideX() { setXVisible(false, animated: false) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func isOverBird(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        return boxRect.contains(p) || (!isDocked && hovering && xRect.insetBy(dx: -3, dy: -3).contains(p))
    }

    private func updateHover(_ event: NSEvent) {
        let over = isOverBird(event)
        guard over != hovering else { return }
        hovering = over
        onHover(over)
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if hovering { hovering = false; onHover(false) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isDocked { onDockedClick(); return }
        if xHit.opacity > 0, xRect.insetBy(dx: -3, dy: -3).contains(p) {
            onClickX()
        } else if boxRect.contains(p) {
            onClickBird()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drops land on the shelf underneath

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropForward?.draggingEntered(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropForward?.draggingUpdated(sender) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropForward?.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropForward?.draggingEnded(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropForward?.performDragOperation(sender) ?? false
    }

    // MARK: Accessibility: the X is a real button while it is shown

    private lazy var xElement: MascotXElement = {
        let e = MascotXElement()
        e.setAccessibilityRole(.button)
        e.setAccessibilityLabel(L("mascot.send-away"))
        e.setAccessibilityParent(self)
        e.press = { [weak self] in self?.onClickX() }
        return e
    }()

    private func updateAccessibilityChildren(xVisible: Bool) {
        if xVisible {
            xElement.setAccessibilityFrameInParentSpace(xRect)
            setAccessibilityChildren([xElement])
        } else {
            setAccessibilityChildren([])
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClickBird()
        return true
    }
}

/// The pet X, as VoiceOver sees it: a button that sends the magpie away.
final class MascotXElement: NSAccessibilityElement {
    var press: () -> Void = {}
    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
