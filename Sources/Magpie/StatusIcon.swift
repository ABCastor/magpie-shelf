import AppKit

/// The menu-bar mark.
///
/// This is the only part of Magpie that is on screen all the time, so it is
/// the app's whole visual identity — and for most of a session it is the *only*
/// evidence the app exists. A real screenshot of the running app showed the
/// incumbent glyph (a rounded-square outline with a 4pt pip parked in the
/// corner) resolving to a featureless dot, indistinguishable from any other
/// small status item on the bar.
///
/// The replacement is two offset cards: literally what the shelf shows when it
/// holds something, and a silhouette that survives being 18 points wide. A
/// filled front card reads at menu-bar size where a thin stroke does not; the
/// back card is stroked, and a cleared gap between them keeps the two shapes
/// legible as two rather than merging into one blob.
///
/// Drawing lives here as a pure function of its two state flags so it can be
/// rendered and asserted in tests. `AppDelegate` only assigns the result.
enum StatusIcon {

    /// Canvas side. `NSStatusItem` scales anything else, and scaling a 1.4pt
    /// stroke is what turns a mark into a smudge.
    static let side: CGFloat = 18

    /// - Parameters:
    ///   - dropping: a drag is currently over a shelf.
    ///   - awake: keep-awake is on.
    static func image(dropping: Bool, awake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(dropping: dropping, awake: awake)
            return true
        }
        // Template: AppKit recolours it for the bar's appearance, for the
        // menu-open highlight, and for Increase Contrast. A non-template
        // status image is the usual reason an icon looks wrong in Light.
        image.isTemplate = true
        return image
    }

    /// The two card rects, in AppKit's bottom-left origin space. The offset is
    /// deliberately large: at 18 points a small offset leaves the back card as
    /// a hairline crescent that disappears on the bar, which is the failure the
    /// incumbent glyph had.
    static let backCard = NSRect(x: 7.0, y: 5.0, width: 9.0, height: 11.0)
    static let frontCard = NSRect(x: 2.0, y: 2.0, width: 9.0, height: 11.0)
    static let cardRadius: CGFloat = 2.0

    /// Width of the cleared channel that keeps the front card readable as a
    /// separate shape where it crosses the back one.
    static let separation: CGFloat = 1.3

    static func draw(dropping: Bool, awake: Bool) {
        let backStroke: CGFloat = dropping ? 2.0 : 1.4

        let back = NSBezierPath(
            roundedRect: backCard.insetBy(dx: backStroke / 2, dy: backStroke / 2),
            xRadius: cardRadius,
            yRadius: cardRadius
        )
        if awake {
            // Both cards solid reads as "active" at a glance, without needing a
            // second colour the menu bar will not give a template image.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: backCard, xRadius: cardRadius, yRadius: cardRadius).fill()
        } else {
            back.lineWidth = backStroke
            NSColor.black.setStroke()
            back.stroke()
        }

        // Punch the channel, then lay the front card into it.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(
            roundedRect: frontCard.insetBy(dx: -separation, dy: -separation),
            xRadius: cardRadius + separation,
            yRadius: cardRadius + separation
        ).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.black.setFill()
        NSBezierPath(roundedRect: frontCard, xRadius: cardRadius, yRadius: cardRadius).fill()
    }
}
