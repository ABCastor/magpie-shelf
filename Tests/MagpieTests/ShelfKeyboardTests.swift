import AppKit
import XCTest
@testable import Magpie

/// The keyboard model, tested where it actually decides things. Both of its
/// call sites — the local key monitor in `App.swift` and `ExpandedShelfView`'s
/// command handler — are unreachable from a unit test, which is the whole
/// reason the arithmetic was extracted into `ShelfKey` and `ShelfFocus`.
final class ShelfKeyboardTests: XCTestCase {

    // MARK: - Parsing a key press

    func test_bare_arrows_move_the_cursor() {
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.left, modifiers: []), .move(.left))
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.right, modifiers: []), .move(.right))
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.up, modifiers: []), .move(.up))
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: []), .move(.down))
    }

    /// AppKit puts `.function` and `.numericPad` on every arrow key and Caps
    /// Lock on everything. Comparing the raw flags against a literal would make
    /// the whole arrow-key model dead on arrival, which is why the parser masks.
    func test_arrows_still_parse_under_the_flags_appkit_always_adds() {
        let asDelivered: NSEvent.ModifierFlags = [.function, .numericPad, .capsLock]
        XCTAssertEqual(
            ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: asDelivered),
            .move(.down)
        )
        XCTAssertEqual(
            ShelfKey.command(keyCode: ShelfKey.Code.up, modifiers: [.shift, .function, .numericPad]),
            .extend(.up)
        )
    }

    func test_shift_arrows_extend() {
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: .shift), .extend(.down))
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.left, modifiers: .shift), .extend(.left))
    }

    func test_the_unmodified_action_keys() {
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.space, modifiers: []), .toggleSelection)
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.return, modifiers: []), .activate)
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.keypadEnter, modifiers: []), .activate)
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.escape, modifiers: []), .exit)
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.delete, modifiers: []), .removeFromShelf)
        XCTAssertEqual(
            ShelfKey.command(keyCode: ShelfKey.Code.forwardDelete, modifiers: []),
            .removeFromShelf
        )
    }

    func test_command_arrows_are_the_finder_open_and_back_pair() {
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: .command), .activate)
        XCTAssertEqual(ShelfKey.command(keyCode: ShelfKey.Code.up, modifiers: .command), .ascend)
    }

    /// Nil is load-bearing: the monitor only swallows an event it has a command
    /// for, so anything this model does not claim reaches the responder chain
    /// exactly as it did before there was a focus cursor.
    func test_unclaimed_presses_return_nil_so_the_monitor_passes_them_on() {
        // ⌥ and ⌃ arrows belong to text navigation, not to us.
        XCTAssertNil(ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: .option))
        XCTAssertNil(ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: .control))
        XCTAssertNil(ShelfKey.command(keyCode: ShelfKey.Code.down, modifiers: [.command, .shift]))
        // ⌘Space is Spotlight. (⌘⌫ *is* claimed now — Move to Bin, ADR 0017 —
        // so it is asserted in ShelfKeyboardInvariantTests rather than here.)
        XCTAssertNil(ShelfKey.command(keyCode: ShelfKey.Code.space, modifiers: .command))
        XCTAssertNil(ShelfKey.command(keyCode: ShelfKey.Code.return, modifiers: .command))
        XCTAssertNil(ShelfKey.command(keyCode: ShelfKey.Code.escape, modifiers: .command))
        // A letter: the ⌘ branch of the monitor handles those by character.
        XCTAssertNil(ShelfKey.command(keyCode: 40, modifiers: .command))
    }

    // MARK: - Column count

    /// The grid is `.adaptive(minimum: 96, maximum: 116)` at a 16pt gutter, so
    /// the count is a function of the panel's width and has to be derived, not
    /// written down: a wrong count makes ↓ move by the wrong number of cards.
    func test_column_count_matches_what_an_adaptive_grid_packs() {
        // n * 96 + (n - 1) * 16 <= width
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 96, minimum: 96, spacing: 16), 1)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 207, minimum: 96, spacing: 16), 1)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 208, minimum: 96, spacing: 16), 2)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 319, minimum: 96, spacing: 16), 2)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 320, minimum: 96, spacing: 16), 3)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 480, minimum: 96, spacing: 16), 4)
    }

    /// A width of zero is what the measurement reports for exactly one frame,
    /// before the geometry reader has run. One column is the safe answer —
    /// ↓ moves by one card instead of by nothing.
    func test_column_count_never_returns_zero() {
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 0, minimum: 96, spacing: 16), 1)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 40, minimum: 96, spacing: 16), 1)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: -10, minimum: 96, spacing: 16), 1)
        XCTAssertEqual(ShelfFocus.columnCount(availableWidth: 400, minimum: 0, spacing: 16), 1)
    }

    // MARK: - Moving the cursor

    func test_an_empty_shelf_has_nowhere_to_focus() {
        for direction in [ShelfKey.Direction.up, .down, .left, .right] {
            XCTAssertNil(ShelfFocus.move(direction, from: nil, count: 0, columns: 3))
            XCTAssertNil(ShelfFocus.move(direction, from: 2, count: 0, columns: 3))
        }
    }

    func test_first_arrow_starts_at_the_end_the_key_points_from() {
        XCTAssertEqual(ShelfFocus.move(.down, from: nil, count: 7, columns: 3), 0)
        XCTAssertEqual(ShelfFocus.move(.right, from: nil, count: 7, columns: 3), 0)
        XCTAssertEqual(ShelfFocus.move(.up, from: nil, count: 7, columns: 3), 6)
        XCTAssertEqual(ShelfFocus.move(.left, from: nil, count: 7, columns: 3), 6)
    }

    /// A cursor left over from a longer shelf is treated as no cursor at all
    /// rather than clamped, because clamping would land it somewhere the user
    /// never put it.
    func test_a_stale_out_of_range_cursor_restarts(){
        XCTAssertEqual(ShelfFocus.move(.down, from: 99, count: 4, columns: 2), 0)
        XCTAssertEqual(ShelfFocus.move(.up, from: -3, count: 4, columns: 2), 3)
    }

    func test_left_and_right_walk_the_flat_order_and_stop_at_the_ends() {
        XCTAssertEqual(ShelfFocus.move(.right, from: 0, count: 7, columns: 3), 1)
        XCTAssertEqual(ShelfFocus.move(.left, from: 4, count: 7, columns: 3), 3)
        XCTAssertEqual(ShelfFocus.move(.left, from: 0, count: 7, columns: 3), 0)
        XCTAssertEqual(ShelfFocus.move(.right, from: 6, count: 7, columns: 3), 6)
    }

    /// Three columns, seven cards: rows are [0 1 2] [3 4 5] [6].
    func test_up_from_the_first_row_stays_put() {
        XCTAssertEqual(ShelfFocus.move(.up, from: 0, count: 7, columns: 3), 0)
        XCTAssertEqual(ShelfFocus.move(.up, from: 1, count: 7, columns: 3), 1)
        XCTAssertEqual(ShelfFocus.move(.up, from: 2, count: 7, columns: 3), 2)
    }

    func test_down_and_up_move_by_exactly_one_row() {
        XCTAssertEqual(ShelfFocus.move(.down, from: 1, count: 9, columns: 3), 4)
        XCTAssertEqual(ShelfFocus.move(.down, from: 4, count: 9, columns: 3), 7)
        XCTAssertEqual(ShelfFocus.move(.up, from: 7, count: 9, columns: 3), 4)
        XCTAssertEqual(ShelfFocus.move(.up, from: 4, count: 9, columns: 3), 1)
    }

    /// The ragged last row is the case that gets written wrong. Rows are
    /// [0 1 2] [3 4 5] [6]: ↓ from 4 has no card under it, and refusing to move
    /// would make the last row unreachable from column 1 or 2.
    func test_down_into_a_ragged_last_row_lands_on_the_last_card() {
        XCTAssertEqual(ShelfFocus.move(.down, from: 4, count: 7, columns: 3), 6)
        XCTAssertEqual(ShelfFocus.move(.down, from: 5, count: 7, columns: 3), 6)
        // Already on the last row, there is nowhere below to go.
        XCTAssertEqual(ShelfFocus.move(.down, from: 6, count: 7, columns: 3), 6)
    }

    func test_down_from_the_last_full_row_stays_put_when_the_grid_is_rectangular() {
        // Rows are [0 1 2] [3 4 5], nothing ragged about it.
        XCTAssertEqual(ShelfFocus.move(.down, from: 3, count: 6, columns: 3), 3)
        XCTAssertEqual(ShelfFocus.move(.down, from: 5, count: 6, columns: 3), 5)
    }

    /// The list view, and the folder list. One column means ↑/↓ are ±1 with no
    /// second code path.
    func test_a_single_column_makes_up_and_down_move_one_at_a_time() {
        XCTAssertEqual(ShelfFocus.move(.down, from: 0, count: 4, columns: 1), 1)
        XCTAssertEqual(ShelfFocus.move(.down, from: 3, count: 4, columns: 1), 3)
        XCTAssertEqual(ShelfFocus.move(.up, from: 3, count: 4, columns: 1), 2)
        XCTAssertEqual(ShelfFocus.move(.up, from: 0, count: 4, columns: 1), 0)
    }

    func test_a_nonsense_column_count_is_treated_as_one() {
        XCTAssertEqual(ShelfFocus.move(.down, from: 0, count: 4, columns: 0), 1)
        XCTAssertEqual(ShelfFocus.move(.down, from: 0, count: 4, columns: -5), 1)
    }

    func test_a_single_card_shelf_never_moves() {
        for direction in [ShelfKey.Direction.up, .down, .left, .right] {
            XCTAssertEqual(ShelfFocus.move(direction, from: 0, count: 1, columns: 3), 0)
        }
    }

    // MARK: - Extending the selection

    /// One ⇧↓ in a grid crosses a whole row. Adding only the far end would
    /// select two cards and skip the four in between.
    func test_shift_arrow_takes_everything_the_cursor_swept_over() {
        let extended = ShelfFocus.extendedSelection([], from: 1, to: 4)
        XCTAssertEqual(extended, [1, 2, 3, 4])
    }

    func test_extending_upwards_covers_the_same_range() {
        XCTAssertEqual(ShelfFocus.extendedSelection([], from: 4, to: 1), [1, 2, 3, 4])
    }

    func test_extending_keeps_what_was_already_selected() {
        XCTAssertEqual(ShelfFocus.extendedSelection([9], from: 0, to: 2), [0, 1, 2, 9])
    }

    func test_extending_with_no_cursor_yet_selects_only_the_landing_card() {
        XCTAssertEqual(ShelfFocus.extendedSelection([], from: nil, to: 3), [3])
    }

    /// ⇧↓ against the bottom edge does not move the cursor, and must still put
    /// the card it is sitting on into the selection rather than doing nothing.
    func test_extending_onto_the_cursors_own_card_still_selects_it() {
        XCTAssertEqual(ShelfFocus.extendedSelection([], from: 5, to: 5), [5])
    }
}
