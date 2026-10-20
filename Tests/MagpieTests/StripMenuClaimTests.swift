import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// **The menu answers to the header, or the app lies about what it is about to
/// take.**
///
/// `StripHeaderClaimTests` pinned the header against the drag: walk all
/// thirty-two selection states of a five-row shelf, render the sentence, parse
/// the numbers back out, compare them to what a drag would carry. The strip's
/// **menu** was never brought under that rule. It was built with no selection at
/// all, so every row read `manager.items(of:)` — and with `1 of 5` on screen,
/// All Actions ▸ Move to Trash recycled five of the user's files.
///
/// So the same walk, for the menu: in every selection state, the set the rows
/// would act on must equal the set the header claims. The subject is read off
/// the built menu's own targets rather than by performing anything — a real
/// context menu blocks AppKit's modal tracking loop for the better part of a
/// minute, and Move to Trash is not an action a test may perform on a real Mac.
@MainActor
final class StripMenuClaimTests: XCTestCase {

    private var scratch: URL!
    private var manager: ShelfManager!
    private var shelfID: UUID!

    /// Storage order, oldest first — the order `items(of:)` returns and the
    /// order the menu's rows are built from.
    private var ids: [UUID] = []

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("strip-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        manager = ShelfManager(
            store: ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        )
        shelfID = manager.createShelf()
        for name in ["one.txt", "two.txt", "three.txt", "four.txt", "five.txt"] {
            let url = scratch.appendingPathComponent(name)
            try Data("payload".utf8).write(to: url)
            _ = manager.addFile(url: url, to: shelfID)
        }
        ids = manager.items(of: shelfID).map(\.id)
        XCTAssertEqual(ids.count, 5, "the walk below assumes a five-row shelf")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Every way a five-row shelf can be narrowed, including the two that mean
    /// the same thing (nothing picked, everything picked).
    private var everySelectionState: [Set<UUID>] {
        (0..<(1 << ids.count)).map { mask in
            Set(ids.indices.filter { mask & (1 << $0) != 0 }.map { ids[$0] })
        }
    }

    /// The menu a right-click on a row builds, and the object every one of its
    /// rows is wired to.
    private func menu(picking explicit: Set<UUID>) throws -> (ShelfActionNSMenu, ShelfActionTargets) {
        let built = ShelfActionMenuBuilder.make(
            manager: manager,
            shelfID: shelfID,
            selection: explicit,
            // Pinned so the walk is the same menu on a machine with Claude and
            // on one without; the handoff row's gating has its own tests.
            claudeInstalled: true
        )
        let shelfMenu = try XCTUnwrap(built as? ShelfActionNSMenu, "the builder stopped vending its own menu class, so nothing can read what its rows would act on")
        return (shelfMenu, try XCTUnwrap(shelfMenu.targets))
    }

    private func rows(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            [item] + (item.submenu.map { rows(in: $0) } ?? [])
        }
    }

    private func row(_ selector: Selector, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(
            rows(in: menu).first { $0.action == selector },
            "the menu no longer offers \(selector) at all"
        )
    }

    /// The integers a rendered row actually states, in the order it prints them.
    /// Read off the title rather than off the count it was built from, for the
    /// same reason the header test does it: a format string that lost its slot,
    /// or a table filled the wrong way round, is invisible to a check on inputs.
    private func statedNumbers(in title: String) -> [Int] {
        title
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { $0.isEmpty ? nil : Int($0) }
    }

    // MARK: - The one invariant

    /// **In every selection state, the set the menu's actions receive is the set
    /// the header claims.**
    ///
    /// Both sides are read the way the app reads them: the claim through
    /// `ShelfStripHeader.title`, rendered and parsed back; the subject off the
    /// targets object every row of the built menu is wired to. If they ever
    /// differ, some row of that menu is about to act on files the user was told
    /// were not in play — which for Move to Trash means their files.
    func test_every_menu_action_receives_exactly_what_the_header_claims() throws {
        for explicit in everySelectionState {
            let claim = ShelfSelection.claim(explicit: explicit, ids: ids)
            let title = ShelfStripHeader.title(name: nil, claim: claim)
            let (_, targets) = try menu(picking: explicit)

            XCTAssertEqual(
                Set(targets.items.map(\.id)),
                ShelfSelection.effective(explicit: explicit, ids: ids),
                "the header reads \"\(title)\" and the menu's rows would act on a different set of files — the menu is not built from the selection the drag and the header are built from"
            )
            XCTAssertEqual(
                targets.items.count, claim.carried,
                "the header reads \"\(title)\" while every row of the menu under it would act on \(targets.items.count) files — Move to Trash included"
            )
        }
    }

    /// Every row hangs off that one object. A row wired to anything else would
    /// have a subject nothing above can see, which is how this defect arrived:
    /// the builder was handed a shelf and never asked what was picked.
    func test_no_row_of_the_menu_has_a_subject_of_its_own() throws {
        let (built, targets) = try menu(picking: [ids[0], ids[1]])
        // AppKit gives an action-less submenu parent its own `submenuAction:`
        // and points it at the menu; that row opens a submenu and acts on
        // nothing, so it has no subject to get wrong.
        let openSubmenu = NSSelectorFromString("submenuAction:")
        let actionable = rows(in: built).filter { $0.action != nil && $0.action != openSubmenu }
        XCTAssertGreaterThan(actionable.count, 10, "read a menu with almost no rows in it")
        for item in actionable {
            XCTAssertTrue(
                item.target === targets,
                "the row \"\(item.title)\" is wired to something other than the menu's targets, so what it acts on is decided somewhere nothing checks"
            )
        }
    }

    /// And nothing inside an action may reach past the two doors at the top of
    /// the class. This is the shape the defect actually had — `batchRename` and
    /// `moveAllToTrash` each re-read `manager.items(of: shelfID)` for
    /// themselves — so a behavioural walk over today's rows is not enough: the
    /// next row added has to inherit the rule.
    func test_no_action_reads_the_shelf_behind_the_selections_back() throws {
        let source = magpieCodeOnly(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfActionMenu.swift"),
            encoding: .utf8
        ))
        XCTAssertTrue(source.contains("final class ShelfActionTargets"), "read the wrong file")
        XCTAssertTrue(
            source.contains("ShelfSelection.carried("),
            "the menu's subject is no longer resolved through the one function the drag and the header are also defined in terms of"
        )
        // Everything from the first @objc action to the end of the class.
        let actions = source
            .components(separatedBy: "@objc func")
            .dropFirst()
            .joined(separator: "\n")
        XCTAssertFalse(actions.isEmpty, "found no actions to check")
        XCTAssertFalse(
            actions.contains("manager.items(of:"),
            "an action in this menu reads the whole shelf for itself instead of the selection — that is exactly how Move to Trash came to recycle five files over a header reading \"1 of 5\""
        )
    }

    // MARK: - What the destructive rows say

    /// **A row that moves a user's file names how many.** The strip is quiet at
    /// rest and says what is in play in words; a bare "Move to Trash" over five
    /// files says nothing about the five, which is how nobody noticed.
    func test_move_to_trash_names_what_it_takes_in_every_state() throws {
        for explicit in everySelectionState {
            let claim = ShelfSelection.claim(explicit: explicit, ids: ids)
            let (built, targets) = try menu(picking: explicit)
            let trash = try row(#selector(ShelfActionTargets.moveAllToTrash), in: built)

            if claim.carried > 1 {
                XCTAssertEqual(
                    statedNumbers(in: trash.title), [claim.carried],
                    "the Trash row reads \"\(trash.title)\" while it would recycle \(targets.items.count) files — a row that takes the user's files must say how many, and no other number"
                )
            } else {
                XCTAssertEqual(
                    trash.title, L("Move to Trash"),
                    "one file is about to be recycled and the row does not read as the singular action"
                )
            }
        }
    }

    /// The other destructive row, and the one that changes its name outright:
    /// emptying the shelf is still **Clear Shelf**, anything less than that says
    /// how much it takes off.
    func test_remove_from_shelf_names_what_it_takes_in_every_state() throws {
        for explicit in everySelectionState {
            let claim = ShelfSelection.claim(explicit: explicit, ids: ids)
            let (built, _) = try menu(picking: explicit)
            let remove = try row(#selector(ShelfActionTargets.clear), in: built)

            if claim.isWholeShelf {
                XCTAssertEqual(
                    remove.title, L("Clear Shelf"),
                    "an untouched shelf's clear row has been renamed — the row that empties the shelf should read as what it has always done"
                )
            } else if claim.carried > 1 {
                XCTAssertEqual(
                    statedNumbers(in: remove.title), [claim.carried],
                    "the row reads \"\(remove.title)\" while it would take \(claim.carried) rows off the shelf"
                )
            } else {
                XCTAssertEqual(
                    remove.title, L("Remove from Shelf"),
                    "with one row picked the clear row still offers to empty the whole shelf"
                )
            }
        }
    }

    /// And the row does what it says. Rows only — nothing here goes near the
    /// filesystem (ADR 0001), which is why this one is driven for real while the
    /// Trash row is checked at its subject.
    func test_remove_from_shelf_takes_only_the_picked_rows_off() throws {
        let picked: Set<UUID> = [ids[0], ids[3]]
        let (built, _) = try menu(picking: picked)
        let remove = try row(#selector(ShelfActionTargets.clear), in: built)
        _ = remove.target?.perform(remove.action)

        XCTAssertEqual(
            Set(manager.items(of: shelfID).map(\.id)),
            Set(ids).subtracting(picked),
            "the row took the wrong rows off the shelf — with two of five picked it cleared something other than those two"
        )
        XCTAssertTrue(
            manager.canUndo,
            "two rows vanished with no way back; ⌘Z has to reverse a removal the user made from a menu"
        )
    }

    /// The untouched shelf is untouched: same rows, same one undo entry, same
    /// title on it. The fix must cost the default state nothing.
    func test_an_untouched_shelf_still_clears_as_one_action() throws {
        let (built, _) = try menu(picking: ShelfSelection.wholeShelf)
        let remove = try row(#selector(ShelfActionTargets.clear), in: built)
        _ = remove.target?.perform(remove.action)

        XCTAssertTrue(
            manager.items(of: shelfID).isEmpty,
            "Clear Shelf no longer empties an unpicked shelf"
        )
        XCTAssertEqual(
            manager.undoSnapshot?.menuTitle, L("undo.clear-shelf"),
            "clearing a whole shelf no longer records itself as a clear, so ⌘Z names something else"
        )
    }

    // MARK: - The ⋯ button is the shelf's, a row is the pick's

    /// The chrome button opens the **shelf's** menu deliberately: it sits beside
    /// close, dock and expand, none of which name a file. What keeps that honest
    /// while the header reads `1 of 5` is that its rows say `5`.
    func test_the_shelf_menu_still_acts_on_the_whole_shelf() throws {
        let (built, targets) = try menu(picking: ShelfSelection.wholeShelf)
        XCTAssertEqual(
            targets.items.count, ids.count,
            "the shelf's own menu no longer acts on the shelf"
        )
        XCTAssertEqual(
            statedNumbers(in: try row(#selector(ShelfActionTargets.moveAllToTrash), in: built).title),
            [ids.count],
            "the shelf menu's Trash row does not say how many files it would take"
        )
    }

    /// And the wiring that decides which is which. Both call sites are one
    /// argument, and getting either one wrong is invisible in a built menu:
    /// the button would silently act on a pick, or a row would silently act on
    /// the shelf — the defect this whole file exists to close.
    func test_the_button_passes_the_shelf_and_a_row_passes_its_pick() throws {
        let button = magpieCodeOnly(try source("Sources/Magpie/ShelfActionMenu.swift"))
        let presentMenu = try XCTUnwrap(
            button.components(separatedBy: "private func presentMenu()").last,
            "could not find the ⋯ button's menu call"
        )
        XCTAssertTrue(
            presentMenu.contains("selection: ShelfSelection.wholeShelf"),
            "the ⋯ button no longer says which set it means, so the shelf's own menu answers to whatever a row was picked out"
        )

        let strip = magpieCodeOnly(try source("Sources/Magpie/CollapsedShelfView.swift"))
        XCTAssertTrue(strip.contains("ShelfStripRow("), "read the wrong file")
        let menuBuilder = try XCTUnwrap(
            strip.components(separatedBy: "menuBuilder:").last,
            "the strip's rows no longer carry a menu at all"
        )
        XCTAssertTrue(
            menuBuilder.contains("selection: selection"),
            "a strip row builds its menu without handing over what is picked, so every row of it acts on the whole shelf again — Move to Trash included"
        )
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

/// The two rows that take something, in nine languages.
///
/// A count that fails to substitute leaves `Move %lld Files to Trash` on screen,
/// and a count that goes missing leaves the vague row this change exists to
/// replace. Both are silent failures, so both are written out here per language:
/// this repo has shipped a localisation test that passed while every value in
/// nine tables was shifted one slot.
final class MenuCountLocalizationTests: XCTestCase {

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = ["menu.trash-count", "menu.remove-count-from-shelf"]

    private func table(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language).lproj/Localizable.strings did not parse"
        )
    }

    func test_every_language_defines_the_counted_rows() throws {
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

    func test_every_language_keeps_the_count() throws {
        for language in Self.languages {
            let strings = try table(language)
            for key in Self.keys {
                let value = try XCTUnwrap(strings[key])
                XCTAssertTrue(
                    value.contains("%lld"),
                    "\(language) lost the count in \(key), so the row goes back to naming no number at all — which is the row that recycled five files over a header reading \"1 of 5\""
                )
            }
        }
    }

    /// The golden. Three files, written out, so a re-translation that drops the
    /// count or attaches it to the wrong noun cannot land quietly.
    func test_three_files_reads_correctly_in_every_language() throws {
        let trash = [
            "Base": "Move 3 Files to Trash",
            "en": "Move 3 Files to Trash",
            "de": "3 Dateien in den Papierkorb legen",
            "es": "Mover 3 archivos a la papelera",
            "fr": "Mettre 3 fichiers à la corbeille",
            "it": "Sposta 3 file nel Cestino",
            "ja": "3 件のファイルをゴミ箱に入れる",
            "pl": "Przenieś 3 plików do Kosza",
            "zh-Hans": "将 3 个文件移到废纸篓",
        ]
        let remove = [
            "Base": "Remove 3 Files from Shelf",
            "en": "Remove 3 Files from Shelf",
            "de": "3 Dateien aus Regal entfernen",
            "es": "Quitar 3 archivos del estante",
            "fr": "Retirer 3 fichiers de l’étagère",
            "it": "Rimuovi 3 file dalla mensola",
            "ja": "3 件のファイルをシェルフから削除",
            "pl": "Usuń 3 plików z półki",
            "zh-Hans": "从搁架移除 3 个文件",
        ]
        for language in Self.languages {
            let strings = try table(language)
            XCTAssertEqual(
                String(format: try XCTUnwrap(strings["menu.trash-count"]), 3), trash[language],
                "\(language) renders the Trash row as something else"
            )
            XCTAssertEqual(
                String(format: try XCTUnwrap(strings["menu.remove-count-from-shelf"]), 3),
                remove[language],
                "\(language) renders the remove row as something else"
            )
        }
    }

    /// Singular plain, plural counted, and emptying the shelf still called what
    /// it has always been called. Composed in one place so the two menus that
    /// show these rows cannot word them differently.
    func test_the_titles_say_what_the_action_will_do() {
        XCTAssertEqual(ShelfActionTitle.moveToTrash(count: 1), L("Move to Trash"))
        XCTAssertEqual(
            ShelfActionTitle.moveToTrash(count: 4),
            String(format: L("menu.trash-count"), 4)
        )
        XCTAssertFalse(
            ShelfActionTitle.moveToTrash(count: 4).contains("%"),
            "a raw placeholder reached the row that moves the user's files"
        )

        XCTAssertEqual(ShelfActionTitle.removeFromShelf(count: 5, of: 5), L("Clear Shelf"))
        XCTAssertEqual(ShelfActionTitle.removeFromShelf(count: 1, of: 5), L("Remove from Shelf"))
        XCTAssertEqual(
            ShelfActionTitle.removeFromShelf(count: 3, of: 5),
            String(format: L("menu.remove-count-from-shelf"), 3)
        )
        XCTAssertFalse(ShelfActionTitle.removeFromShelf(count: 3, of: 5).contains("%"))
    }
}
