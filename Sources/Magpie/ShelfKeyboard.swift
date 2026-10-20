import AppKit
import Foundation

/// What a key press means, decided as pure arithmetic over numbers.
///
/// The two call sites are both untestable: `App.swift`'s local key monitor turns
/// an `NSEvent` into a `ShelfKey.Command` here, and `ExpandedShelfView` applies
/// that command using the arithmetic in `ShelfFocus`. Neither can be reached
/// from a unit test, which is exactly why every decision they make lives in this
/// file instead — the same shape as `EdgeSummonDetector.shouldSummon` and
/// `MagpieURL.parse`.
enum ShelfKey {

    /// Virtual key codes. Layout-independent, unlike `charactersIgnoringModifiers`,
    /// and the only handle on a key that produces no character at all.
    enum Code {
        static let `return`: UInt16 = 36
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    enum Direction: Equatable {
        case up, down, left, right
    }

    enum Command: Equatable {
        /// Arrow: move the focus cursor.
        case move(Direction)
        /// Shift-arrow: move it, and take everything it swept over into the selection.
        case extend(Direction)
        /// Space: select or deselect whatever is focused.
        case toggleSelection
        /// Return, ⌘↓: descend into the focused folder, or open the focused file —
        /// the same two branches a double-click already takes.
        case activate
        /// ⌘↑: back out of the folder being browsed.
        case ascend
        /// ⌫ / ⌦: take the focused row off the shelf. Never touches the file.
        case removeFromShelf
        /// ⌘⌫ / ⌘⌦: put the file itself in the Bin. The one command here that
        /// touches something the user owns, which is why it is the one that
        /// does not run from this file — it names `ShelfTrash` and nothing else
        /// (ADR 0017).
        case moveToTrash
        /// ⌘Y: Quick Look the focused item. Space is Quick Look for everyone who
        /// has not started navigating with the keyboard, so a keyboard user needs
        /// the other half of Finder's pair.
        case quickLook
        /// Escape: leave the folder, else collapse the shelf.
        case exit
    }

    /// `NSEvent.modifierFlags` on an arrow key also carries `.function` and
    /// `.numericPad`, and Caps Lock rides along on everything, so the raw flags
    /// can never be compared against a literal. Only these four mean anything here.
    static let significant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Pure: the command a key press means, or nil for "not ours — pass it on".
    /// Nil is load-bearing: the monitor only swallows an event it has a command
    /// for, so every key this model does not claim reaches the responder chain
    /// exactly as it did before there was a focus cursor.
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        let mods = modifiers.intersection(significant)

        if mods.isEmpty {
            switch keyCode {
            case Code.left: return .move(.left)
            case Code.right: return .move(.right)
            case Code.up: return .move(.up)
            case Code.down: return .move(.down)
            case Code.space: return .toggleSelection
            case Code.return, Code.keypadEnter: return .activate
            case Code.delete, Code.forwardDelete: return .removeFromShelf
            case Code.escape: return .exit
            default: return nil
            }
        }

        if mods == .shift {
            switch keyCode {
            case Code.left: return .extend(.left)
            case Code.right: return .extend(.right)
            case Code.up: return .extend(.up)
            case Code.down: return .extend(.down)
            default: return nil
            }
        }

        if mods == .command {
            switch keyCode {
            case Code.down: return .activate
            case Code.up: return .ascend
            // ⌘⌫ is Finder's Move to Bin, and it is bound here deliberately,
            // reversing an earlier decision recorded in this repo (ADR 0017).
            // That decision was that ⌘⌫ sits one thumb-slip from plain ⌫, the
            // most frequent key in the app. It still does. What changed is the
            // rest of the sentence: the slip costs a trip to the Bin, not a
            // file, because `ShelfTrash` moves it to the Bin rather than
            // deleting it, and ⌘Z
            // moves the file back out to where it was. The alternative was
            // leaving the app's most-wanted destructive action reachable only
            // through two levels of menu, which is its own kind of unsafe —
            // users who cannot find the supported way invent an unsupported
            // one.
            //
            // ⇧ stays unbound on purpose: in Finder that is Empty Bin, which
            // is the one thing here that would not be recoverable.
            case Code.delete, Code.forwardDelete: return .moveToTrash
            default: return nil
            }
        }

        return nil
    }

    /// Which commands the **collapsed strip** answers.
    ///
    /// The monitor swallows every command it forwards, so forwarding one the
    /// strip does not implement turns a live key into a silent dead one — the
    /// exact failure this repo has already shipped (a shortcut that was dead for
    /// a whole release because nothing asked whether it worked from the state
    /// the app is actually in). The strip is a selection surface and nothing
    /// more: it moves a cursor, extends and toggles a selection, and leaves
    /// Return, ⌫, ⌘↑ and ⌘Y to behave exactly as they did before it had a
    /// keyboard at all.
    ///
    /// **Escape is the one command whose answer depends on state.** The strip
    /// is quiet at rest and says what a drag will take in its header, so the
    /// way back from `1 of 5` to `5 Files` has to be obvious and forgiving —
    /// Escape is half of it (a click on the panel is the other half). But a
    /// strip nobody has narrowed has nothing to undo, and swallowing the key
    /// there would make Escape dead in the state a shelf spends most of its
    /// life in. So it is claimed only when there is a pick to clear, and falls
    /// through untouched otherwise.
    ///
    /// Exhaustive on purpose: a new command cannot be added without answering
    /// this question for it.
    static func isCollapsedStripCommand(
        _ command: Command,
        hasNarrowedSelection: Bool = false
    ) -> Bool {
        switch command {
        case .move, .extend, .toggleSelection:
            return true
        case .exit:
            return hasNarrowedSelection
        // ⌘⌫ is answered here and it has to be. The strip is the state a shelf
        // spends most of its life in — a file dropped on the desktop, touched,
        // and then unwanted is looked at as a pill, never as an expanded panel
        // — so a Move to Bin that only worked when expanded would be dead in
        // the state the user is actually in. That is the exact failure this
        // repo has already shipped once, and the reason this switch is
        // exhaustive.
        //
        // It needs no narrowed selection and no focus cursor: with nothing
        // picked the subject is the whole shelf, which is what the header says
        // and what the menu row does (ADR 0012, ADR 0014).
        case .moveToTrash:
            return true
        case .activate, .ascend, .removeFromShelf, .quickLook:
            return false
        }
    }

    /// Escape, while a drop is still landing, stops the drop.
    ///
    /// Its own decision rather than a case inside `command` because the answer
    /// has to be reachable from the state the shelf is *actually* in when files
    /// are arriving. `command`'s `.exit` is only ever consulted for an expanded
    /// panel, and a drop almost always lands on a collapsed pill — wiring the
    /// cancel there would have shipped a key that does nothing, which is the
    /// exact failure this repo has already paid for once.
    static func cancelsIngest(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isIngesting: Bool
    ) -> Bool {
        guard isIngesting, keyCode == Code.escape else { return false }
        return modifiers.intersection(significant).isEmpty
    }
}

/// One parsed key press, addressed to the shelf whose panel was key when it
/// arrived. The monitor decides only *which* command a press is; the expanded
/// view owns the cursor and the selection and decides what it does.
struct KeyCommandRequest {
    let shelfID: UUID
    let command: ShelfKey.Command
}

/// Where the focus cursor goes, given only numbers.
enum ShelfFocus {

    /// How many cards `LazyVGrid(columns: [.adaptive(minimum:maximum:spacing:)])`
    /// fits across `availableWidth`. Derived rather than hardcoded, because the
    /// grid is adaptive: the count changes with the panel's width, and ↓ has to
    /// move by exactly one row or it moves by the wrong number of cards.
    ///
    /// SwiftUI packs the largest `n` satisfying
    /// `n * minimum + (n - 1) * spacing <= availableWidth`.
    static func columnCount(
        availableWidth: CGFloat,
        minimum: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard availableWidth > 0, minimum > 0 else { return 1 }
        let fitted = Int(floor((availableWidth + spacing) / (minimum + spacing)))
        return max(1, fitted)
    }

    /// Pure: the index the cursor lands on, or nil when there is nothing to
    /// focus. `columns` is 1 in list mode and in the folder list, which makes
    /// ↑/↓ move by one row there without a second code path.
    static func move(
        _ direction: ShelfKey.Direction,
        from focus: Int?,
        count: Int,
        columns: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        let cols = max(1, columns)

        guard let focus, focus >= 0, focus < count else {
            // No cursor yet, or a stale one left over from a shorter shelf.
            // The key points somewhere, so start at the end it points from.
            switch direction {
            case .down, .right: return 0
            case .up, .left: return count - 1
            }
        }

        switch direction {
        case .left:
            return max(0, focus - 1)
        case .right:
            return min(count - 1, focus + 1)
        case .up:
            let target = focus - cols
            return target >= 0 ? target : focus
        case .down:
            let target = focus + cols
            if target < count { return target }
            // Ragged last row: ↓ from the row above lands on the last card
            // rather than refusing to move, so the bottom row is always
            // reachable. Already on the last row, the cursor stays put.
            let lastRow = (count - 1) / cols
            return (focus / cols) < lastRow ? count - 1 : focus
        }
    }

    /// Pure: the selection after a shift-arrow. Everything the cursor swept
    /// over, not just the two ends — one ⇧↓ in a grid crosses a whole row, and
    /// adding only the far end would select two cards and skip four.
    static func extendedSelection(
        _ selected: Set<Int>,
        from oldFocus: Int?,
        to newFocus: Int
    ) -> Set<Int> {
        var result = selected
        guard let oldFocus, oldFocus != newFocus else {
            result.insert(newFocus)
            return result
        }
        for index in min(oldFocus, newFocus)...max(oldFocus, newFocus) {
            result.insert(index)
        }
        return result
    }
}

/// ⌫, as its own named function so the invariant can be tested on the exact
/// code the key runs.
///
/// **Removing from the shelf is a row removal and never touches the file on
/// disk.** ADR 0001: the only path allowed to touch a user file is a
/// user-initiated Move to Trash, and this is not it. `ShelfKeyboardInvariantTests`
/// pins both halves — that a real file survives this call, and that no file on
/// the keyboard path names a mutating `FileManager` call.
///
/// It also captures an undo snapshot, which `ShelfManager.removeItem` does not
/// do on its own. A key that makes cards vanish needs ⌘Z behind it; the pointer
/// paths through `removeItem` are left exactly as they were.
@MainActor
enum ShelfKeyboardRemove {
    static func removeFromShelf(items: [ShelfItem], in shelfID: UUID, manager: ShelfManager) {
        guard !items.isEmpty else { return }
        manager.captureRemoveUndo(items: items, in: shelfID)
        for item in items {
            manager.removeItem(id: item.id, from: shelfID)
        }
    }
}
