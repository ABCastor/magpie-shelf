import CoreGraphics
import Foundation

/// What ⌥⇧C should do this time.
///
/// Every case copies the shelf to the pasteboard first — that never depends on
/// a permission, an app being installed, or anything else that can fail — so
/// the plan only decides what, if anything, happens *after* the copy. That is
/// why every failure below is still a working copy plus a toast, and never a
/// shortcut that did nothing.
enum AgentSendPlan: Equatable {
    /// The default, and what the shortcut has always done: copy, toast, done.
    case copyOnly
    case paste(InstalledHarness)
    /// Auto-paste is on, but the chosen harness is not on this Mac.
    case targetMissing(AgentHarness)
    /// Auto-paste is on, but Accessibility was never granted — or was granted
    /// once and revoked in System Settings since.
    case permissionMissing
}

/// Whether a paste is permitted, decided without touching AppKit so the whole
/// permission question is testable without granting anything.
enum AgentSendPolicy {
    /// The order of the guards is the order of the answers the user gets, and
    /// it is deliberate: the toggle first, because off means today's behaviour
    /// and nothing else is even asked; then the app, because "Codex isn't on
    /// this Mac" is more actionable than a permission dialog that would not
    /// help; then trust.
    static func plan(
        autoPasteEnabled: Bool,
        target: AgentHarness,
        installed: InstalledHarness?,
        accessibilityTrusted: Bool
    ) -> AgentSendPlan {
        guard autoPasteEnabled else { return .copyOnly }
        guard let installed else { return .targetMissing(target) }
        guard accessibilityTrusted else { return .permissionMissing }
        return .paste(installed)
    }

    /// Polls `condition` until it holds or `attempts` is exhausted, awaiting
    /// `wait` between tries — `attempts` evaluations, `attempts - 1` waits.
    ///
    /// Awaiting rather than blocking is load-bearing, not a style choice:
    /// `NSWorkspace.frontmostApplication` is updated from a notification
    /// delivered on the main run loop, so a blocking spin on the main actor
    /// would poll a value that can never change and would time out every time.
    /// Awaiting inside a `@MainActor` function releases the actor for the
    /// duration of the wait, which is exactly what lets that notification land.
    @MainActor
    static func poll(
        attempts: Int,
        condition: () -> Bool,
        wait: () async -> Void
    ) async -> Bool {
        let total = max(attempts, 1)
        for attempt in 0..<total {
            if condition() { return true }
            if attempt < total - 1 { await wait() }
        }
        return false
    }
}

/// The one predicate standing between a synthesised ⌘V and the wrong window.
///
/// It compares **process ids**, not bundle identifiers: two copies of an app
/// share a bundle id, and the pid is what the keystroke will actually reach.
/// `nil` — no frontmost app at all, which happens mid-switch — is a refusal,
/// never a pass.
enum FrontmostGate {
    static func allows(expected: pid_t, frontmost: pid_t?) -> Bool {
        guard let frontmost else { return false }
        return frontmost == expected
    }

    /// Modifiers that change what ⌘V means. The shortcut that gets here is
    /// ⌥⇧C, so at the moment of the send the user is very likely still holding
    /// ⌥⇧: posting ⌘V under them delivers ⌥⇧⌘V, which is a different command
    /// in every one of these apps. ⌘ itself is not disqualifying — it is the
    /// modifier we are about to send anyway.
    static let disqualifyingModifiers: CGEventFlags = [
        .maskAlternate, .maskShift, .maskControl,
    ]

    static func isClearOfModifiers(_ flags: CGEventFlags) -> Bool {
        flags.intersection(disqualifyingModifiers).isEmpty
    }
}
