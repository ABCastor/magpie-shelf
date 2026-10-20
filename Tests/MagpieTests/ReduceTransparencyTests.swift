import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// Reduce Transparency reaches the shelf the same way Reduce Motion does: one
/// live read (`Design.Transparency.isReduced`), applied to the panel and
/// re-applied when the user flips the setting mid-session. The system setting
/// itself cannot be toggled from a test, so these exercise the seam the panel
/// exposes — `applyReduceTransparency(_:)` — plus the wiring that calls it.
@MainActor
final class ReduceTransparencyTests: XCTestCase {

    private func makePanel() -> FloatingPanel<Text> {
        FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120)) {
            Text(verbatim: "ground probe")
        }
    }

    /// The swap itself: exactly one ground is live in each mode.
    func test_reduced_swaps_the_material_for_an_opaque_ground() {
        let panel = makePanel()

        panel.applyReduceTransparency(true)
        XCTAssertTrue(
            panel.materialView.isHidden,
            "Reduce Transparency is on but the blur material is still the panel's ground"
        )
        XCTAssertFalse(
            panel.opaqueGround.isHidden,
            "Reduce Transparency is on but no opaque ground replaces the material"
        )

        panel.applyReduceTransparency(false)
        XCTAssertFalse(
            panel.materialView.isHidden,
            "Reduce Transparency is off but the material did not come back"
        )
        XCTAssertTrue(
            panel.opaqueGround.isHidden,
            "Reduce Transparency is off but the opaque ground is still covering the material"
        )
    }

    /// A panel created while the setting is already on must be born opaque —
    /// the state the app is actually in when an affected user summons a shelf.
    func test_a_new_panel_matches_the_live_setting() {
        let panel = makePanel()
        let reduced = Design.Transparency.isReduced
        XCTAssertEqual(
            panel.materialView.isHidden, reduced,
            "a fresh panel ignores the live Reduce Transparency setting"
        )
        XCTAssertEqual(
            panel.opaqueGround.isHidden, !reduced,
            "a fresh panel's opaque ground disagrees with the live setting"
        )
    }

    /// Flipping the setting mid-session must reach panels already on screen.
    /// The setting itself cannot be flipped from here, so: sabotage the panel
    /// into an impossible state, post the notification the observer listens
    /// for, and require it to reconcile back to the live value.
    func test_the_setting_change_notification_reapplies_the_live_value() {
        let panel = makePanel()
        panel.materialView.isHidden = true
        panel.opaqueGround.isHidden = true

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )

        // The observer hops through a MainActor task; give the main queue a
        // few turns to drain it.
        let reduced = Design.Transparency.isReduced
        var reconciled = false
        for _ in 0..<50 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if panel.materialView.isHidden == reduced,
               panel.opaqueGround.isHidden == !reduced {
                reconciled = true
                break
            }
        }
        XCTAssertTrue(
            reconciled,
            "the accessibility-options notification did not re-apply Reduce Transparency, so a mid-session toggle would not reach panels already on screen"
        )
    }
}
