import AppKit
import Foundation

/// What a drag off the collapsed strip will take, and how a click changes it.
///
/// The strip used to be one drag surface: a drag off any row carried the whole
/// shelf, which was invisible while the shelf was drawn as a single stack of
/// paper and obviously wrong the moment ADR 0010 drew one row per file. This is
/// the model that replaces it, and every rule in it is pure over ids — the
/// AppKit side of a click (`DragInitiatorView.mouseUp`) and the SwiftUI side of
/// a row cannot be reached from a unit test, so neither of them decides
/// anything.
///
/// **The empty set means the whole shelf.** A shelf's premise is that it holds a
/// set (ADR 0007), so taking the set has to stay the effortless default. There
/// is deliberately no state in which the strip would drag nothing: deselecting
/// the last row, or removing the last selected file, returns the shelf to its
/// default.
///
/// **What says so is the header, in words, not a wall of highlighted rows.**
/// ADR 0012 first drew every row selected at rest, on the argument that an
/// unhighlighted strip cannot show what a drag takes. The owner rejected the
/// result — five files were five solid bars of accent — and asked the question
/// that actually matters: *"if they are not highlighted and I click on one,
/// will it carry just that outside or will it carry all of them?"* So the claim
/// moved to `Claim`, which the header states as `5 Files` or `1 of 5`, and the
/// fill moved to `highlighted` — nothing at rest, the carried set for the
/// length of a drag. All three are derived from `effective`, which is what
/// `beginDrag` is defined in terms of, so the sentence on screen and the
/// payload of a drag are one answer read twice.
enum ShelfSelection {

    /// The default: no explicit narrowing, which *is* the whole shelf.
    static let wholeShelf: Set<UUID> = []

    /// What a drag will take right now, as counts — the thing the header says
    /// out loud so the user never has to infer it from a highlight.
    struct Claim: Equatable {
        /// How many files a drag off a picked row carries.
        let carried: Int
        /// How many files are on the shelf.
        let total: Int
        /// Whether a live explicit pick exists. A full explicit set is
        /// intentionally different from the untouched empty set: both carry
        /// the whole shelf, but only the former should read as selected.
        let isExplicit: Bool

        /// Nothing has been picked out, so a drag takes the set. The quiet
        /// state: no row is filled, and the header names the shelf rather than
        /// a fraction of it.
        var isWholeShelf: Bool { carried == total }
    }

    /// The claim, derived from the same `effective` that decides the payload.
    /// One function, so the header cannot state a number a drag would not
    /// honour.
    static func claim(explicit: Set<UUID>, ids: [UUID]) -> Claim {
        Claim(
            carried: effective(explicit: explicit, ids: ids).count,
            total: ids.count,
            isExplicit: !explicit.intersection(ids).isEmpty
        )
    }

    /// The rows that wear a selection fill.
    ///
    /// **At rest this is only what the user explicitly picked, and the default
    /// is nothing.** The whole-shelf state draws no fill at all, because the
    /// header already says `5 Files` in words and a column of solid accent bars
    /// says the same thing far louder.
    ///
    /// **While a drag is in flight it is the set being carried**, which is the
    /// one moment a highlight earns its noise: it happens before the drop, so a
    /// user who sees the wrong files light up can still abort.
    static func highlighted(explicit: Set<UUID>, ids: [UUID], isDragging: Bool) -> Set<UUID> {
        isDragging ? effective(explicit: explicit, ids: ids) : explicit.intersection(ids)
    }

    /// The explicit selection after a click, and where a later ⇧-click counts
    /// from.
    struct Outcome: Equatable {
        let selection: Set<UUID>
        let anchor: UUID?
    }

    /// What a drag starting on one row carries, and the selection it leaves
    /// behind. Both come out of one call so the picture and the payload cannot
    /// be computed from different rules.
    struct DragStart: Equatable {
        let selection: Set<UUID>
        let dragged: Set<UUID>
    }

    /// What is actually selected right now, in ids that still exist.
    ///
    /// Stale ids are dropped rather than carried: a file taken off the shelf
    /// must not keep a place in the set. If that leaves nothing explicit, the
    /// answer is the whole shelf — the same rule as an untouched strip.
    static func effective(explicit: Set<UUID>, ids: [UUID]) -> Set<UUID> {
        let live = explicit.intersection(ids)
        return live.isEmpty ? Set(ids) : live
    }

    /// The subject of an expanded browser item menu.
    ///
    /// This is deliberately not `effective`: unlike the collapsed strip, an
    /// expanded browser has a real "nothing selected" state, and a right-click
    /// outside the selection must not promote that click to the whole shelf.
    /// Finder's rule is the useful one here: a right-click inside a selection
    /// keeps the selection; a right-click outside it acts on that item alone.
    static func itemMenuSubject(
        rightClicked itemID: UUID,
        explicit: Set<UUID>,
        items: [ShelfItem]
    ) -> [ShelfItem] {
        guard explicit.contains(itemID) else {
            return items.first { $0.id == itemID }.map { [$0] } ?? []
        }
        let selected = items.filter { explicit.contains($0.id) }
        return selected.isEmpty
            ? (items.first { $0.id == itemID }.map { [$0] } ?? [])
            : selected
    }

    /// **The files an action operates on.** One door, so that every surface the
    /// strip offers answers to the sentence in its header.
    ///
    /// The header, the drag and ⌘C were already three readings of `effective`.
    /// The strip's context menu was not: it read `manager.items(of:)` and so,
    /// with `1 of 5` on screen, its **Move to Trash** recycled five of the
    /// user's files (ADR 0013 recorded it as owed; ADR 0014 pays it). Anything
    /// that acts on a set resolves that set here instead, so a row that says
    /// "Move 3 Files to Trash" cannot hand five paths to `NSWorkspace.recycle`.
    ///
    /// Order is the caller's own, untouched: this narrows a set, it does not
    /// reorder one. The shelf menu's rows are built from storage order and the
    /// display-ordered surfaces pass display order in — both keep what they had.
    static func carried(_ items: [ShelfItem], explicit: Set<UUID>) -> [ShelfItem] {
        let live = effective(explicit: explicit, ids: items.map(\.id))
        return items.filter { live.contains($0.id) }
    }

    /// The empty set is reserved for the implicit whole-shelf default; a full
    /// explicit set must survive so the user can see that they deliberately
    /// selected every row.
    static func narrowed(to selection: Set<UUID>, ids: [UUID]) -> Set<UUID> {
        let live = selection.intersection(ids)
        if live.isEmpty { return wholeShelf }
        return live
    }

    /// The standard macOS list contract: a plain click narrows to one row,
    /// ⇧-click extends a range from the anchor, ⌘-click toggles one row.
    ///
    /// ⌘ is read before ⇧ because a toggle is the more specific request. ⌥ and
    /// Caps Lock fall through to a plain click — selecting is the harmless
    /// reading of an ambiguous modifier.
    ///
    /// **⌃ is not ambiguous and is read first.** On macOS a ⌃-click *is* the
    /// secondary click, so it belongs to the context menu and must leave the
    /// selection exactly as it found it. It used to fall through to a plain
    /// click here, which meant a user reaching for the menu also silently threw
    /// away everything they had picked. `CellClick.intent` stops one arriving
    /// from the pointer; this is the same rule where every other selection rule
    /// is written down, so neither path can drift from the other.
    static func click(
        id: UUID,
        modifiers: NSEvent.ModifierFlags,
        explicit: Set<UUID>,
        anchor: UUID?,
        ids: [UUID]
    ) -> Outcome {
        guard ids.contains(id) else { return Outcome(selection: explicit, anchor: anchor) }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control) {
            return Outcome(selection: explicit, anchor: anchor)
        }

        if flags.contains(.command) {
            var next = effective(explicit: explicit, ids: ids)
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            return Outcome(selection: narrowed(to: next, ids: ids), anchor: id)
        }

        if flags.contains(.shift) {
            // No anchor yet — the top row is where a range counts from, the
            // same place Finder starts one in a fresh list.
            let from = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            guard
                let from,
                let start = ids.firstIndex(of: from),
                let end = ids.firstIndex(of: id)
            else {
                return Outcome(selection: narrowed(to: [id], ids: ids), anchor: id)
            }
            let range = Set(ids[min(start, end)...max(start, end)])
            return Outcome(selection: narrowed(to: range, ids: ids), anchor: from)
        }

        return Outcome(selection: narrowed(to: [id], ids: ids), anchor: id)
    }

    /// The space bar over the keyboard cursor. The same thing a ⌘-click does,
    /// named for what the key means rather than for the modifier it borrows —
    /// so the two paths share the rule without the keyboard having to pretend
    /// it is a mouse.
    static func toggle(id: UUID, explicit: Set<UUID>, anchor: UUID?, ids: [UUID]) -> Outcome {
        click(id: id, modifiers: .command, explicit: explicit, anchor: anchor, ids: ids)
    }

    /// Finder's drag rule, and the whole of the owner's report: a drag that
    /// starts on a **selected** row carries the selection, and a drag that
    /// starts anywhere else narrows to that row first and carries only it.
    ///
    /// With no explicit narrowing every row is in the effective set, so the
    /// default drag still takes the whole shelf — which is what a shelf is for,
    /// and what the header says in words rather than in colour.
    static func beginDrag(from id: UUID, explicit: Set<UUID>, ids: [UUID]) -> DragStart {
        guard ids.contains(id) else {
            return DragStart(selection: explicit, dragged: [])
        }
        let current = effective(explicit: explicit, ids: ids)
        if current.contains(id) {
            return DragStart(selection: explicit, dragged: current)
        }
        return DragStart(selection: narrowed(to: [id], ids: ids), dragged: [id])
    }
}

/// The one sentence in the collapsed strip's header, and the only thing in the
/// app that says what a drag off the strip will take.
///
/// The strip is quiet at rest, so this line is not decoration: it is the answer
/// to *"if I click one row, will a drag carry that one or all of them?"*,
/// written on screen at all times in a place that already existed. `5 Files`
/// means a drag takes five. `1 of 5` means it takes one. There is no third
/// reading, and no state in which the user has to work it out from what is or
/// is not highlighted.
///
/// A named shelf keeps its name while nothing is picked, because the name says
/// which shelf this is and the rows below it are all of it — nothing is
/// withheld. The moment something *is* picked the name gives way to the count,
/// because that is the moment the rows on screen and the files that would
/// travel stop being the same set, and only this line can say so.
enum ShelfStripHeader {
    static func title(name: String?, claim: ShelfSelection.Claim) -> String {
        if claim.isExplicit {
            return String(format: L("selection.of-total"), claim.carried, claim.total)
        }
        if let name, !name.isEmpty { return name }
        if claim.total == 0 { return L("shelf.default-name") }
        return claim.total == 1
            ? L("1 File")
            : String(format: L("%lld Files"), claim.total)
    }
}
