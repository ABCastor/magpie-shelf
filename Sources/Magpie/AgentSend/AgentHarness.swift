import AppKit

/// The agent front-ends a shelf can be sent to.
///
/// A flat enum, not a registry: these are five apps the owner actually runs,
/// each a fixed fact about this Mac. Adding a sixth is a case and a bundle id,
/// which is cheaper than any plugin point would be.
enum AgentHarness: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case openCode
    case antigravity
    case terminal

    var id: String { rawValue }

    /// Product names, so not localized — with the terminal as the exception,
    /// because it is two different apps. See `InstalledHarness.displayName`.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .antigravity: return "Antigravity"
        case .terminal: return "Terminal"
        }
    }

    /// Candidates in preference order; the first one installed wins. That is
    /// the whole of "iTerm if it is there, else Terminal.app" — no special
    /// case, just a two-element list.
    ///
    /// `com.openai.codex` resolves to `ChatGPT.app` on a Mac with the ChatGPT
    /// desktop app: OpenAI ships one bundle under that identifier, with
    /// `CFBundleAlternateNames = [Codex]`. That is the right app, under a
    /// name the owner may not expect to see come forward.
    var bundleIdentifiers: [String] {
        switch self {
        case .claudeCode: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex"]
        case .openCode: return ["ai.opencode.desktop"]
        case .antigravity: return ["com.google.antigravity"]
        case .terminal: return ["com.googlecode.iterm2", "com.apple.Terminal"]
        }
    }

    /// Recorded, and deliberately unused — see ADR 0005. Every scheme here
    /// opens a *new* conversation, which is the feature "Send to Claude for
    /// Filing" already is (ADR 0002); this one exists to reach the
    /// conversation the owner is already in, and no scheme can address that.
    /// It is here because it is the fact the ADR's reversal trigger keys on.
    var urlScheme: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .openCode: return "opencode"
        case .antigravity: return "antigravity"
        case .terminal: return nil
        }
    }
}

/// A harness that is actually on this Mac, with the copy of it LaunchServices
/// resolved. A harness only ever reaches the send path in this form, so
/// "is it installed?" is answered once, by construction, rather than re-asked
/// at each step.
struct InstalledHarness: Equatable {
    let harness: AgentHarness
    let bundleIdentifier: String
    let applicationURL: URL

    /// What to say out loud. A named product says its own name; the terminal
    /// option says whichever terminal actually resolved, because "pasted into
    /// Terminal" is a small lie on a Mac where iTerm came forward.
    var displayName: String {
        switch harness {
        case .terminal: return OpenWithApplicationPresentation.name(for: applicationURL)
        default: return harness.displayName
        }
    }
}

enum HarnessResolver {
    /// The first candidate `locate` answers for. Pure, so "which app would
    /// this pick, given what is installed" is a test rather than a machine.
    static func resolve(_ harness: AgentHarness, locate: (String) -> URL?) -> InstalledHarness? {
        for bundleIdentifier in harness.bundleIdentifiers {
            if let url = locate(bundleIdentifier) {
                return InstalledHarness(
                    harness: harness,
                    bundleIdentifier: bundleIdentifier,
                    applicationURL: url
                )
            }
        }
        return nil
    }

    /// Everything installed, in enum order. A harness that is not on this Mac
    /// is absent from the list and so is never offered in Settings.
    static func installed(
        _ harnesses: [AgentHarness] = AgentHarness.allCases,
        locate: (String) -> URL?
    ) -> [InstalledHarness] {
        harnesses.compactMap { resolve($0, locate: locate) }
    }

    /// The one AppKit line. Asked by bundle id and never by path, so a copy in
    /// `~/Applications`, or one an installer moves, still resolves.
    @MainActor
    static func locate(_ bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
