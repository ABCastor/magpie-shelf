import AppKit
import QuartzCore

/// The magpie, built as a tree of layers that mirrors the drawing's groups.
///
/// One property per layer, each layer turning about its own part's pivot, so a
/// CSS `transform-origin` becomes an `anchorPoint` and nothing has to be
/// composed by hand. The behaviours then run as render-server animations: a
/// bird that idles for an hour costs the app nothing on the CPU. Flights are
/// the exception, driven frame by frame by `MascotStage`, because they are
/// functions of where the shelf and the tab are, and they last two seconds.
final class MascotLayer: CALayer {
    let isDark: Bool

    // One layer per transform, outermost first.
    private let box = CALayer()
    private let drawing = CALayer()
    private let allMove: CALayer
    private let allScale: CALayer
    private let legsTurn: CALayer
    private let legsScale: CALayer
    private let lean: CALayer
    private let tailRim: CALayer
    private let tail: CALayer
    private let belly: CALayer
    private let wingMove: CALayer
    private let wingTurn: CALayer
    private let wingFluff: CALayer
    private let eye: CALayer
    private let sparkScale: CALayer
    private let sparkTurn: CALayer
    private let heldX = CAShapeLayer()

    private(set) var pose = MascotPose.rest

    init(dark: Bool) {
        isDark = dark
        let p = MascotDrawing.Pivot.self
        allMove = Self.group(p.all)
        allScale = Self.group(p.all)
        legsTurn = Self.group(p.legs)
        legsScale = Self.group(p.legs)
        lean = Self.group(p.lean)
        tailRim = Self.group(p.tail)
        tail = Self.group(p.tail)
        belly = Self.group(p.belly)
        wingMove = Self.group(p.wing)
        wingTurn = Self.group(p.wing)
        wingFluff = Self.group(p.wing)
        eye = Self.group(p.eye)
        sparkScale = Self.group(p.spark)
        sparkTurn = Self.group(p.spark)
        super.init()
        build()
    }

    override init(layer: Any) {
        let other = layer as! MascotLayer
        isDark = other.isDark
        allMove = other.allMove; allScale = other.allScale
        legsTurn = other.legsTurn; legsScale = other.legsScale
        lean = other.lean; tailRim = other.tailRim; tail = other.tail
        belly = other.belly; wingMove = other.wingMove; wingTurn = other.wingTurn
        wingFluff = other.wingFluff; eye = other.eye
        sparkScale = other.sparkScale; sparkTurn = other.sparkTurn
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A group the size of the drawing's whole space, pinned so its own
    /// coordinates are the drawing's, turning about `pivot`.
    private static func group(_ pivot: CGPoint) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 500, height: 620)
        layer.anchorPoint = CGPoint(x: pivot.x / 500, y: pivot.y / 620)
        layer.position = pivot
        return layer
    }

    private func shape(_ d: String, fill: NSColor?, stroke: NSColor? = nil, width: CGFloat = 0) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = MascotDrawing.path(d)
        s.fillColor = fill?.cgColor
        s.strokeColor = stroke?.cgColor
        s.lineWidth = width
        s.lineJoin = .round
        s.lineCap = .round
        return s
    }

    private func rim(_ d: String) -> CAShapeLayer? {
        guard isDark else { return nil }
        let paper = MascotDrawing.Palette.paper
        return shape(d, fill: paper, stroke: paper, width: MascotDrawing.darkRim)
    }

    private func build() {
        let ink = MascotDrawing.Palette.ink
        let paper = MascotDrawing.Palette.paper
        bounds = CGRect(origin: .zero, size: MascotDrawing.size)
        anchorPoint = .zero
        masksToBounds = false

        box.bounds = CGRect(origin: .zero, size: MascotDrawing.size)
        box.anchorPoint = CGPoint(x: 0.5, y: MascotDrawing.feetFraction)
        addSublayer(box)

        let s = MascotGeometry.drawingScale
        drawing.bounds = MascotDrawing.viewBox
        drawing.anchorPoint = .zero
        drawing.position = MascotGeometry.drawingOffset
        drawing.transform = CATransform3DMakeScale(s, s, 1)
        box.addSublayer(drawing)

        drawing.addSublayer(allMove)
        allMove.addSublayer(allScale)

        // Legs: under everything else, and folded in flight.
        allScale.addSublayer(legsTurn)
        legsTurn.addSublayer(legsScale)
        let legFill = isDark ? paper : ink
        for d in [MascotDrawing.legFront, MascotDrawing.legBack] {
            if let r = rim(d) { legsScale.addSublayer(r) }
        }
        legsScale.addSublayer(shape(MascotDrawing.legFront, fill: legFill))
        legsScale.addSublayer(shape(MascotDrawing.legBack, fill: legFill))

        allScale.addSublayer(lean)
        if let r = rim(MascotDrawing.tail) { tailRim.addSublayer(r) }
        lean.addSublayer(tailRim)
        if let r = rim(MascotDrawing.body) { lean.addSublayer(r) }
        tail.addSublayer(shape(MascotDrawing.tail, fill: ink))
        lean.addSublayer(tail)
        lean.addSublayer(shape(MascotDrawing.body, fill: ink))
        belly.addSublayer(shape(MascotDrawing.belly, fill: paper))
        lean.addSublayer(belly)
        wingFluff.addSublayer(shape(MascotDrawing.wing, fill: paper, stroke: ink, width: MascotDrawing.wingOutline))
        wingTurn.addSublayer(wingFluff)
        wingMove.addSublayer(wingTurn)
        lean.addSublayer(wingMove)
        let eyeShape = CAShapeLayer()
        let c = MascotDrawing.eyeCenter, r = MascotDrawing.eyeRadius
        eyeShape.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
        eyeShape.fillColor = paper.cgColor
        eye.addSublayer(eyeShape)
        lean.addSublayer(eye)

        var sparkTransform = CGAffineTransform(translationX: MascotDrawing.sparkCenter.x, y: MascotDrawing.sparkCenter.y)
            .scaledBy(x: MascotDrawing.sparkScale, y: MascotDrawing.sparkScale)
        let sparkShape = CAShapeLayer()
        sparkShape.path = MascotDrawing.path(MascotDrawing.spark).copy(using: &sparkTransform)
        sparkShape.fillColor = MascotDrawing.Palette.spark.cgColor
        sparkTurn.addSublayer(sparkShape)
        sparkScale.addSublayer(sparkTurn)
        lean.addSublayer(sparkScale)

        heldX.path = MascotDrawing.path(MascotDrawing.heldX)
        heldX.strokeColor = ink.cgColor
        heldX.fillColor = nil
        heldX.lineWidth = MascotDrawing.heldXWidth
        heldX.lineCap = .round
        lean.addSublayer(heldX)

        apply(.rest)
    }

    // MARK: - Pose

    /// Sets every part to `pose`, with no implicit animation.
    func apply(_ pose: MascotPose) {
        self.pose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let o = MascotGeometry.origin
        box.position = CGPoint(x: pose.x + o.x, y: pose.y + o.y)
        box.transform = CATransform3DMakeScale(pose.k * pose.sx, pose.k * pose.sy, 1)
        box.opacity = Float(pose.opacity)
        allMove.transform = CATransform3DMakeTranslation(pose.allTx, pose.allTy, 0)
        allScale.transform = CATransform3DMakeScale(pose.allSx, pose.allSy, 1)
        legsTurn.transform = Self.turn(pose.legsRotation)
        legsScale.transform = CATransform3DMakeScale(pose.legsSx, pose.legsSy, 1)
        lean.transform = Self.turn(pose.lean)
        tail.transform = Self.turn(pose.tail)
        tailRim.transform = Self.turn(pose.tail)
        belly.transform = CATransform3DMakeScale(pose.bellyScale, pose.bellyScale, 1)
        wingMove.transform = CATransform3DMakeTranslation(pose.wingTx, pose.wingTy, 0)
        wingTurn.transform = Self.turn(pose.wing)
        wingFluff.transform = CATransform3DMakeScale(pose.bellyScale, pose.bellyScale, 1)
        eye.transform = CATransform3DMakeScale(1, pose.eyeScaleY, 1)
        sparkScale.transform = CATransform3DMakeScale(pose.sparkScale, pose.sparkScale, 1)
        sparkScale.opacity = Float(pose.sparkOpacity)
        sparkTurn.transform = Self.turn(pose.sparkRotation)
        heldX.isHidden = !pose.holdsX
        CATransaction.commit()
    }

    /// Degrees, clockwise on screen. The layer tree is drawn y-down (the
    /// stage view is flipped), so a positive z rotation reads clockwise,
    /// which is the CSS convention the motion was written in.
    private static func turn(_ degrees: CGFloat) -> CATransform3D {
        CATransform3DMakeRotation(degrees * .pi / 180, 0, 0, 1)
    }

    // MARK: - Behaviours

    private static let moodKeys = ["mood.tail", "mood.eye", "mood.allTx", "mood.allTy", "mood.allSx",
                                   "mood.allSy", "mood.wing", "mood.belly", "mood.fluff",
                                   "mood.sparkOpacity", "mood.sparkScale", "mood.sparkTurn"]

    /// Plays the CSS tracks of `mood` as render-server animations. Idle is
    /// the ground every other mood plays over, as on the page, where the
    /// `idle` class stays on and a later class wins only the properties it
    /// names.
    func play(_ moods: [MascotMood]) {
        for (layer, key) in animatedLayers { layer.removeAnimation(forKey: key) }
        animatedLayers.removeAll()
        var claimed: [MascotTrack.Property: MascotTrack] = [:]
        for mood in moods {
            for track in MascotBehaviour.tracks(for: mood) { claimed[track.property] = track }
        }
        let now = convertTime(CACurrentMediaTime(), from: nil)
        for track in claimed.values {
            for (layer, keyPath, scale) in targets(for: track.property) {
                let animation = keyframes(track, keyPath: keyPath, scale: scale)
                // Loops share one clock, so the six-second idle keeps its
                // phase however often a mood comes and goes over it.
                animation.beginTime = track.repeats.isFinite ? now : 0
                let key = "mood.\(keyPath).\(track.property)"
                layer.add(animation, forKey: key)
                animatedLayers.append((layer, key))
            }
        }
    }

    private var animatedLayers: [(CALayer, String)] = []

    private func targets(for property: MascotTrack.Property) -> [(CALayer, String, CGFloat)] {
        let rad = CGFloat.pi / 180
        switch property {
        case .tail: return [(tail, "transform.rotation.z", rad), (tailRim, "transform.rotation.z", rad)]
        case .eyeScaleY: return [(eye, "transform.scale.y", 1)]
        case .allTx: return [(allMove, "transform.translation.x", 1)]
        case .allTy: return [(allMove, "transform.translation.y", 1)]
        case .allSx: return [(allScale, "transform.scale.x", 1)]
        case .allSy: return [(allScale, "transform.scale.y", 1)]
        case .wing: return [(wingTurn, "transform.rotation.z", rad)]
        case .bellyScale: return [(belly, "transform.scale", 1), (wingFluff, "transform.scale", 1)]
        case .sparkOpacity: return [(sparkScale, "opacity", 1)]
        case .sparkScale: return [(sparkScale, "transform.scale", 1)]
        case .sparkRotation: return [(sparkTurn, "transform.rotation.z", rad)]
        }
    }

    private func keyframes(_ track: MascotTrack, keyPath: String, scale: CGFloat) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = track.stops.map { NSNumber(value: Double($0.1 * scale)) }
        a.keyTimes = track.stops.map { NSNumber(value: Double($0.0)) }
        let timing: CAMediaTimingFunction
        switch track.timing {
        case .ease: timing = CAMediaTimingFunction(name: .default)
        case .easeOut: timing = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
        case .easeInOut: timing = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        }
        a.timingFunctions = Array(repeating: timing, count: max(1, track.stops.count - 1))
        a.duration = track.duration
        a.repeatCount = track.repeats
        a.isRemovedOnCompletion = !track.holdsEnd
        a.fillMode = track.holdsEnd ? .forwards : .removed
        return a
    }

    /// Lean in, or straighten up, over the page's overshooting transition.
    func setCurious(_ curious: Bool, animated: Bool) {
        let target: CGFloat = curious ? 1 : 0
        let from = curiousAmount
        curiousAmount = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lean.transform = CATransform3DMakeRotation(MascotBehaviour.curiousLean * target * .pi / 180, 0, 0, 1)
        wingMove.transform = CATransform3DMakeTranslation(
            MascotBehaviour.curiousWing.x * target, MascotBehaviour.curiousWing.y * target, 0)
        CATransaction.commit()
        guard animated, from != target else { return }
        // Sampled rather than handed to a timing function: the curve
        // overshoots (y1 = 1.4), which `CAMediaTimingFunction` will not do.
        let samples = 24
        let curve = (0...samples).map { i -> CGFloat in
            let t = CGFloat(i) / CGFloat(samples)
            let c = MascotBehaviour.curiousTiming
            return from + (target - from) * MascotEase.cubicBezier(c.0, c.1, c.2, c.3, t)
        }
        let lean = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        lean.values = curve.map { NSNumber(value: Double($0 * MascotBehaviour.curiousLean * .pi / 180)) }
        lean.duration = MascotBehaviour.curiousDuration
        self.lean.add(lean, forKey: "curious")
        let lift = CAKeyframeAnimation(keyPath: "transform.translation")
        lift.values = curve.map { NSValue(size: CGSize(width: $0 * MascotBehaviour.curiousWing.x,
                                                       height: $0 * MascotBehaviour.curiousWing.y)) }
        lift.duration = MascotBehaviour.curiousDuration
        wingMove.add(lift, forKey: "curious")
    }

    private var curiousAmount: CGFloat = 0

    /// Stops every behaviour, for flight.
    func stopBehaviours() {
        for (layer, key) in animatedLayers { layer.removeAnimation(forKey: key) }
        animatedLayers.removeAll()
        lean.removeAnimation(forKey: "curious")
        wingMove.removeAnimation(forKey: "curious")
        curiousAmount = 0
    }
}

/// The view a magpie lives in. Flipped, so the layer tree is y-down like the
/// drawing and the page.
class MascotCanvasView: NSView {
    override var isFlipped: Bool { true }
}
