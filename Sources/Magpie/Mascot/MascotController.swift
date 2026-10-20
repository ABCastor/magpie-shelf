import AppKit
import QuartzCore

/// The magpie on every shelf, and what it does when the shelf does something.
///
/// One `MascotPerch` per shelf panel. The app tells this controller what the
/// shelves are doing (appearing, docking, closing, working, being dragged
/// onto); this decides what the bird does about it, from the approved
/// reference: the Flutter flight for docking and for a shelf appearing, one
/// continuous pass that bites the X for closing and for being sent away, and
/// the five behaviours on the perch. Under Reduce Motion there is no flight
/// and no behaviour: the bird is simply in place.
@MainActor
final class MascotController {
    private var perches: [UUID: MascotPerch] = [:]
    /// Called when the bird leaves or comes back, so the shelves can give
    /// back, or make, the strip of space it stands in.
    var onShownChanged: () -> Void = {}
    /// The shelf's own drop view, for a file dragged onto the bird.
    var dropView: (UUID) -> NSView? = { _ in nil }
    /// A click on the bird standing in a docked tab is a click on the tab.
    var onDockedClick: (UUID) -> Void = { _ in }

    var isShown: Bool { MascotPreference.isShown }
    private var reduceMotion: Bool { Design.Motion.isReduced }

    func attach(_ shelfID: UUID, panel: NSPanel) {
        guard perches[shelfID] == nil else { return }
        let perch = MascotPerch(shelfID: shelfID, panel: panel)
        perch.onSendAway = { [weak self] in self?.sendAway(from: shelfID) }
        perch.dropForward = { [weak self] in self?.dropView(shelfID) }
        perch.onDockedClick = { [weak self] in self?.onDockedClick(shelfID) }
        perches[shelfID] = perch
    }

    func detach(_ shelfID: UUID) {
        perches.removeValue(forKey: shelfID)?.tearDown()
    }

    // MARK: - The shelf's life

    /// A shelf has just come on screen.
    func shelfShown(_ shelfID: UUID, island: Bool = false) {
        guard let perch = perches[shelfID] else { return }
        perch.island = island
        guard isShown else { perch.hide(); return }
        if reduceMotion { perch.stand(mode: .perched) } else { perch.flyIn() }
    }

    func shelfHidden(_ shelfID: UUID) {
        perches[shelfID]?.hide()
    }

    /// The panel is about to glide to `frame` (a resize, a park, a restore).
    func panelWillMove(_ shelfID: UUID, to frame: NSRect, timing: Design.Motion.PanelTiming?) {
        perches[shelfID]?.follow(panelTo: frame, timing: timing)
    }

    /// The shelf folds to the edge: the bird flies to the tab and lands in it.
    func dock(_ shelfID: UUID, from shelf: NSRect, to tab: NSRect) {
        guard let perch = perches[shelfID], isShown else { return }
        if reduceMotion { perch.stand(mode: .docked, panelFrame: tab) } else { perch.flyToDock(from: shelf, tab: tab) }
    }

    /// The tab opens back into a shelf: the bird flies back to its edge.
    func undock(_ shelfID: UUID, to shelf: NSRect) {
        guard let perch = perches[shelfID], isShown else { return }
        if reduceMotion { perch.stand(mode: .perched, panelFrame: shelf) } else { perch.flyIn(panelFrame: shelf) }
    }

    /// The shelf's X was pressed. Returns false when there is nothing to fly
    /// (no bird, Reduce Motion), so the caller closes the shelf at once.
    /// Otherwise `fade` runs when the beak takes the X and `close` when the
    /// pass is over.
    func closeWithX(_ shelfID: UUID, fade: @escaping () -> Void, close: @escaping () -> Void) -> Bool {
        guard isShown, !reduceMotion, let perch = perches[shelfID], perch.canFly else { return false }
        perch.biteShelfX(onGrab: fade, done: close)
        return true
    }

    // MARK: - Moods

    func setCurious(_ shelfID: UUID, dragging: Bool) {
        perches[shelfID]?.dropCurious = dragging
    }

    func setWorking(_ shelfIDs: Set<UUID>) {
        for (id, perch) in perches { perch.working = shelfIDs.contains(id) }
    }

    func flash(_ shelfID: UUID, _ mood: MascotMood) {
        perches[shelfID]?.flash(mood)
    }

    // MARK: - The pet

    /// The pet X: it bites the X and flies off with it, and stays away.
    private func sendAway(from shelfID: UUID) {
        MascotPreference.set(false)
        for (id, perch) in perches where id != shelfID { perch.hide() }
        guard let perch = perches[shelfID], !reduceMotion else {
            perches[shelfID]?.hide()
            onShownChanged()
            return
        }
        perch.biteOwnX { [weak self] in self?.onShownChanged() }
    }

    /// Settings or the menu brought it back.
    func bringBack() {
        guard !isShown else { return }
        MascotPreference.set(true)
        onShownChanged()
        refreshShown()
    }

    /// The preference changed somewhere (Settings): match it.
    func refreshShown() {
        for perch in perches.values where perch.panelIsVisible {
            if isShown {
                guard !perch.isStanding else { continue }
                if reduceMotion { perch.stand(mode: perch.mode) } else { perch.flyIn() }
            } else {
                perch.hide()
            }
        }
    }

    /// The system's appearance changed: redraw every bird in its new ink.
    func appearanceChanged() {
        for perch in perches.values { perch.redraw() }
    }

    func setIsland(_ shelfID: UUID, _ island: Bool) {
        perches[shelfID]?.island = island
    }
}

/// One shelf's magpie: a rest window that stands on the panel's edge and
/// moves with it, and a flight window it crosses the screen in.
@MainActor
final class MascotPerch {
    enum Mode { case perched, docked }

    let shelfID: UUID
    weak var panel: NSPanel?
    private(set) var mode: Mode = .perched
    var onSendAway: () -> Void = {}
    var dropForward: () -> NSView? = { nil }
    var onDockedClick: () -> Void = {}
    /// The notch island is black whatever the appearance, so its bird wears
    /// the dark drawing.
    var island = false { didSet { if island != oldValue { redraw() } } }

    private let restWindow = MascotWindow(interactive: true)
    private let restView: MascotRestView
    private let flightWindow = MascotWindow(interactive: false)
    private let flightView = MascotCanvasView()
    private var restBird: MascotLayer
    private var flightBird: MascotLayer
    private var timer: Timer?
    private var flying = false
    private var hovering = false
    private var flashing: MascotMood?
    private var flashTimer: Timer?

    var dropCurious = false { didSet { if dropCurious != oldValue { updateCurious() } } }
    var working = false { didSet { if working != oldValue { updateMoods() } } }

    init(shelfID: UUID, panel: NSPanel) {
        self.shelfID = shelfID
        self.panel = panel
        let dark = Self.isDark(panel)
        restBird = MascotLayer(dark: dark)
        flightBird = MascotLayer(dark: dark)
        restView = MascotRestView(frame: NSRect(origin: .zero, size: MascotPlacement.restWindowSize))
        restWindow.contentView = restView
        restView.bird = restBird
        flightView.wantsLayer = true
        flightWindow.contentView = flightView
        flightView.layer?.addSublayer(flightBird)
        flightView.layer?.masksToBounds = false
        restView.onHover = { [weak self] over in self?.hover(over) }
        restView.onClickBird = { [weak self] in self?.flash(.done) }
        restView.onClickX = { [weak self] in self?.onSendAway() }
        restView.onDockedClick = { [weak self] in self?.onDockedClick() }
    }

    func tearDown() {
        timer?.invalidate()
        flashTimer?.invalidate()
        detachFromPanel()
        restWindow.orderOut(nil)
        flightWindow.orderOut(nil)
    }

    private static func isDark(_ panel: NSPanel?) -> Bool {
        let appearance = panel?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var dark: Bool { island || Self.isDark(panel) }

    var panelIsVisible: Bool { panel?.isVisible == true }
    var isStanding: Bool { restWindow.isVisible || flying }
    var canFly: Bool { panel?.isVisible == true && !flying && restWindow.isVisible && mode == .perched }

    func redraw() {
        let d = dark
        guard restBird.isDark != d else { return }
        let pose = restBird.pose
        restBird = MascotLayer(dark: d)
        restBird.apply(pose)
        restView.bird = restBird
        flightBird.removeFromSuperlayer()
        flightBird = MascotLayer(dark: d)
        flightView.layer?.addSublayer(flightBird)
        restView.layoutX(dark: d)
        updateMoods()
        updateCurious(animated: false)
    }

    // MARK: Standing

    private var restScale: CGFloat { mode == .docked ? MascotFlight.dockScale : 1 }

    private func feet(for frame: NSRect, mode: Mode) -> NSPoint {
        switch mode {
        case .perched:
            return MascotPlacement.perchedFeet(onShelf: frame)
        case .docked:
            let screen = panel?.screen?.frame ?? NSScreen.main?.frame ?? frame
            return MascotPlacement.dockedFeet(onTab: frame, screen: screen)
        }
    }

    private func restFrame(for panelFrame: NSRect, mode: Mode) -> NSRect {
        MascotPlacement.restFrame(feet: feet(for: panelFrame, mode: mode))
    }

    /// Puts the bird on its edge, at rest, with no flight.
    func stand(mode: Mode, panelFrame: NSRect? = nil) {
        guard let panel else { return }
        cancelFlight()
        self.mode = mode
        let frame = panelFrame ?? panel.frame
        detachFromPanel()
        restWindow.setFrame(restFrame(for: frame, mode: mode), display: false)
        var pose = MascotPose.rest
        let box = MascotPlacement.restBox
        pose.x = box.x; pose.y = box.y; pose.k = restScale
        restBird.apply(pose)
        restView.isDocked = mode == .docked
        restView.layoutX(dark: dark)
        restView.setXVisible(false, animated: false)
        restWindow.orderFront(nil)
        attachToPanel()
        updateMoods()
        updateCurious(animated: false)
    }

    func hide() {
        cancelFlight()
        hovering = false
        detachFromPanel()
        restWindow.orderOut(nil)
        flightWindow.orderOut(nil)
    }

    /// Glide with the panel when it resizes or moves under the app's hand;
    /// when the user drags the panel, the rest window rides along as a child.
    func follow(panelTo frame: NSRect, timing: Design.Motion.PanelTiming?) {
        guard restWindow.isVisible, !flying else { return }
        let target = restFrame(for: frame, mode: mode)
        detachFromPanel()
        guard let timing else {
            restWindow.setFrame(target, display: false)
            attachToPanel()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = timing.duration
            ctx.timingFunction = timing.mediaTimingFunction
            restWindow.animator().setFrame(target, display: false)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.attachToPanel() }
        })
    }

    private func attachToPanel() {
        guard let panel, restWindow.isVisible, restWindow.parent == nil else { return }
        panel.addChildWindow(restWindow, ordered: .above)
        restView.dropForward = dropForward()
    }

    private func detachFromPanel() {
        if let parent = restWindow.parent { parent.removeChildWindow(restWindow) }
    }

    // MARK: Moods

    private func hover(_ over: Bool) {
        hovering = over
        updateCurious()
        restView.setXVisible(over && mode == .perched, animated: !Design.Motion.isReduced)
    }

    private func updateCurious(animated: Bool = true) {
        restBird.setCurious((hovering || dropCurious) && !flying, animated: animated && !Design.Motion.isReduced)
    }

    private func updateMoods() {
        guard !flying else { return }
        if Design.Motion.isReduced { restBird.play([]); return }
        var moods: [MascotMood] = [.idle]
        if working { moods.append(.working) }
        if let flashing { moods.append(flashing) }
        restBird.play(moods)
    }

    /// A one-shot mood: the catch (`done`) or the shake (`oops`).
    func flash(_ mood: MascotMood) {
        guard restWindow.isVisible, !flying, let duration = MascotBehaviour.duration(of: mood) else { return }
        flashing = mood
        updateMoods()
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flashing = nil
                self?.updateMoods()
            }
        }
    }

    // MARK: Flight

    private var space: MascotSpace { .current }

    private func screenFrame(around rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        return screen?.frame ?? rect
    }

    /// The box position of a resting bird for a panel frame, y-down global.
    private func homeBox(_ frame: NSRect, mode: Mode) -> CGPoint {
        space.box(feet: feet(for: frame, mode: mode))
    }

    /// Runs a flight in the flight window. `pose` is in global y-down points.
    private func fly(
        over screen: NSRect,
        duration: TimeInterval,
        delay: TimeInterval = 0,
        before: MascotPose? = nil,
        pose: @escaping (CGFloat) -> MascotPose,
        tick: ((CGFloat) -> Void)? = nil,
        done: @escaping () -> Void
    ) {
        cancelFlight()
        flying = true
        hovering = false
        restView.setXVisible(false, animated: false)
        restBird.stopBehaviours()
        flightBird.stopBehaviours()
        let origin = space.down(screen).origin
        func local(_ p: MascotPose) -> MascotPose {
            var q = p; q.x -= origin.x; q.y -= origin.y; return q
        }
        flightWindow.setFrame(screen, display: false)
        flightBird.apply(local(before ?? pose(0)))
        flightWindow.orderFront(nil)
        detachFromPanel()
        restWindow.orderOut(nil)
        let start = CACurrentMediaTime() + delay
        let step = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = CACurrentMediaTime()
                guard now >= start else { return }
                let t = CGFloat(min(1, (now - start) / duration))
                self.flightBird.apply(local(pose(t)))
                tick?(t)
                if t >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.flying = false
                    done()
                }
            }
        }
        RunLoop.main.add(step, forMode: .common)
        timer = step
    }

    private func cancelFlight() {
        timer?.invalidate()
        timer = nil
        flying = false
        flightWindow.orderOut(nil)
    }

    /// Lands at the rest spot: the 320 ms squash, in the rest window.
    private func land(mode: Mode, panelFrame: NSRect) {
        self.mode = mode
        restWindow.setFrame(restFrame(for: panelFrame, mode: mode), display: false)
        let box = MascotPlacement.restBox
        restBird.apply(MascotFlight.land(0, at: box, k: restScale))
        restView.isDocked = mode == .docked
        restView.layoutX(dark: dark)
        restWindow.orderFront(nil)
        flightWindow.orderOut(nil)
        attachToPanel()
        let k = restScale
        let start = CACurrentMediaTime()
        flying = true
        let step = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = CGFloat(min(1, (CACurrentMediaTime() - start) / MascotFlight.landDuration))
                self.restBird.apply(MascotFlight.land(t, at: box, k: k))
                if t >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.flying = false
                    self.updateMoods()
                    self.updateCurious(animated: false)
                }
            }
        }
        RunLoop.main.add(step, forMode: .common)
        timer = step
    }

    /// The shelf appears (or the bird comes back): a short flight in from
    /// above and to the left, landing on the bottom edge.
    func flyIn(panelFrame: NSRect? = nil) {
        guard let panel else { return }
        let frame = panelFrame ?? panel.frame
        let to = homeBox(frame, mode: .perched)
        let screen = screenFrame(around: frame)
        var from = CGPoint(x: to.x + MascotFlight.appearOffset.x, y: to.y + MascotFlight.appearOffset.y)
        // The whole bird stays on screen: start it inside the screen it is
        // flying across, however near the edge the shelf was summoned.
        let bounds = space.down(screen)
        var probe = MascotPose.flying(x: from.x, y: from.y)
        from.x += MascotFlight.keepIn(probe, bounds: bounds)
        probe = MascotPose.flying(x: from.x, y: from.y)
        let drawn = MascotGeometry.drawnBounds(probe)
        if drawn.minY < bounds.minY + MascotFlight.screenMargin {
            from.y += bounds.minY + MascotFlight.screenMargin - drawn.minY
        }
        let start = from
        fly(over: screen, duration: MascotFlight.appearDuration, delay: MascotFlight.appearDelay,
            before: .flying(x: start.x, y: start.y),
            pose: { MascotFlight.flutter($0, from: start, to: to) },
            done: { [weak self] in self?.land(mode: .perched, panelFrame: frame) })
    }

    /// Docking: the shelf folds to the edge and the bird flies to the tab,
    /// shrinking as it lands so it fits inside, feet on the tab's bottom edge.
    func flyToDock(from shelf: NSRect, tab: NSRect) {
        let from = homeBox(shelf, mode: .perched)
        let to = homeBox(tab, mode: .docked)
        let screen = screenFrame(around: tab)
        fly(over: screen, duration: MascotFlight.dockDuration, delay: MascotFlight.dockDelay,
            before: MascotPose(x: from.x, y: from.y),
            pose: { MascotFlight.dock($0, from: from, to: to) },
            done: { [weak self] in self?.land(mode: .docked, panelFrame: tab) })
    }

    /// Closing the shelf with its X: one continuous pass from slightly above,
    /// the beak through the X, and out with it, gone as the shelf closes.
    func biteShelfX(onGrab: @escaping () -> Void, done: @escaping () -> Void) {
        guard let panel else { done(); return }
        let frame = panel.frame
        let x = space.down(MascotPlacement.closeX(onShelf: frame))
        let pass = MascotPass.closing(from: homeBox(frame, mode: .perched), x: x)
        var grabbed = false
        fly(over: screenFrame(around: frame), duration: pass.duration,
            pose: { pass.pose(at: $0) },
            tick: { t in
                if !grabbed, pass.hasGrabbed(at: t) { grabbed = true; onGrab() }
            },
            done: { [weak self] in
                self?.flightWindow.orderOut(nil)
                done()
            })
    }

    /// Sent away with its own X: it lifts off with minimal movement, bites
    /// the X in passing, and flies away carrying it.
    func biteOwnX(done: @escaping () -> Void) {
        guard let panel else { done(); return }
        let frame = panel.frame
        let home = homeBox(frame, mode: .perched)
        let xRect = MascotPlacement.petX
        let x = CGPoint(x: home.x + xRect.midX, y: home.y + xRect.midY)
        let pass = MascotPass.dismissing(from: home, x: x)
        // The X stays exactly where it was until the beak takes it: drawn in
        // the flight window, at the same spot, until the grab.
        let pin = CATextLayer()
        pin.string = "×"
        pin.alignmentMode = .center
        pin.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        pin.fontSize = 15
        pin.contentsScale = panel.backingScaleFactor
        pin.foregroundColor = (dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.62)).cgColor
        let screen = screenFrame(around: frame)
        let origin = space.down(screen).origin
        pin.frame = CGRect(x: x.x - origin.x - 9, y: x.y - origin.y - 9, width: 18, height: 18)
        flightView.layer?.addSublayer(pin)
        var grabbed = false
        fly(over: screen, duration: pass.duration,
            pose: { pass.pose(at: $0) },
            tick: { t in
                if !grabbed, pass.hasGrabbed(at: t) { grabbed = true; pin.removeFromSuperlayer() }
            },
            done: { [weak self] in
                pin.removeFromSuperlayer()
                self?.flightWindow.orderOut(nil)
                done()
            })
    }
}

extension MascotPose {
    init(x: CGFloat, y: CGFloat) {
        self.init()
        self.x = x
        self.y = y
    }
}
