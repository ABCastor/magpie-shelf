import AppKit
import XCTest
@testable import Magpie

/// The owner's report, as a set of properties: *"I want to be able to drag one
/// thing out also individually"* and *"the standard option is that it
/// highlights everything"*.
///
/// The second half of that was built literally and then reversed on the owner's
/// instruction. The strip is quiet at rest now and the header says `5 Files`
/// in words instead. What the header claims is pinned by
/// `StripHeaderClaimTests`; what a drag *takes* is pinned here, and the two
/// halves are derived from the same `effective` so they cannot come apart.
///
/// All of it lives in `ShelfSelection`, pure over ids, because the two places
/// that consume it — an `NSView`'s `mouseUp` and a SwiftUI row's fill — are
/// equally unreachable from a test.
final class ShelfSelectionTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private var ids: [UUID] { [a, b, c] }

    // MARK: - The default

    /// A shelf holds a set (ADR 0007), so taking the set is the state the user
    /// starts in and never has to ask for.
    func test_an_untouched_shelf_still_hands_over_every_row() {
        XCTAssertEqual(
            ShelfSelection.effective(explicit: ShelfSelection.wholeShelf, ids: ids),
            Set(ids),
            "a shelf nobody has clicked selects nothing, so the effortless default is no longer taking the whole set"
        )
    }

    /// The invariant the whole model turns on: the set the shelf considers
    /// picked and the set a drag from one of those rows carries are read off
    /// the same function, so they cannot drift. What the *header* says about
    /// that set is the other half, and it is `StripHeaderClaimTests`.
    func test_a_picked_row_drags_the_set_it_belongs_to() {
        for explicit in [ShelfSelection.wholeShelf, Set([a, b]), Set([c])] {
            let picked = ShelfSelection.effective(explicit: explicit, ids: ids)
            for id in ids {
                let start = ShelfSelection.beginDrag(from: id, explicit: explicit, ids: ids)
                if picked.contains(id) {
                    XCTAssertEqual(
                        start.dragged, picked,
                        "row \(id) is part of the pick but a drag from it takes something else — the shelf and the drag disagree about what is about to leave"
                    )
                } else {
                    XCTAssertEqual(
                        start.dragged, [id],
                        "row \(id) is outside the pick but a drag from it takes more than itself"
                    )
                }
            }
        }
    }

    // MARK: - Clicking

    func test_a_plain_click_narrows_to_one_row() {
        let outcome = ShelfSelection.click(
            id: b, modifiers: [], explicit: ShelfSelection.wholeShelf, anchor: nil, ids: ids
        )
        XCTAssertEqual(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids), [b],
            "clicking a row does not narrow the shelf to it, so there is no way to pick one file"
        )
        XCTAssertEqual(outcome.anchor, b, "a plain click is where the next ⇧-click counts from")
    }

    func test_command_click_takes_one_row_out_of_the_default() {
        let outcome = ShelfSelection.click(
            id: b, modifiers: .command, explicit: ShelfSelection.wholeShelf, anchor: nil, ids: ids
        )
        XCTAssertEqual(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids), [a, c],
            "⌘-clicking a row of an untouched shelf does not deselect it"
        )
    }

    func test_command_click_puts_a_row_back() {
        let outcome = ShelfSelection.click(
            id: c, modifiers: .command, explicit: [a], anchor: a, ids: ids
        )
        XCTAssertEqual(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids), [a, c],
            "⌘-click does not add to an existing selection"
        )
    }

    /// There is deliberately no state in which the strip looks empty-handed:
    /// deselecting your last pick is a return to the default, not a shelf whose
    /// drag would take nothing.
    func test_deselecting_the_last_row_returns_to_the_whole_shelf() {
        let outcome = ShelfSelection.click(
            id: a, modifiers: .command, explicit: [a], anchor: a, ids: ids
        )
        XCTAssertEqual(outcome.selection, ShelfSelection.wholeShelf)
        XCTAssertEqual(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids), Set(ids),
            "deselecting the last row leaves a shelf that shows nothing selected and would drag nothing"
        )
    }

    func test_shift_click_selects_the_range_from_the_anchor() {
        let outcome = ShelfSelection.click(
            id: c, modifiers: .shift, explicit: [a], anchor: a, ids: ids
        )
        XCTAssertEqual(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids), Set(ids),
            "⇧-click does not extend a range, so picking two adjacent files takes two ⌘-clicks"
        )
        XCTAssertEqual(outcome.anchor, a, "a ⇧-click moved the anchor, so the next one counts from the wrong end")
    }

    func test_shift_click_takes_the_whole_range_not_just_its_ends() {
        let outcome = ShelfSelection.click(
            id: c, modifiers: .shift, explicit: [a], anchor: a, ids: [a, b, c]
        )
        XCTAssertTrue(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids).contains(b),
            "⇧-click skipped the row between its two ends"
        )
    }

    /// No anchor yet is the state a fresh shelf is in, and a range has to count
    /// from somewhere. The top row is where Finder starts one.
    func test_shift_click_without_an_anchor_counts_from_the_top_row() {
        let outcome = ShelfSelection.click(
            id: b, modifiers: .shift, explicit: ShelfSelection.wholeShelf, anchor: nil, ids: ids
        )
        XCTAssertEqual(
            ShelfSelection.effective(explicit: outcome.selection, ids: ids), [a, b],
            "a ⇧-click with no anchor does not produce a range from the top of the strip"
        )
    }

    /// ⌥ and Caps Lock are not selection modifiers here. Of the two readings of
    /// an ambiguous modifier only one of them can leave the user holding files
    /// they did not mean to.
    func test_an_unrelated_modifier_selects_rather_than_toggles() {
        for modifier in [NSEvent.ModifierFlags.option, .capsLock] {
            let outcome = ShelfSelection.click(
                id: b, modifiers: modifier, explicit: ShelfSelection.wholeShelf, anchor: nil, ids: ids
            )
            XCTAssertEqual(
                ShelfSelection.effective(explicit: outcome.selection, ids: ids), [b],
                "\(modifier) is read as a toggle, so an unrelated modifier changes what a click means"
            )
        }
    }

    /// **⌃ is the one modifier that is not ambiguous, and it used to be read as
    /// one.** On macOS a ⌃-click *is* the secondary click: it belongs to the
    /// context menu and must leave the selection exactly where it found it.
    /// Reading it as a plain click meant that reaching for the menu on a shelf
    /// the user had narrowed to three files silently threw the other two picks
    /// away — and where a cell offers no menu at all (the folder browser's
    /// cells, which wire no menu builder) that was the *only* thing a ⌃-click
    /// did.
    func test_a_control_click_leaves_the_selection_exactly_as_it_was() {
        for modifier in [NSEvent.ModifierFlags.control, [.control, .shift], [.control, .command]] {
            let outcome = ShelfSelection.click(
                id: c, modifiers: modifier, explicit: [a, b], anchor: a, ids: ids
            )
            XCTAssertEqual(
                outcome.selection, [a, b],
                "a ⌃-click changes the selection, so opening the context menu throws away what the user picked"
            )
            XCTAssertEqual(
                outcome.anchor, a,
                "a ⌃-click moved the anchor, so the next ⇧-click counts a range from somewhere the user never clicked"
            )
        }
    }

    func test_a_click_on_a_row_that_is_not_there_changes_nothing() {
        let outcome = ShelfSelection.click(
            id: UUID(), modifiers: [], explicit: [a], anchor: a, ids: ids
        )
        XCTAssertEqual(outcome.selection, [a])
        XCTAssertEqual(outcome.anchor, a)
    }

    // MARK: - Dragging

    /// **The defect.** Eleven rows on screen, drag one, get eleven.
    func test_a_drag_from_an_unselected_row_narrows_to_it_and_carries_only_it() {
        let start = ShelfSelection.beginDrag(from: c, explicit: [a], ids: ids)
        XCTAssertEqual(
            start.dragged, [c],
            "dragging a row outside the selection still carries the whole selection — the report this ADR exists for"
        )
        XCTAssertEqual(
            ShelfSelection.effective(explicit: start.selection, ids: ids), [c],
            "the drag left the selection pointing at a row the user did not drag"
        )
    }

    func test_a_drag_from_a_selected_row_carries_the_whole_selection() {
        let start = ShelfSelection.beginDrag(from: a, explicit: [a, b], ids: ids)
        XCTAssertEqual(
            start.dragged, [a, b],
            "dragging one of several selected rows drops the others — a multi-file drag is unreachable"
        )
        XCTAssertEqual(start.selection, [a, b], "a drag inside the selection changed it")
    }

    func test_the_default_drag_still_takes_the_whole_shelf() {
        let start = ShelfSelection.beginDrag(
            from: b, explicit: ShelfSelection.wholeShelf, ids: ids
        )
        XCTAssertEqual(
            start.dragged, Set(ids),
            "a drag off an untouched shelf no longer takes the set, so the shelf's whole premise costs a ⌘A first"
        )
        XCTAssertEqual(
            start.selection, ShelfSelection.wholeShelf,
            "the default drag wrote an explicit selection, so a file added afterwards would not join it"
        )
    }

    // MARK: - Items coming and going

    func test_a_file_taken_off_the_shelf_loses_its_place_in_the_selection() {
        XCTAssertEqual(
            ShelfSelection.effective(explicit: [a, b], ids: [a, c]), [a],
            "a removed file keeps a place in the selection, so the count the user sees and the count that leaves differ"
        )
    }

    func test_a_selection_of_only_removed_files_falls_back_to_the_whole_shelf() {
        XCTAssertEqual(
            ShelfSelection.effective(explicit: [b], ids: [a, c]), Set([a, c]),
            "every selected file was removed and the shelf is left selecting nothing at all"
        )
    }

    /// Selecting every row is an explicit state, not the untouched default.
    /// Both carry the current shelf, but only the explicit state should draw
    /// selected rows and tell the user that they deliberately selected all.
    func test_selecting_every_row_stays_explicit() {
        XCTAssertEqual(
            ShelfSelection.narrowed(to: Set(ids), ids: ids), Set(ids),
            "the explicit full selection is not retained, so the header cannot distinguish select-all from the untouched shelf"
        )
        let d = UUID()
        XCTAssertEqual(
            ShelfSelection.effective(
                explicit: ShelfSelection.narrowed(to: Set(ids), ids: ids), ids: ids + [d]
            ),
            Set(ids),
            "a file dropped onto an explicit select-all was silently added, so the explicit selection no longer names the rows the user selected"
        )
    }

    func test_an_empty_shelf_selects_nothing() {
        XCTAssertEqual(ShelfSelection.effective(explicit: [a], ids: []), [])
        XCTAssertEqual(ShelfSelection.beginDrag(from: a, explicit: [], ids: []).dragged, [])
    }

    // MARK: - The wiring

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

    /// A model nothing consults is not a model, and this is the shape of failure
    /// the repo has already paid for: a perfect pure function beside a view that
    /// still does it the old way. The strip must ask for what a row drags and
    /// for what a row shows, and it must no longer vend the whole shelf from one
    /// overlay over the stack.
    func test_the_strip_drags_and_draws_from_the_selection_model() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/CollapsedShelfView.swift"))
        XCTAssertTrue(text.contains("ShelfStripRow("), "read the wrong file")
        XCTAssertTrue(
            text.contains("ShelfSelection.beginDrag("),
            "the strip decides for itself what a drag carries, so nothing above describes what leaves the shelf"
        )
        XCTAssertTrue(
            text.contains("ShelfSelection.highlighted("),
            "the rows decide their own fill, so the strip can light up rows a drag is not carrying — or go back to lighting up every row at rest, which is what the owner rejected"
        )
        XCTAssertTrue(
            text.contains("isDragging: isDragging"),
            "the fill is not told whether a drag is in flight, so either nothing lights up mid-drag or everything lights up at rest"
        )
        XCTAssertFalse(
            text.contains("provider: { items.compactMap { $0.fileURL } }"),
            "the strip is one drag surface again: a drag off any row carries the whole shelf, which is the report this ADR exists for"
        )
    }

    /// ADR 0010 recorded this as owed: *"VoiceOver still hears '3 Files' for
    /// the strip, not three names… Per-row labels want the per-row drag
    /// contract decided first; recorded as owed, not done."* It is decided, so
    /// this is the debt.
    ///
    /// SwiftUI's accessibility tree cannot be read from a unit test, so what is
    /// checked is that the row asks for the three things a VoiceOver user needs:
    /// its own name, its own hint, and whether it is selected — and that the
    /// strip stopped hiding its rows behind one label.
    func test_every_row_is_named_and_says_whether_it_is_selected() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/CollapsedShelfView.swift"))
        XCTAssertTrue(text.contains("ShelfStripRow("), "read the wrong file")
        XCTAssertTrue(
            text.contains("ShelfItemAccessibility.itemLabel("),
            "a strip row has no spoken name of its own, so VoiceOver still hears a count where a sighted user reads filenames"
        )
        XCTAssertTrue(
            text.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"),
            "a strip row never says whether it is selected, so the one thing that decides what a drag takes is inaudible"
        )
        XCTAssertTrue(
            text.contains(".accessibilityHint(L(\"a11y.item.hint\"))"),
            "a strip row does not say what can be done with it"
        )
        XCTAssertFalse(
            text.contains(".accessibilityElement(children: .ignore)\n        .accessibilityLabel("),
            "the strip hides its rows behind one label again — the gap ADR 0010 recorded as owed"
        )
    }

    /// And the container has to turn a click and a space bar into a selection
    /// through the same rules, or each path grows its own untested contract.
    /// Two named entry points, so a break in either one is visible here.
    func test_the_pointer_and_the_keyboard_go_through_the_selection_model() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/ShelfContainerView.swift"))
        XCTAssertTrue(text.contains("CollapsedShelfView("), "read the wrong file")
        XCTAssertTrue(
            text.contains("ShelfSelection.click("),
            "a row click is interpreted somewhere other than ShelfSelection, so ⇧ and ⌘ mean whatever that call site decides"
        )
        XCTAssertTrue(
            text.contains("ShelfSelection.toggle("),
            "the space bar toggles a row by its own rules, so the keyboard and the pointer can disagree about what is selected"
        )
    }

    func test_the_space_bar_and_command_click_are_the_same_rule() {
        XCTAssertEqual(
            ShelfSelection.toggle(id: b, explicit: [a], anchor: a, ids: ids),
            ShelfSelection.click(id: b, modifiers: .command, explicit: [a], anchor: a, ids: ids),
            "toggling from the keyboard has drifted from ⌘-clicking, so the same row ends up in two different states depending on how it was reached"
        )
    }
}

/// The strip is a selection surface and nothing more. Every command the monitor
/// forwards is swallowed, so a command the strip does not implement becomes a
/// silent dead key — the failure this repo has already shipped once.
final class CollapsedStripKeyboardTests: XCTestCase {

    func test_the_strip_answers_the_selection_keys() {
        for command: ShelfKey.Command in [
            .move(.up), .move(.down), .move(.left), .move(.right),
            .extend(.up), .extend(.down), .toggleSelection,
        ] {
            XCTAssertTrue(
                ShelfKey.isCollapsedStripCommand(command),
                "\(command) does not reach a collapsed strip, so selection is unreachable from the keyboard in the state a shelf is actually in"
            )
        }
    }

    func test_the_strip_leaves_every_other_key_alone() {
        for command: ShelfKey.Command in [
            .activate, .ascend, .removeFromShelf, .quickLook,
        ] {
            for narrowed in [true, false] {
                XCTAssertFalse(
                    ShelfKey.isCollapsedStripCommand(command, hasNarrowedSelection: narrowed),
                    "\(command) is swallowed by a collapsed strip that does not implement it — a live key becomes a dead one"
                )
            }
        }
    }

    /// **Escape is the way back to "a drag takes the whole shelf", and only
    /// then.** The strip is quiet at rest, so undoing an accidental pick has to
    /// be effortless; but a resting strip has nothing to undo, and swallowing
    /// the key there would make Escape dead in the state a shelf spends most of
    /// its life in — the exact failure this repo has already shipped.
    func test_escape_is_claimed_only_when_there_is_a_pick_to_clear() {
        XCTAssertTrue(
            ShelfKey.isCollapsedStripCommand(.exit, hasNarrowedSelection: true),
            "Escape does not reach a narrowed strip, so a user who picked one row by accident has no key that puts the shelf back"
        )
        XCTAssertFalse(
            ShelfKey.isCollapsedStripCommand(.exit, hasNarrowedSelection: false),
            "Escape is swallowed by a resting strip with nothing to clear — a live key becomes a dead one"
        )
    }

    /// The monitor has to consult it, **with the state**, or the decision above
    /// is not the one that runs: asking without the narrowing would make Escape
    /// either permanently dead or permanently swallowed.
    func test_the_key_monitor_asks_before_swallowing() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/App.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("addLocalMonitorForEvents"), "read the wrong file")
        XCTAssertTrue(
            text.contains("ShelfKey.isCollapsedStripCommand("),
            "the key monitor no longer asks which commands a collapsed strip answers, so it either swallows keys the strip ignores or never forwards the ones it needs"
        )
        XCTAssertTrue(
            text.contains("hasNarrowedSelection:"),
            "the monitor asks without saying whether the strip is narrowed, so Escape is answered the same way in both states — dead where it should clear, or swallowed where it should fall through"
        )
        XCTAssertTrue(
            text.contains("shelvesWithNarrowedSelection"),
            "nothing tells the monitor whether this shelf has a pick to clear, so the answer above is a constant"
        )
    }

    /// Every route through the whole-shelf states has to exist. Escape and a
    /// click on the header clear back to the quiet default; ⌘A selects every
    /// row explicitly so it remains visibly different.
    func test_every_route_through_the_whole_shelf_states_is_wired() throws {
        let text = magpieCodeOnly(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfContainerView.swift"),
            encoding: .utf8
        ))
        XCTAssertTrue(text.contains("CollapsedShelfView("), "read the wrong file")
        // The strip's exhaustive switch, matched on the cases it *ignores*.
        // `case .exit:` on its own is not enough: the expanded view in this
        // same file has one too, so that assertion passed while the strip had
        // dropped Escape back into the ignore list — a vacuous test, caught by
        // falsifying it.
        XCTAssertTrue(
            text.contains("case .activate, .ascend, .removeFromShelf, .quickLook:"),
            "the collapsed strip ignores Escape again, so the key the monitor now swallows for it is a dead key"
        )
        XCTAssertTrue(
            text.contains("onClearSelection: clearStripSelection"),
            "a click on the header or the empty panel does not clear the pick, so undoing an accidental click needs the keyboard"
        )
        XCTAssertTrue(
            text.contains("clearStripSelection()"),
            "the header and Escape no longer return the strip to its quiet whole-shelf default"
        )
        XCTAssertTrue(
            text.contains("selectAllStripSelection()"),
            "⌘A returns to the quiet default instead of keeping an explicit select-all visible"
        )
    }

    /// And the strip has to offer that click surface at all. A row's own
    /// `DragInitiatorView` consumes its clicks first, so this only ever fires
    /// on the header, the margins and the gap — which is exactly the intent.
    func test_the_strip_offers_a_click_target_that_clears_the_pick() throws {
        let text = magpieCodeOnly(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/CollapsedShelfView.swift"),
            encoding: .utf8
        ))
        XCTAssertTrue(text.contains("ShelfStripRow("), "read the wrong file")
        XCTAssertTrue(
            text.contains(".onTapGesture(perform: onClearSelection)"),
            "nothing on the strip itself answers a click outside a row, so the header the user is reading is not something they can click to go back"
        )
    }
}
