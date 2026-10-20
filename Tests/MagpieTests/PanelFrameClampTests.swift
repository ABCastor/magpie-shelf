import Foundation
import XCTest
@testable import Magpie

/// Undocking restores the saved pre-dock frame — but the display it was saved
/// on can be unplugged in between, and this app has no dock icon and no window
/// menu, so a panel restored to coordinates no screen has is unrecoverable
/// from inside the app. `PanelFrameClamp.clamp` is the guard.
final class PanelFrameClampTests: XCTestCase {
    /// A 1512×982 laptop screen, origin at zero (visible-frame style).
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
    /// An external display sitting to the right of it.
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1440)

    func test_a_frame_already_on_screen_is_returned_verbatim() {
        let frame = NSRect(x: 100, y: 200, width: 320, height: 420)
        XCTAssertEqual(PanelFrameClamp.clamp(frame, into: [laptop, external]), frame)
    }

    /// The unplugged-monitor case this exists for: the saved frame names
    /// coordinates only the missing display had.
    func test_a_frame_on_a_vanished_display_moves_fully_onto_a_remaining_screen() {
        let savedOnExternal = NSRect(x: 2000, y: 600, width: 320, height: 420)
        let clamped = PanelFrameClamp.clamp(savedOnExternal, into: [laptop])
        XCTAssertTrue(
            laptop.contains(clamped),
            "the restored panel sits at \(clamped), outside the only screen \(laptop)"
        )
        XCTAssertEqual(clamped.size, savedOnExternal.size, "clamping must move, never resize")
    }

    func test_a_partially_offscreen_frame_is_pulled_fully_inside() {
        let hangingOff = NSRect(x: 1400, y: -50, width: 320, height: 420)
        let clamped = PanelFrameClamp.clamp(hangingOff, into: [laptop])
        XCTAssertTrue(laptop.contains(clamped), "got \(clamped)")
    }

    /// A frame straddling two screens belongs to the one holding more of it;
    /// snapping to the other would teleport the panel across displays.
    func test_a_straddling_frame_clamps_into_the_screen_with_the_larger_overlap() {
        // 20pt on the laptop, 300pt on the external, poking past the top.
        let straddling = NSRect(x: 1492, y: 1300, width: 320, height: 420)
        let clamped = PanelFrameClamp.clamp(straddling, into: [laptop, external])
        XCTAssertTrue(
            external.contains(clamped),
            "most of the frame was on the external screen, but it clamped to \(clamped)"
        )
    }

    func test_no_screens_returns_the_frame_unchanged() {
        let frame = NSRect(x: 5000, y: 5000, width: 320, height: 420)
        XCTAssertEqual(PanelFrameClamp.clamp(frame, into: []), frame)
    }

    /// A frame larger than the screen pins to the near edge rather than
    /// oscillating past the far one — the top-left stays reachable.
    func test_an_oversized_frame_pins_to_the_screen_origin() {
        let huge = NSRect(x: -300, y: -300, width: 2000, height: 1200)
        let clamped = PanelFrameClamp.clamp(huge, into: [laptop])
        XCTAssertEqual(clamped.origin, laptop.origin)
        XCTAssertEqual(clamped.size, huge.size)
    }
}
