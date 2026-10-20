import Foundation
import XCTest
@testable import Magpie

/// The "Clear Recent Shelves" confirmation is only worth having if it names
/// what is about to go. These tests hold the composed copy and its nine
/// tables to that: real counts substituted, singular/plural chosen, no raw
/// placeholder ever reaching the user.
final class ClearAllShelvesLocalizationTests: XCTestCase {

    func test_summary_substitutes_both_counts() {
        let summary = ClearAllShelvesConfirmation.summary(shelfCount: 3, itemCount: 12)
        XCTAssertTrue(summary.contains("3"), "the dialog must name how many shelves go: \(summary)")
        XCTAssertTrue(summary.contains("12"), "the dialog must name how many files go: \(summary)")
        XCTAssertFalse(summary.contains("%"), "a raw placeholder leaked into the dialog: \(summary)")
    }

    func test_summary_uses_the_singular_forms_for_one() {
        let summary = ClearAllShelvesConfirmation.summary(shelfCount: 1, itemCount: 1)
        XCTAssertTrue(
            summary.contains(L("shelf-count.one")),
            "one shelf must read as the singular phrase, got: \(summary)"
        )
        XCTAssertTrue(
            summary.contains(L("1 file")),
            "one file must read as the singular phrase, got: \(summary)"
        )
        XCTAssertFalse(summary.contains("%"), "a raw placeholder leaked into the dialog: \(summary)")
    }

    // MARK: - The nine tables

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "alert.clear-all.title",
        "alert.clear-all.body",
        "shelf-count.one",
        "shelf-count.many",
        "undo.clear-all-shelves",
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

    func test_every_language_defines_the_clear_all_strings() throws {
        for language in Self.languages {
            let strings = try table(language)
            for key in Self.keys {
                let value = strings[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
        }
    }

    /// The body must keep both injection points and the shelf-count plural
    /// its `%lld`; losing either turns the named confirmation back into a
    /// vague yes/no.
    func test_every_language_keeps_the_placeholders() throws {
        for language in Self.languages {
            let strings = try table(language)
            let body = try XCTUnwrap(strings["alert.clear-all.body"])
            XCTAssertTrue(body.contains("%1$@"), "\(language) lost the shelf count in alert.clear-all.body")
            XCTAssertTrue(body.contains("%2$@"), "\(language) lost the file count in alert.clear-all.body")
            let many = try XCTUnwrap(strings["shelf-count.many"])
            XCTAssertTrue(many.contains("%lld"), "\(language) lost the count in shelf-count.many")
        }
    }
}
