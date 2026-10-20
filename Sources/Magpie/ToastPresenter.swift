import AppKit
import SwiftUI

/// The toast's geometry decisions, all pure: how big a panel a message needs,
/// and whether the pointer is holding one open. `ToastPresenter` is the thin
/// AppKit call site around them and carries no judgement of its own, because
/// none of it can be reached from a test.
enum ToastMetrics {

    // MARK: - Bounds

    /// A floor, and only a floor: enough that a two-word message is still a
    /// shape rather than a sliver.
    ///
    /// **It was 210**, matched to the width of the old square panel, and that
    /// is the defect the owner reported. A floor that wide is not a floor —
    /// it is the operative width for most real messages, so "OCR cancelled."
    /// was painted at the left edge of a box with a hundred points of nothing
    /// beside it. A toast is sized by its sentence; the shelf's width has no
    /// opinion about it.
    static let minWidth: CGFloat = 120
    /// Past this a pop-up stops reading as a toast and starts reading as a
    /// dialog, so a long message wraps and the panel grows downwards instead.
    /// Was 320 — nearly twice the width of the shelf it is anchored under.
    static let maxWidth: CGFloat = 260
    /// Around twelve lines. No translated string comes within a third of it;
    /// the cap is here so a route the user named in a paragraph cannot turn a
    /// toast into a wall.
    static let maxHeight: CGFloat = 200

    // MARK: - Chrome

    static let horizontalPadding = Design.Space.xl
    static let verticalPadding = Design.Space.lg
    /// The leading glyph's column, and the gap after it. Geometry rather than
    /// vocabulary, so it lives here and not in `Design`.
    static let glyphWidth: CGFloat = 14
    static let glyphGap = Design.Space.sm
    /// Everything across the panel that is not the message.
    static let chromeWidth = horizontalPadding * 2 + glyphWidth + glyphGap

    /// SwiftUI breaks the lines itself, and it can disagree with TextKit by a
    /// fraction of a point. Every measurement below is taken 1pt meaner than
    /// the room the live layout will offer, so the drawn text can only ever
    /// wrap the same or fewer times than the panel was sized for.
    static let fitTolerance: CGFloat = 1
    /// The same disagreement, vertically. `ToastView` fixes the text's size so
    /// it can never be truncated; these two points keep a hair of overflow
    /// from painting into the corner radius.
    static let heightSlack: CGFloat = 2
    /// Wide enough that nothing wraps while the natural width is taken.
    static let unboundedWidth: CGFloat = 100_000

    // MARK: - The message

    /// The `.strings` files carry hard line breaks tuned for the old fixed
    /// two-line box (`"One or more items is\nalready present in the shelf"`).
    /// The toast now wraps at whatever width it chose, where an inherited
    /// break only puts a ragged edge in the middle of a sentence. The nine
    /// files keep theirs; the toast folds them away as it renders.
    static func normalized(_ message: String) -> String {
        message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// TextKit's answer for the message, in the font `ToastView` draws it in.
    static func measureText(_ text: String, width: CGFloat) -> CGSize {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Design.Text.controlMeasuring, .paragraphStyle: style]
        )
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// The panel size a message needs: as wide as the message wants up to
    /// `maxWidth`, then as tall as the wrapped text needs. `measure` is
    /// injected so the arithmetic can be tested apart from real type.
    static func panelSize(
        for message: String,
        measure: (String, CGFloat) -> CGSize = measureText(_:width:)
    ) -> CGSize {
        let text = normalized(message)
        let natural = measure(text, unboundedWidth).width + fitTolerance
        let width = min(max(natural + chromeWidth, minWidth), maxWidth)
        // No height floor. There was one, set two lines deep, and it padded
        // every short message with a line of empty space it had no use for.
        // A floor here can only ever make the panel bigger than its sentence,
        // which is the whole of the defect: TextKit already gives an empty
        // string a full line of height, so nothing can render shorter than
        // one line anyway.
        let textHeight = measure(text, width - chromeWidth - fitTolerance).height
        let height = min(textHeight + verticalPadding * 2 + heightSlack, maxHeight)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    // MARK: - Hover

    /// Whether the pointer is holding the toast open.
    ///
    /// A pressed button means a drag is in flight. The toast sits in the
    /// corridor directly below the shelf, which is exactly where a drag *out*
    /// of the shelf travels, and pinning a banner under that cursor for the
    /// length of the drag would be a worse bug than the one hover fixes.
    static func isHolding(pointer: NSPoint, frame: NSRect, buttonsDown: Bool) -> Bool {
        guard !buttonsDown else { return false }
        return frame.contains(pointer)
    }
}

/// When a toast goes away.
enum ToastDismissal {
    /// Long enough to read a short message, short enough not to nag.
    static let visible: TimeInterval = 2.5
    /// The countdown restarted once the pointer leaves: short, because the
    /// message has just been read, but not instant, because a cursor clipping
    /// a corner on its way past should not read as a glitch.
    static let afterHover: TimeInterval = 0.5
    /// How often the pointer is sampled while a toast is on screen.
    static let sampleInterval: TimeInterval = 0.08

    /// Pure: the auto-dismiss deadline after one sample. Hover suspends the
    /// countdown outright rather than extending it, so a toast held under the
    /// pointer stays up for as long as the user keeps reading it.
    static func deadline(
        now: Date,
        holding: Bool,
        wasHolding: Bool,
        current: Date
    ) -> Date {
        if holding { return .distantFuture }
        if wasHolding { return now.addingTimeInterval(afterHover) }
        return current
    }
}

@MainActor
final class ToastPresenter {
    private var toastPanel: NSPanel?
    private var sampler: Timer?
    private var deadline = Date.distantPast
    private var wasHolding = false

    /// `anchorWindow` is normally a shelf panel; Settings anchors here too when
    /// a preference change needs to report a problem, and the status item's own
    /// window anchors it when nothing else is on screen.
    ///
    /// `symbol` defaults to the warning glyph because most toasts report a
    /// problem; a confirmation passes a checkmark rather than telling the user
    /// something went wrong.
    func show(
        _ message: String,
        near anchorWindow: NSWindow,
        symbol: String = "exclamationmark.circle.fill"
    ) {
        // The panel is sized to the message, and to nothing else. It used to
        // be sized to the message *or* to a 210pt floor borrowed from the old
        // square panel, whichever was larger, which is how a three-word
        // message became a block of text in the corner of an empty box.
        let size = ToastMetrics.panelSize(for: message)
        let panel = makeToastPanel(message: message, symbol: symbol, size: size)
        toastPanel?.orderOut(nil)
        toastPanel = panel

        let shelfFrame = anchorWindow.frame
        let gap = Design.Space.lg
        var originX = shelfFrame.midX - size.width / 2
        var originY = shelfFrame.minY - size.height - gap

        if let screenFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            originX = max(screenFrame.minX + 8,
                          min(originX, screenFrame.maxX - size.width - 8))
            if originY < screenFrame.minY + 8 {
                // Not enough room below; show above the shelf instead.
                originY = shelfFrame.maxY + gap
            }
        }

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: true
        )
        panel.orderFront(nil)

        deadline = Date().addingTimeInterval(ToastDismissal.visible)
        wasHolding = false
        startSampling()
    }

    /// One repeating timer does both jobs — sample the pointer, retire the
    /// toast — and it exists only while a toast is on screen.
    ///
    /// `.common` mode is not optional: AppKit spins a tracking loop for the
    /// whole of a drag out of the shelf, and a default-mode timer stalls
    /// there, leaving the toast on screen for the length of the drag.
    private func startSampling() {
        sampler?.invalidate()
        let timer = Timer(
            timeInterval: ToastDismissal.sampleInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func stopSampling() {
        sampler?.invalidate()
        sampler = nil
    }

    /// Hover is read from the pointer's position rather than from a tracking
    /// area, because the panel deliberately never receives a mouse event —
    /// see `makeToastPanel`.
    private func sample() {
        guard let panel = toastPanel, panel.isVisible else {
            stopSampling()
            return
        }
        let now = Date()
        let holding = ToastMetrics.isHolding(
            pointer: NSEvent.mouseLocation,
            frame: panel.frame,
            buttonsDown: NSEvent.pressedMouseButtons != 0
        )
        deadline = ToastDismissal.deadline(
            now: now,
            holding: holding,
            wasHolding: wasHolding,
            current: deadline
        )
        wasHolding = holding
        if now >= deadline { hide() }
    }

    private func hide() {
        stopSampling()
        toastPanel?.orderOut(nil)
    }

    private func makeToastPanel(message: String, symbol: String, size: CGSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // The toast lands in the corridor below the shelf, which is where a
        // drag *out* of the shelf travels. Two independent things keep that
        // drag going where the user aimed it, and it needs both:
        //
        // 1. It ignores mouse events, still. The panel is transparent to every
        //    event the window server routes, so presses, clicks and the
        //    outside-click watcher behave exactly as they did before there was
        //    a hover affordance at all. That is also why hover cannot be a
        //    tracking area — a panel that receives no mouse events receives no
        //    mouse-entered either — and why `sample()` reads the pointer.
        // 2. Nothing here is a dragging destination. AppKit resolves a drag by
        //    walking front-to-back for a *registered* destination and skips a
        //    view that has none, rather than letting it block. `NSHostingView`
        //    registers types when its SwiftUI content declares a drop, which
        //    `ToastView` does not; unregistering says so out loud so it cannot
        //    quietly become true later.
        panel.ignoresMouseEvents = true
        // Reduce Motion is decided in one place for the whole app.
        panel.animationBehavior = Design.Motion.isReduced ? .none : .utilityWindow

        let hosting = NSHostingView(
            rootView: ToastView(message: ToastMetrics.normalized(message), symbol: symbol)
        )
        // **The panel is sized by `ToastMetrics` and by nothing else, and this
        // is what makes that true of the window rather than only of the view.**
        //
        // The hosting view used to be pinned to the container's four edges with
        // required constraints. A window resizes itself to satisfy required
        // constraints in its content view, and `ToastView` ends in
        // `.frame(maxWidth: .infinity, maxHeight: .infinity)` — so AppKit asked
        // the SwiftUI view how big it wanted to be, was told "as big as you
        // like", and grew the panel to it. Measured, before this line changed:
        // "OCR cancelled." was sized 134×37 and presented in a 134×**215**
        // window; a one-sentence notice was sized 260×52 and presented in a
        // 260×**710** window. `setFrame` ran first and Auto Layout undid it.
        //
        // That is the defect the owner photographed, and it is why shrinking
        // the view did not shrink the box: every test measured `ToastMetrics`,
        // which was already right. So the toast opts out of Auto Layout
        // entirely. Autoresizing keeps the view filling a panel whose size is
        // decided in exactly one place.
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(hosting)
        container.unregisterDraggedTypes()
        hosting.unregisterDraggedTypes()
        panel.contentView = container
        return panel
    }
}

/// Internal rather than private for the same reason as `DragModeBar`:
/// `RenderSnapshots` is the only thing in this toolchain that can look at the
/// app, and the toast's shape was reported as a defect by someone who *did*
/// look at it.
struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        // First baseline, so the glyph sits on the first line of a wrapped
        // message instead of drifting to the middle of the block.
        HStack(alignment: .firstTextBaseline, spacing: ToastMetrics.glyphGap) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Design.Ink.glyph)
                .frame(width: ToastMetrics.glyphWidth)
            Text(message)
                .font(Design.Text.control)
                .foregroundStyle(Design.Ink.strong)
                // No line limit, and a fixed vertical size: the text takes the
                // height it needs and can never be truncated. `ToastMetrics`
                // sized the panel for exactly this.
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                // The message wins the width, and there is no `Spacer` beside
                // it to argue. A `Spacer(minLength: 0)` used to sit here and
                // an HStack splits its width between two flexible children —
                // so the text was handed less room than `ToastMetrics` sized
                // the panel for and wrapped a sentence that fitted. The old
                // 210pt floor hid it; a panel that hugs its message cannot.
                .layoutPriority(1)
        }
        .padding(.horizontal, ToastMetrics.horizontalPadding)
        .padding(.vertical, ToastMetrics.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                .fill(Design.Surface.toast)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                        .strokeBorder(Design.Line.hairlineFaint, lineWidth: Design.Line.hairlineWidth)
                )
        )
    }
}
