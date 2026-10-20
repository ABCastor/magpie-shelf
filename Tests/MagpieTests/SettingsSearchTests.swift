import XCTest
@testable import Magpie

/// Settings search. The matching is a value type precisely so this can be
/// asserted rather than clicked.
final class SettingsSearchTests: XCTestCase {

    private let row = ["Show Magpie in the menu bar", "menu bar", "menubar", "hide", "icon"]

    /// An empty query shows everything. A search that hides rows before you
    /// have typed is a broken settings pane.
    func testEmptyQueryShowsEverything() {
        var search = SettingsSearch()
        XCTAssertFalse(search.isActive)
        XCTAssertTrue(search.matches(row))
        XCTAssertTrue(search.matches([]))

        search.query = "   \n "
        XCTAssertFalse(search.isActive, "whitespace is not a search")
        XCTAssertTrue(search.matches(row))
    }

    func testMatchesTheVisibleLabelCaseInsensitively() {
        var search = SettingsSearch()
        for q in ["magpie", "MAGPIE", "Menu Bar", "bar"] {
            search.query = q
            XCTAssertTrue(search.matches(row), "\"\(q)\" should find the menu-bar row")
        }
    }

    /// The point of the keyword list: someone who cannot remember the label
    /// types what they want, not what it is called.
    func testMatchesKeywordsThatAreNotInTheLabel() {
        var search = SettingsSearch()
        for q in ["hide", "icon", "menubar"] {
            search.query = q
            XCTAssertTrue(search.matches(row), "\"\(q)\" is a keyword and must match")
        }
    }

    /// A French or Polish user on a US keyboard types without accents. If that
    /// returns nothing, the feature is broken for everyone but English.
    func testMatchingIgnoresDiacritics() {
        var search = SettingsSearch()
        search.query = "reglages"
        XCTAssertTrue(
            search.matches(["Réglages de Magpie", "settings"]),
            "an unaccented query must still find an accented label"
        )
        search.query = "wyszukiwanie"
        XCTAssertTrue(search.matches(["Wyszukiwanie", "search"]))
    }

    func testNonMatchingQueryHidesTheRow() {
        var search = SettingsSearch()
        search.query = "bluetooth"
        XCTAssertFalse(search.matches(row))
    }

    /// A section with no matching row must vanish. A header floating over
    /// nothing reads as a rendering bug, not as an empty result.
    func testSectionIsHiddenOnlyWhenEveryRowFails() {
        var search = SettingsSearch()
        let section = [row, ["Launch at login", "startup", "boot"]]

        search.query = "boot"
        XCTAssertTrue(search.sectionMatches(section), "one matching row keeps the section")

        search.query = "bluetooth"
        XCTAssertFalse(search.sectionMatches(section), "no matching row must hide the section")

        search.query = ""
        XCTAssertTrue(search.sectionMatches(section), "an empty query shows every section")
        XCTAssertTrue(search.sectionMatches([]), "an empty query shows a section with no rows declared")
    }

    /// Every locale must carry the search strings, or a non-English user gets
    /// a raw key in the field they are typing into.
    func testEveryLocaleHasTheSearchStrings() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        let locales = try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        XCTAssertGreaterThanOrEqual(locales.count, 9)

        for locale in locales {
            let table = try String(
                contentsOf: locale.appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            for key in ["settings.search.placeholder",
                        "settings.search.no-results",
                        "settings.search.clear"] {
                guard let line = table.components(separatedBy: .newlines)
                    .first(where: { $0.hasPrefix("\"\(key)\"") }) else {
                    XCTFail("\(locale.lastPathComponent) is missing \(key)")
                    continue
                }
                let value = line.components(separatedBy: "= ").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\";")) ?? ""
                XCTAssertFalse(
                    value.isEmpty,
                    "\(locale.lastPathComponent): \(key) is empty"
                )
            }
        }
    }

    /// The settings window must name the product. It said "Shelf Settings" in
    /// English and Base long after the rename, because the rename pass updated
    /// the seven tables that had a translation and skipped the two that carried
    /// the key verbatim.
    func testTheSettingsWindowNamesTheProduct() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        for locale in try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "lproj" }) {
            let table = try String(
                contentsOf: locale.appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            XCTAssertFalse(
                table.contains("\"Shelf Settings\""),
                "\(locale.lastPathComponent) still carries the pre-rename \"Shelf Settings\" key"
            )
            guard let line = table.components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("\"Magpie Settings\"") }) else {
                XCTFail("\(locale.lastPathComponent) has no window title")
                continue
            }
            XCTAssertTrue(
                line.localizedCaseInsensitiveContains("Magpie"),
                "\(locale.lastPathComponent)'s settings window title does not name the app"
            )
        }
    }
}
