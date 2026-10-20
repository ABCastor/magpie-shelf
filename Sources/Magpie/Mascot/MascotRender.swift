import AppKit

/// Draws a magpie pose to a bitmap through the same view and layer tree the
/// app puts on screen. Used by the offscreen snapshots and by the tests that
/// check the drawing's orientation, so neither can be fooled by a second,
/// look-alike renderer.
enum MascotRender {
    /// `canvas` is the area drawn, in points; the pose is placed in it.
    @MainActor
    static func bitmap(_ pose: MascotPose, dark: Bool, canvas: CGSize, scale: CGFloat = 2,
                       curious: Bool = false) -> NSBitmapImageRep? {
        let view = MascotCanvasView(frame: NSRect(origin: .zero, size: canvas))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let bird = MascotLayer(dark: dark)
        bird.apply(pose)
        if curious { bird.setCurious(true, animated: false) }
        view.layer?.addSublayer(bird)
        return draw(view, scale: scale)
    }

    /// Renders a layer-backed view's layer tree into a bitmap at `scale`.
    @MainActor
    static func draw(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cg)
        return rep
    }
}
