import Foundation
import XCTest
@testable import Magpie

/// One missing semicolon makes a whole `.strings` file fail to parse and every
/// string in that language silently falls back to its raw key. Same guard as
/// `HandoffLocalizationTests`, for the routes strings.
final class RouteLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "routes.menu",
        "routes.finished",
        "routes.failed.title",
        "routes.failed.exit",
        "routes.failed.timeout",
        "routes.failed.launch",
        "routes.failed.secret",
        "routes.failed.no-detail",
        "routes.error.unreadable",
        "routes.error.invalid-json",
        "routes.error.shape",
        "routes.error.version",
        "routes.error.bad-field",
        "routes.error.relative-command",
        "routes.error.duplicate-id",
        "routes.error.files-token",
        "settings.routes.empty",
        "settings.routes.reveal",
        "settings.routes.reload",
        "settings.routes.description",
        "settings.secrets.title",
        "settings.secrets.empty",
        "settings.secrets.add",
        "settings.secrets.delete",
        "settings.secrets.failed",
        "settings.secrets.description",
        "alert.secret.body",
    ]
    /// Keys whose text is filled in with `String(format:)`, and how many
    /// arguments the call site passes.
    private static let formats: [String: Int] = [
        "routes.finished": 1,
        "routes.failed.exit": 2,
        "routes.failed.timeout": 2,
        "routes.failed.launch": 2,
        "routes.failed.secret": 2,
        "routes.error.version": 2,
        "routes.error.bad-field": 2,
        "routes.error.relative-command": 2,
        "routes.error.duplicate-id": 1,
        "routes.error.files-token": 1,
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    func test_every_language_parses_and_defines_the_routes_strings() throws {
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

    /// A translation that drops a placeholder prints a half-empty sentence; one
    /// that mixes positional and bare specifiers crashes `String(format:)`.
    func test_format_strings_keep_every_placeholder_in_every_language() throws {
        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for (key, expected) in Self.formats {
                let value = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                let placeholders = value.components(separatedBy: "%").count - 1
                XCTAssertEqual(
                    placeholders, expected,
                    "\(language)/\(key) has \(placeholders) placeholders, expected \(expected)"
                )
                if expected > 1 {
                    XCTAssertTrue(
                        value.contains("%1$") && value.contains("%2$"),
                        "\(language)/\(key) must use positional placeholders"
                    )
                }
            }
        }
    }
}
