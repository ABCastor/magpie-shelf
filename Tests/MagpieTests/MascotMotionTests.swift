import AppKit
import XCTest
@testable import Magpie

/// The motion is the approved reference's, transcribed: these hold the
/// transcription to the page's numbers and to the physical promises the
/// design made (it lands where it stands, the beak goes through the X, the
/// docked bird fits the tab).
final class MascotMotionTests: XCTestCase {

    // MARK: Flutter

    func testFlutterLandsExactlyAtRestOnItsTarget() {
        let a = CGPoint(x: 10, y: 300), b = CGPoint(x: 400, y: 120)
        let end = MascotFlight.flutter(1, from: a, to: b)
        XCTAssertEqual(end.x, b.x, accuracy: 0.001)
        XCTAssertEqual(end.y, b.y, accuracy: 0.001)
        XCTAssertEqual(end.lean, 0, accuracy: 0.001, "it lands still tipped forward")
        XCTAssertEqual(end.wing, 0, accuracy: 0.001, "it lands with its wing raised")
        XCTAssertEqual(end.legsSy, 1, accuracy: 0.001, "it lands with its legs tucked")
        XCTAssertEqual(end.sx, 1, accuracy: 0.001)
        XCTAssertEqual(end.sy, 1, accuracy: 0.001)
    }

    func testOnlyTheLastFifthBlendsIntoStanding() {
        let a = CGPoint.zero, b = CGPoint(x: 300, y: 0)
        XCTAssertEqual(MascotFlight.flutter(0.5, from: a, to: b).lean, 30, accuracy: 0.001,
                       "mid-flight the bird is not tipped the approved 30 degrees")
        XCTAssertEqual(MascotFlight.flutter(0.78, from: a, to: b).lean, 30, accuracy: 0.001,
                       "the blend to standing starts before the last fifth")
        let late = MascotFlight.flutter(0.9, from: a, to: b)
        XCTAssertGreaterThan(late.lean, 0)
        XCTAssertLessThan(late.lean, 30, "the last fifth does not blend")
    }

    func testFlutterArcsUpAndIsEased() {
        let a = CGPoint(x: 0, y: 200), b = CGPoint(x: 300, y: 200)
        let mid = MascotFlight.flutter(0.5, from: a, to: b)
        XCTAssertEqual(mid.y, 160, accuracy: 0.001, "the slight arc is 40 points at the top")
        let early = MascotFlight.flutter(0.1, from: a, to: b)
        XCTAssertLessThan(early.x, 0.1 * 300, "not eased in")
    }

    // MARK: Dock

    func testTheDockedBirdShrinksToFitAndStandsOnTheTabsBottomEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let tab = NSRect(x: screen.maxX - ShelfLayout.docked.width + ShelfLayout.dockedOffscreen,
                         y: 300, width: ShelfLayout.docked.width, height: ShelfLayout.docked.height)
        let feet = MascotPlacement.dockedFeet(onTab: tab, screen: screen)
        XCTAssertEqual(feet.y, tab.minY, "the docked bird does not stand on the tab's bottom edge")
        let space = MascotSpace(top: screen.maxY)
        let to = space.box(feet: feet)
        let end = MascotFlight.dock(1, from: CGPoint(x: 900, y: 400), to: to)
        XCTAssertEqual(end.k, MascotFlight.dockScale, accuracy: 0.001)
        XCTAssertEqual(MascotFlight.dockScale, 0.44, "the approved docked size is 0.44")
        // The drawn bird, at that size, is inside the visible part of the tab.
        var standing = MascotPose(x: to.x, y: to.y); standing.k = end.k
        let drawn = MascotGeometry.drawnBounds(standing)
        let visible = space.down(tab.intersection(screen))
        let body = drawn.insetBy(dx: 0, dy: 0)
        XCTAssertGreaterThanOrEqual(body.minX, visible.minX, "the docked bird overhangs the tab's left side")
        XCTAssertLessThanOrEqual(body.maxX, visible.maxX, "the docked bird overhangs the screen edge")
        // Feet on the edge: the feet line is the tab's bottom in y-down.
        let feetLine = CGPoint(x: 268, y: MascotDrawing.feetY).applying(MascotGeometry.drawingToStage(standing))
        XCTAssertEqual(feetLine.y, space.down(feet).y, accuracy: 0.1)
    }

    func testTheShrinkStartsOnlyAfterTheMiddleOfTheFlight() {
        let p = MascotFlight.dock(0.45, from: .zero, to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(p.k, 1, accuracy: 0.001, "the bird shrinks before 45% of the dock flight")
    }

    // MARK: The bite in passing

    func testTheBeakPassesThroughTheShelfXWithoutTheXMoving() {
        let x = CGPoint(x: 621, y: 205)
        let pass = MascotPass.closing(from: CGPoint(x: 780, y: 300), x: x)
        // The grab is at eased time one half, which is linear time one half.
        let grab = pass.pose(at: 0.5)
        let beak = MascotGeometry.beak(grab)
        XCTAssertEqual(beak.x, x.x, accuracy: 1, "the beak misses the X horizontally")
        XCTAssertEqual(beak.y, x.y, accuracy: 1, "the beak misses the X vertically")
        XCTAssertTrue(grab.holdsX, "the X is not taken at the moment the beak reaches it")
        XCTAssertFalse(pass.pose(at: 0.49).holdsX, "the X is taken before the beak reaches it")
    }

    func testThePassNeverStopsAndEndsGone() {
        let pass = MascotPass.dismissing(from: CGPoint(x: 100, y: 100), x: CGPoint(x: 165, y: 98))
        var last = pass.pose(at: 0)
        for i in 1...40 {
            let p = pass.pose(at: CGFloat(i) / 40)
            let moved = hypot(p.x - last.x, p.y - last.y)
            XCTAssertGreaterThan(moved, 0.05, "the pass stops at step \(i)")
            last = p
        }
        XCTAssertEqual(pass.pose(at: 1).opacity, 0, accuracy: 0.001, "the bird is still visible after flying off")
        XCTAssertTrue(pass.pose(at: 1).holdsX)
    }

    func testClosingSwoopsFromAboveFacingTheX() {
        let start = CGPoint(x: 780, y: 300)
        let pass = MascotPass.closing(from: start, x: CGPoint(x: 621, y: 205))
        let quarter = pass.pose(at: 0.3)
        XCTAssertLessThan(quarter.sx, 0, "the closing pass is not mirrored toward the X on the left")
        XCTAssertLessThan(quarter.y, start.y, "the closing pass does not come over from above")
    }

    // MARK: Behaviours, against mp-motion.css

    func testTheIdleFlickAndDoubleBlinkLandOnTheirKeyframes() {
        XCTAssertEqual(MascotBehaviour.pose(.idle, at: 6 * 0.81).tail, -10, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.idle, at: 6 * 0.84).tail, 3.5, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.idle, at: 6 * 0.4075).eyeScaleY, 0.1, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.idle, at: 6 * 0.4225).eyeScaleY, 0.1, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.idle, at: 6 * 0.2).eyeScaleY, 1, accuracy: 0.01)
        // Every six seconds.
        XCTAssertEqual(MascotBehaviour.pose(.idle, at: 6 + 6 * 0.81).tail, -10, accuracy: 0.01)
    }

    func testTheHopIsTwoFootedAndSixHundredMilliseconds() {
        let top = MascotBehaviour.pose(.working, at: 0.6 * 0.58)
        XCTAssertEqual(top.allTy, -56, accuracy: 0.01)
        XCTAssertEqual(top.allSy, 1.03, accuracy: 0.001)
        let crouch = MascotBehaviour.pose(.working, at: 0.6 * 0.2)
        XCTAssertEqual(crouch.allSx, 1.03, accuracy: 0.001)
        XCTAssertEqual(crouch.allSy, 0.96, accuracy: 0.001)
        XCTAssertEqual(MascotBehaviour.pose(.working, at: 0.6 * 0.8).tail, 6, accuracy: 0.01)
    }

    func testTheCatchAndTheShake() {
        let caught = MascotBehaviour.pose(.done, at: 0.45)
        XCTAssertEqual(caught.sparkScale, 1, accuracy: 0.001)
        XCTAssertEqual(caught.sparkRotation, 45, accuracy: 0.01)
        let after = MascotBehaviour.pose(.done, at: 2)
        XCTAssertEqual(after.sparkOpacity, 0, accuracy: 0.001, "the spark does not fade out and stay gone")
        XCTAssertEqual(MascotBehaviour.pose(.done, at: 0.16).wing, -8, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.oops, at: 0.25 * 0.2).allTx, -16, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.oops, at: 0.25 * 0.4).allTx, 16, accuracy: 0.01)
        XCTAssertEqual(MascotBehaviour.pose(.oops, at: 0.125).bellyScale, 1.05, accuracy: 0.001)
    }

    func testCuriousLeansInWithTheOvershootingTransition() {
        let end = MascotBehaviour.pose(.curious, at: 1)
        XCTAssertEqual(end.lean, 5, accuracy: 0.001)
        XCTAssertEqual(end.wingTx, -4, accuracy: 0.001)
        XCTAssertEqual(end.wingTy, -4, accuracy: 0.001)
        // cubic-bezier(.3,1.4,.5,1) overshoots on the way.
        let peak = (1...31).map { MascotBehaviour.pose(.curious, at: Double($0) / 100).lean }.max() ?? 0
        XCTAssertGreaterThan(peak, 5, "the lean does not spring past and settle back")
    }

    // MARK: Placement

    func testThePerchedBirdStandsOnTheShelfsBottomEdgeAtTheRight() {
        let shelf = NSRect(x: 500, y: 300, width: 240, height: 200)
        let feet = MascotPlacement.perchedFeet(onShelf: shelf)
        XCTAssertEqual(feet.y, shelf.minY, "the feet are not on the shelf's bottom edge")
        XCTAssertEqual(feet.x, shelf.maxX - 45, accuracy: 0.001)
        // The rest window holds the bird, its tail, and the pet X.
        let window = MascotPlacement.restFrame(feet: feet)
        let space = MascotSpace(top: 1000)
        let box = space.box(feet: feet)
        let localBox = CGPoint(x: box.x - window.minX, y: box.y - (1000 - window.maxY))
        XCTAssertEqual(localBox.x, MascotPlacement.restBox.x, accuracy: 0.001)
        XCTAssertEqual(localBox.y, MascotPlacement.restBox.y, accuracy: 0.001)
        let pose = MascotPose(x: localBox.x, y: localBox.y)
        let bounds = CGRect(origin: .zero, size: MascotPlacement.restWindowSize)
        XCTAssertTrue(bounds.contains(MascotGeometry.drawnBounds(pose)), "the bird or its tail is cut by its window")
        XCTAssertTrue(bounds.contains(MascotPlacement.petX.offsetBy(dx: localBox.x, dy: localBox.y)), "the pet X is cut by its window")
        // The X is just inside the shelf's right edge.
        let xRight = window.minX + localBox.x + MascotPlacement.petX.maxX
        XCTAssertLessThan(xRight, shelf.maxX, "the pet X is outside the shelf")
        XCTAssertGreaterThan(xRight, shelf.maxX - 6, "the pet X is not by the shelf's right edge")
    }

    func testTheStripLeavesTheBirdItsSpace() {
        let with = ShelfLayout.collapsedSize(itemCount: 3, perch: true)
        let without = ShelfLayout.collapsedSize(itemCount: 3, perch: false)
        XCTAssertEqual(with.height - without.height, ShelfLayout.perchClearance)
        // The bird's head clears the last row.
        let headAboveEdge = MascotGeometry.origin.y
        XCTAssertLessThanOrEqual(headAboveEdge, ShelfLayout.margin + ShelfLayout.perchClearance,
                                 "the perched bird stands over the last file's row")
    }
}
