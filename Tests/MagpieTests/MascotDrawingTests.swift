import AppKit
import XCTest
@testable import Magpie

/// The magpie is the approved drawing, the right way up, turning the way the
/// reference turns. Each test samples real pixels from the same layer tree the
/// app shows, at points the drawing's own geometry predicts.
@MainActor
final class MascotDrawingTests: XCTestCase {
    private let canvas = CGSize(width: 160, height: 160)

    /// Alpha and brightness of the pixel at a y-down point in points.
    private func sample(_ rep: NSBitmapImageRep, _ p: CGPoint) -> (alpha: CGFloat, white: CGFloat) {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let x = Int(p.x * scale), y = Int(p.y * scale)
        guard let c = rep.colorAt(x: x, y: y) else { return (0, 0) }
        let rgb = c.usingColorSpace(.deviceRGB) ?? c
        return (rgb.alphaComponent, (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3)
    }

    private func at(_ drawing: CGPoint, _ pose: MascotPose, lean: Bool = true) -> CGPoint {
        drawing.applying(lean ? MascotGeometry.leanToStage(pose) : MascotGeometry.drawingToStage(pose))
    }

    private var placed: MascotPose { MascotPose(x: 50, y: 40) }

    /// "Slightly smaller" than the page's 58 × 75: smaller, but not by half.
    func testTheBirdIsSlightlySmallerThanThePagesAndKeepsItsShape() {
        let page = CGSize(width: 58, height: 75)
        let ratio = MascotDrawing.size.height / page.height
        XCTAssertLessThan(ratio, 0.86, "the bird is still the page's size, which the owner found too big on the shelf")
        XCTAssertGreaterThan(ratio, 0.74, "the bird shrank by more than 'slightly'")
        XCTAssertEqual(MascotDrawing.size.width / MascotDrawing.size.height, page.width / page.height, accuracy: 0.005,
                       "the bird's box changed shape")
    }

    func testThePathsParseToTheDrawingsOwnExtent() {
        let body = MascotDrawing.path(MascotDrawing.body).boundingBoxOfPath
        XCTAssertEqual(body.minY, 33, accuracy: 0.5, "the head is not where the drawing puts it")
        XCTAssertGreaterThan(body.maxX, 440, "the bill is missing from the body")
        XCTAssertLessThan(body.maxY, MascotDrawing.feetY, "the body reaches below the feet")
        let tail = MascotDrawing.path(MascotDrawing.tail).boundingBoxOfPath
        XCTAssertGreaterThan(tail.maxY, MascotDrawing.feetY, "the tail no longer hangs below the feet")
    }

    func testTheBirdIsDrawnTheRightWayUpInBothInks() throws {
        for dark in [false, true] {
            let rep = try XCTUnwrap(MascotRender.bitmap(placed, dark: dark, canvas: canvas))
            // The eye is paper inside an ink head.
            let eye = sample(rep, at(MascotDrawing.eyeCenter, placed))
            XCTAssertGreaterThan(eye.white, 0.8, "dark=\(dark): the eye is not paper where the drawing puts it — the bird is upside down or misplaced")
            let crown = sample(rep, at(CGPoint(x: 300, y: 60), placed))
            XCTAssertGreaterThan(crown.alpha, 0.9)
            XCTAssertLessThan(crown.white, 0.2, "dark=\(dark): the crown is not ink")
            // Feet stand on the line, tail hangs below it.
            let foot = sample(rep, at(CGPoint(x: 305, y: 462), placed))
            XCTAssertGreaterThan(foot.alpha, 0.9, "dark=\(dark): no foot on the line")
            let below = sample(rep, at(CGPoint(x: 300, y: 520), placed))
            XCTAssertLessThan(below.alpha, 0.1, "dark=\(dark): something is drawn below the feet where only air should be")
        }
    }

    /// A pitch of 30 tips the bird forward, clockwise, like the page. A tree
    /// that turned the other way would put the bill where the geometry says
    /// air is.
    func testTheFlyingPoseTipsForwardLikeTheReference() throws {
        let pose = MascotPose.flying(x: 50, y: 40)
        let rep = try XCTUnwrap(MascotRender.bitmap(pose, dark: false, canvas: canvas))
        let bill = sample(rep, at(CGPoint(x: 428, y: 112), pose))
        XCTAssertGreaterThan(bill.alpha, 0.9, "the bill is not where a clockwise pitch puts it")
        XCTAssertLessThan(bill.white, 0.2)
        // And where the bill would be had it turned anticlockwise, there is air.
        let mirrored = MascotPose.flying(x: 50, y: 40, pitch: -30)
        let wrong = sample(rep, at(CGPoint(x: 428, y: 112), mirrored))
        XCTAssertLessThan(wrong.alpha, 0.1, "the bird turned the wrong way")
    }

    func testTheDarkDrawingWearsAPaperRim() throws {
        let light = try XCTUnwrap(MascotRender.bitmap(placed, dark: false, canvas: canvas))
        let dark = try XCTUnwrap(MascotRender.bitmap(placed, dark: true, canvas: canvas))
        // Just outside the back, where only the rim reaches.
        let p = at(CGPoint(x: 302, y: 28), placed)
        XCTAssertLessThan(sample(light, p).alpha, 0.1, "the light drawing has a rim")
        XCTAssertGreaterThan(sample(dark, p).white, 0.8, "the dark drawing lost its paper rim")
    }

    func testTheSparkIsHiddenAtRestAndShownByTheCatch() throws {
        let p = at(MascotDrawing.sparkCenter, placed)
        let rest = try XCTUnwrap(MascotRender.bitmap(placed, dark: false, canvas: canvas))
        XCTAssertLessThan(sample(rest, p).alpha, 0.1, "a spark shows on a bird at rest")
        let catchPose = MascotBehaviour.pose(.done, at: 0.45, base: placed)
        let caught = try XCTUnwrap(MascotRender.bitmap(catchPose, dark: false, canvas: canvas))
        let spark = sample(caught, p)
        XCTAssertGreaterThan(spark.alpha, 0.9, "the catch shows no spark at the beak")
    }

    func testTheHeldXIsOnlyInTheBeakAfterTheGrab() throws {
        var pose = MascotPose.flying(x: 50, y: 40)
        let p = at(CGPoint(x: 441, y: 115), pose)
        let without = try XCTUnwrap(MascotRender.bitmap(pose, dark: false, canvas: canvas))
        pose.holdsX = true
        let with = try XCTUnwrap(MascotRender.bitmap(pose, dark: false, canvas: canvas))
        XCTAssertLessThan(sample(without, p).alpha, 0.5, "an X is in the beak before it was taken")
        XCTAssertGreaterThan(sample(with, p).alpha, 0.9, "the X the bird took is not in its beak")
    }
}
