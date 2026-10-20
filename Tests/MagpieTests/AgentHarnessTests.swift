import Foundation
import XCTest
@testable import Magpie

/// Resolution is pure so "which app would Magpie bring forward, given what is
/// installed" is a table rather than a machine — the one question that has to
/// be right before any keystroke is ever synthesised.
final class AgentHarnessTests: XCTestCase {
    private func fake(_ path: String) -> URL { URL(fileURLWithPath: path) }

    /// Answers for the ids in `present` and nothing else.
    private func locator(present: [String: String]) -> (String) -> URL? {
        { id in present[id].map { URL(fileURLWithPath: $0) } }
    }

    // MARK: - The model

    func test_every_harness_names_itself_and_at_least_one_bundle() {
        for harness in AgentHarness.allCases {
            XCTAssertFalse(harness.displayName.isEmpty, "\(harness) has no display name")
            XCTAssertFalse(
                harness.bundleIdentifiers.isEmpty,
                "\(harness) names no bundle identifier, so it can never resolve"
            )
        }
    }

    /// Two harnesses sharing a bundle id would make the picker ambiguous and
    /// the "did the right app come forward" check meaningless.
    func test_no_two_harnesses_claim_the_same_bundle_identifier() {
        let all = AgentHarness.allCases.flatMap(\.bundleIdentifiers)
        XCTAssertEqual(all.count, Set(all).count, "two harnesses claim the same app")
    }

    /// The `claude://` scheme is emitted from `ClaudeLink` and recorded here.
    /// Pinning them together is what stops the model quietly describing a
    /// scheme the app no longer uses.
    func test_the_recorded_claude_scheme_matches_the_link_the_app_emits() throws {
        let emitted = try XCTUnwrap(
            ClaudeLink.url(prompt: "hello", folder: fake("/Users/someone"))
        )
        XCTAssertEqual(AgentHarness.claudeCode.urlScheme, emitted.scheme)
    }

    func test_a_terminal_has_no_scheme_to_record() {
        XCTAssertNil(AgentHarness.terminal.urlScheme)
    }

    // MARK: - Resolution

    func test_a_harness_that_is_not_installed_resolves_to_nothing() {
        XCTAssertNil(HarnessResolver.resolve(.claudeCode, locate: locator(present: [:])))
    }

    func test_resolution_carries_the_identifier_it_actually_matched() throws {
        let resolved = try XCTUnwrap(HarnessResolver.resolve(
            .openCode,
            locate: locator(present: ["ai.opencode.desktop": "/Applications/OpenCode.app"])
        ))
        XCTAssertEqual(resolved.harness, .openCode)
        XCTAssertEqual(resolved.bundleIdentifier, "ai.opencode.desktop")
        XCTAssertEqual(resolved.applicationURL, fake("/Applications/OpenCode.app"))
    }

    /// The whole of "iTerm if it is there, else Terminal.app": an ordered
    /// candidate list, first match wins.
    func test_the_terminal_option_prefers_iterm_when_it_is_installed() throws {
        let resolved = try XCTUnwrap(HarnessResolver.resolve(
            .terminal,
            locate: locator(present: [
                "com.googlecode.iterm2": "/Applications/iTerm.app",
                "com.apple.Terminal": "/System/Applications/Utilities/Terminal.app",
            ])
        ))
        XCTAssertEqual(resolved.bundleIdentifier, "com.googlecode.iterm2")
    }

    func test_the_terminal_option_falls_back_to_the_system_terminal() throws {
        let resolved = try XCTUnwrap(HarnessResolver.resolve(
            .terminal,
            locate: locator(present: [
                "com.apple.Terminal": "/System/Applications/Utilities/Terminal.app",
            ])
        ))
        XCTAssertEqual(resolved.bundleIdentifier, "com.apple.Terminal")
    }

    func test_only_installed_harnesses_are_offered_and_the_order_is_kept() {
        let installed = HarnessResolver.installed(locate: locator(present: [
            "com.google.antigravity": "/Applications/Antigravity.app",
            "com.anthropic.claudefordesktop": "/Applications/Claude.app",
        ]))
        XCTAssertEqual(installed.map(\.harness), [.claudeCode, .antigravity])
    }

    func test_nothing_installed_offers_nothing() {
        XCTAssertTrue(HarnessResolver.installed(locate: locator(present: [:])).isEmpty)
    }

    // MARK: - What it is called out loud

    func test_a_named_product_keeps_its_own_name() throws {
        let resolved = try XCTUnwrap(HarnessResolver.resolve(
            .claudeCode,
            locate: locator(present: ["com.anthropic.claudefordesktop": "/Applications/Claude.app"])
        ))
        XCTAssertEqual(resolved.displayName, "Claude Code")
    }

    /// "Pasted into Terminal" is a small lie on a Mac where iTerm came
    /// forward, so the terminal option says whichever one resolved.
    func test_the_terminal_option_says_which_terminal_resolved() throws {
        let resolved = try XCTUnwrap(HarnessResolver.resolve(
            .terminal,
            locate: locator(present: ["com.googlecode.iterm2": "/nowhere/iTerm.app"])
        ))
        XCTAssertEqual(resolved.displayName, "iTerm")
    }
}
