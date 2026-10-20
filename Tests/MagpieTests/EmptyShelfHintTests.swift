import Foundation
import XCTest
@testable import Magpie

/// The empty collapsed shelf is the one surface a stranger is guaranteed to
/// look at, and what it says has to be honest: name the summon triggers that
/// are switched on, with the shortcut the user actually configured, and never
/// a gesture that has been turned off.
///
/// "Drop or shake here" sat translated in nine tables while no view showed it
/// — the string existed, the teaching did not. The wiring test at the bottom
/// exists so that cannot happen again.
final class EmptyShelfHintTests: XCTestCase {

    // MARK: - What the hint says, as a pure function of the preferences

    func test_shake_on_titles_the_prompt_that_names_shaking() {
        let hint = EmptyShelfHint.from(
            shakeEnabled: true, hotkeyEnabled: true, hotkeyPreset: .optionShiftS
        )
        XCTAssertEqual(hint.title, L("Drop or shake here"))
    }

    func test_shake_off_never_mentions_shaking() {
        let hint = EmptyShelfHint.from(
            shakeEnabled: false, hotkeyEnabled: true, hotkeyPreset: .optionShiftS
        )
        XCTAssertEqual(hint.title, L("Drop files here"))
        XCTAssertNotEqual(
            hint.title, L("Drop or shake here"),
            "the empty state teaches a gesture the user switched off"
        )
    }

    func test_the_hint_names_the_configured_shortcut_not_the_default() throws {
        let hint = EmptyShelfHint.from(
            shakeEnabled: true, hotkeyEnabled: true, hotkeyPreset: .f13
        )
        let subtitle = try XCTUnwrap(hint.subtitle)
        XCTAssertTrue(
            subtitle.contains(HotkeyPreset.f13.displayName),
            "the hint does not carry the shortcut the user chose"
        )
        XCTAssertFalse(
            subtitle.contains(HotkeyPreset.optionShiftS.displayName),
            "the hint hardcodes the default shortcut instead of the configured one"
        )
    }

    func test_hotkey_off_shows_no_shortcut_line() {
        let hint = EmptyShelfHint.from(
            shakeEnabled: true, hotkeyEnabled: false, hotkeyPreset: .optionShiftS
        )
        XCTAssertNil(
            hint.subtitle,
            "the empty state advertises a shortcut that is not registered"
        )
    }

    // MARK: - The nine tables

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    /// The subtitle is a format string: a translation that loses the `%@`
    /// swallows the shortcut and the line becomes a sentence about nothing.
    func test_every_language_defines_the_hint_and_keeps_its_placeholder() throws {
        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            let value = try XCTUnwrap(
                table["empty.summon-hint"], "\(language) is missing empty.summon-hint"
            )
            XCTAssertFalse(value.isEmpty, "\(language) has an empty empty.summon-hint")
            XCTAssertNotEqual(value, "empty.summon-hint", "\(language) left the key untranslated")
            XCTAssertTrue(
                value.contains("%@"),
                "\(language) lost the %@ placeholder — the shortcut cannot be inserted"
            )
            XCTAssertFalse(
                Set(table.keys).contains(value),
                "\(language): empty.summon-hint holds the name of another key (\(value)) — the table may be shifted"
            )
        }
    }

    // MARK: - The wiring

    /// The failure this whole file guards against, caught at its source: the
    /// view must derive its empty state from `EmptyShelfHint`, not from a
    /// hardcoded string beside a richer one nobody renders.
    func test_the_collapsed_view_actually_renders_the_hint() throws {
        let view = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/CollapsedShelfView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            view.contains("EmptyShelfHint.from("),
            "CollapsedShelfView no longer derives its empty state from EmptyShelfHint — the tested function and the rendered text have come apart"
        )
        XCTAssertFalse(
            view.contains("Text(L(\"Drop files here\"))"),
            "CollapsedShelfView hardcodes the empty-state string again, bypassing the trigger-aware hint"
        )
    }
}
