import Foundation
import XCTest
@testable import Magpie

/// `DragInitiatorView`'s accessibility overrides can't be exercised without a
/// running app and a VoiceOver session, so the one decision they make — which
/// actions a given cell offers, and what it is called — lives in a pure enum
/// and is pinned here instead.
final class ShelfCellAccessibilityTests: XCTestCase {
    func test_a_cell_with_nothing_wired_offers_no_actions() {
        // An advertised action that does nothing is worse than a missing one.
        XCTAssertEqual(
            ShelfCellAccessibility.actions(
                canOpen: false, canShowMenu: false, canSelect: false
            ),
            []
        )
    }

    func test_a_document_tile_offers_open_then_menu_then_selection() {
        // DocumentGridItem / DocumentListItem wire all three closures.
        XCTAssertEqual(
            ShelfCellAccessibility.actions(
                canOpen: true, canShowMenu: true, canSelect: true
            ),
            [.open, .showMenu, .toggleSelection]
        )
    }

    func test_a_folder_entry_cell_offers_no_menu_because_it_has_none() {
        // FolderEntryGridCell / FolderEntryListItem pass no menuBuilder.
        XCTAssertEqual(
            ShelfCellAccessibility.actions(
                canOpen: true, canShowMenu: false, canSelect: true
            ),
            [.open, .toggleSelection]
        )
    }

    func test_the_collapsed_stack_offers_only_its_menu() {
        // StackedDocumentPreview wires a menu and nothing else: a click on the
        // front card does nothing today, so neither does a press.
        XCTAssertEqual(
            ShelfCellAccessibility.actions(
                canOpen: false, canShowMenu: true, canSelect: false
            ),
            [.showMenu]
        )
    }

    func test_every_action_has_a_distinct_non_empty_title() {
        let titles = ShelfCellAccessibility.Action.allCases.map(\.title)
        XCTAssertEqual(
            Set(titles).count, ShelfCellAccessibility.Action.allCases.count,
            "two actions read the same in the rotor"
        )
        for title in titles {
            XCTAssertFalse(title.isEmpty, "an action has no spoken name")
        }
    }

    func test_a_cell_with_nothing_to_drag_has_no_spoken_name() {
        XCTAssertNil(ShelfCellAccessibility.label(forDraggedURLs: []))
    }

    func test_a_single_item_cell_is_named_after_its_file() {
        XCTAssertEqual(
            ShelfCellAccessibility.label(
                forDraggedURLs: [URL(fileURLWithPath: "/tmp/Deck.pdf")]
            ),
            "Deck.pdf"
        )
    }

    func test_a_multi_selection_cell_is_named_by_count_not_by_one_file() {
        let label = ShelfCellAccessibility.label(forDraggedURLs: [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
            URL(fileURLWithPath: "/tmp/c.pdf"),
        ])
        // The wording is the user's language; the count is what has to survive.
        XCTAssertTrue(
            label?.contains("3") ?? false,
            "the count is what distinguishes this cell; got \(label ?? "nil")"
        )
        XCTAssertFalse(
            label?.contains("a.pdf") ?? true,
            "naming one file of three says the wrong thing about the drag"
        )
    }
}

/// Same guard as `AccessibilityLocalizationTests`: a missing key here means
/// VoiceOver reads the raw key ("a11y.action.show-menu") as the action's name.
final class ShelfCellActionLocalizationTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "a11y.action.show-menu",
        "a11y.action.toggle-selection",
    ]
    /// Titles the action list reuses rather than restating; dropping one of
    /// these leaves an action, or a whole cell, without a name.
    private static let borrowedKeys = ["Open", "%lld Files"]

    func test_every_language_defines_the_cell_action_strings() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
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
