import AppKit
import SwiftUI

/// The one question the magpie asks, the first time the user presses its X:
/// hide it, or keep it. It is a card the bird carries in, sets down beside
/// the shelf and stands on, rather than a system alert with a picture of the
/// bird on it: the bird is the thing being asked about, and fetching and
/// carrying is what it does.
///
/// Keyboard first: Return and Escape keep the bird (the safe answer), and
/// ⌘⌫ hides it, as a destructive button's shortcut does elsewhere on the Mac.
@MainActor
final class MascotQuestionCard: NSPanel {
    var onKeep: () -> Void = {}
    var onHide: () -> Void = {}
    private let hosting: NSHostingView<MascotQuestionView>

    init() {
        var keep: () -> Void = {}
        var hide: () -> Void = {}
        hosting = NSHostingView(rootView: MascotQuestionView(keep: { keep() }, hide: { hide() }))
        hosting.frame.size = hosting.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: hosting.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        keep = { [weak self] in self?.onKeep() }
        hide = { [weak self] in self?.onHide() }
        contentView = hosting
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setAccessibilityLabel(L("mascot.hide.title"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Escape keeps the bird.
    override func cancelOperation(_ sender: Any?) { onKeep() }

    var size: CGSize { hosting.frame.size }

    /// The card drawn as a picture, for the flight: the bird carries this,
    /// and the live card takes its place once it is set down.
    func snapshot() -> CGImage? {
        hosting.appearance = NSApp.effectiveAppearance
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    /// Where the card goes, in screen points (y-up): under the shelf, with
    /// room above it for the bird to stand on its top edge; above the shelf
    /// when the shelf is too near the bottom of the screen; else in the
    /// middle of the screen. Its right edge lines up with the shelf's, which
    /// is the side the bird stands on.
    static func frame(size: CGSize, shelf: NSRect, visible: NSRect) -> NSRect {
        let margin: CGFloat = 8
        var origin = CGPoint(x: shelf.maxX - size.width, y: shelf.minY - birdRoom - size.height)
        if origin.y < visible.minY + margin {
            origin.y = shelf.maxY + gap
            if origin.y + size.height + birdRoom > visible.maxY - margin {
                origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            }
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - margin - size.width)
        return NSRect(origin: origin, size: size)
    }

    /// The headroom the bird needs above the card to stand on it, and the
    /// gap kept between a card above the shelf and the shelf.
    static let birdRoom: CGFloat = 58
    static let gap: CGFloat = 16
}

/// The card's face.
struct MascotQuestionView: View {
    let keep: () -> Void
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            Text(L("mascot.hide.title"))
                .font(Design.Text.title)
                .foregroundStyle(Design.Ink.primary)
            Text(L("mascot.hide.body"))
                .font(Design.Text.item)
                .foregroundStyle(Design.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.md) {
                Spacer(minLength: 0)
                Button(L("mascot.hide.confirm"), role: .destructive, action: hide)
                    .keyboardShortcut(.delete, modifiers: .command)
                Button(L("Cancel"), action: keep)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Design.Space.xs)
        }
        .padding(Design.Space.gutter)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                .fill(Design.Surface.question)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                .strokeBorder(Design.Line.panel, lineWidth: Design.Line.panelWidth)
        )
    }
}
