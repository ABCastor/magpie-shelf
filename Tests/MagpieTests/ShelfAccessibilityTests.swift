import Foundation
import XCTest
@testable import Magpie

/// The cell label is the one accessibility decision in the shelf views that
/// isn't a constant, so it lives in a pure function and is pinned here rather
/// than eyeballed in a VoiceOver pass.
final class ShelfAccessibilityTests: XCTestCase {
    func test_item_label_reads_name_then_kind_then_detail() {
        XCTAssertEqual(
            ShelfItemAccessibility.itemLabel(
                name: "Invoice.pdf", kind: "File", meta: "1.2 MB"
            ),
            "Invoice.pdf, File, 1.2 MB"
        )
    }

    func test_item_label_spells_out_the_middle_dot_separator() {
        // VoiceOver reads "·" as nothing, so "1.2 MB · PDF" runs together.
        XCTAssertEqual(
            ShelfItemAccessibility.itemLabel(
                name: "Deck.pdf", kind: "File", meta: "1.2 MB · 12 pages"
            ),
            "Deck.pdf, File, 1.2 MB, 12 pages"
        )
    }

    func test_item_label_does_not_say_the_kind_twice() {
        // A folder whose recursive size hasn't been computed yet shows
        // "Folder" as its meta line as well as being one.
        XCTAssertEqual(
            ShelfItemAccessibility.itemLabel(
                name: "Receipts", kind: "Folder", meta: "Folder"
            ),
            "Receipts, Folder"
        )
    }

    func test_item_label_flattens_a_multiline_snippet_name() {
        XCTAssertEqual(
            ShelfItemAccessibility.itemLabel(
                name: "first line\n\n  second line  ", kind: "Text", meta: "Text · 24 chars"
            ),
            "first line second line, Text, Text, 24 chars"
        )
    }

    func test_item_label_drops_empty_parts_rather_than_leaving_gaps() {
        XCTAssertEqual(
            ShelfItemAccessibility.itemLabel(name: "notes.txt", kind: "", meta: ""),
            "notes.txt"
        )
    }

    func test_kind_is_a_distinct_non_empty_noun_for_every_item_shape() {
        let kinds = [
            ShelfItemAccessibility.kind(isDirectory: true, type: .file),
            ShelfItemAccessibility.kind(isDirectory: false, type: .file),
            ShelfItemAccessibility.kind(isDirectory: false, type: .image),
            ShelfItemAccessibility.kind(isDirectory: false, type: .text),
        ]
        XCTAssertEqual(Set(kinds).count, 4, "two item shapes speak the same noun")
        for kind in kinds {
            XCTAssertFalse(kind.isEmpty, "an item shape has no spoken noun")
        }
    }
}

/// Same guard as `HandoffLocalizationTests`: a missing key here means VoiceOver
/// announces the raw key ("a11y.close-shelf") in that language.
final class AccessibilityLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "a11y.close-shelf",
        "a11y.collapse-shelf",
        "a11y.back",
        "a11y.dock-shelf",
        "a11y.expand-shelf",
        "a11y.open-shelf",
        "a11y.pinned",
        "a11y.grid-view",
        "a11y.list-view",
        "a11y.open-folder",
        "a11y.kind.image",
        "a11y.kind.text",
        "a11y.item.hint",
        "a11y.stack.hint",
    ]
    /// Labels the views reuse rather than restating; if one of these is ever
    /// dropped from a table, an icon-only control goes mute.
    private static let borrowedKeys = [
        "Accent", "Cancel", "Deselect All", "File", "Folder",
        "Remove from Shelf", "Reveal in Finder", "Select All",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/MagpieTests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    func test_every_language_parses_and_defines_the_accessibility_strings() throws {
        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            for key in Self.keys + Self.borrowedKeys {
                let value = table[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
            for key in Self.keys {
                XCTAssertNotEqual(table[key], key, "\(language) left \(key) untranslated")
            }
        }
    }
}
