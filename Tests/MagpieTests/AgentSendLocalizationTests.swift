import Foundation
import XCTest
@testable import Magpie

/// One missing semicolon makes a whole `.strings` file fail to parse and every
/// string in that language silently falls back to its raw key. Same guard as
/// `HandoffLocalizationTests` and `RouteLocalizationTests`, for the send-to-agent
/// strings — where a fallback would leave the permission trade unexplained in
/// the one place the user decides whether to make it.
final class AgentSendLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "agent.section",
        "agent.none-installed",
        "agent.auto-paste",
        "agent.auto-paste.description",
        "agent.toast.pasted",
        "agent.toast.not-installed",
        "agent.toast.no-accessibility",
        "agent.toast.could-not-paste",
        "agent.toast.modifiers-held",
    ]
    /// The strings a display name is substituted into.
    private static let formatted = [
        "agent.toast.pasted",
        "agent.toast.not-installed",
        "agent.toast.could-not-paste",
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

    func test_every_language_parses_and_defines_the_agent_strings() throws {
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

    /// A translation that drops the `%@` produces a toast that names no app,
    /// which is the one thing these messages exist to say.
    func test_every_language_keeps_the_placeholder_for_the_app_name() throws {
        for language in Self.languages {
            let strings = try table(language)
            for key in Self.formatted {
                XCTAssertTrue(
                    strings[key]?.contains("%@") ?? false,
                    "\(language) lost the app-name placeholder in \(key)"
                )
            }
        }
    }

    /// The permission trade belongs in one short line, not a paragraph — but it
    /// still has to say what the permission buys. This is the only string in the
    /// app that explains why Magpie would ever want Accessibility, so a stub
    /// here is worse than a long sentence.
    ///
    /// The floor is script-aware. A flat character count is wrong for CJK: the
    /// Japanese line carries the same meaning as the English one in half the
    /// characters, so a single floor either lets a Latin stub through or fails a
    /// perfectly good Japanese sentence.
    func test_the_permission_description_is_concise_everywhere() throws {
        let dense: Set<String> = ["ja", "zh-Hans"]
        for language in Self.languages {
            let value = try XCTUnwrap(table(language)["agent.auto-paste.description"])
            let floor = dense.contains(language) ? 15 : 45
            XCTAssertGreaterThan(
                value.count, floor,
                "\(language)'s auto-paste description (\(value.count)) is too short to have explained the permission"
            )
            XCTAssertLessThan(
                value.count, 140,
                "\(language)'s auto-paste description has grown back into a paragraph"
            )
            XCTAssertFalse(value.contains("\n"), "\(language)'s description must stay on one line")
            // A stub that clears the floor by padding still fails the point:
            // the line must name the permission it is asking for.
            let namesPermission = ["Accessibility", "Bedienungshilfen", "Accesibilidad",
                                   "Accessibilité", "Accessibilità", "アクセシビリティ",
                                   "Dostępności", "辅助功能"]
                .contains { value.localizedCaseInsensitiveContains($0) }
            XCTAssertTrue(
                namesPermission,
                "\(language)'s auto-paste description never names the permission being requested"
            )
        }
    }
}
