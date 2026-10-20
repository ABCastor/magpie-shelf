import AppKit
import QuartzCore

/// The magpie, and what it does when the shelves do something.
///
/// **One bird, many shelves.** Each shelf panel has a `MascotPerch` (the
/// windows the bird can stand and fly in), but the magpie stands on one shelf
/// at a time: the one in use. When the user turns to another shelf it makes a
/// short flight across to it. The app tells this controller what the shelves
/// are doing (appearing, becoming key, docking, closing, working, being
/// dragged onto); this decides what the bird does about it, from the approved
/// reference: the Flutter flight, the bite in passing, and the five
/// behaviours on the perch. Under Reduce Motion there is no flight and no
/// behaviour: the bird is simply in place.
@MainActor
final class MascotController {
    private var perches: [UUID: MascotPerch] = [:]
    /// The shelf the bird stands on, and the order shelves were last used in,
    /// so it knows where to go when its shelf closes.
    private(set) var active: UUID?
    private var recency: [UUID] = []
    private var keyObservers: [UUID: NSObjectProtocol] = [:]

    /// Called when the bird leaves or comes back, so the shelves can give
    /// back, or make, the strip of space it stands in.
    var onShownChanged: () -> Void = {}
    /// The shelf's own drop view, for a file dragged onto the bird.
    var dropView: (UUID) -> NSView? = { _ in nil }
    /// A click on the bird standing in a docked tab is a click on the tab.
    var onDockedClick: (UUID) -> Void = { _ in }
    /// Asks, the first time only, whether the pet X should really send the
    /// bird away, and answers true to hide it. By default the bird carries
    /// the question in on a card; injectable so tests never raise one.
    var confirmFirstSendAway: (MascotPerch?, @escaping (Bool) -> Void) -> Void = { perch, answer in
        guard let perch else { answer(false); return }
        perch.carryQuestion(answered: answer)
    }

    static let askedKey = "shelf.mascot.sendAwayConfirmed"

    /// For tests: the perch of a shelf.
    func perch(for shelfID: UUID) -> MascotPerch? { perches[shelfID] }

    var isShown: Bool { MascotPreference.isShown }
    private var reduceMotion: Bool { Design.Motion.isReduced }

    func attach(_ shelfID: UUID, panel: NSPanel) {
        guard perches[shelfID] == nil else { return }
        let perch = MascotPerch(shelfID: shelfID, panel: panel)
        perch.onSendAway = { [weak self] in self?.sendAway(from: shelfID) }
        perch.dropForward = { [weak self] in self?.dropView(shelfID) }
        perch.onDockedClick = { [weak self] in self?.onDockedClick(shelfID) }
        perches[shelfID] = perch
        // The shelf the user clicks into is the shelf in use.
        keyObservers[shelfID] = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.use(shelfID) }
        }
    }

    func detach(_ shelfID: UUID) {
        if let observer = keyObservers.removeValue(forKey: shelfID) {
            NotificationCenter.default.removeObserver(observer)
        }
        perches.removeValue(forKey: shelfID)?.tearDown()
        recency.removeAll { $0 == shelfID }
        if active == shelfID {
            active = nil
            moveToNextShelf(excluding: shelfID)
        }
    }

    private func touch(_ shelfID: UUID) {
        recency.removeAll { $0 == shelfID }
        recency.insert(shelfID, at: 0)
    }

    // MARK: - The shelf's life

    /// A shelf has just come on screen. `from` is where the user summoned it
    /// (the shake), in screen coordinates: the bird starts there.
    func shelfShown(_ shelfID: UUID, island: Bool = false, from: NSPoint? = nil) {
        guard let perch = perches[shelfID] else { return }
        perch.island = island
        touch(shelfID)
        guard isShown else { perch.hide(); return }
        arrive(at: shelfID, from: from)
    }

    /// The user turned to this shelf (clicked into it, dropped onto it).
    func use(_ shelfID: UUID) {
        guard perches[shelfID]?.panelIsVisible == true else { return }
        touch(shelfID)
        guard isShown, active != shelfID else { return }
        arrive(at: shelfID, from: nil)
    }

    /// Brings the bird to `shelfID`: from the summon point, or across from
    /// the shelf it was on, or in from above when it was nowhere.
    private func arrive(at shelfID: UUID, from point: NSPoint?) {
        guard let perch = perches[shelfID] else { return }
        let previous = active.flatMap { $0 == shelfID ? nil : perches[$0] }
        active = shelfID
        if reduceMotion {
            previous?.hide()
            perch.stand(mode: perch.mode)
            return
        }
        if let point {
            previous?.hide()
            perch.flyIn(start: .point(point))
        } else if let previous, previous.isStanding, let box = previous.restingBox {
            previous.hide()
            perch.flyIn(start: .box(box, scale: previous.restScale), duration: MascotFlight.crossDuration)
        } else {
            previous?.hide()
            perch.flyIn(start: .above)
        }
    }

    func shelfHidden(_ shelfID: UUID) {
        perches[shelfID]?.hide()
        if active == shelfID {
            active = nil
            moveToNextShelf(excluding: shelfID)
        }
    }

    /// Its shelf went away: the bird goes to the shelf used most recently of
    /// those still open, if any.
    private func moveToNextShelf(excluding gone: UUID? = nil) {
        // The closing shelf is excluded by id: the app tells the bird before
        // it orders the panel out, so that panel still reads as visible.
        guard isShown, let next = recency.first(where: { $0 != gone && perches[$0]?.panelIsVisible == true }) else { return }
        arrive(at: next, from: nil)
    }

    /// The panel is about to glide to a new frame (a resize, a park, a
    /// restore). The bird rides its live bottom edge for as long as that takes.
    func panelWillMove(_ shelfID: UUID, timing: Design.Motion.PanelTiming?) {
        perches[shelfID]?.ride(for: (timing?.duration ?? 0) + 0.2)
    }

    /// The shelf folds to the edge: the bird flies to the tab and lands in it.
    func dock(_ shelfID: UUID) {
        guard let perch = perches[shelfID], isShown, active == shelfID else {
            perches[shelfID]?.setMode(.docked)
            return
        }
        if reduceMotion { perch.setMode(.docked); perch.stand(mode: .docked) } else { perch.flyToDock() }
    }

    /// The tab opens back into a shelf: the bird flies back to its edge.
    func undock(_ shelfID: UUID) {
        guard let perch = perches[shelfID] else { return }
        let fromTab = perch.restingBox
        perch.setMode(.perched)
        guard isShown, active == shelfID else { return }
        if reduceMotion {
            perch.stand(mode: .perched)
        } else if let fromTab {
            perch.flyIn(start: .box(fromTab, scale: MascotFlight.dockScale))
        } else {
            perch.flyIn(start: .above)
        }
    }

    /// The shelf's X was pressed. Returns false when there is nothing to fly
    /// (no bird on this shelf, Reduce Motion), so the caller closes the shelf
    /// at once. Otherwise `fade` runs when the beak takes the X and `close`
    /// when the pass is over.
    func closeWithX(_ shelfID: UUID, fade: @escaping () -> Void, close: @escaping () -> Void) -> Bool {
        guard isShown, !reduceMotion, active == shelfID, let perch = perches[shelfID], perch.canFly else { return false }
        perch.biteShelfX(onGrab: fade, done: close)
        return true
    }

    // MARK: - Moods

    func setCurious(_ shelfID: UUID, dragging: Bool) {
        perches[shelfID]?.dropCurious = dragging
        if dragging { use(shelfID) }
    }

    func setWorking(_ shelfIDs: Set<UUID>) {
        for (id, perch) in perches { perch.working = shelfIDs.contains(id) }
    }

    func flash(_ shelfID: UUID, _ mood: MascotMood) {
        perches[shelfID]?.flash(mood)
    }

    // MARK: - The pet

    /// The pet X: it bites the X and flies off with it, and stays away. The
    /// first time, it asks, so a stray click does not lose the bird.
    private func sendAway(from shelfID: UUID) {
        guard UserDefaults.standard.bool(forKey: Self.askedKey) else {
            confirmFirstSendAway(perches[shelfID]) { [weak self] hide in
                guard hide else { return }
                UserDefaults.standard.set(true, forKey: Self.askedKey)
                self?.goAway(from: shelfID)
            }
            return
        }
        goAway(from: shelfID)
    }

    /// Hides the bird for good (until brought back). When it is still on its
    /// perch it bites its X and flies off with it; when it has already flown
    /// off with the question card, there is nothing left to fly.
    private func goAway(from shelfID: UUID) {
        MascotPreference.set(false)
        for (id, perch) in perches where id != shelfID { perch.hide() }
        guard let perch = perches[shelfID], !reduceMotion, perch.restWindowVisible else {
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
        if isShown {
            guard active.flatMap({ perches[$0]?.isStanding }) != true else { return }
            active = nil
            moveToNextShelf()
        } else {
            for perch in perches.values { perch.hide() }
            active = nil
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

/// One shelf's place for the magpie: a rest window that stands on the
/// panel's live bottom edge, and a flight window it crosses the screen in.
@MainActor
final class MascotPerch {
    enum Mode { case perched, docked }

    /// Where an arriving flight starts.
    enum Start {
        /// Up and to the left of where it lands: the shelf appearing.
        case above
        /// Centred on a screen point (y-up): where the shelf was summoned.
        case point(NSPoint)
        /// From another shelf's perch: a box in y-down global points.
        case box(CGPoint, scale: CGFloat)
    }

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
    private var rideTimer: Timer?
    private var rideUntil: CFTimeInterval = 0
    private var frameObservers: [NSObjectProtocol] = []
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
        // Any change to the panel's frame, however it happens, moves the bird
        // with the panel's live bottom edge.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: panel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.snapToPanel() }
            })
        }
    }

    func tearDown() {
        dropQuestion()
        timer?.invalidate()
        rideTimer?.invalidate()
        flashTimer?.invalidate()
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
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
    var restScale: CGFloat { mode == .docked ? MascotFlight.dockScale : 1 }

    /// For tests: where the windows are and what the flying bird is doing.
    var restWindowFrame: NSRect { restWindow.frame }
    var restWindowVisible: Bool { restWindow.isVisible }
    var isFlying: Bool { flying }
    var flightWindowFrame: NSRect { flightWindow.frame }
    var flightPose: MascotPose { flightBird.pose }
    func expectedRestFrame() -> NSRect? { panel.map { restFrame(for: $0.frame, mode: mode) } }

    func setMode(_ mode: Mode) { self.mode = mode }

    /// Where the resting bird's box is now, y-down global, if it is resting.
    var restingBox: CGPoint? {
        guard restWindow.isVisible, !flying, let panel else { return nil }
        return homeBox(panel.frame, mode: mode)
    }

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

    // MARK: Standing on the live edge

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
    func stand(mode: Mode) {
        guard let panel else { return }
        cancelFlight()
        self.mode = mode
        detachFromPanel()
        restWindow.setFrame(restFrame(for: panel.frame, mode: mode), display: false)
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
        dropQuestion()
        cancelFlight()
        hovering = false
        detachFromPanel()
        restWindow.orderOut(nil)
        flightWindow.orderOut(nil)
    }

    /// Puts the rest window back on the panel's live bottom edge.
    private func snapToPanel() {
        guard let panel, restWindow.isVisible, !flying else { return }
        let target = restFrame(for: panel.frame, mode: mode)
        if restWindow.frame != target { restWindow.setFrame(target, display: false) }
    }

    /// Rides the panel's live bottom edge, every frame, for `seconds`: the
    /// length of an animated resize. The rest window is a child of the panel
    /// for the user's own drags; for the app's animated resizes it is let go
    /// and moved to the live edge each frame instead, because a child only
    /// follows its parent's origin, and a strip that grows downward moves its
    /// bottom edge without that being a move of the window.
    func ride(for seconds: TimeInterval) {
        guard restWindow.isVisible, !flying else { return }
        rideUntil = max(rideUntil, CACurrentMediaTime() + seconds)
        guard rideTimer == nil else { return }
        detachFromPanel()
        let step = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.snapToPanel()
                if CACurrentMediaTime() >= self.rideUntil {
                    self.rideTimer?.invalidate()
                    self.rideTimer = nil
                    self.snapToPanel()
                    self.attachToPanel()
                }
            }
        }
        RunLoop.main.add(step, forMode: .common)
        rideTimer = step
    }

    private func attachToPanel() {
        guard let panel, restWindow.isVisible, restWindow.parent == nil, rideTimer == nil else { return }
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

    /// Where the bird lands, read from the panel's frame as it is right now:
    /// never captured when the flight starts, because the shelf can grow,
    /// shrink or move while the bird is in the air.
    private func liveHome(_ mode: Mode) -> CGPoint {
        guard let panel else { return .zero }
        return homeBox(panel.frame, mode: mode)
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

    /// Lands at the rest spot on the live edge: the 320 ms squash, in the
    /// rest window, which keeps riding the edge while it squashes.
    private func land(mode: Mode) {
        guard let panel else { return }
        self.mode = mode
        restWindow.setFrame(restFrame(for: panel.frame, mode: mode), display: false)
        let box = MascotPlacement.restBox
        restBird.apply(MascotFlight.land(0, at: box, k: restScale))
        restView.isDocked = mode == .docked
        restView.layoutX(dark: dark)
        restWindow.orderFront(nil)
        flightWindow.orderOut(nil)
        let k = restScale
        let start = CACurrentMediaTime()
        flying = true
        let step = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                let target = self.restFrame(for: panel.frame, mode: mode)
                if self.restWindow.frame != target { self.restWindow.setFrame(target, display: false) }
                let t = CGFloat(min(1, (CACurrentMediaTime() - start) / MascotFlight.landDuration))
                self.restBird.apply(MascotFlight.land(t, at: box, k: k))
                if t >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.flying = false
                    self.attachToPanel()
                    self.updateMoods()
                    self.updateCurious(animated: false)
                }
            }
        }
        RunLoop.main.add(step, forMode: .common)
        timer = step
    }

    /// Arrives on this shelf's edge: in from above when the shelf appears,
    /// from the pointer when the shelf was summoned there, or across from the
    /// shelf it was standing on.
    func flyIn(start: Start, duration: TimeInterval = MascotFlight.appearDuration) {
        guard let panel else { return }
        mode = mode == .docked ? .docked : .perched
        let landing = mode
        let screen = screenFrame(around: panel.frame)
        let bounds = space.down(screen)
        let to = liveHome(landing)
        var from: CGPoint
        var startScale: CGFloat = 1
        var fadeIn = false
        var delay = MascotFlight.appearDelay
        switch start {
        case .above:
            from = CGPoint(x: to.x + MascotFlight.appearOffset.x, y: to.y + MascotFlight.appearOffset.y)
        case .point(let p):
            let c = space.down(p)
            from = CGPoint(x: c.x - MascotDrawing.size.width / 2, y: c.y - MascotDrawing.size.height * 0.6)
            fadeIn = true
            delay = 0
        case .box(let box, let scale):
            from = box
            startScale = scale
            delay = 0
        }
        // The whole bird stays on screen: start it inside the screen it is
        // flying across, however near the edge the shelf was summoned.
        let probe = MascotPose.flying(x: from.x, y: from.y)
        from.x += MascotFlight.keepIn(probe, bounds: bounds)
        let drawn = MascotGeometry.drawnBounds(MascotPose.flying(x: from.x, y: from.y))
        if drawn.minY < bounds.minY + MascotFlight.screenMargin {
            from.y += bounds.minY + MascotFlight.screenMargin - drawn.minY
        }
        let a = from
        let endScale: CGFloat = landing == .docked ? MascotFlight.dockScale : 1
        let fly: (CGFloat) -> MascotPose = { [weak self] t in
            let target = self?.liveHome(landing) ?? to
            let k = startScale + (endScale - startScale) * MascotEase.smooth(min(1, t / 0.55))
            var p = MascotFlight.flutter(t, from: a, to: target, k: k)
            if fadeIn { p.opacity = MascotEase.smooth(min(1, t / 0.12)) }
            return p
        }
        var before = MascotPose.flying(x: a.x, y: a.y, k: startScale)
        if fadeIn { before.opacity = 0 }
        self.fly(over: screen, duration: duration, delay: delay, before: before, pose: fly,
                 done: { [weak self] in self?.land(mode: landing) })
    }

    /// Docking: the shelf folds to the edge and the bird flies to the tab,
    /// shrinking as it lands so it fits inside, feet on the tab's bottom edge.
    func flyToDock() {
        guard let panel else { return }
        let from = restingBox ?? liveHome(.perched)
        mode = .docked
        let to = liveHome(.docked)
        fly(over: screenFrame(around: panel.frame), duration: MascotFlight.dockDuration, delay: MascotFlight.dockDelay,
            before: MascotPose(x: from.x, y: from.y),
            pose: { [weak self] t in MascotFlight.dock(t, from: from, to: self?.liveHome(.docked) ?? to) },
            done: { [weak self] in self?.land(mode: .docked) })
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

    // MARK: The question

    private var question: MascotQuestionCard?
    private var questionLayer: CALayer?

    /// A question card left open when the bird is hidden or its shelf goes
    /// away: put away without an answer, which keeps the bird.
    private func dropQuestion() {
        question?.onKeep = {}
        question?.onHide = {}
        question?.orderOut(nil)
        question = nil
        questionLayer?.removeFromSuperlayer()
        questionLayer = nil
    }

    /// Brings the hide question on a card in its beak, sets it down beside
    /// the shelf and stands on it. Keep: it carries the card back and lands
    /// on the shelf again. Hide: it flies off with the card. `answered` is
    /// called with true once the bird has gone, false as it heads home.
    func carryQuestion(answered: @escaping (Bool) -> Void) {
        guard let panel, let screenVisible = (panel.screen ?? NSScreen.main)?.visibleFrame else { answered(false); return }
        dropQuestion()
        let card = MascotQuestionCard()
        let frame = MascotQuestionCard.frame(size: card.size, shelf: panel.frame, visible: screenVisible)
        let screen = screenFrame(around: frame)
        let origin = space.down(screen).origin
        let down = space.down(frame)
        let home = restingBox ?? liveHome(.perched)
        let reduced = Design.Motion.isReduced

        let layer = CALayer()
        layer.contents = card.snapshot()
        layer.contentsGravity = .resize
        layer.contentsScale = panel.backingScaleFactor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        flightView.layer?.insertSublayer(layer, below: flightBird)
        question = card
        questionLayer = layer
        func place(_ r: CGRect, _ opacity: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = r.offsetBy(dx: -origin.x, dy: -origin.y)
            layer.opacity = Float(opacity)
            CATransaction.commit()
        }
        place(down, reduced ? 1 : 0)

        // Standing on the card, looking at the user, while they decide.
        let standOnCard = { [weak self] in
            guard let self else { return }
            let box = MascotCarry.stand(on: down)
            var pose = MascotPose.rest
            pose.x = box.x - origin.x; pose.y = box.y - origin.y
            self.flightWindow.setFrame(screen, display: false)
            self.flightBird.apply(pose)
            layer.isHidden = true
            card.setFrame(frame, display: true)
            card.orderFront(nil)
            card.makeKey()
            self.flightWindow.orderFront(nil)
            if !reduced {
                self.flightBird.play([.idle])
                self.flightBird.setCurious(true, animated: true)
            }
        }

        var settled = false
        let settle: (Bool) -> Void = { [weak self] hide in
            guard !settled else { return }
            settled = true
            card.onKeep = {}
            card.onHide = {}
            card.orderOut(nil)
            guard let self else { answered(hide); return }
            self.question = nil
            self.flightBird.stopBehaviours()
            self.flightBird.setCurious(false, animated: false)
            layer.isHidden = false
            place(down, 1)
            let finish = {
                layer.removeFromSuperlayer()
                if self.questionLayer === layer { self.questionLayer = nil }
            }
            if reduced {
                finish()
                self.flightWindow.orderOut(nil)
                if hide { self.hide(); answered(true) } else { self.stand(mode: .perched); answered(false) }
                return
            }
            if hide {
                self.fly(over: screen, duration: MascotCarry.awayDuration,
                         pose: { MascotCarry.away($0, card: down).pose },
                         tick: { t in let s = MascotCarry.away(t, card: down); place(s.card, s.opacity) },
                         done: { [weak self] in
                             finish()
                             self?.flightWindow.orderOut(nil)
                             answered(true)
                         })
            } else {
                answered(false)
                self.fly(over: screen, duration: MascotCarry.returnDuration,
                         pose: { [weak self] t in MascotCarry.takeBack(t, card: down, to: self?.liveHome(.perched) ?? home).pose },
                         tick: { [weak self] t in
                             let s = MascotCarry.takeBack(t, card: down, to: self?.liveHome(.perched) ?? home)
                             place(s.card, s.opacity)
                         },
                         done: { [weak self] in
                             finish()
                             self?.land(mode: .perched)
                         })
            }
        }
        card.onKeep = { settle(false) }
        card.onHide = { settle(true) }

        if reduced {
            cancelFlight()
            detachFromPanel()
            restWindow.orderOut(nil)
            standOnCard()
            return
        }
        fly(over: screen, duration: MascotCarry.bringDuration,
            before: MascotPose(x: home.x, y: home.y),
            pose: { MascotCarry.bring($0, from: home, card: down).pose },
            tick: { t in let s = MascotCarry.bring(t, from: home, card: down); place(s.card, s.opacity) },
            done: { standOnCard() })
    }

    /// For tests: the question card, while it is open.
    var openQuestion: MascotQuestionCard? { question }

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
