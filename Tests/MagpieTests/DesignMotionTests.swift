import SwiftUI
import XCTest
@testable import Magpie

/// `Design.Motion.animation(_:reduceMotion:)` and `panelTiming(_:reduceMotion:)`
/// are the whole motion decision. Everything else in the app is a thin call
/// site around them, so this is where Reduce Motion is actually verifiable —
/// the views and the AppKit panel animations are not.
final class DesignMotionTests: XCTestCase {

    private let roles: [Design.Motion.Role] = [.state, .hover, .transform, .shelfState]

    // MARK: - Reduce Motion off: the consolidated curves

    func test_full_motion_curves() {
        XCTAssertEqual(
            Design.Motion.animation(.state, reduceMotion: false),
            .easeOut(duration: 0.15)
        )
        XCTAssertEqual(
            Design.Motion.animation(.hover, reduceMotion: false),
            .spring(response: 0.30, dampingFraction: 0.72)
        )
        XCTAssertEqual(
            Design.Motion.animation(.transform, reduceMotion: false),
            .spring(response: 0.42, dampingFraction: 0.85)
        )
        XCTAssertEqual(
            Design.Motion.animation(.shelfState, reduceMotion: false),
            .spring(response: 0.34, dampingFraction: 0.86)
        )
    }

    /// The shelf's collapse/expand gesture is deliberately *not* folded into
    /// `transform`: it runs in lockstep with the AppKit panel resize, which is
    /// a different constraint from content moving inside a panel that is
    /// already the right size.
    func test_shelfState_is_not_transform() {
        XCTAssertNotEqual(
            Design.Motion.animation(.shelfState, reduceMotion: false),
            Design.Motion.animation(.transform, reduceMotion: false)
        )
    }

    func test_every_role_animates_when_reduce_motion_is_off() {
        for role in roles {
            XCTAssertNotNil(Design.Motion.animation(role, reduceMotion: false))
        }
    }

    // MARK: - Reduce Motion on

    /// A hover lift is scale and offset with nothing else to show, so it does
    /// not animate at all. Everything else becomes the same short crossfade.
    func test_hover_does_not_animate_under_reduce_motion() {
        XCTAssertNil(Design.Motion.animation(.hover, reduceMotion: true))
    }

    func test_remaining_roles_become_a_crossfade_under_reduce_motion() {
        for role in [Design.Motion.Role.state, .transform, .shelfState] {
            XCTAssertEqual(
                Design.Motion.animation(role, reduceMotion: true),
                Design.Motion.crossfade
            )
        }
    }

    /// No spring survives Reduce Motion: whatever a role resolves to with the
    /// setting on, it is never the curve it uses with the setting off.
    func test_no_role_keeps_its_full_curve_under_reduce_motion() {
        for role in roles {
            XCTAssertNotEqual(
                Design.Motion.animation(role, reduceMotion: true),
                Design.Motion.animation(role, reduceMotion: false)
            )
        }
    }

    // MARK: - AppKit panel timings

    func test_panel_timings_are_unchanged_when_reduce_motion_is_off() {
        let frame = Design.Motion.panelTiming(.frame, reduceMotion: false)
        XCTAssertEqual(
            frame,
            Design.Motion.PanelTiming(duration: 0.3, c0: 0.25, c1: 0.9, c2: 0.3, c3: 1.0)
        )
        let glide = Design.Motion.panelTiming(.glide, reduceMotion: false)
        XCTAssertEqual(
            glide,
            Design.Motion.PanelTiming(duration: 0.95, c0: 0.32, c1: 0.0, c2: 0.18, c3: 1.0)
        )
    }

    /// nil is the caller's signal to set the frame outright, with no glide.
    func test_panel_timings_are_dropped_under_reduce_motion() {
        XCTAssertNil(Design.Motion.panelTiming(.frame, reduceMotion: true))
        XCTAssertNil(Design.Motion.panelTiming(.glide, reduceMotion: true))
    }

    // MARK: - Purity

    /// The decision depends on the argument and on nothing else — in
    /// particular not on the machine the tests happen to run on, which is the
    /// only reason Reduce Motion can be tested here at all.
    func test_decision_is_independent_of_the_live_system_setting() {
        for role in roles {
            let onA = Design.Motion.animation(role, reduceMotion: true)
            let offA = Design.Motion.animation(role, reduceMotion: false)
            for _ in 0..<3 {
                XCTAssertEqual(Design.Motion.animation(role, reduceMotion: true), onA)
                XCTAssertEqual(Design.Motion.animation(role, reduceMotion: false), offA)
            }
        }
    }

    /// The live flag has exactly one source, so a caller can never read a
    /// stale copy of it.
    @MainActor
    func test_live_flag_reads_the_workspace_setting() {
        XCTAssertEqual(
            Design.Motion.isReduced,
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// The convenience accessors are the live flag applied to the pure
    /// function, not a second copy of the decision.
    @MainActor
    func test_accessors_agree_with_the_pure_function() {
        let reduced = Design.Motion.isReduced
        XCTAssertEqual(Design.Motion.state, Design.Motion.animation(.state, reduceMotion: reduced))
        XCTAssertEqual(Design.Motion.hover, Design.Motion.animation(.hover, reduceMotion: reduced))
        XCTAssertEqual(Design.Motion.transform, Design.Motion.animation(.transform, reduceMotion: reduced))
        XCTAssertEqual(Design.Motion.shelfState, Design.Motion.animation(.shelfState, reduceMotion: reduced))
        XCTAssertEqual(Design.Motion.panelFrame, Design.Motion.panelTiming(.frame, reduceMotion: reduced))
        XCTAssertEqual(Design.Motion.panelGlide, Design.Motion.panelTiming(.glide, reduceMotion: reduced))
    }
}
