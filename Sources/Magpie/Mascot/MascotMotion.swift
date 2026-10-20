import CoreGraphics
import Foundation

/// Everything the magpie can be doing, as numbers.
///
/// The approved reference is a web page: the behaviours are CSS keyframes and
/// the flights are frame-clock functions in its script. This file is those two
/// things transcribed, value for value, so the app moves the way the page does
/// and a test can hold it to that. It is pure — no layers, no windows — which
/// is what lets the offscreen snapshots draw any instant of any motion.
///
/// Coordinates: the bird's box is `MascotDrawing.size` points, placed by its
/// top-left corner in a y-down space, exactly as the page's `translate(x,y)`.
/// Part transforms are in the drawing's own units about each part's pivot.
struct MascotPose: Equatable {
    // The box.
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// Uniform scale, about the feet. 0.44 when standing in the docked tab.
    var k: CGFloat = 1
    /// Squash and stretch, and a horizontal flip (`sx < 0`), about the feet.
    var sx: CGFloat = 1
    var sy: CGFloat = 1
    var opacity: CGFloat = 1

    // The parts.
    var lean: CGFloat = 0        // degrees, clockwise, about Pivot.lean
    var tail: CGFloat = 0        // degrees, about Pivot.tail
    var wing: CGFloat = 0        // degrees, about Pivot.wing
    var wingTx: CGFloat = 0
    var wingTy: CGFloat = 0
    var bellyScale: CGFloat = 1
    var eyeScaleY: CGFloat = 1
    var allTx: CGFloat = 0
    var allTy: CGFloat = 0
    var allSx: CGFloat = 1
    var allSy: CGFloat = 1
    /// Legs: folded with the pitch in flight, `rotate(pitch) scale(.9, legs)`.
    var legsRotation: CGFloat = 0
    var legsSx: CGFloat = 1
    var legsSy: CGFloat = 1
    var sparkOpacity: CGFloat = 0
    var sparkScale: CGFloat = 0
    var sparkRotation: CGFloat = 0
    /// The X in the beak.
    var holdsX = false

    static let rest = MascotPose()

    /// The page's `pose(s, x, y, o)` with `o.fly` set: the perched drawing,
    /// tipped forward, legs tucked, its own wing patch moved.
    static func flying(
        x: CGFloat, y: CGFloat, k: CGFloat = 1,
        sx: CGFloat = 1, sy: CGFloat = 1,
        pitch: CGFloat = 30, wing: CGFloat = 0, tail: CGFloat = -8, legs: CGFloat = 0.35
    ) -> MascotPose {
        var p = MascotPose()
        p.x = x; p.y = y; p.k = k; p.sx = sx; p.sy = sy
        p.lean = pitch
        p.wing = wing
        p.tail = tail
        p.legsRotation = pitch
        p.legsSx = 0.9
        p.legsSy = legs
        return p
    }
}

// MARK: - Easing (the page's own)

enum MascotEase {
    /// `eio`: cubic ease in and out.
    static func inOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    /// `sine`: sinusoidal ease in and out.
    static func sine(_ t: CGFloat) -> CGFloat { -(cos(.pi * t) - 1) / 2 }
    /// `sm`: smoothstep.
    static func smooth(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    /// A CSS `cubic-bezier(x1, y1, x2, y2)` evaluated at progress `t`.
    static func cubicBezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ t: CGFloat) -> CGFloat {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        func bx(_ s: CGFloat) -> CGFloat { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
        func by(_ s: CGFloat) -> CGFloat { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
        var lo: CGFloat = 0, hi: CGFloat = 1, s = t
        for _ in 0..<40 {
            s = (lo + hi) / 2
            if bx(s) < t { lo = s } else { hi = s }
        }
        return by(s)
    }
}

// MARK: - Behaviours (mp-motion.css)

/// The five moods, each the CSS class the page toggles.
enum MascotMood: Equatable {
    /// Tail flick with a spring and a double blink, every six seconds.
    case idle
    /// Lean in plus a wing lift: hover, and files dragged toward the shelf.
    case curious
    /// The two-footed hop, while a conversion or a route runs.
    case working
    /// The spark at the beak plus a wing flutter: something finished.
    case done
    /// The ruffled shake: something failed.
    case oops
}

/// One CSS keyframe track: a property over a normalised time, with the
/// timing function CSS applies to each segment between stops.
struct MascotTrack {
    enum Property: CaseIterable {
        case tail, eyeScaleY, allTx, allTy, allSx, allSy, wing, bellyScale
        case sparkOpacity, sparkScale, sparkRotation
    }
    enum Timing: Equatable {
        case ease, easeOut, easeInOut
        func apply(_ t: CGFloat) -> CGFloat {
            switch self {
            case .ease: return MascotEase.cubicBezier(0.25, 0.1, 0.25, 1, t)
            case .easeOut: return MascotEase.cubicBezier(0, 0, 0.58, 1, t)
            case .easeInOut: return MascotEase.cubicBezier(0.42, 0, 0.58, 1, t)
            }
        }
    }

    let property: Property
    let duration: TimeInterval
    /// How many times it plays; `.infinity` for a loop.
    let repeats: Float
    let timing: Timing
    /// (offset 0...1, value)
    let stops: [(CGFloat, CGFloat)]
    /// Keep the last value after a finite run (`animation-fill-mode: forwards`).
    var holdsEnd = false

    /// The value at `elapsed` seconds into the track.
    func value(at elapsed: TimeInterval) -> CGFloat {
        var cycle = elapsed / duration
        if repeats.isFinite, cycle >= Double(repeats) {
            return holdsEnd ? stops.last!.1 : stops.first!.1
        }
        cycle -= floor(cycle)
        let t = CGFloat(cycle)
        guard let upper = stops.firstIndex(where: { $0.0 >= t }) else { return stops.last!.1 }
        if upper == 0 { return stops[0].1 }
        let (t0, v0) = stops[upper - 1]
        let (t1, v1) = stops[upper]
        let local = t1 > t0 ? (t - t0) / (t1 - t0) : 1
        return v0 + (v1 - v0) * timing.apply(local)
    }
}

enum MascotBehaviour {
    /// The tracks a mood plays. Transcribed from `mp-motion.css`; the comment
    /// on each is the CSS it came from.
    static func tracks(for mood: MascotMood) -> [MascotTrack] {
        switch mood {
        case .idle:
            return [
                // @keyframes mp-flick{0%,78%{0}81%{-10deg}84%{3.5deg}87%{-1.2deg}90%,100%{0}} 6s infinite
                MascotTrack(property: .tail, duration: 6, repeats: .infinity, timing: .ease,
                            stops: [(0, 0), (0.78, 0), (0.81, -10), (0.84, 3.5), (0.87, -1.2), (0.90, 0), (1, 0)]),
                // @keyframes mp-blink{0%,40%{1}40.75%{.1}41.5%{1}42.25%{.1}43%,100%{1}} 6s infinite
                MascotTrack(property: .eyeScaleY, duration: 6, repeats: .infinity, timing: .ease,
                            stops: [(0, 1), (0.40, 1), (0.4075, 0.1), (0.415, 1), (0.4225, 0.1), (0.43, 1), (1, 1)]),
            ]
        case .curious:
            // A transition, not keyframes; see `curiousLean` and `curiousTiming`.
            return []
        case .working:
            return [
                // @keyframes mp-hop{0%{none}20%{scale(1.03,.96)}58%{translateY(-56px) scale(.98,1.03)}82%{translateY(0) scale(1.02,.98)}100%{none}} .6s infinite
                MascotTrack(property: .allTy, duration: 0.6, repeats: .infinity, timing: .ease,
                            stops: [(0, 0), (0.20, 0), (0.58, -56), (0.82, 0), (1, 0)]),
                MascotTrack(property: .allSx, duration: 0.6, repeats: .infinity, timing: .ease,
                            stops: [(0, 1), (0.20, 1.03), (0.58, 0.98), (0.82, 1.02), (1, 1)]),
                MascotTrack(property: .allSy, duration: 0.6, repeats: .infinity, timing: .ease,
                            stops: [(0, 1), (0.20, 0.96), (0.58, 1.03), (0.82, 0.98), (1, 1)]),
                // @keyframes mp-dip{0%,60%{0}80%{6deg}100%{0}} .6s infinite
                MascotTrack(property: .tail, duration: 0.6, repeats: .infinity, timing: .ease,
                            stops: [(0, 0), (0.60, 0), (0.80, 6), (1, 0)]),
            ]
        case .done:
            return [
                // @keyframes mp-spark{0%{opacity:1;scale(0) rotate(0)}45%{opacity:1;scale(1) rotate(45deg)}100%{opacity:0;scale(.7) rotate(90deg)}} 1s ease-out forwards
                MascotTrack(property: .sparkOpacity, duration: 1, repeats: 1, timing: .easeOut,
                            stops: [(0, 1), (0.45, 1), (1, 0)], holdsEnd: true),
                MascotTrack(property: .sparkScale, duration: 1, repeats: 1, timing: .easeOut,
                            stops: [(0, 0), (0.45, 1), (1, 0.7)], holdsEnd: true),
                MascotTrack(property: .sparkRotation, duration: 1, repeats: 1, timing: .easeOut,
                            stops: [(0, 0), (0.45, 45), (1, 90)], holdsEnd: true),
                // @keyframes mp-flutter{0%,100%{0}50%{-8deg}} .32s ease-in-out 2
                MascotTrack(property: .wing, duration: 0.32, repeats: 2, timing: .easeInOut,
                            stops: [(0, 0), (0.5, -8), (1, 0)]),
            ]
        case .oops:
            return [
                // @keyframes mp-shake{0%,100%{none}20%{-16px}40%{16px}60%{-12px}80%{12px}} .25s ease-in-out
                MascotTrack(property: .allTx, duration: 0.25, repeats: 1, timing: .easeInOut,
                            stops: [(0, 0), (0.2, -16), (0.4, 16), (0.6, -12), (0.8, 12), (1, 0)]),
                // @keyframes mp-fluff{0%,100%{1}50%{1.05}} .25s ease-in-out, on wing and belly
                MascotTrack(property: .bellyScale, duration: 0.25, repeats: 1, timing: .easeInOut,
                            stops: [(0, 1), (0.5, 1.05), (1, 1)]),
            ]
        }
    }

    /// How long a one-shot mood lasts before the bird goes back to idle.
    static func duration(of mood: MascotMood) -> TimeInterval? {
        switch mood {
        case .done: return 1.1   // the page clears `win` after 1100 ms
        case .oops: return 0.25
        case .idle, .curious, .working: return nil
        }
    }

    /// `.mp.lean .mp-lean{rotate(5deg)}`, `.mp.lean .mp-wing{translate(-4px,-4px)}`.
    static let curiousLean: CGFloat = 5
    static let curiousWing = CGPoint(x: -4, y: -4)
    /// `transition: transform .32s cubic-bezier(.3,1.4,.5,1)`.
    static let curiousDuration: TimeInterval = 0.32
    static let curiousTiming: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.3, 1.4, 0.5, 1)

    /// The pose of a perched bird `elapsed` seconds into `mood`. Snapshots use
    /// this to draw a frozen instant; the app plays the same tracks as
    /// render-server animations.
    static func pose(_ mood: MascotMood, at elapsed: TimeInterval, base: MascotPose = .rest) -> MascotPose {
        var p = base
        if mood == .curious {
            let t = MascotEase.cubicBezier(curiousTiming.0, curiousTiming.1, curiousTiming.2, curiousTiming.3,
                                           CGFloat(min(1, elapsed / curiousDuration)))
            p.lean = curiousLean * t
            p.wingTx = curiousWing.x * t
            p.wingTy = curiousWing.y * t
            return p
        }
        for track in tracks(for: mood) {
            let v = track.value(at: elapsed)
            switch track.property {
            case .tail: p.tail = v
            case .eyeScaleY: p.eyeScaleY = v
            case .allTx: p.allTx = v
            case .allTy: p.allTy = v
            case .allSx: p.allSx = v
            case .allSy: p.allSy = v
            case .wing: p.wing = v
            case .bellyScale: p.bellyScale = v
            case .sparkOpacity: p.sparkOpacity = v
            case .sparkScale: p.sparkScale = v
            case .sparkRotation: p.sparkRotation = v
            }
        }
        return p
    }
}

// MARK: - Geometry of a pose

enum MascotGeometry {
    static var size: CGSize { MascotDrawing.size }
    /// The box's own transform origin: centre, feet.
    static var origin: CGPoint { CGPoint(x: size.width / 2, y: size.height * MascotDrawing.feetFraction) }

    /// SVG `preserveAspectRatio="xMidYMid meet"`: the drawing's uniform scale
    /// into the box, and where its frame's top-left lands.
    static var drawingScale: CGFloat {
        min(size.width / MascotDrawing.viewBox.width, size.height / MascotDrawing.viewBox.height)
    }
    static var drawingOffset: CGPoint {
        let s = drawingScale
        return CGPoint(
            x: (size.width - MascotDrawing.viewBox.width * s) / 2,
            y: (size.height - MascotDrawing.viewBox.height * s) / 2
        )
    }

    /// A rotation about `pivot`, clockwise in a y-down space, as the CSS does it.
    static func rotation(_ degrees: CGFloat, about pivot: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
    }

    /// Drawing units, inside the lean group, to the stage (y-down points).
    static func leanToStage(_ pose: MascotPose) -> CGAffineTransform {
        let lean = rotation(pose.lean, about: MascotDrawing.Pivot.lean)
        let all = CGAffineTransform(translationX: MascotDrawing.Pivot.all.x, y: MascotDrawing.Pivot.all.y)
            .translatedBy(x: pose.allTx, y: pose.allTy)
            .scaledBy(x: pose.allSx, y: pose.allSy)
            .translatedBy(x: -MascotDrawing.Pivot.all.x, y: -MascotDrawing.Pivot.all.y)
        return lean.concatenating(all).concatenating(drawingToStage(pose))
    }

    /// Drawing units (outside any part transform) to the stage.
    static func drawingToStage(_ pose: MascotPose) -> CGAffineTransform {
        let s = drawingScale, off = drawingOffset, o = origin
        let toBox = CGAffineTransform(translationX: off.x, y: off.y)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -MascotDrawing.viewBox.minX, y: -MascotDrawing.viewBox.minY)
        let box = CGAffineTransform(translationX: pose.x + o.x, y: pose.y + o.y)
            .scaledBy(x: pose.k * pose.sx, y: pose.k * pose.sy)
            .translatedBy(x: -o.x, y: -o.y)
        return toBox.concatenating(box)
    }

    /// Where the bill tip is on the stage in this pose: the page's `beakAt`.
    static func beak(_ pose: MascotPose) -> CGPoint {
        MascotDrawing.billTip.applying(leanToStage(pose))
    }

    /// The drawn bird's bounds on the stage (body and tail, as the page
    /// measures `.mp-lean`).
    static func drawnBounds(_ pose: MascotPose) -> CGRect {
        let path = CGMutablePath()
        path.addPath(MascotDrawing.path(MascotDrawing.body))
        path.addPath(MascotDrawing.path(MascotDrawing.tail))
        var t = leanToStage(pose)
        return path.copy(using: &t)?.boundingBoxOfPath ?? .null
    }

    /// The box position that stands the bird's feet on `point` (a line's
    /// midpoint, y-down): the page's `home` and the tab target.
    static func standing(feetAt point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}

// MARK: - Flights (the page's script)

enum MascotFlight {
    /// `V.flutter`: the approved flight. `a` and `b` are box positions.
    static func flutter(_ t: CGFloat, from a: CGPoint, to b: CGPoint, k: CGFloat = 1) -> MascotPose {
        let e = MascotEase.inOut(t)
        let f = sin(t * 2 * .pi * 9)
        // The last fifth blends flight into standing: pitch, wing, legs and
        // squash all ease to rest together.
        let land = MascotEase.smooth(max(0, (t - 0.78) / 0.22))
        let air = 1 - land
        return .flying(
            x: a.x + (b.x - a.x) * e,
            y: a.y + (b.y - a.y) * e - sin(.pi * e) * 40,
            k: k,
            sx: 1 + 0.025 * f * air,
            sy: 1 - 0.025 * f * air,
            pitch: 30 * air,
            wing: (-8 + 10 * f) * air,
            tail: -8 * air,
            legs: 0.35 + 0.65 * land
        )
    }

    /// The landing squash, 320 ms: `land`.
    static let landDuration: TimeInterval = 0.32
    static func land(_ t: CGFloat, at p: CGPoint, k: CGFloat = 1) -> MascotPose {
        let q = sin(.pi * t) * (1 - t)
        var pose = MascotPose()
        pose.x = p.x; pose.y = p.y; pose.k = k
        pose.sx = 1 + 0.08 * q
        pose.sy = 1 - 0.08 * q
        return pose
    }

    // MARK: Dock

    static let dockDuration: TimeInterval = 2.2
    static let dockDelay: TimeInterval = 0.12
    /// It shrinks as it lands so it fits inside the narrow tab: 0.44.
    static let dockScale: CGFloat = 0.44
    /// The page keeps the drawn bird at least this far from the stage's edge.
    static let screenMargin: CGFloat = 8

    /// The dock flight at `t`, with the shrink that starts at 45%.
    static func dock(_ t: CGFloat, from a: CGPoint, to b: CGPoint) -> MascotPose {
        let k = 1 + (dockScale - 1) * MascotEase.smooth(max(0, (t - 0.45) / 0.55))
        return flutter(t, from: a, to: b, k: k)
    }

    // MARK: Appear (the shelf appears; the bird is brought back)

    static let appearDuration: TimeInterval = 1.3
    static let appearDelay: TimeInterval = 0.1
    /// It starts up and to the left of where it lands.
    static let appearOffset = CGPoint(x: -150, y: -110)

    /// Crossing to the shelf now in use: the same flight, a little shorter,
    /// so the move reads as the bird following the user rather than a show.
    static let crossDuration: TimeInterval = 0.9

    /// `keepIn`: how far to slide a pose horizontally so the drawn bird stays
    /// `screenMargin` inside `bounds`. Zero when it already is.
    static func keepIn(_ pose: MascotPose, bounds: CGRect) -> CGFloat {
        let r = MascotGeometry.drawnBounds(pose)
        if r.maxX > bounds.maxX - screenMargin { return bounds.maxX - screenMargin - r.maxX }
        if r.minX < bounds.minX + screenMargin { return bounds.minX + screenMargin - r.minX }
        return 0
    }
}

/// One continuous pass that bites an X on the way through: closing a shelf,
/// and sending the pet away. The page's `passBy`.
///
/// The X never moves. The beak is measured in the grab pose, so the curve is
/// laid out for the box such that the bill tip, not the box, passes through
/// the X at the halfway point of the eased time.
struct MascotPass {
    let start: CGPoint      // box position at rest
    let target: CGPoint     // the X's centre, stage points
    let flip: Bool          // face left (the shelf's X is on the left)
    let lift: CGFloat       // how far above the higher end the curve rises
    let exit: CGPoint       // where it leaves to, relative to the X
    let duration: TimeInterval

    /// Closing a shelf: swoops over from slightly above, mirrored.
    static func closing(from start: CGPoint, x: CGPoint) -> MascotPass {
        // 1.0 s, down from the reference's 1.25: the owner asked for closing
        // to be slightly quicker while staying smooth (2026-10-20).
        MascotPass(start: start, target: x, flip: true, lift: 46,
                   exit: CGPoint(x: -170, y: -120), duration: 1.0)
    }

    /// Sending the pet away: lifts off with minimal movement.
    static func dismissing(from start: CGPoint, x: CGPoint) -> MascotPass {
        // 0.85 s, down from the reference's 1.1: "a little quicker".
        MascotPass(start: start, target: x, flip: false, lift: 10,
                   exit: CGPoint(x: 150, y: -130), duration: 0.85)
    }

    /// Eased time at which the beak is on the X.
    static let grabAt: CGFloat = 0.5

    private var beakOffset: CGPoint {
        let grab = MascotPose.flying(x: target.x, y: target.y, sx: flip ? -1 : 1)
        let b = MascotGeometry.beak(grab)
        return CGPoint(x: target.x - b.x, y: target.y - b.y)
    }

    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * c.x + t * t * b.x,
            y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * c.y + t * t * b.y
        )
    }

    /// Whether, at linear time `t`, the X has been taken.
    func hasGrabbed(at t: CGFloat) -> Bool { MascotEase.sine(t) >= Self.grabAt - 1e-9 }

    /// The pose at linear time `t` in 0...1.
    func pose(at t: CGFloat) -> MascotPose {
        let off = beakOffset
        let c1 = CGPoint(x: (start.x + target.x) / 2 + (flip ? 40 : 0), y: min(start.y, target.y) - lift)
        let end = CGPoint(x: target.x + exit.x, y: target.y + exit.y)
        let gb = CGPoint(x: target.x + off.x, y: target.y + off.y)
        let cb = CGPoint(x: c1.x + off.x, y: c1.y + off.y)
        let eb = CGPoint(x: end.x + off.x, y: end.y + off.y)
        let u = MascotEase.sine(t)
        let tg = Self.grabAt
        let p: CGPoint
        if u < tg - 1e-9 {
            p = Self.quad(start, cb, gb, min(1, u / tg))
        } else {
            let c2 = CGPoint(x: gb.x + (eb.x - gb.x) * 0.3, y: gb.y + (eb.y - gb.y) * 0.1)
            p = Self.quad(gb, c2, eb, (u - tg) / (1 - tg))
        }
        let f = sin(t * 2 * .pi * 9)
        let settle = min(1, t * 5)
        var pose = MascotPose.flying(
            x: p.x, y: p.y,
            sx: (flip ? -1 : 1) * (1 + 0.02 * f),
            sy: 1 - 0.02 * f,
            pitch: 30 * settle,
            wing: -8 + 10 * f,
            tail: -8,
            legs: 1 - 0.65 * settle
        )
        let grabbed = u >= tg - 1e-9
        pose.holdsX = grabbed
        pose.opacity = grabbed ? 1 - MascotEase.smooth(max(0, (u - 0.62) / 0.38)) : 1
        return pose
    }
}
