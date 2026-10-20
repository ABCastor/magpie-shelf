import Foundation
import XCTest
@testable import Magpie

/// A single missing semicolon makes an entire `.strings` file fail to parse,
/// and every string in that language silently falls back to its raw key. This
/// reads the source files themselves so the failure is caught here rather than
/// by a user running Magpie in German.
final class HandoffLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "handoff.ingest",
        "handoff.staging-failed",
        "handoff.nothing-to-send",
        "handoff.no-claude",
        "handoff.no-receipt",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/MagpieTests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    func test_every_language_parses_and_defines_the_handoff_strings() throws {
        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            for key in Self.keys {
                let value = table[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
        }
    }
}
