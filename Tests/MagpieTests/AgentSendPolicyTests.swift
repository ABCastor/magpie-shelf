import CoreGraphics
import Foundation
import XCTest
@testable import Magpie

/// The permission question, answered without granting anything. Every branch
/// that decides whether Magpie may type is here, in a pure function, precisely
/// because the AppKit half of it cannot be reached from a test.
final class AgentSendPolicyTests: XCTestCase {
    private let claude = InstalledHarness(
        harness: .claudeCode,
        bundleIdentifier: "com.anthropic.claudefordesktop",
        applicationURL: URL(fileURLWithPath: "/Applications/Claude.app")
    )

    // MARK: - The plan

    /// The toggle is the outermost guard: off means today's behaviour, and
    /// nothing about the app or the permission is even consulted.
    func test_the_toggle_off_always_means_copy_only() {
        for installed in [claude, nil] {
            for trusted in [true, false] {
                XCTAssertEqual(
                    AgentSendPolicy.plan(
                        autoPasteEnabled: false,
                        target: .claudeCode,
                        installed: installed,
                        accessibilityTrusted: trusted
                    ),
                    .copyOnly,
                    "auto-paste off must never reach the paste path"
                )
            }
        }
    }

    func test_an_uninstalled_target_is_named_rather_than_pasted_into() {
        XCTAssertEqual(
            AgentSendPolicy.plan(
                autoPasteEnabled: true,
                target: .codex,
                installed: nil,
                accessibilityTrusted: true
            ),
            .targetMissing(.codex)
        )
    }

    /// Reported before the permission, because "Codex isn't on this Mac" is
    /// actionable and a permission dialog would not have helped.
    func test_a_missing_app_is_reported_before_a_missing_permission() {
        XCTAssertEqual(
            AgentSendPolicy.plan(
                autoPasteEnabled: true,
                target: .codex,
                installed: nil,
                accessibilityTrusted: false
            ),
            .targetMissing(.codex)
        )
    }

    func test_no_accessibility_means_no_paste() {
        XCTAssertEqual(
            AgentSendPolicy.plan(
                autoPasteEnabled: true,
                target: .claudeCode,
                installed: claude,
                accessibilityTrusted: false
            ),
            .permissionMissing
        )
    }

    func test_the_only_way_to_a_paste_is_on_installed_and_trusted() {
        XCTAssertEqual(
            AgentSendPolicy.plan(
                autoPasteEnabled: true,
                target: .claudeCode,
                installed: claude,
                accessibilityTrusted: true
            ),
            .paste(claude)
        )
    }

    // MARK: - The frontmost gate

    func test_no_frontmost_app_at_all_is_a_refusal() {
        XCTAssertFalse(FrontmostGate.allows(expected: 501, frontmost: nil))
    }

    func test_a_different_process_is_a_refusal() {
        XCTAssertFalse(FrontmostGate.allows(expected: 501, frontmost: 502))
    }

    func test_the_gate_opens_only_for_the_exact_process() {
        XCTAssertTrue(FrontmostGate.allows(expected: 501, frontmost: 501))
    }

    // MARK: - Modifiers still held from the shortcut

    func test_nothing_held_is_clear() {
        XCTAssertTrue(FrontmostGate.isClearOfModifiers([]))
    }

    /// ⌥⇧ is half of the shortcut that got here, and ⌥⇧⌘V is a different
    /// command from ⌘V in every one of these apps.
    func test_each_disqualifying_modifier_blocks_on_its_own() {
        for flag in [CGEventFlags.maskAlternate, .maskShift, .maskControl] {
            XCTAssertFalse(
                FrontmostGate.isClearOfModifiers(flag),
                "\(flag) would change what the synthesised ⌘V means"
            )
        }
    }

    /// Command is the modifier being sent, and caps lock does not change what
    /// a paste is — neither should hold up a send forever.
    func test_command_and_caps_lock_do_not_block() {
        XCTAssertTrue(FrontmostGate.isClearOfModifiers(.maskCommand))
        XCTAssertTrue(FrontmostGate.isClearOfModifiers(.maskAlphaShift))
    }

    // MARK: - Polling

    @MainActor
    func test_a_condition_that_already_holds_costs_no_waiting() async {
        var waits = 0
        let held = await AgentSendPolicy.poll(
            attempts: 10, condition: { true }, wait: { waits += 1 }
        )
        XCTAssertTrue(held)
        XCTAssertEqual(waits, 0)
    }

    @MainActor
    func test_polling_stops_at_the_first_true() async {
        var checks = 0
        var waits = 0
        let held = await AgentSendPolicy.poll(
            attempts: 10,
            condition: {
                checks += 1
                return checks == 3
            },
            wait: { waits += 1 }
        )
        XCTAssertTrue(held)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(waits, 2, "one wait between each pair of checks, and no trailing one")
    }

    @MainActor
    func test_a_condition_that_never_holds_gives_up_and_says_so() async {
        var checks = 0
        var waits = 0
        let held = await AgentSendPolicy.poll(
            attempts: 4,
            condition: {
                checks += 1
                return false
            },
            wait: { waits += 1 }
        )
        XCTAssertFalse(held, "a timed-out wait must never read as success")
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(waits, 3)
    }

    @MainActor
    func test_a_nonsense_attempt_count_still_asks_once() async {
        var checks = 0
        _ = await AgentSendPolicy.poll(
            attempts: 0,
            condition: {
                checks += 1
                return false
            },
            wait: {}
        )
        XCTAssertEqual(checks, 1)
    }
}
