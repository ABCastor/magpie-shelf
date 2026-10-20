import Foundation
import XCTest
@testable import Magpie

/// Magpie can now type into another app. That is acceptable only because the user
/// starts it, from a shortcut they pressed, into an app they chose, after the app
/// has been seen to be in front. None of those three is something a runtime
/// assertion can reach, so these tests read the sources — the same technique
/// and the same reasoning as `RouteTriggerInvariantTests`, one step sharper: a
/// route that fires by accident runs the user's own command over their own
/// files, while a keystroke that lands in the wrong window types a file manifest into
/// whatever happened to be in front of it.
final class AgentSendInvariantTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie")
    }

    private func swiftFiles() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(atPath: sources.path)
        )
        var files: [(String, String)] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let url = sources.appendingPathComponent(relative)
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    private func files(containing needle: String) throws -> Set<String> {
        Set(try swiftFiles().filter { $0.text.contains(needle) }.map(\.name))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sources.appendingPathComponent(relativePath), encoding: .utf8
        )
    }

    // MARK: - One place types, one place calls it

    func test_only_one_file_can_synthesise_a_keystroke() throws {
        XCTAssertEqual(
            try files(containing: "CGEvent("),
            ["AgentPasteSender.swift"],
            "a second place building keyboard events appeared — is it gated on the frontmost app?"
        )
        XCTAssertEqual(
            try files(containing: "post(tap:"),
            ["AgentPasteSender.swift"],
            "a second place posting events appeared"
        )
        XCTAssertEqual(
            try files(containing: ".cghidEventTap"),
            ["AgentPasteSender.swift"]
        )
    }

    /// One reader of the Accessibility right, so nowhere else can assume the
    /// answer instead of asking for it. Same shape as `SecretStore.value(`.
    func test_accessibility_trust_is_read_from_one_place_only() throws {
        XCTAssertEqual(
            try files(containing: "AXIsProcessTrusted"),
            ["AgentPasteSender.swift"]
        )
    }

    func test_only_the_app_delegate_can_ask_for_a_paste() throws {
        XCTAssertEqual(
            try files(containing: "AgentPasteSender.send("),
            ["App.swift"],
            "a new caller of the paste sender appeared — is it a key the user pressed?"
        )
    }

    /// The shortcut handler is the only door, and the call site inside
    /// `App.swift` has to stay singular too: two mentions is the declaration
    /// plus the one hotkey case.
    func test_the_shortcut_is_the_only_thing_that_reaches_the_send() throws {
        let app = try source("App.swift")
        XCTAssertEqual(
            app.components(separatedBy: "copyShelfForChat").count - 1, 2,
            "copyShelfForChat gained a caller — only the hotkey may reach it"
        )
        XCTAssertTrue(
            app.contains("case .copyForChat: self?.copyShelfForChat()"),
            "the copy-for-chat hotkey case moved; this test needs to follow it"
        )
        XCTAssertEqual(
            app.components(separatedBy: "pasteShelfIntoAgent").count - 1, 2,
            "pasteShelfIntoAgent gained a caller outside copyShelfForChat"
        )
    }

    /// Nothing inside the subsystem may wire itself to a clock, a
    /// notification or a publisher — the three shapes an automated trigger
    /// takes everywhere else in this app.
    func test_nothing_in_the_subsystem_can_fire_itself() throws {
        let forbidden = ["Timer", "NotificationCenter", "addObserver", ".sink", "Combine"]
        for file in try swiftFiles() where file.name.hasPrefix("Agent") {
            for marker in forbidden {
                XCTAssertFalse(
                    file.text.contains(marker),
                    "\(file.name) mentions \(marker) — a send may only follow a key the user pressed"
                )
            }
        }
    }

    /// ADR 0003's invariant, extended: a web page can fire `magpie://`, so the
    /// inbound handler must not be able to reach anything that types.
    func test_the_inbound_url_layer_cannot_reach_the_keyboard() throws {
        let magpieURL = try source("MagpieURL.swift")
        for marker in ["Harness", "Paste", "CGEvent"] {
            XCTAssertFalse(
                magpieURL.contains(marker),
                "MagpieURL must not reference \(marker) — ADR 0003 decision 2"
            )
        }

        let app = try source("App.swift")
        for marker in [
            "func application(_ application: NSApplication, open urls: [URL]) {",
            "private func addFiles(from url: URL) {",
        ] {
            let body = try XCTUnwrap(
                Self.body(after: marker, in: app),
                "could not find \(marker) — the invariant test needs updating"
            )
            for forbidden in ["paste", "harness", "cgevent"] {
                XCTAssertFalse(
                    body.lowercased().contains(forbidden),
                    "the inbound URL handler must only add files and show the panel"
                )
            }
        }
    }

    // MARK: - The gate itself

    /// The frontmost re-read and the post are one statement, so nothing can be
    /// inserted between them by a later edit that looks harmless. If you are
    /// reading this because you reformatted that guard: put the check and the
    /// post back in the same statement, then update the literal below.
    func test_the_post_is_guarded_by_a_fresh_frontmost_check_in_the_same_statement() throws {
        let sender = try source("AgentSend/AgentPasteSender.swift")
        XCTAssertTrue(
            sender.contains(
                """
                        guard FrontmostGate.allows(expected: expected, frontmost: frontmostPID()),
                              postCommandV()
                """
            ),
            "the last frontmost check must be the statement that posts the keystroke"
        )
        XCTAssertTrue(sender.contains("private static func postCommandV()"))
    }

    /// Return is never synthesised: the user reads what landed before sending it.
    func test_nothing_ever_presses_return() throws {
        let sender = try source("AgentSend/AgentPasteSender.swift")
        for marker in ["kVK_Return", "kVK_ANSI_KeypadEnter", "kVK_ANSI_Return"] {
            XCTAssertFalse(
                sender.contains(marker),
                "\(marker) appeared — the paste must never submit the message"
            )
        }
    }

    // MARK: - The preference

    /// The toggle defaults to off, and the two sides of it agree on the key.
    /// A third reader, or a `register(defaults:)` line, would each quietly
    /// turn the permission story on for someone who never asked.
    func test_the_auto_paste_preference_is_off_by_default_and_has_two_readers() throws {
        XCTAssertEqual(
            try files(containing: "\"shelf.agentSend.autoPaste\""),
            ["App.swift", "SettingsView.swift"]
        )
        let app = try source("App.swift")
        XCTAssertFalse(
            app.contains("\"shelf.agentSend.autoPaste\": true"),
            "registering the auto-paste key as true would switch it on for everyone"
        )
        XCTAssertTrue(
            try source("SettingsView.swift").contains(
                "@AppStorage(\"shelf.agentSend.autoPaste\") private var agentAutoPaste: Bool = false"
            ),
            "the toggle must declare itself off"
        )
    }

    /// The body of the first function whose signature matches `marker`,
    /// by brace balance.
    private static func body(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        var depth = 1
        var body = ""
        for character in text[range.upperBound...] {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(character)
        }
        return nil
    }
}
