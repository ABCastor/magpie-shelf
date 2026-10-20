import AppKit
import XCTest
@testable import Magpie

/// The card the magpie brings: held in the beak on the way, set down where
/// the placement says, the bird standing on its top edge; carried back or
/// away when answered. Pure geometry, so every claim is exact.
@MainActor
final class MascotCarryTests: XCTestCase {
    private let home = CGPoint(x: 900, y: 300)
    private let card = CGRect(x: 600, y: 420, width: 300, height: 130)

    func testOnTheWayTheCardHangsFromTheBeakAndGrows() {
        let early = MascotCarry.bring(0.5, from: home, card: card)
        let beak = MascotGeometry.beak(early.pose)
        let scale = early.card.width / card.width
        XCTAssertEqual(early.card.minX, beak.x - MascotCarry.grip(card.size).x * scale, accuracy: 0.01, "the card is not held at the beak")
        XCTAssertEqual(early.card.minY, beak.y - MascotCarry.grip(card.size).y * scale, accuracy: 0.01, "the card is not held at the beak")
        XCTAssertLessThan(scale, 0.9, "the card does not grow on the way, it arrives full size")
        XCTAssertLessThan(MascotCarry.bring(0.3, from: home, card: card).card.width, card.width * 0.25,
                          "the card is already large as the bird takes off, so it covers the shelf")
        let later = MascotCarry.bring(0.7, from: home, card: card)
        XCTAssertGreaterThan(later.card.width, early.card.width, "the card shrinks as it is brought")
    }

    func testItIsSetDownInPlaceWithTheBirdStandingOnIt() {
        let end = MascotCarry.bring(1, from: home, card: card)
        XCTAssertEqual(end.card, card, "the card is not set down where it belongs")
        XCTAssertEqual(end.opacity, 1, accuracy: 0.001)
        let feet = CGPoint(x: end.pose.x + MascotGeometry.origin.x, y: end.pose.y + MascotGeometry.origin.y)
        XCTAssertEqual(feet.y, card.minY, accuracy: 0.01, "the bird is not standing on the card's top edge")
        XCTAssertTrue((card.minX...card.maxX).contains(feet.x), "the bird stands beside the card, not on it")
        XCTAssertEqual(end.pose.lean, 0, accuracy: 0.01, "the bird is still pitched in flight when it lands on the card")
    }

    func testKeepingCarriesTheCardHomeAndPutsItAway() {
        let start = MascotCarry.takeBack(0, card: card, to: home)
        XCTAssertEqual(start.card, card, "the card jumps before it is picked up")
        let end = MascotCarry.takeBack(1, card: card, to: home)
        XCTAssertEqual(end.pose.x, home.x, accuracy: 0.01, "the bird does not go home")
        XCTAssertEqual(end.pose.y, home.y, accuracy: 0.01, "the bird does not go home")
        XCTAssertEqual(end.opacity, 0, accuracy: 0.001, "the card is still showing when the bird is home")
        XCTAssertLessThan(end.card.width, card.width * 0.3, "the card is not carried in the beak")
    }

    func testHidingFliesOffWithTheCardAndBothFade() {
        let start = MascotCarry.away(0, card: card)
        XCTAssertEqual(start.card, card)
        let end = MascotCarry.away(1, card: card)
        XCTAssertEqual(end.pose.opacity, 0, accuracy: 0.001, "the bird is still visible after flying off")
        XCTAssertEqual(end.opacity, 0, accuracy: 0.001, "the card is left behind")
        XCTAssertLessThan(end.pose.y, MascotCarry.stand(on: card).y - 100, "it does not fly away, up and out")
    }

    // MARK: Placement

    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 300, height: 130)

    func testTheCardGoesUnderTheShelfWithRoomForTheBird() {
        let shelf = NSRect(x: 900, y: 500, width: 240, height: 200)
        let f = MascotQuestionCard.frame(size: size, shelf: shelf, visible: visible)
        XCTAssertEqual(f.maxX, shelf.maxX, accuracy: 0.01, "the card is not lined up under the bird's side of the shelf")
        XCTAssertEqual(shelf.minY - f.maxY, MascotQuestionCard.birdRoom, accuracy: 0.01, "no room left for the bird to stand on the card")
        XCTAssertGreaterThan(MascotQuestionCard.birdRoom, MascotDrawing.size.height * MascotDrawing.feetFraction,
                             "the bird standing on the card would overlap the shelf")
    }

    func testANearlyBottomShelfGetsTheCardAboveIt() {
        let shelf = NSRect(x: 900, y: 40, width: 240, height: 200)
        let f = MascotQuestionCard.frame(size: size, shelf: shelf, visible: visible)
        XCTAssertGreaterThanOrEqual(f.minY, shelf.maxY, "the card was put below a shelf with no room under it")
        XCTAssertTrue(visible.contains(f), "the card went off screen")
    }

    func testTheCardStaysOnScreenAtTheLeftEdge() {
        let shelf = NSRect(x: 2, y: 500, width: 180, height: 200)
        let f = MascotQuestionCard.frame(size: size, shelf: shelf, visible: visible)
        XCTAssertGreaterThanOrEqual(f.minX, visible.minX, "the card went off the left edge")
    }

    // MARK: Pace

    /// "Even slightly faster": every flight is quicker than the previous
    /// build's, and none so quick it stops reading as a flight.
    func testEveryFlightIsSlightlyFasterThanTheLastBuild() {
        let previous: [(String, TimeInterval, TimeInterval)] = [
            ("appear", 1.3, MascotFlight.appearDuration),
            ("cross", 0.9, MascotFlight.crossDuration),
            ("dock", 2.2, MascotFlight.dockDuration),
            ("close", 1.0, MascotPass.closing(from: .zero, x: CGPoint(x: 10, y: 10)).duration),
            ("send away", 0.85, MascotPass.dismissing(from: .zero, x: CGPoint(x: 10, y: 10)).duration),
        ]
        for (name, before, now) in previous {
            XCTAssertLessThanOrEqual(now, before * 0.9, "\(name) is not faster than before")
            XCTAssertGreaterThanOrEqual(now, before * 0.75, "\(name) got more than slightly faster")
        }
    }
}
