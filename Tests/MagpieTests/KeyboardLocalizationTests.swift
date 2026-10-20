import Foundation
import XCTest
@testable import Magpie

/// One missing semicolon makes a whole `.strings` file fail to parse and every
/// string in that language silently falls back to its raw key. Same guard as
/// `AgentSendLocalizationTests`, for the strings the keyboard model added —
/// where a fallback would leave the ⌘K palette prompting with "palette.placeholder"
/// and ⌘Z offering to undo "undo.remove-from-shelf".
final class KeyboardLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "palette.title",
        "palette.placeholder",
        "palette.no-matches",
        "undo.remove-from-shelf",
        "undo.remove-from-shelf-count",
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

    func test_every_language_parses_and_defines_the_keyboard_strings() throws {
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

    /// A translation that drops the count leaves ⌘Z saying "Undo Remove from
    /// Shelf" over four cards it is about to bring back.
    func test_every_language_keeps_the_count_placeholder() throws {
        for language in Self.languages {
            let value = try XCTUnwrap(table(language)["undo.remove-from-shelf-count"])
            XCTAssertTrue(
                value.contains("%lld"),
                "\(language) lost the count placeholder in undo.remove-from-shelf-count"
            )
        }
    }
}
