import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import Magpie

/// Every state of the redesigned shelf, light and dark, at true size: the
/// real strip and the real magpie layer tree, composed the way the app lays
/// them out (the bird stands in its own window on the panel's bottom edge).
///
/// Outside the gate, like `RenderSnapshots`:
///
///     MAGPIE_RENDER_SNAPSHOTS=1 swift test --filter MascotSnapshots
///
/// Each PNG is 2x pixels with its point size recorded, so it opens at the
/// size it is on a Retina screen. Light on the left, dark on the right.
/// The panel's blur is approximated by blurring the backdrop, which is the
/// one thing a real screenshot judges better.
@MainActor
final class MascotSnapshots: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["MAGPIE_RENDER_SNAPSHOTS"] == "1" }
    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAGPIE_SNAPSHOT_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("magpie-snapshots").path, isDirectory: true)
    }
    private let scale: CGFloat = 2
    private let scene = CGSize(width: 440, height: 330)
    private let panelOrigin = CGPoint(x: 170, y: 40)   // y-down, top-left of the panel in the scene

    // MARK: Fixture

    private func fixture() throws -> (ShelfManager, UUID, URL) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("magpie-mascot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, bytes) in [("Quarterly report.pdf", 182_000), ("Screenshot 2026-10-20 at 14.02.png", 412_000), ("Meeting notes.txt", 2_400)] {
            let url = scratch.appendingPathComponent(name)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            urls.append(url)
        }
        let manager = ShelfManager(store: ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json")))
        let id = manager.createShelf()
        for url in urls { _ = manager.addFile(url: url, to: id) }
        return (manager, id, scratch)
    }

    // MARK: Backdrop and panel

    /// A busy desktop: colour and text, so the glass has something to show.
    private func backdrop(dark: Bool) -> NSImage {
        NSImage(size: scene, flipped: true) { rect in
            let colors: [NSColor] = dark
                ? [NSColor(srgbRed: 0.13, green: 0.19, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.29, green: 0.17, blue: 0.24, alpha: 1)]
                : [NSColor(srgbRed: 0.66, green: 0.77, blue: 0.87, alpha: 1), NSColor(srgbRed: 0.94, green: 0.79, blue: 0.66, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: rect, angle: -35)
            let ink = dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.5)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: ink]
            for row in 0..<14 {
                ("The quick brown fox jumps over the lazy dog 0123456789" as NSString)
                    .draw(at: NSPoint(x: CGFloat(row % 3) * -40, y: CGFloat(row) * 24), withAttributes: attrs)
            }
            NSColor(srgbRed: 0.77, green: 0.33, blue: 0.16, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 300, y: 120, width: 90, height: 90)).fill()
            return true
        }
    }

    private func blurred(_ image: NSImage, radius: CGFloat) -> NSImage {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return image }
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ci.extent)
        let rep = NSCIImageRep(ciImage: out)
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    /// The SwiftUI content of a panel, rendered through its real views.
    private func content<V: View>(_ view: V, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    enum Ground { case glass(Double), island }

    /// One scene: backdrop, panel (ground + content), magpie.
    private func compose(
        dark: Bool,
        panel size: CGSize,
        at origin: CGPoint? = nil,
        ground: Ground = .glass(ShelfGlass.defaultValue),
        topInset: CGFloat = 0,
        content rep: NSBitmapImageRep?,
        bird: MascotPose?,
        curious: Bool = false,
        petX: Bool = false,
        pinnedX: CGPoint? = nil,
        notch: CGRect? = nil,
        panelAlpha: CGFloat = 1
    ) -> NSImage {
        let o = origin ?? panelOrigin
        let back = backdrop(dark: dark)
        let soft = blurred(back, radius: 18)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        return NSImage(size: scene, flipped: true) { rect in
            back.draw(in: rect)
            let frame = NSRect(x: o.x, y: o.y, width: size.width, height: size.height)
            let radius = Design.Radius.panel
            let shape: NSBezierPath
            if case .island = ground {
                shape = NSBezierPath()
                shape.move(to: NSPoint(x: frame.minX, y: frame.minY))
                shape.line(to: NSPoint(x: frame.maxX, y: frame.minY))
                shape.appendArc(from: NSPoint(x: frame.maxX, y: frame.maxY), to: NSPoint(x: frame.minX, y: frame.maxY), radius: radius)
                shape.appendArc(from: NSPoint(x: frame.minX, y: frame.maxY), to: NSPoint(x: frame.minX, y: frame.minY), radius: radius)
                shape.close()
            } else {
                shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            }
            NSGraphicsContext.saveGraphicsState()
            if panelAlpha < 1 { NSGraphicsContext.current?.cgContext.setAlpha(panelAlpha) }
            NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            NSShadow().then { $0.shadowColor = NSColor(white: 0, alpha: 0.3); $0.shadowBlurRadius = 20; $0.shadowOffset = NSSize(width: 0, height: -8); $0.set() }
            NSColor.black.withAlphaComponent(0.01).setFill(); shape.fill()
            NSShadow().set()
            shape.addClip()
            switch ground {
            case .glass(let value):
                soft.draw(in: rect)
                var ground = NSColor.windowBackgroundColor
                appearance.performAsCurrentDrawingAppearance {
                    ground = (NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .gray)
                }
                ground.withAlphaComponent(ShelfGlass.groundAlpha(value)).setFill()
                frame.fill()
            case .island:
                NSColor.black.setFill(); frame.fill()
            }
            if let rep {
                rep.draw(in: NSRect(x: frame.minX, y: frame.minY + topInset, width: rep.size.width, height: rep.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            var stroke = NSColor.black
            appearance.performAsCurrentDrawingAppearance { stroke = dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.12) }
            stroke.setStroke(); shape.lineWidth = 1.5; shape.stroke()
            NSGraphicsContext.current?.cgContext.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
            if let notch {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: notch, xRadius: 9, yRadius: 9).fill()
            }
            if let bird, let birdRep = MascotRender.bitmap(bird, dark: dark || { if case .island = ground { return true } else { return false } }(),
                                                            canvas: self.scene, scale: self.scale, curious: curious) {
                birdRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let xColor = dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.62)
            let xAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: xColor]
            if petX, let bird {
                let r = MascotPlacement.petX.offsetBy(dx: bird.x, dy: bird.y)
                ("×" as NSString).draw(in: r.insetBy(dx: -2, dy: -3), withAttributes: xAttrs.merging([.paragraphStyle: Self.centred]) { $1 })
            }
            if let p = pinnedX {
                ("×" as NSString).draw(in: CGRect(x: p.x - 9, y: p.y - 10, width: 18, height: 18), withAttributes: xAttrs.merging([.paragraphStyle: Self.centred]) { $1 })
            }
            return true
        }
    }

    private static let centred: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.alignment = .center; return p
    }()

    /// Home box for a panel at `origin` of `size`, in scene (y-down) points.
    private func home(_ size: CGSize, at origin: CGPoint? = nil) -> CGPoint {
        let o = origin ?? panelOrigin
        let feet = CGPoint(x: o.x + size.width - MascotPlacement.inset + MascotDrawing.size.width / 2, y: o.y + size.height)
        return MascotGeometry.standing(feetAt: feet)
    }

    private func write(_ name: String, _ make: (Bool) -> NSImage) throws {
        let light = make(false), dark = make(true)
        let gap: CGFloat = 0
        let w = scene.width * 2 + gap, h = scene.height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        light.draw(in: NSRect(x: 0, y: 0, width: scene.width, height: h))
        dark.draw(in: NSRect(x: scene.width + gap, y: 0, width: scene.width, height: h))
        NSGraphicsContext.restoreGraphicsState()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: The states

    func testEveryMagpieStateInBothAppearances() throws {
        try XCTSkipUnless(enabled, "set MAGPIE_RENDER_SNAPSHOTS=1 to render")
        let (manager, id, scratch) = try fixture()
        defer { try? FileManager.default.removeItem(at: scratch) }
        MascotPreference.set(true)
        let count = manager.items(of: id).count
        let strip = ShelfLayout.collapsedSize(itemCount: count)
        let panel = ShelfLayout.collapsedSize(itemCount: count, perch: true)
        func stripRep(_ dark: Bool, hidesClose: Bool = false) -> NSBitmapImageRep? {
            content(
                CollapsedShelfView(namespace: Namespace().wrappedValue, manager: manager, shelfID: id,
                                   items: manager.items(of: id), showCloseWhenEmpty: true, hidesClose: hidesClose)
                    .padding(ShelfLayout.margin)
                    .frame(width: strip.width, height: panel.height, alignment: .top),
                size: panel, dark: dark)
        }
        let rest = home(panel)
        var base = MascotPose(); base.x = rest.x; base.y = rest.y

        try write("01-idle") { compose(dark: $0, panel: panel, content: stripRep($0), bird: base) }
        try write("02-idle-blink") { compose(dark: $0, panel: panel, content: stripRep($0), bird: MascotBehaviour.pose(.idle, at: 6 * 0.81, base: base)) }
        try write("03-curious-hover-with-pet-x") { compose(dark: $0, panel: panel, content: stripRep($0), bird: base, curious: true, petX: true) }
        try write("04-working-hop") { compose(dark: $0, panel: panel, content: stripRep($0), bird: MascotBehaviour.pose(.working, at: 0.6 * 0.58, base: base)) }
        try write("05-done-catch") { compose(dark: $0, panel: panel, content: stripRep($0), bird: MascotBehaviour.pose(.done, at: 0.45, base: base)) }
        try write("06-oops-shake") { compose(dark: $0, panel: panel, content: stripRep($0), bird: MascotBehaviour.pose(.oops, at: 0.25 * 0.2, base: base)) }

        // Sent away: the X stays put while the bird lifts off toward it, then it is in the beak.
        let petCentre = CGPoint(x: rest.x + MascotPlacement.petX.midX, y: rest.y + MascotPlacement.petX.midY)
        let dismiss = MascotPass.dismissing(from: rest, x: petCentre)
        try write("07-sent-away-lifting-off") { compose(dark: $0, panel: panel, content: stripRep($0), bird: dismiss.pose(at: 0.3), pinnedX: petCentre) }
        try write("08-sent-away-x-in-beak") { compose(dark: $0, panel: panel, content: stripRep($0), bird: dismiss.pose(at: 0.62)) }

        // Closing with the shelf's X: the swoop from above and the bite.
        let closeX = CGPoint(x: panelOrigin.x + ShelfLayout.margin + Design.Size.chromeButton / 2,
                             y: panelOrigin.y + ShelfLayout.margin + Design.Size.chromeButton / 2)
        let close = MascotPass.closing(from: rest, x: closeX)
        try write("09-closing-swoop") { compose(dark: $0, panel: panel, content: stripRep($0), bird: close.pose(at: 0.35)) }
        try write("10-closing-bite") { compose(dark: $0, panel: panel, content: stripRep($0, hidesClose: true), bird: close.pose(at: 0.5)) }
        try write("11-closing-gone-with-x") { compose(dark: $0, panel: panel, content: stripRep($0, hidesClose: true), bird: close.pose(at: 0.75), panelAlpha: 0.35) }

        // Appearing: a short flight in, landing on the bottom edge.
        let from = CGPoint(x: rest.x + MascotFlight.appearOffset.x, y: rest.y + MascotFlight.appearOffset.y)
        try write("12-appearing-flight") { compose(dark: $0, panel: panel, content: stripRep($0), bird: MascotFlight.flutter(0.45, from: from, to: rest)) }
        try write("13-appearing-landing") { compose(dark: $0, panel: panel, content: stripRep($0), bird: MascotFlight.flutter(0.9, from: from, to: rest)) }

        // Docking: mid-flight, and landed inside the original-size tab at 0.44.
        let tabSize = ShelfLayout.docked
        let tabOrigin = CGPoint(x: scene.width - tabSize.width + ShelfLayout.dockedOffscreen, y: 120)
        let tabFeet = CGPoint(x: tabOrigin.x + (tabSize.width - ShelfLayout.dockedOffscreen) / 2, y: tabOrigin.y + tabSize.height)
        let tabBox = MascotGeometry.standing(feetAt: tabFeet)
        func tabRep(_ dark: Bool) -> NSBitmapImageRep? {
            content(DockedTabView(onExpand: {}, dropTargeted: false), size: tabSize, dark: dark)
        }
        let leftHome = home(panel, at: CGPoint(x: 40, y: 40))
        try write("14-docking-flight") {
            compose(dark: $0, panel: tabSize, at: tabOrigin, content: tabRep($0), bird: MascotFlight.dock(0.55, from: leftHome, to: tabBox))
        }
        var docked = MascotPose(); docked.x = tabBox.x; docked.y = tabBox.y; docked.k = MascotFlight.dockScale
        try write("15-docked-in-the-tab") { compose(dark: $0, panel: tabSize, at: tabOrigin, content: tabRep($0), bird: docked) }

        // Glass: light frost, frosted (the default), solid.
        for (name, value) in [("16-glass-light-frost", 0.0), ("17-glass-frosted-default", ShelfGlass.defaultValue), ("18-glass-solid", 1.0)] {
            try write(name) { compose(dark: $0, panel: panel, ground: .glass(value), content: stripRep($0), bird: base) }
        }

        // The notch island: black, flush with the top, the camera's band left empty.
        let notchHeight: CGFloat = 32
        let island = CGSize(width: panel.width, height: panel.height + notchHeight)
        let islandOrigin = CGPoint(x: (scene.width - island.width) / 2, y: 0)
        let notch = CGRect(x: scene.width / 2 - 95, y: -10, width: 190, height: notchHeight + 10)
        let islandHome = home(island, at: islandOrigin)
        var islandBird = MascotPose(); islandBird.x = islandHome.x; islandBird.y = islandHome.y
        try write("19-notch-island") { _ in
            compose(dark: true, panel: island, at: islandOrigin, ground: .island, topInset: notchHeight,
                    content: stripRep(true), bird: islandBird, notch: notch)
        }
        print("magpie snapshots written to \(dir.path)")
    }
}

private extension NSObjectProtocol {
    @discardableResult
    func then(_ body: (Self) -> Void) -> Self { body(self); return self }
}
