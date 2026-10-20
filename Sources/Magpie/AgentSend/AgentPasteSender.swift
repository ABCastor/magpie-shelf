import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Whether macOS has granted this process the Accessibility right.
///
/// Confined to this file so `AXIsProcessTrusted` has exactly one reader — the
/// same shape as the single Keychain reader in `RouteService`, and for the same
/// reason: a second caller is a second place the answer could be assumed
/// instead of asked. A test pins the confinement.
@MainActor
enum AgentAccessibility {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Asks, and lets macOS put up its own dialog. The return value is the
    /// state *now*, not the user's answer: the dialog is asynchronous and the
    /// grant lands minutes later in System Settings, so `false` here means
    /// "not yet", never "denied". Settings watches for the grant; the send
    /// path re-reads `isGranted` and refuses without it.
    @discardableResult
    static func requestShowingSystemPrompt() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }
}

/// THE ONLY PLACE MAGPIE SYNTHESISES A KEYSTROKE.
///
/// One door, in the shape of `RouteLauncher.run` (ADR 0004) and for a sharper
/// reason: a route that starts by accident runs the owner's own command over
/// the owner's own files, while a keystroke that lands in the wrong window
/// types a file manifest into whatever happened to be in front — a chat with
/// someone else, a terminal, a form. `AgentSendInvariantTests` reads the
/// sources and fails the moment a second caller appears.
///
/// The rule this whole file exists to keep: **the frontmost process is re-read
/// and compared in the statement immediately before the post.** Not before the
/// activation, not before the waits — immediately before, with nothing in
/// between, because everything above takes time the user can Cmd-Tab through.
@MainActor
enum AgentPasteSender {
    enum Outcome: Equatable {
        case pasted
        /// Accessibility is not granted right now, whatever the toggle says.
        case notTrusted
        /// The target never came forward, or it left again before the post,
        /// or the event could not be built. All three mean the same thing to
        /// the user: nothing was typed, and the shelf is still on the
        /// clipboard. The log line carries which.
        case couldNotPaste
        /// The user is still holding the modifiers from the shortcut, which
        /// would turn ⌘V into something else.
        case modifiersHeld
    }

    /// 40 × 50ms = 2 seconds for the target to come forward. An app that has
    /// to launch cold takes most of that; one already running takes one poll.
    static let activationAttempts = 40
    /// 20 × 50ms = 1 second for the user to let go of ⌥⇧.
    static let modifierAttempts = 20
    static let pollInterval: TimeInterval = 0.05

    static func send(to target: InstalledHarness) async -> Outcome {
        // Re-read rather than trusted from the toggle: the right can be
        // revoked in System Settings while Magpie is running, and the toggle
        // would still be on.
        guard AgentAccessibility.isGranted else { return .notTrusted }

        guard let app = await activate(target) else { return .couldNotPaste }
        let expected = app.processIdentifier

        let cameForward = await AgentSendPolicy.poll(
            attempts: activationAttempts,
            condition: { FrontmostGate.allows(expected: expected, frontmost: frontmostPID()) },
            wait: { await sleepOnePoll() }
        )
        guard cameForward else {
            NSLog("Magpie: \(target.bundleIdentifier) did not come forward — nothing was typed")
            return .couldNotPaste
        }

        let modifiersClear = await AgentSendPolicy.poll(
            attempts: modifierAttempts,
            condition: {
                FrontmostGate.isClearOfModifiers(
                    CGEventSource.flagsState(.combinedSessionState)
                )
            },
            wait: { await sleepOnePoll() }
        )
        guard modifiersClear else { return .modifiersHeld }

        // The check that matters. Nothing may be inserted between it and the
        // post — not a log line, not an await, not a toast.
        guard FrontmostGate.allows(expected: expected, frontmost: frontmostPID()),
              postCommandV()
        else {
            NSLog("Magpie: gave up the paste to \(target.bundleIdentifier) at the last check")
            return .couldNotPaste
        }
        return .pasted
    }

    // MARK: - AppKit

    /// `openApplication` rather than `NSRunningApplication.activate()`: it
    /// launches the harness if it is not running, and it hands back the exact
    /// process — which is what the gate compares against, so a second copy of
    /// the same app under the same bundle id cannot be mistaken for the one
    /// this call opened.
    private static func activate(_ target: InstalledHarness) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            return try await NSWorkspace.shared.openApplication(
                at: target.applicationURL, configuration: configuration
            )
        } catch {
            NSLog("Magpie: could not activate \(target.bundleIdentifier) — \(error)")
            return nil
        }
    }

    private static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func sleepOnePoll() async {
        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }

    /// ⌘V, and nothing else: never Return, because the user reads the payload
    /// before sending it.
    ///
    /// `.cghidEventTap` rather than `CGEvent.postToPid`: three of these five
    /// harnesses are Electron apps, and a process-targeted post delivers the
    /// key without the session modifier state those apps read, so ⌘V arrives
    /// as a bare "v" and types a letter into the composer. The HID tap is the
    /// only delivery that works everywhere, and the gate above is what makes
    /// it safe. The two events are posted back to back with nothing between
    /// them, so focus cannot move between the press and the release.
    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
