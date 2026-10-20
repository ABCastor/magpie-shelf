import Foundation
import XCTest
@testable import Magpie

/// Ten Settings descriptions were translated into all nine tables and rendered
/// nowhere: the copy a stranger needs to learn the product was paid for and
/// then never shown. These tests hold both halves of the repair. The tables
/// keep carrying every key with a real value, with the same shift-bug guards
/// `DiagnosticsLocalizationTests` uses; and `SettingsView` keeps referencing
/// every key, so none of this copy can quietly go dead again.
final class SettingsCopyLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    /// Dotted keys, where a value equal to its own key is an untranslated leak.
    private static let describedKeys = [
        "settings.trigger.shake.description",
        "settings.trigger.hotkey.description",
        "settings.trigger.edge.description",
        "settings.trigger.menubar.description",
        "settings.park.description",
        "settings.collapse.description",
        "settings.clear-after-drag.description",
        "settings.launch.description",
        "settings.appearance.description",
        "settings.updates.description",
        "settings.language.description",
        "settings.cache.title",
        "settings.cache.clear",
        "settings.cache.description",
    ]

    /// English sentences used as their own keys, so `value == key` is
    /// legitimate in Base and en and the own-key check cannot apply.
    private static let sentenceKeys = [
        "Takes effect on next launch.",
        "Quit & Reopen",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = resources
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language).lproj/Localizable.strings did not parse"
        )
    }

    private var settingsViewSource: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Sources/Magpie/SettingsView.swift"),
                encoding: .utf8
            )
        }
    }

    /// The defect itself: a key can be perfect in nine tables and still be
    /// dead. Every one of these must be referenced by the Settings screen.
    func test_settings_view_renders_every_settings_description() throws {
        let source = try settingsViewSource
        for key in Self.describedKeys + Self.sentenceKeys {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "\(key) is localized in nine languages and rendered nowhere — SettingsView must reference it"
            )
        }
    }

    func test_every_language_defines_a_real_value_for_every_settings_key() throws {
        for language in Self.languages {
            let table = try table(language)
            for key in (Self.describedKeys + Self.sentenceKeys) {
                let value = table[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
            for key in Self.describedKeys {
                XCTAssertNotEqual(table[key], key, "\(language) left \(key) untranslated")
            }
        }
    }

    /// The shift bug, caught directly: each of these is a distinct sentence,
    /// so two keys sharing a value means a line landed one slot away from
    /// where it belongs.
    func test_no_two_settings_keys_share_a_value_in_any_language() throws {
        for language in Self.languages {
            let table = try table(language)
            var seen: [String: String] = [:]
            for key in Self.describedKeys {
                let value = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                if let owner = seen[value] {
                    XCTFail("\(language): \(key) has the same text as \(owner)")
                }
                seen[value] = key
            }
        }
    }

    /// A value that is the literal name of some *other* key is the exact shape
    /// of the "Shelf Settings" bug.
    func test_no_settings_value_is_another_keys_name() throws {
        for language in Self.languages {
            let table = try table(language)
            let allKeys = Set(table.keys)
            for key in Self.describedKeys {
                let value = try XCTUnwrap(table[key])
                XCTAssertFalse(
                    allKeys.contains(value) && value != key,
                    "\(language): \(key) holds the name of another key (\(value))"
                )
            }
        }
    }
}
