import XCTest
@testable import Magpie

/// ⌘K did nothing, and it was found by hand in the manual regression pass
/// that no agent can run.
///
/// The cause was a guard in the key monitor: `case "k"` returned early unless
/// the shelf was already expanded. A summoned shelf starts COLLAPSED, so the
/// first ⌘K anyone ever pressed was swallowed. Nothing failed, nothing logged,
/// the palette simply never appeared — the worst shape of bug, and one the 442
/// tests that shipped with the feature could not see, because none of them
/// asked whether the shortcut was reachable from the state a shelf is in.
///
/// These are source-level assertions for the same reason `MenuBarVisibilityTests`
/// is: reaching the real path needs a running `NSApplication`, a key panel, and
/// a synthesised keyDown. Weaker than a behavioural test, and far stronger than
/// what was there.
final class PaletteReachabilityTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// THE regression. ⌘K must not be gated on the shelf already being expanded.
    func testCommandKIsNotGatedOnTheShelfBeingExpanded() throws {
        let app = try source("Sources/Magpie/App.swift")
        let branch = app
            .components(separatedBy: "case \"k\":")
            .dropFirst().first?
            .components(separatedBy: "case \"y\":").first ?? ""
        XCTAssertFalse(branch.isEmpty, "could not find the ⌘K branch of the key monitor")
        XCTAssertFalse(
            branch.contains("guard self.expandedShelfIDs.contains(shelfID)"),
            "⌘K is gated on the shelf being expanded again — it will do nothing from the collapsed state a summoned shelf starts in"
        )
        XCTAssertTrue(
            branch.contains("paletteRequested.send"),
            "the ⌘K branch no longer requests the palette"
        )
    }

    /// The request has to have a subscriber in EVERY state it can be sent from.
    /// `ExpandedShelfView` owns the palette but is absent from the tree while
    /// collapsed or docked, so the container must carry its own subscriber —
    /// otherwise the event lands nowhere, which is exactly the original bug in
    /// a different place.
    func testContainerSubscribesSoTheRequestIsNeverDropped() throws {
        let view = try source("Sources/Magpie/ShelfContainerView.swift")
        let subscribers = view.components(separatedBy: "onReceive(manager.paletteRequested)").count - 1
        XCTAssertGreaterThanOrEqual(
            subscribers, 2,
            "only one subscriber to paletteRequested: a ⌘K sent while collapsed or docked has nowhere to land"
        )
        XCTAssertTrue(
            view.contains("palettePending"),
            "nothing carries the pending ⌘K across the expand transition"
        )
    }

    /// The handover must be consumed exactly once. A flag left set would pop
    /// the palette again on the next expand the user performs by hand.
    func testPendingPaletteIsClearedWhenConsumed() throws {
        let view = try source("Sources/Magpie/ShelfContainerView.swift")
        let onAppear = view
            .components(separatedBy: "guard palettePending else { return }")
            .dropFirst().first?.prefix(300) ?? ""
        XCTAssertTrue(
            onAppear.contains("palettePending = false"),
            "palettePending is never cleared; the palette would reopen on the next manual expand"
        )
    }

    /// Reduce Motion must not inherit a wait for an animation that does not run.
    func testTheSettleWaitIsReadFromTheAnimationTokenNotHardcoded() throws {
        let view = try source("Sources/Magpie/ShelfContainerView.swift")
        XCTAssertTrue(
            view.contains("panelTiming(.frame, reduceMotion: Design.Motion.isReduced)"),
            "the palette's settle delay is hardcoded; it must come from the same token that drives the panel resize, and collapse to zero under Reduce Motion"
        )
    }
}
