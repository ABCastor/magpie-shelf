import AppKit
import XCTest
@testable import Magpie

/// The magpie's choreography against real panels: it stands on the live
/// bottom edge, follows a resize, lands where the shelf is now, asks before
/// the first send-away, and is one bird across shelves.
@MainActor
final class MascotControllerTests: XCTestCase {
    private var saved: Any?
    private var savedAsked: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: MascotPreference.defaultsKey)
        savedAsked = UserDefaults.standard.object(forKey: MascotController.askedKey)
        MascotPreference.set(true)
        UserDefaults.standard.removeObject(forKey: MascotController.askedKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: MascotPreference.defaultsKey)
        UserDefaults.standard.set(savedAsked, forKey: MascotController.askedKey)
        super.tearDown()
    }

    private func makePanel(_ frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        return panel
    }

    private var screen: NSRect { NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func frameNear(_ a: NSRect, _ b: NSRect, _ message: String) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1, message)
        XCTAssertEqual(a.minY, b.minY, accuracy: 1, message)
    }

    /// The owner's case: a file dropped before the arrival flight has landed
    /// grows the shelf, and the bird used to land on the old, stale edge.
    func testTheArrivalLandsOnTheShelfsEdgeAsItIsWhenItLands() throws {
        try XCTSkipIf(Design.Motion.isReduced, "no flights under Reduce Motion")
        let controller = MascotController()
        let id = UUID()
        let start = NSRect(x: screen.midX - 120, y: screen.midY, width: 240, height: 150)
        let panel = makePanel(start)
        defer { panel.orderOut(nil); controller.detach(id) }
        controller.attach(id, panel: panel)
        controller.shelfShown(id)
        let perch = try XCTUnwrap(controller.perch(for: id))
        XCTAssertTrue(perch.isFlying, "the shelf appeared and the bird did not fly in")
        // Timed from the flight's own figures, so a faster flight keeps the
        // same three moments: a quarter in, near the end, and landed.
        let flight = MascotFlight.appearDelay + MascotFlight.appearDuration
        wait(MascotFlight.appearDelay + MascotFlight.appearDuration * 0.25)
        // Mid-flight, the shelf grows downward by a row and a half.
        let grown = NSRect(x: start.minX, y: start.minY - 60, width: 240, height: 210)
        panel.setFrame(grown, display: false)
        // Late in the flight, the bird is already heading for the new edge:
        // it does not fly to the old one and then jump.
        wait(flight * 0.88 - (MascotFlight.appearDelay + MascotFlight.appearDuration * 0.25))
        XCTAssertTrue(perch.isFlying)
        let pose = perch.flightPose, window = perch.flightWindowFrame
        let feetNow = NSPoint(x: window.minX + pose.x + MascotGeometry.origin.x,
                              y: window.maxY - (pose.y + MascotGeometry.origin.y))
        let target = MascotPlacement.perchedFeet(onShelf: grown)
        XCTAssertEqual(feetNow.y, target.y, accuracy: 4, "the flight is still aiming at the edge the shelf had when it started")
        wait(flight * 0.12 + MascotFlight.landDuration + 0.4)
        XCTAssertFalse(perch.isFlying)
        XCTAssertTrue(perch.restWindowVisible)
        frameNear(perch.restWindowFrame, MascotPlacement.restFrame(feet: MascotPlacement.perchedFeet(onShelf: grown)),
                  "the bird landed on the edge the shelf had when the flight started, not the edge it has now")
    }

    /// A resize while the bird stands: it rides the bottom edge down.
    func testTheStandingBirdFollowsAResize() throws {
        let controller = MascotController()
        let id = UUID()
        let start = NSRect(x: screen.midX - 120, y: screen.midY, width: 240, height: 150)
        let panel = makePanel(start)
        defer { panel.orderOut(nil); controller.detach(id) }
        controller.attach(id, panel: panel)
        let perch = try XCTUnwrap(controller.perch(for: id))
        perch.stand(mode: .perched)
        let timing = Design.Motion.PanelTiming(duration: 0.3, c0: 0.25, c1: 0.9, c2: 0.3, c3: 1)
        controller.panelWillMove(id, timing: timing)
        let grown = NSRect(x: start.minX - 80, y: start.minY - 90, width: 400, height: 240)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = timing.duration
            panel.animator().setFrame(grown, display: false)
        }
        wait(0.8)
        frameNear(perch.restWindowFrame, MascotPlacement.restFrame(feet: MascotPlacement.perchedFeet(onShelf: grown)),
                  "the bird stayed where the old bottom edge was")
        // And a plain setFrame, with no animation and no warning.
        let moved = grown.offsetBy(dx: 0, dy: 30)
        panel.setFrame(moved, display: false)
        wait(0.1)
        frameNear(perch.restWindowFrame, MascotPlacement.restFrame(feet: MascotPlacement.perchedFeet(onShelf: moved)),
                  "a frame change the app did not announce left the bird behind")
    }

    /// One bird: it stands on the shelf in use and crosses to the next.
    func testOneMagpieMovesToTheShelfInUse() throws {
        let controller = MascotController()
        let a = UUID(), b = UUID()
        let pa = makePanel(NSRect(x: screen.minX + 100, y: screen.midY, width: 240, height: 150))
        let pb = makePanel(NSRect(x: screen.minX + 500, y: screen.midY, width: 240, height: 150))
        defer { pa.orderOut(nil); pb.orderOut(nil); controller.detach(a); controller.detach(b) }
        controller.attach(a, panel: pa)
        controller.attach(b, panel: pb)
        controller.shelfShown(a)
        controller.shelfShown(b)
        XCTAssertEqual(controller.active, b, "a new shelf did not get the bird")
        XCTAssertFalse(controller.perch(for: a)?.isStanding ?? true, "two magpies: the first shelf kept its bird")
        controller.use(a)
        XCTAssertEqual(controller.active, a, "turning back to a shelf did not bring the bird")
        XCTAssertFalse(controller.perch(for: b)?.isStanding ?? true)
        controller.shelfHidden(a)
        XCTAssertEqual(controller.active, b, "closing the bird's shelf left the open one without it")
    }

    /// The shake: the bird starts where the pointer was.
    func testASummonedShelfsBirdStartsAtThePointer() throws {
        try XCTSkipIf(Design.Motion.isReduced, "no flights under Reduce Motion")
        let controller = MascotController()
        let id = UUID()
        let panel = makePanel(NSRect(x: screen.midX + 100, y: screen.midY - 200, width: 240, height: 150))
        defer { panel.orderOut(nil); controller.detach(id) }
        controller.attach(id, panel: panel)
        let pointer = NSPoint(x: screen.midX - 200, y: screen.midY + 100)
        controller.shelfShown(id, from: pointer)
        let perch = try XCTUnwrap(controller.perch(for: id))
        let pose = perch.flightPose
        let window = perch.flightWindowFrame
        // Box centre, back in screen coordinates (the flight window is a screen).
        let centre = NSPoint(x: window.minX + pose.x + MascotDrawing.size.width / 2,
                             y: window.maxY - (pose.y + MascotDrawing.size.height * 0.6))
        XCTAssertEqual(centre.x, pointer.x, accuracy: 2, "the bird does not start where the shake happened")
        XCTAssertEqual(centre.y, pointer.y, accuracy: 2, "the bird does not start where the shake happened")
        XCTAssertEqual(pose.opacity, 0, accuracy: 0.01, "the bird does not appear at the pointer, it is already there")
    }

    /// The first press of the pet X asks; declining keeps the bird.
    func testTheFirstSendAwayAsksAndCanBeDeclined() throws {
        let controller = MascotController()
        var asked = 0
        controller.confirmFirstSendAway = { _, answer in asked += 1; answer(false) }
        let id = UUID()
        let panel = makePanel(NSRect(x: screen.midX, y: screen.midY, width: 240, height: 150))
        defer { panel.orderOut(nil); controller.detach(id) }
        controller.attach(id, panel: panel)
        let perch = try XCTUnwrap(controller.perch(for: id))
        perch.stand(mode: .perched)
        perch.onSendAway()
        XCTAssertEqual(asked, 1, "the first press of the X did not ask")
        XCTAssertTrue(MascotPreference.isShown, "declining still sent the bird away")
        controller.confirmFirstSendAway = { _, answer in asked += 1; answer(true) }
        perch.onSendAway()
        XCTAssertFalse(MascotPreference.isShown)
        MascotPreference.set(true)
        perch.stand(mode: .perched)
        perch.onSendAway()
        XCTAssertEqual(asked, 2, "it asked again after the user had already said yes")
    }

    /// The question is brought by the bird, not raised by the system: the
    /// first press of the X puts a card on screen beside the shelf with the
    /// real bird standing on it, and keeping the bird carries the card away
    /// and lands the bird back on its shelf.
    func testTheBirdBringsTheQuestionAndKeepingItLandsItBack() throws {
        let controller = MascotController()
        let id = UUID()
        let shelf = NSRect(x: screen.midX - 120, y: screen.midY, width: 240, height: 150)
        let panel = makePanel(shelf)
        defer { panel.orderOut(nil); controller.detach(id) }
        controller.attach(id, panel: panel)
        let perch = try XCTUnwrap(controller.perch(for: id))
        perch.stand(mode: .perched)
        var answers: [Bool] = []
        perch.carryQuestion { answers.append($0) }
        wait(MascotCarry.bringDuration + 0.3)
        let card = try XCTUnwrap(perch.openQuestion, "no question card is open after the bird brought it")
        XCTAssertTrue(card.isVisible, "the card the bird brought is not on screen")
        let expected = MascotQuestionCard.frame(size: card.size, shelf: shelf, visible: panel.screen?.visibleFrame ?? screen)
        frameNear(card.frame, expected, "the card was not set down where the placement puts it")
        XCTAssertFalse(card.frame.intersects(shelf), "the card covers the shelf it is asking about")
        XCTAssertTrue(answers.isEmpty, "the question answered itself")
        card.onKeep()
        XCTAssertEqual(answers, [false])
        XCTAssertFalse(card.isVisible, "the card stayed after the user answered")
        wait(MascotCarry.returnDuration + MascotFlight.landDuration + 0.4)
        XCTAssertTrue(perch.restWindowVisible, "keeping the bird did not bring it back to its shelf")
        frameNear(perch.restWindowFrame, MascotPlacement.restFrame(feet: MascotPlacement.perchedFeet(onShelf: shelf)),
                  "the bird came back to the wrong place")
        XCTAssertNil(perch.openQuestion)
    }

    /// The pointer can travel from the bird to its X without losing it.
    func testTheHoverAreaCoversTheBirdTheXAndTheGapBetween() {
        let view = MascotRestView(frame: NSRect(origin: .zero, size: MascotPlacement.restWindowSize))
        let bird = MascotLayer(dark: false)
        var pose = MascotPose(); pose.x = MascotPlacement.restBox.x; pose.y = MascotPlacement.restBox.y
        bird.apply(pose)
        view.bird = bird
        let box = view.boxRect, x = view.xRect
        let gap = CGPoint(x: (box.maxX + x.minX) / 2, y: x.maxY + 2)
        for (name, p) in [("bird", CGPoint(x: box.midX, y: box.midY)), ("X", CGPoint(x: x.midX, y: x.midY)), ("gap", gap)] {
            XCTAssertTrue(view.hoverRect.contains(p), "the pointer on the \(name) is outside the hover area, so the X disappears")
        }
        XCTAssertGreaterThan(MascotRestView.hoverGrace, 0.3, "the X hides the instant the pointer leaves")
    }
}
