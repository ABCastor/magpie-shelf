import XCTest
@testable import Magpie

/// The glass slider: Apple's own material at the light end, the approved
/// frosted look by default, solid at the other end, and every step between
/// visibly different from the last.
final class GlassTests: XCTestCase {
    func testTheLightEndIsTheSystemsOwnGlass() {
        XCTAssertEqual(ShelfGlass.groundAlpha(0), 0, accuracy: 0.001,
                       "the light end still lays a coat over the system material, so the slider barely changes anything")
    }

    func testTheSolidEndIsSolid() {
        XCTAssertEqual(ShelfGlass.groundAlpha(1), 1, accuracy: 0.001)
    }

    /// The default keeps the frosted look approved on the design page,
    /// a coat of 0.85 under the old mapping.
    func testTheDefaultKeepsTheApprovedFrost() {
        XCTAssertEqual(ShelfGlass.groundAlpha(ShelfGlass.defaultValue), 0.85, accuracy: 0.02,
                       "the default glass no longer looks like the approved design")
    }

    /// Every tenth of the slider changes the coat by a visible amount, and
    /// always in the same direction.
    func testEveryStepOfTheSliderDoesSomething() {
        var last = ShelfGlass.groundAlpha(0)
        for i in 1...10 {
            let now = ShelfGlass.groundAlpha(Double(i) / 10)
            XCTAssertGreaterThan(now - last, 0.015, "slider step \(i) changes the glass by too little to see")
            last = now
        }
    }
}
