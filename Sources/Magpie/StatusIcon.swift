import AppKit

/// The menu-bar mark: the magpie alone, in one colour.
///
/// It is the app's only permanent presence, so it is the same bird that
/// stands on the shelves, drawn the way macOS draws menu-bar icons: a template
/// image, ink where the bird is black and holes where it is white (belly, wing
/// patch, eye), so the bar's own colour shows through as the paper does on
/// the shelf. AppKit recolours it for the bar's appearance, the menu-open
/// highlight and Increase Contrast.
///
/// Drawing lives here as a pure function of its two state flags so it can be
/// rendered and asserted in tests. `AppDelegate` only assigns the result.
enum StatusIcon {

    /// Canvas side. `NSStatusItem` scales anything else.
    static let side: CGFloat = 18

    /// The part of the drawing the mark frames: the bird from its crown to the
    /// tip of its tail, in the drawing's own y-down units.
    static let frame = CGRect(x: 20, y: 28, width: 430, height: 562)

    /// - Parameters:
    ///   - dropping: a drag is currently over a shelf. The bird leans in, the
    ///     way it does on the shelf when files come toward it.
    ///   - awake: keep-awake is on. The bird is drawn solid, patches filled,
    ///     eye still open: "active" at a glance in a single colour.
    static func image(dropping: Bool, awake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            draw(dropping: dropping, awake: awake)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Drawing units to the canvas, y-down, centred.
    static func transform(lean: CGFloat) -> CGAffineTransform {
        let s = side / frame.height
        let dx = (side - frame.width * s) / 2
        let pivot = MascotDrawing.Pivot.lean
        let turn = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: lean * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        return turn
            .concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: dx, y: 0))
    }

    /// The mark's ink, in canvas points: every black part of the bird.
    static func inkBounds(dropping: Bool) -> CGRect {
        var t = transform(lean: dropping ? MascotBehaviour.curiousLean : 0)
        let path = CGMutablePath()
        for d in [MascotDrawing.body, MascotDrawing.tail, MascotDrawing.legFront, MascotDrawing.legBack] {
            path.addPath(MascotDrawing.path(d))
        }
        return path.copy(using: &t)?.boundingBoxOfPath ?? .null
    }

    static func draw(dropping: Bool, awake: Bool) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let legs = transform(lean: 0)
        let bird = transform(lean: dropping ? MascotBehaviour.curiousLean : 0)
        func fill(_ d: String, _ t: CGAffineTransform) {
            var t = t
            if let p = MascotDrawing.path(d).copy(using: &t) { cg.addPath(p); cg.fillPath() }
        }
        cg.setFillColor(NSColor.black.cgColor)
        fill(MascotDrawing.legFront, legs)
        fill(MascotDrawing.legBack, legs)
        fill(MascotDrawing.tail, bird)
        fill(MascotDrawing.body, bird)

        // The white of the bird is the bar showing through.
        cg.setBlendMode(.clear)
        if !awake {
            fill(MascotDrawing.belly, bird)
            // The wing patch, inset by its own outline so it stays a shape of
            // its own rather than merging with the belly.
            var t = bird
            if let wing = MascotDrawing.path(MascotDrawing.wing).copy(using: &t) {
                cg.addPath(wing)
                cg.fillPath()
                cg.setBlendMode(.normal)
                cg.addPath(wing)
                cg.setStrokeColor(NSColor.black.cgColor)
                cg.setLineWidth(MascotDrawing.wingOutline * side / frame.height * 2.2)
                cg.strokePath()
                cg.setBlendMode(.clear)
            }
        }
        let c = MascotDrawing.eyeCenter.applying(bird)
        let r = max(1.1, MascotDrawing.eyeRadius * side / frame.height * 1.6)
        cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        cg.setBlendMode(.normal)
    }
}
