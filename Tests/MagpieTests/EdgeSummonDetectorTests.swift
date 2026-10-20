import XCTest
@testable import Magpie

final class EdgeSummonDetectorTests: XCTestCase {
    // Primary display in AppKit's bottom-left-origin coordinate space.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func test_tunables() {
        // Pinned deliberately: the band and dwell are the whole feel of this
        // trigger, and a silent change would be invisible in every other test.
        XCTAssertEqual(EdgeSummonDetector.bandWidth, 4)
        XCTAssertEqual(EdgeSummonDetector.dwell, 0.4)
    }

    // MARK: - Band

    func test_right_edge_band_includes_the_last_pixels() {
        // NSEvent.mouseLocation tops out one point short of maxX.
        XCTAssertTrue(band(x: 1439, edge: .right))
        XCTAssertTrue(band(x: 1436, edge: .right))
    }

    func test_right_edge_band_excludes_the_interior() {
        XCTAssertFalse(band(x: 1435, edge: .right))
        XCTAssertFalse(band(x: 720, edge: .right))
        XCTAssertFalse(band(x: 0, edge: .right))
    }

    func test_left_edge_band_includes_the_first_pixels() {
        XCTAssertTrue(band(x: 0, edge: .left))
        XCTAssertTrue(band(x: 4, edge: .left))
    }

    func test_left_edge_band_excludes_the_interior() {
        XCTAssertFalse(band(x: 5, edge: .left))
        XCTAssertFalse(band(x: 1439, edge: .left))
    }

    func test_band_respects_vertical_bounds() {
        XCTAssertFalse(
            EdgeSummonDetector.isWithinBand(
                point: CGPoint(x: 1439, y: 901), screenFrame: screen, edge: .right
            )
        )
        XCTAssertFalse(
            EdgeSummonDetector.isWithinBand(
                point: CGPoint(x: 1439, y: -1), screenFrame: screen, edge: .right
            )
        )
    }

    func test_band_is_relative_to_the_given_screen() {
        // Secondary display sitting to the right of the primary one.
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(
            EdgeSummonDetector.isWithinBand(
                point: CGPoint(x: 3359, y: 500), screenFrame: secondary, edge: .right
            )
        )
        XCTAssertFalse(
            EdgeSummonDetector.isWithinBand(
                point: CGPoint(x: 1439, y: 500), screenFrame: secondary, edge: .right
            )
        )
        XCTAssertTrue(
            EdgeSummonDetector.isWithinBand(
                point: CGPoint(x: 1441, y: 500), screenFrame: secondary, edge: .left
            )
        )
    }

    // MARK: - Dwell

    func test_no_summon_before_the_cursor_has_entered_the_band() {
        XCTAssertFalse(summon(x: 1439, dwellStart: nil, now: 100))
    }

    func test_no_summon_before_the_dwell_elapses() {
        XCTAssertFalse(summon(x: 1439, dwellStart: 100, now: 100))
        XCTAssertFalse(summon(x: 1439, dwellStart: 100, now: 100.39))
    }

    func test_summon_once_the_dwell_elapses() {
        XCTAssertTrue(summon(x: 1439, dwellStart: 100, now: 100.4))
        XCTAssertTrue(summon(x: 1439, dwellStart: 100, now: 101))
    }

    func test_no_summon_once_the_cursor_has_left_the_band() {
        // Dwell long satisfied, but the cursor is back in the interior.
        XCTAssertFalse(summon(x: 700, dwellStart: 100, now: 105))
    }

    func test_edge_preference_is_honoured() {
        XCTAssertFalse(summon(x: 1439, dwellStart: 100, now: 105, edge: .left))
        XCTAssertTrue(summon(x: 1, dwellStart: 100, now: 105, edge: .left))
        XCTAssertFalse(summon(x: 1, dwellStart: 100, now: 105, edge: .right))
    }

    func test_edge_raw_values_are_pinned() {
        // @AppStorage persists the raw value. Pinned literals rather than a
        // round-trip loop, which is compiler-guaranteed and cannot fail — see
        // the note in HotkeyPresetTests.test_raw_values_are_pinned.
        XCTAssertEqual(SummonEdge.allCases.map(\.rawValue), ["right", "left"])
        XCTAssertNil(SummonEdge(rawValue: "top"))
    }

    // MARK: - Helpers

    private func band(x: CGFloat, edge: SummonEdge) -> Bool {
        EdgeSummonDetector.isWithinBand(
            point: CGPoint(x: x, y: 450), screenFrame: screen, edge: edge
        )
    }

    private func summon(
        x: CGFloat,
        dwellStart: CFTimeInterval?,
        now: CFTimeInterval,
        edge: SummonEdge = .right
    ) -> Bool {
        EdgeSummonDetector.shouldSummon(
            point: CGPoint(x: x, y: 450),
            screenFrame: screen,
            edge: edge,
            dwellStart: dwellStart,
            now: now
        )
    }
}
