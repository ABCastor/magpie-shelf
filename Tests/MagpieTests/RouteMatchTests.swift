import Foundation
import XCTest
@testable import Magpie

/// The eligibility predicate behind the Routes submenu — pure, so the menu
/// logic itself needs no test harness.
final class RouteMatchTests: XCTestCase {
    private let pdf = RouteInput(pathExtension: "pdf", typeIdentifier: "com.adobe.pdf")
    private let png = RouteInput(pathExtension: "png", typeIdentifier: "public.png")
    private let audio = RouteInput(pathExtension: "m4a", typeIdentifier: "public.mpeg-4-audio")
    private let unknown = RouteInput(pathExtension: "weird", typeIdentifier: nil)

    func test_no_match_means_any_file() {
        XCTAssertTrue(RouteMatch.applies(nil, to: [pdf, png, unknown]))
        XCTAssertTrue(RouteMatch.applies(
            RouteMatch(extensions: [], utis: []), to: [unknown]
        ))
    }

    func test_an_empty_selection_never_matches() {
        XCTAssertFalse(RouteMatch.applies(nil, to: []))
        XCTAssertFalse(RouteMatch.applies(RouteMatch(extensions: ["pdf"], utis: []), to: []))
    }

    func test_extension_match_is_case_insensitive() {
        let match = RouteMatch(extensions: ["pdf"], utis: [])
        XCTAssertTrue(match.matches(pdf))
        XCTAssertTrue(match.matches(
            RouteInput(pathExtension: "PDF", typeIdentifier: nil)
        ))
        XCTAssertFalse(match.matches(png))
    }

    func test_uti_match_follows_conformance() {
        let match = RouteMatch(extensions: [], utis: ["public.image"])
        XCTAssertTrue(match.matches(png))
        XCTAssertFalse(match.matches(pdf))
    }

    func test_extensions_and_utis_are_or_ed() {
        let match = RouteMatch(extensions: ["pdf"], utis: ["public.image"])
        XCTAssertTrue(match.matches(pdf))
        XCTAssertTrue(match.matches(png))
        XCTAssertFalse(match.matches(audio))
    }

    func test_every_file_has_to_match_not_just_one() {
        let match = RouteMatch(extensions: ["pdf"], utis: [])
        XCTAssertTrue(RouteMatch.applies(match, to: [pdf, pdf]))
        XCTAssertFalse(RouteMatch.applies(match, to: [pdf, png]))
    }

    func test_an_unreadable_type_falls_back_to_the_extension() {
        let match = RouteMatch(extensions: ["weird"], utis: ["public.image"])
        XCTAssertTrue(match.matches(unknown))
        XCTAssertFalse(match.matches(
            RouteInput(pathExtension: "other", typeIdentifier: nil)
        ))
    }

    func test_a_nonsense_uti_in_the_file_matches_nothing_rather_than_everything() {
        let match = RouteMatch(extensions: [], utis: ["not a uti at all"])
        XCTAssertFalse(match.matches(png))
        XCTAssertFalse(match.matches(pdf))
    }
}
