import Foundation
import XCTest
@testable import Magpie

/// Nine tables, and a missing key does not fail — it renders the raw key on
/// screen. This project has been bitten twice: the menu-bar strings shifted one
/// slot in all nine, and "Shelf Settings" survived in en and Base because they
/// held the old name as both key and value.
///
/// So key presence is the weakest of the three checks here. The other two are
/// the ones that catch a shift: a value must never be its own key, and no two
/// of these keys may share a value — every one of them is a different sentence,
/// so a duplicate means a line landed in the wrong slot.
final class DiagnosticsLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "store.alert.quarantined.title",
        "store.alert.quarantined.body",
        "store.alert.read-only.title",
        "store.alert.read-only.body",
        "store.alert.unreadable.title",
        "store.alert.unreadable.body",
        "settings.diagnostics",
        "settings.diagnostics.version",
        "settings.diagnostics.title",
        "settings.diagnostics.reveal",
        "settings.diagnostics.copy",
        "settings.diagnostics.copied",
        "settings.diagnostics.description",
        "diagnostics.logs-hint",
        "diagnostics.review-warning",
    ]
    /// The launch alert reuses these rather than minting near-duplicates, so
    /// they have to still be there.
    private static let reusedKeys = ["OK", "Show in Finder"]

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

    func test_every_language_defines_a_real_value_for_every_diagnostics_key() throws {
        for language in Self.languages {
            let table = try table(language)
            for key in (Self.keys + Self.reusedKeys) {
                let value = table[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
            // "OK" is legitimately its own value everywhere; a sentence is not.
            for key in Self.keys {
                XCTAssertNotEqual(table[key], key, "\(language) left \(key) untranslated")
            }
        }
    }

    /// The shift bug, caught directly: every one of these is a distinct
    /// sentence, so two keys holding the same text means a value landed a slot
    /// away from where it belongs.
    func test_no_two_diagnostics_keys_share_a_value_in_any_language() throws {
        for language in Self.languages {
            let table = try table(language)
            var seen: [String: String] = [:]
            for key in Self.keys {
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
    func test_no_diagnostics_value_is_another_keys_name() throws {
        for language in Self.languages {
            let table = try table(language)
            let allKeys = Set(table.keys)
            for key in Self.keys {
                let value = try XCTUnwrap(table[key])
                XCTAssertFalse(
                    allKeys.contains(value) && value != key,
                    "\(language): \(key) holds the name of another key (\(value))"
                )
            }
        }
    }

    /// The report's trailing lines are the only part of the blob a user is
    /// asked to act on, so they have to arrive in that user's language.
    func test_the_report_footer_is_localized_and_carries_the_log_command() {
        let report = Diagnostics.text([("app", "1.0")])

        XCTAssertTrue(report.contains(L("diagnostics.logs-hint")))
        XCTAssertTrue(report.contains(L("diagnostics.review-warning")))
        XCTAssertNotEqual(L("diagnostics.review-warning"), "diagnostics.review-warning")
        XCTAssertTrue(report.contains(#"process == "Magpie""#))
    }
}
