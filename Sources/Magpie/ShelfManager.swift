import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfManager: ObservableObject {
    @Published private(set) var shelves: [Shelf]
    @Published private(set) var currentShelfID: UUID?
    @Published var isDragging: Bool = false
    /// True while *any* visible shelf panel is currently being targeted by
    /// an in-flight drop. Used by the status item to swap its icon glyph.
    @Published private(set) var isAnyShelfDropTarget: Bool = false

    /// Which shelves a drop is hovering over right now. Published so the
    /// magpie on that shelf can lean in, curious.
    @Published private(set) var dropTargetedShelfIDs: Set<UUID> = []

    /// Shelves whose X was pressed and whose magpie is on its way to bite it:
    /// the strip hides its X the moment the beak takes it.
    @Published var shelvesBeingClosed: Set<UUID> = []

    /// Shelves open as an island under the notch, with the height of the
    /// notch band their content must stay below.
    @Published var islandInsets: [UUID: CGFloat] = [:]

    func setDropTargeted(shelfID: UUID, _ targeted: Bool) {
        if targeted {
            dropTargetedShelfIDs.insert(shelfID)
        } else {
            dropTargetedShelfIDs.remove(shelfID)
        }
        let any = !dropTargetedShelfIDs.isEmpty
        if isAnyShelfDropTarget != any { isAnyShelfDropTarget = any }
    }

    // Emits the shelfID that rejected a duplicate file/folder.
    let duplicateRejected = PassthroughSubject<UUID, Never>()
    // Emits the shelfID whose clipboard import was declined because the
    // pasteboard is flagged concealed (a password manager's copy). Every
    // import is a deliberate user action, so declining silently would read
    // as a broken app.
    let concealedClipboardRejected = PassthroughSubject<UUID, Never>()
    // Emits the shelfID when a docked panel was dragged away from the edge
    // and should revert to collapsed state in-place.
    let undockRequested = PassthroughSubject<UUID, Never>()
    // Emits the key shelfID when Cmd-A is pressed in its panel; the
    // expanded view picks this up to select every shelf-root item.
    let selectAllRequested = PassthroughSubject<UUID, Never>()
    // Emits the key shelfID when Cmd-C is pressed in its panel; the
    // expanded view writes the current selection (root or folder) to
    // the pasteboard.
    let copyRequested = PassthroughSubject<UUID, Never>()
    // Emits a shelfID when the AppDelegate wants the corresponding panel
    // to collapse from its expanded state back to the pill view (e.g. on
    // an outside click when the close-on-outside-click setting is on).
    let collapseRequested = PassthroughSubject<UUID, Never>()

    /// A shelf asking to be dismissed outright, not merely collapsed to its
    /// pill. Sent when a drag out empties a shelf and the user has asked for
    /// that to close it; answered by `AppDelegate`, which owns the panels.
    let closeRequested = PassthroughSubject<UUID, Never>()
    // Emits a key press the app-level monitor has already parsed into a
    // command. The monitor decides only *which* command a press is; the
    // expanded view owns the focus cursor and the selection and decides what
    // it does — the same request/response shape as selectAllRequested.
    let keyCommandRequested = PassthroughSubject<KeyCommandRequest, Never>()
    // Emits the key shelfID on ⌘K, so its expanded view opens the palette.
    let paletteRequested = PassthroughSubject<UUID, Never>()

    /// Shelves whose expanded view currently shows a keyboard focus cursor.
    ///
    /// Read by the key monitor and never rendered from, so deliberately not
    /// `@Published`: the space bar has to keep reaching Quick Look untouched
    /// for anyone who has not started navigating with the keyboard, and whether
    /// a cursor exists is the only way to tell those two users apart.
    var shelvesWithKeyboardFocus: Set<UUID> = []

    /// What the user has picked out on each **visible collapsed strip**, keyed
    /// by shelf. An entry exists only while a strip is on screen and narrowed;
    /// no entry means the whole shelf, which is the same reading `effective`
    /// gives an empty set (ADR 0012).
    ///
    /// It is here because the strip's selection is `@State` inside a view, and
    /// two things outside that view have to know it: the key monitor, which
    /// must not swallow Escape on a strip with nothing to clear, and the app
    /// delegate's Quick Look provider, which previewed the whole shelf while
    /// the header read `1 of 5` (ADR 0014). Not `@Published` for the same
    /// reason as the set above — nothing renders from it.
    var stripSelections: [UUID: Set<UUID>] = [:]

    /// Collapsed strips the user has narrowed to a subset of their rows — the
    /// only state in which Escape has anything to undo.
    ///
    /// Derived rather than stored, so "there is a pick here" and "the pick is
    /// this" can never disagree. Read by the key monitor, with the same
    /// consequence if it is wrong: swallowing Escape on a resting strip would
    /// turn a live key into a silent dead one, which is a failure this repo has
    /// already shipped once.
    var shelvesWithNarrowedSelection: Set<UUID> { Set(stripSelections.keys) }

    private let store: ShelfStore
    private let loadedStoreIsAuthoritative: Bool

    /// What the load made of the store on disk, so something can finally say it
    /// to the user. Read-only and separate from `loadedStoreIsAuthoritative`,
    /// which stays the sole input to the fail-closed eviction guard below.
    let loadOutcome: ShelfStore.LoadOutcome

    private var cancellables = Set<AnyCancellable>()

    init(store: ShelfStore = ShelfStore()) {
        self.store = store
        let loaded = store.load()
        self.loadedStoreIsAuthoritative = loaded.isAuthoritative
        self.loadOutcome = loaded.outcome
        self.shelves = loaded.shelves.isEmpty ? [Shelf()] : loaded.shelves
        self.currentShelfID = loaded.currentShelfID.flatMap { loadedID in
            shelves.contains(where: { $0.id == loadedID }) ? loadedID : nil
        } ?? shelves.last?.id
        evictManagedCacheIfNeeded()

        for shelf in shelves {
            for item in shelf.items {
                // Text snippets render their preview from `textContent`; a QL
                // thumbnail would just be the system .txt icon and would replace
                // the snippet preview, so skip them.
                if item.type == .text { continue }
                if let url = item.fileURL {
                    if item.isDirectory {
                        recomputeFolderSize(itemID: item.id, in: shelf.id)
                    } else {
                        requestThumbnail(for: url, replacing: item.id)
                    }
                }
            }
        }

        $shelves.combineLatest($currentShelfID)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] shelves, currentShelfID in
                self?.store.save(shelves: shelves, currentShelfID: currentShelfID)
            }
            .store(in: &cancellables)
    }

    func flushPendingSave() {
        store.save(shelves: shelves, currentShelfID: currentShelfID)
    }

    // MARK: - Queries

    func shelf(id: UUID) -> Shelf? {
        shelves.first { $0.id == id }
    }

    func items(of shelfID: UUID) -> [ShelfItem] {
        shelf(id: shelfID)?.items ?? []
    }

    /// **What an action on this shelf operates on**, given what the user picked.
    /// The whole shelf when nothing is picked; exactly the pick otherwise.
    func carriedItems(of shelfID: UUID, selection: Set<UUID>) -> [ShelfItem] {
        ShelfSelection.carried(items(of: shelfID), explicit: selection)
    }

    /// The same answer for a surface that cannot see the strip's `@State`.
    ///
    /// Quick Look is the one that needs it: the space bar and ⌘Y reach
    /// `QuickLookController` through the responder chain, and its URL provider
    /// lives on the app delegate, which has no view to ask. It previewed the
    /// whole shelf over a header reading `1 of 5` — harmless, and the same lie
    /// the context menu was telling with the user's files at stake.
    func carriedItemsOnStrip(of shelfID: UUID) -> [ShelfItem] {
        carriedItems(
            of: shelfID,
            selection: stripSelections[shelfID] ?? ShelfSelection.wholeShelf
        )
    }

    /// Exposed so a caller can tell a Magpie cache copy from a real user file,
    /// and can site its own app-owned directory beside it.
    var managedFilesDirectory: URL { store.managedFilesDirectory }

    /// Where Magpie keeps its files. Revealed from Settings.
    var storeDirectory: URL { store.directory }

    func containsFile(url: URL, in shelfID: UUID) -> Bool {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        return items(of: shelfID).contains { item in
            guard let existing = item.fileURL else { return false }
            return existing.resolvingSymlinksInPath().standardizedFileURL.path == key
        }
    }

    func totalBytes(of shelfID: UUID) -> Int64 {
        items(of: shelfID).reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    func displayTotalSize(of shelfID: UUID) -> String {
        let total = totalBytes(of: shelfID)
        guard total > 0 else { return "—" }
        return ShelfItem.format(bytes: total)
    }

    // MARK: - Shelves

    @discardableResult
    func createShelf() -> UUID {
        let shelf = Shelf()
        shelves.append(shelf)
        currentShelfID = shelf.id
        return shelf.id
    }

    func removeShelf(id: UUID) {
        shelves.removeAll { $0.id == id }
        // A snapshot restores into its own shelf, so once that shelf is gone
        // the entry can never land — keeping it leaves ⌘Z enabled and titled
        // for an undo that silently does nothing. `.removeShelves` entries
        // survive on purpose: they restore the shelves themselves, so they
        // depend on no live shelf.
        undoStack.removeAll { $0.restoresIntoShelfID == id }
        if currentShelfID == id { currentShelfID = shelves.last?.id }
    }

    /// "Clear Recent Shelves": removes every unpinned shelf and records ONE
    /// undo entry that puts them all back — shelves, items, names, accents.
    /// Returns the removed IDs so the caller can close their panels.
    ///
    /// This is the honest form of undo across shelf removal: per-item entries
    /// restore INTO a shelf and die with it (see `removeShelf`), but a
    /// whole-shelf snapshot restores the shelf itself, so ⌘Z after a bulk
    /// clear does exactly what its menu title says. Nothing here touches
    /// disk — shelves hold references and managed copies (ADR 0001).
    @discardableResult
    func clearAllUnpinnedShelvesUndoably() -> [UUID] {
        let removed = shelves.filter { !$0.pinned }
        guard !removed.isEmpty else { return [] }
        let savedCurrentID = currentShelfID
        let ids = Set(removed.map(\.id))
        shelves.removeAll { !$0.pinned }
        // The per-shelf entries owned by these shelves could only restore
        // into them and can never land again; the aggregate entry below is
        // their replacement.
        undoStack.removeAll { entry in
            entry.restoresIntoShelfID.map { ids.contains($0) } ?? false
        }
        if let current = currentShelfID, ids.contains(current) {
            currentShelfID = shelves.last?.id
        }
        pushUndo(.removeShelves(shelves: removed, currentShelfID: savedCurrentID))
        return removed.map(\.id)
    }

    func setCurrentShelf(id: UUID) {
        guard shelves.contains(where: { $0.id == id }) else { return }
        currentShelfID = id
    }

    /// Sets a custom display name for a shelf. Pass nil/empty to clear.
    func renameShelf(id: UUID, to name: String?) {
        guard let i = index(of: id) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard shelves[i].name != newName else { return }
        shelves[i].name = newName
    }

    func setShelfPinned(id: UUID, _ pinned: Bool) {
        guard let i = index(of: id) else { return }
        guard shelves[i].pinned != pinned else { return }
        shelves[i].pinned = pinned
    }

    func setShelfAccent(id: UUID, _ accent: ShelfAccent?) {
        guard let i = index(of: id) else { return }
        guard shelves[i].accent != accent else { return }
        shelves[i].accent = accent
    }

    /// Removes shelves whose last activity (most recent item add, falling back
    /// to shelf createdAt) is older than `days`. Shelf expiry never touches
    /// files on disk.
    /// Returns the IDs of the shelves that were pruned so callers can close
    /// any associated UI.
    @discardableResult
    func pruneShelves(olderThanDays days: Int) -> [UUID] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        let expired = shelves.filter { shelf in
            // Pinned shelves are exempt from auto-expiry regardless of age.
            guard !shelf.pinned else { return false }
            let last = shelf.items.map(\.createdAt).max() ?? shelf.createdAt
            return last < cutoff
        }
        guard !expired.isEmpty else { return [] }

        let ids = expired.map(\.id)
        shelves.removeAll { ids.contains($0.id) }
        undoStack.removeAll { entry in
            entry.restoresIntoShelfID.map(ids.contains) ?? false
        }
        if let currentShelfID, ids.contains(currentShelfID) {
            self.currentShelfID = shelves.last?.id
        }
        return ids
    }

    private func index(of shelfID: UUID) -> Int? {
        shelves.firstIndex { $0.id == shelfID }
    }

    // MARK: - Items

    func addItem(_ item: ShelfItem, to shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        // Animate the insertion so dropped tiles slide/fade in instead of
        // popping (and so any layout reflow in the grid is smoothed too).
        withAnimation(Design.Motion.transform) {
            shelves[idx].items.append(item)
        }
    }

    func removeItem(id itemID: UUID, from shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        shelves[idx].items.removeAll { $0.id == itemID }
    }

    /// Drops the cards for files a destination has just moved away.
    ///
    /// Deletes nothing: the file having left is what tells us to do this, and
    /// the card is a reference to something that is no longer there. Shared by
    /// the expanded grid, the list and the collapsed stack, which all drag out
    /// and all have to react the same way.
    func removeItems(withFileURLs urls: [URL], from shelfID: UUID) {
        let moved = Set(urls)
        for item in items(of: shelfID) where item.fileURL.map(moved.contains) == true {
            removeItem(id: item.id, from: shelfID)
        }
    }

    /// The same removal, plus the half the "clear the shelf after a drag out"
    /// preference adds: a shelf the drag emptied asks to be closed.
    ///
    /// Closing lives here rather than in `removeItems` because the two callers
    /// mean different things. A ⌘-move with the preference off drops the card
    /// of a file that genuinely left, and an empty shelf is a legitimate place
    /// to stand — the user may be about to drop something else on it. Only the
    /// preference says "and I am done with this shelf".
    ///
    /// The request is published rather than performed: panels belong to
    /// `AppDelegate`, and the manager has never known about windows.
    func removeItemsAfterDragOut(
        withFileURLs urls: [URL],
        from shelfID: UUID,
        closeWhenEmpty: Bool
    ) {
        removeItems(withFileURLs: urls, from: shelfID)
        guard closeWhenEmpty, items(of: shelfID).isEmpty else { return }
        closeRequested.send(shelfID)
    }

    func clear(shelfID: UUID) {
        guard let idx = index(of: shelfID) else { return }
        let removed = shelves[idx].items
        shelves[idx].items.removeAll()
        if !removed.isEmpty {
            pushUndo(.clearShelf(shelfID: shelfID, items: removed))
        }
    }

    // MARK: - Undo

    enum UndoableAction {
        case clearShelf(shelfID: UUID, items: [ShelfItem])
        /// `trashedURLs` is the original→trashed map returned by
        /// `NSWorkspace.shared.recycle`; empty when the item was a text
        /// snippet or a row removal that didn't touch the filesystem.
        case moveToTrash(
            shelfID: UUID,
            items: [ShelfItem],
            trashedURLs: [URL: URL]
        )
        /// Rows taken off the shelf by ⌫. No file moved, so undo is a plain
        /// re-add. Its own case rather than a reused `.moveToTrash` with an
        /// empty map, because the menu title is the only thing telling the user
        /// what ⌘Z is about to reverse and "Undo Move to Trash" would be a lie
        /// about a key that never went near the Trash.
        case removeFromShelf(shelfID: UUID, items: [ShelfItem])
        /// Whole shelves taken away by "Clear Recent Shelves". Undo restores
        /// the shelves themselves — not rows into a shelf — which is why this
        /// entry survives the removal of the shelves it snapshots.
        case removeShelves(shelves: [Shelf], currentShelfID: UUID?)

        /// The live shelf this action restores into, nil for an action that
        /// re-creates its shelves instead. An entry that restores INTO a
        /// shelf outlives that shelf only as a lie, so the manager drops it
        /// when the shelf goes.
        var restoresIntoShelfID: UUID? {
            switch self {
            case .clearShelf(let id, _),
                 .removeFromShelf(let id, _),
                 .moveToTrash(let id, _, _):
                return id
            case .removeShelves:
                return nil
            }
        }

        var items: [ShelfItem] {
            switch self {
            case .clearShelf(_, let items),
                 .removeFromShelf(_, let items),
                 .moveToTrash(_, let items, _):
                return items
            case .removeShelves(let shelves, _):
                return shelves.flatMap(\.items)
            }
        }

        var menuTitle: String {
            switch self {
            case .clearShelf: return L("undo.clear-shelf")
            case .moveToTrash(_, let items, _):
                return items.count <= 1
                    ? L("undo.move-to-trash")
                    : String(format: L("undo.move-to-trash-count"), items.count)
            case .removeFromShelf(_, let items):
                return items.count <= 1
                    ? L("undo.remove-from-shelf")
                    : String(format: L("undo.remove-from-shelf-count"), items.count)
            case .removeShelves:
                return L("undo.clear-all-shelves")
            }
        }
    }

    @Published private(set) var undoStack: [UndoableAction] = []

    /// Depth three, not ten. ⌘Z is global: it fires from whichever panel is
    /// key but restores into the snapshot's own shelf, so a deep history means
    /// firing blind into a shelf that may not even be on screen. Three covers
    /// the sequence that actually hurts — a run of ✕ clicks in a row.
    private static let undoDepth = 3

    /// What ⌘Z would reverse next. The read surface stays singular so the menu
    /// title and `canUndo` never have to know the stack is there.
    var undoSnapshot: UndoableAction? { undoStack.last }

    var canUndo: Bool { undoSnapshot != nil }

    private func pushUndo(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > Self.undoDepth {
            undoStack.removeFirst(undoStack.count - Self.undoDepth)
        }
    }

    /// Private on purpose. `finishMoveToTrash` is the only honest caller: it
    /// knows which files NSWorkspace actually moved. A caller that pairs this
    /// with a removal door would push two entries and cost the user two ⌘Z
    /// presses to undo one action — which is what the context menu used to do.
    private func captureTrashUndo(items: [ShelfItem], trashedURLs: [URL: URL], in shelfID: UUID) {
        guard !items.isEmpty else { return }
        pushUndo(.moveToTrash(shelfID: shelfID, items: items, trashedURLs: trashedURLs))
    }

    /// Called only from the keyboard remove path. `removeItem` deliberately
    /// stays snapshot-free so the pointer routes through it — the tile's X, the
    /// context-menu row, a drag-out that really moved the file — behave exactly
    /// as they did.
    /// Removes one card and records a way back. Every deliberate single-card
    /// removal goes through here — the tile's ✕ and the context-menu row — so
    /// ⌘Z means the same thing whichever way the card was removed. The keyboard
    /// path captures one snapshot for a whole selection before looping
    /// `removeItem`, so it deliberately does not use this door; the drag-out
    /// path does not either, because after a real move the file is gone and
    /// restoring the card would restore a broken one.
    func removeItemUndoably(id itemID: UUID, from shelfID: UUID) {
        guard let item = items(of: shelfID).first(where: { $0.id == itemID }) else { return }
        captureRemoveUndo(items: [item], in: shelfID)
        removeItem(id: itemID, from: shelfID)
    }

    func captureRemoveUndo(items: [ShelfItem], in shelfID: UUID) {
        guard !items.isEmpty else { return }
        pushUndo(.removeFromShelf(shelfID: shelfID, items: items))
    }

    /// Applies only the successful entries returned by NSWorkspace. Any row
    /// whose file was not moved remains on its shelf.
    func finishMoveToTrash(
        items: [ShelfItem],
        trashedURLs: [URL: URL],
        error: Error?,
        in shelfID: UUID
    ) -> String? {
        let trashedPaths = Set(trashedURLs.keys.map(Self.pathKey))
        let movedItems = items.filter { item in
            item.fileURL.map { trashedPaths.contains(Self.pathKey($0)) } ?? false
        }
        if !movedItems.isEmpty {
            captureTrashUndo(items: movedItems, trashedURLs: trashedURLs, in: shelfID)
            for item in movedItems {
                removeItem(id: item.id, from: shelfID)
            }
        }
        if let error { return error.localizedDescription }
        return movedItems.count == items.count
            ? nil : L("One or more files couldn't be moved to Trash.")
    }

    func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        let fm = FileManager.default
        if case .removeShelves(let removed, let savedCurrentID) = snapshot {
            // Restore the shelves themselves. Items whose backing file is
            // gone are dropped under the same rule as every other restore
            // below — a card pointing at nothing is worse than a missing
            // card — but the shelf still comes back even if emptied, because
            // the shelf (its name, pin-exempt history, accent) was the thing
            // removed. IDs already live are skipped defensively: a duplicate
            // shelf ID would corrupt every by-ID lookup.
            let liveIDs = Set(shelves.map(\.id))
            let restored = removed
                .filter { !liveIDs.contains($0.id) }
                .map { shelf -> Shelf in
                    var kept = shelf
                    kept.items = shelf.items.filter { item in
                        item.fileURL.map { fm.fileExists(atPath: $0.path) } ?? true
                    }
                    return kept
                }
            guard !restored.isEmpty else { return }
            withAnimation(Design.Motion.transform) {
                shelves.append(contentsOf: restored)
            }
            if let savedCurrentID,
               shelves.contains(where: { $0.id == savedCurrentID }) {
                currentShelfID = savedCurrentID
            }
            return
        }
        if case .moveToTrash(_, _, let trashedURLs) = snapshot {
            // Put the trashed files back before re-adding the rows.
            for (originalURL, trashedURL) in trashedURLs {
                guard fm.fileExists(atPath: trashedURL.path) else { continue }
                if fm.fileExists(atPath: originalURL.path) { continue }
                try? fm.moveItem(at: trashedURL, to: originalURL)
            }
        }
        guard let target = snapshot.restoresIntoShelfID,
              let idx = index(of: target) else { return }
        // No branch may restore a row whose backing file is gone. The snapshot
        // is not counted by `evictManagedCacheIfNeeded`, so a managed copy can
        // be reclaimed while the snapshot holds the only reference to it — and
        // a user file can simply be deleted in Finder in between. Either way
        // the card would come back live but pointing at nothing: drag-out,
        // Open and Quick Look would all silently fail, and the next
        // `pruneMissingFiles` sweep would delete it again with no explanation.
        // Rows with no file at all (a bare text snippet) are always kept.
        let restored = snapshot.items.filter { item in
            item.fileURL.map { fm.fileExists(atPath: $0.path) } ?? true
        }
        guard !restored.isEmpty else { return }
        withAnimation(Design.Motion.transform) {
            shelves[idx].items.append(contentsOf: restored)
        }
    }

    /// Pure: the shelves with confirmed-missing items dropped, or nil when
    /// nothing would change. The nil is the point — assigning `shelves`
    /// republishes the whole model to every view and schedules a store write,
    /// so a sweep that removed nothing must not touch it.
    nonisolated static func pruningMissingFiles(
        from shelves: [Shelf],
        isMissing: (URL) -> Bool
    ) -> (shelves: [Shelf], removed: Int)? {
        var pruned = shelves
        var removed = 0
        for index in pruned.indices {
            let kept = pruned[index].items.filter { item in
                guard let url = item.fileURL else { return true }
                return !isMissing(url)
            }
            guard kept.count != pruned[index].items.count else { continue }
            removed += pruned[index].items.count - kept.count
            pruned[index].items = kept
        }
        return removed > 0 ? (pruned, removed) : nil
    }

    /// Drops items whose backing file is gone (e.g. moved to Trash from
    /// Finder while the shelf was open). Text items have no fileURL and are
    /// always kept. Returns the number of items removed.
    @discardableResult
    func pruneMissingFiles() -> Int {
        let fm = FileManager.default
        guard let result = Self.pruningMissingFiles(from: shelves, isMissing: { url in
            ShelfStore.fileAvailability(at: url, fileManager: fm) == .confirmedMissing
        }) else { return 0 }
        shelves = result.shelves
        return result.removed
    }

    enum RenameError: LocalizedError {
        case itemNotFound
        case missingURL
        case sourceMissing(URL)
        case destinationExists(URL)
        case moveFailed(URL, URL, Error)
        case moveDidNotTakeEffect(URL, URL)

        var errorDescription: String? {
            switch self {
            case .itemNotFound: return L("rename.error.item-not-found")
            case .missingURL: return L("rename.error.missing-url")
            case .sourceMissing(let url):
                return String(format: L("rename.error.source-missing"), url.path)
            case .destinationExists(let url):
                return String(format: L("rename.error.destination-exists"), url.lastPathComponent)
            case .moveFailed(_, _, let err):
                return err.localizedDescription
            case .moveDidNotTakeEffect:
                return L("rename.error.no-effect")
            }
        }
    }

    func renameItem(id itemID: UUID, to newURL: URL, in shelfID: UUID) throws {
        guard let sIdx = index(of: shelfID),
              let iIdx = shelves[sIdx].items.firstIndex(where: { $0.id == itemID })
        else { throw RenameError.itemNotFound }
        guard let oldURL = shelves[sIdx].items[iIdx].fileURL
        else { throw RenameError.missingURL }
        guard FileManager.default.fileExists(atPath: oldURL.path)
        else { throw RenameError.sourceMissing(oldURL) }

        if oldURL.standardizedFileURL.path != newURL.standardizedFileURL.path {
            guard !FileManager.default.fileExists(atPath: newURL.path)
            else { throw RenameError.destinationExists(newURL) }
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            throw RenameError.moveFailed(oldURL, newURL, error)
        }

        // Verify the rename actually took effect — covers weird cases
        // (aliases, sync engines, case-insensitive filesystems).
        guard FileManager.default.fileExists(atPath: newURL.path)
        else { throw RenameError.moveDidNotTakeEffect(oldURL, newURL) }

        let old = shelves[sIdx].items[iIdx]
        shelves[sIdx].items[iIdx] = old.with(
            fileURL: newURL,
            bookmarkData: .some(nil),
            persistedPath: .some(nil)
        )
    }

    @discardableResult
    func addFile(url: URL, to shelfID: UUID) -> ShelfItem? {
        guard index(of: shelfID) != nil else { return nil }
        let persistedURL: URL
        do {
            persistedURL = try store.prepareForIngest(url)
        } catch {
            NSLog("Shelf: failed to persist ingested file — \(error)")
            return nil
        }
        return insert(Self.describe(persistedURL), into: shelfID)
    }

    /// Everything about a file that can be read without touching the model, so
    /// a drop can read it on a background thread and hand the main actor a
    /// value instead of a filesystem.
    struct DescribedFile: Sendable {
        let url: URL
        let isDirectory: Bool
        let isImage: Bool
        let pixelSize: CGSize?
        let pageCount: Int?
    }

    /// Use UTType conformance instead of a hardcoded extension list so RAW
    /// formats (CR2, NEF, ARW, DNG, etc.) and newer codecs (AVIF, HEIF) all get
    /// image-style flush rendering rather than the doc-card white frame.
    nonisolated static func describe(_ url: URL) -> DescribedFile {
        let values = (try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]))
        let contentType = values?.contentType
        let isDirectory = values?.isDirectory ?? false
        let isImage = !isDirectory && (contentType?.conforms(to: .image) ?? false)
        return DescribedFile(
            url: url,
            isDirectory: isDirectory,
            isImage: isImage,
            pixelSize: isImage ? ShelfItem.readImagePixelSize(url: url) : nil,
            pageCount: (!isDirectory && (contentType?.conforms(to: .pdf) ?? false))
                ? ShelfItem.readPDFPageCount(url: url) : nil
        )
    }

    /// The one place a described file becomes a card. Both ingest doors — the
    /// synchronous `addFile` and the asynchronous drop — end here, so a dropped
    /// file and a pasted one produce exactly the same row, duplicate handling
    /// included.
    @discardableResult
    private func insert(_ file: DescribedFile, into shelfID: UUID) -> ShelfItem? {
        guard index(of: shelfID) != nil else { return nil }
        if let existing = items(of: shelfID).first(where: {
            guard let url = $0.fileURL else { return false }
            return Self.pathKey(url) == Self.pathKey(file.url)
        }) {
            if existing.isDirectory {
                recomputeFolderSize(itemID: existing.id, in: shelfID)
            } else {
                requestThumbnail(for: file.url, replacing: existing.id)
            }
            duplicateRejected.send(shelfID)
            return nil
        }
        let item = ShelfItem(
            type: file.isImage ? .image : .file,
            fileURL: file.url,
            thumbnail: NSWorkspace.shared.icon(forFile: file.url.path),
            pixelSize: file.pixelSize,
            pageCount: file.pageCount,
            isDirectory: file.isDirectory
        )
        addItem(item, to: shelfID)
        evictManagedCacheIfNeeded()
        if file.isDirectory {
            recomputeFolderSize(itemID: item.id, in: shelfID)
        } else {
            requestThumbnail(for: file.url, replacing: item.id)
        }
        return item
    }

    // MARK: - Dropping a pile of files

    /// How far a drop has got, 0...1, keyed by the shelf receiving it. Absent
    /// means nothing is arriving — or that what is arriving is too small to be
    /// worth saying anything about, which `IngestProgressPolicy` decides.
    ///
    /// Deliberately its own `@Published` and not part of `shelves`: the store
    /// write is driven by `$shelves`, and a progress bar ticking must not turn
    /// into a file write per tick.
    @Published private(set) var ingestProgress: [UUID: Double] = [:]

    /// Files waiting for the shelf's current batch to finish. A second drop
    /// while one is running joins the queue instead of cancelling it — the
    /// coalescing rule that fits a folder walk (one walk per item, newest wins)
    /// would throw away files the user just dropped.
    private var ingestQueue: [UUID: [URL]] = [:]
    private var ingestTasks: [UUID: Task<Void, Never>] = [:]
    /// The heaviest single file seen in the shelf's current batch. Latched, so
    /// the bar does not appear and vanish between a big file and a small one.
    private var ingestWeight: [UUID: Int64] = [:]
    /// Staging files an ingest is writing right now. `evictManagedCacheIfNeeded`
    /// reads this: a staging file is unreferenced by definition, so without it
    /// a big drop could reclaim the very bytes it is in the middle of writing.
    private var reservedIngestPaths: Set<String> = []

    /// Read-only view for `EvictionReservationWiringTests`, which has to prove
    /// that the *argument-less* eviction callers forward this set. Exposing the
    /// set beats letting the test hand one in: a test that supplies its own
    /// reservation cannot tell whether the real callers pass theirs.
    var reservedIngestPathsForTesting: Set<String> { reservedIngestPaths }

    /// Test seam: how many shelves have a drop in flight.
    var inFlightIngestCount: Int { ingestTasks.count }

    func isIngesting(shelfID: UUID) -> Bool { ingestTasks[shelfID] != nil }

    /// Takes in a dropped pile without blocking the main thread.
    ///
    /// The reads that can take real time — the duplicate comparison, the copy
    /// into `ManagedFiles`, and the per-file metadata — happen on a detached
    /// task, exactly as `recomputeFolderSize` does. The main actor is touched
    /// once per file, to add its card, which is also what keeps the panel
    /// answering while the pile lands.
    func addFiles(_ urls: [URL], to shelfID: UUID) {
        guard index(of: shelfID) != nil, !urls.isEmpty else { return }
        ingestQueue[shelfID, default: []].append(contentsOf: urls)
        startIngestIfIdle(in: shelfID)
    }

    /// Stops the drop this shelf is taking in. What has already landed stays —
    /// those are whole files with whole cards; what has not is simply never
    /// started. Nothing is left half-copied, because `ManagedIngest` only ever
    /// moves a copy into place once it is complete.
    func cancelIngest(shelfID: UUID) {
        ingestQueue.removeValue(forKey: shelfID)
        ingestTasks[shelfID]?.cancel()
        ingestProgress.removeValue(forKey: shelfID)
    }

    /// Test seam: waits for every drop in flight to finish or unwind.
    func awaitIngest() async {
        while let task = ingestTasks.values.first { await task.value }
    }

    private func startIngestIfIdle(in shelfID: UUID) {
        guard ingestTasks[shelfID] == nil else { return }
        guard let batch = ingestQueue.removeValue(forKey: shelfID), !batch.isEmpty else {
            ingestProgress.removeValue(forKey: shelfID)
            ingestWeight.removeValue(forKey: shelfID)
            return
        }
        let locations = store.ingestLocations
        // One staging name for the whole batch: the files are taken one at a
        // time and each one's staging file is moved or removed before the next
        // begins, so a single reservation covers the run.
        let staging = ManagedIngest.stagingURL(in: locations.managedFilesDirectory)
        reservedIngestPaths.insert(Self.pathKey(staging))
        ingestTasks[shelfID] = Task.detached(priority: .userInitiated) {
            for (offset, url) in batch.enumerated() {
                if Task.isCancelled { break }
                // Reported *before* the work, not after: a bar that appears
                // once the wait is over is not a progress bar.
                let weight = ManagedIngest.managedWorkEstimate(for: url, locations: locations)
                await MainActor.run { [weak self] in
                    self?.reportIngest(
                        in: shelfID, completed: offset, total: batch.count, weight: weight
                    )
                }
                if Task.isCancelled { break }

                var described: ShelfManager.DescribedFile?
                do {
                    let prepared = try ManagedIngest.prepare(
                        url,
                        locations: locations,
                        stagingURL: staging,
                        isCancelled: { Task.isCancelled }
                    )
                    described = ShelfManager.describe(prepared)
                } catch is CancellationError {
                    break
                } catch {
                    NSLog("Shelf: failed to persist ingested file — \(error)")
                }
                if Task.isCancelled { break }

                let landed = described
                await MainActor.run { [weak self] in
                    if let landed { self?.insert(landed, into: shelfID) }
                    self?.reportIngest(
                        in: shelfID, completed: offset + 1, total: batch.count, weight: 0
                    )
                }
            }
            await MainActor.run { [weak self] in
                self?.finishIngestBatch(in: shelfID, staging: staging)
            }
        }
    }

    private func reportIngest(in shelfID: UUID, completed: Int, total: Int, weight: Int64) {
        // A hop already in the air when Cancel was pressed must not put the
        // bar back up after the shelf has been told the drop is over.
        guard let task = ingestTasks[shelfID], !task.isCancelled else { return }
        let heaviest = max(ingestWeight[shelfID] ?? 0, weight)
        ingestWeight[shelfID] = heaviest
        guard IngestProgressPolicy.isVisible(
            batchSize: total, heaviestManagedBytes: heaviest
        ) else { return }
        ingestProgress[shelfID] = Double(completed) / Double(max(1, total))
    }

    private func finishIngestBatch(in shelfID: UUID, staging: URL) {
        reservedIngestPaths.remove(Self.pathKey(staging))
        ingestTasks[shelfID] = nil
        ingestProgress.removeValue(forKey: shelfID)
        ingestWeight.removeValue(forKey: shelfID)
        startIngestIfIdle(in: shelfID)
    }

    /// Walks currently in flight, keyed by item. Cleared by the walk itself.
    private var folderWalks: [UUID: (url: URL, task: Task<Void, Never>)] = [:]

    /// Test seam: how many folder walks are in flight right now.
    var inFlightFolderWalkCount: Int { folderWalks.count }

    /// Walks the directory at the item's URL and writes the total content
    /// size back to the item. Runs on a detached task so a multi-GB folder
    /// can't block the UI, and at most one walk per item is ever in flight —
    /// `init` and every repeat `addFile` of an item already on the shelf both
    /// ask for a recompute, so without coalescing one folder gets a fresh
    /// walk per call over the very same tree.
    func recomputeFolderSize(
        itemID: UUID,
        in shelfID: UUID,
        limits: FolderWalk.Limits = .default
    ) {
        guard let sIdx = index(of: shelfID),
              let iIdx = shelves[sIdx].items.firstIndex(where: { $0.id == itemID }),
              shelves[sIdx].items[iIdx].isDirectory,
              let url = shelves[sIdx].items[iIdx].fileURL
        else { return }
        if let inFlight = folderWalks[itemID] {
            // Same tree: the walk already running is the answer.
            guard inFlight.url != url else { return }
            // Different tree: the running walk answers a question nobody is
            // asking any more, and it checks cancellation as it goes.
            inFlight.task.cancel()
        }
        folderWalks[itemID] = (url, Task.detached(priority: .utility) {
            let size = FolderWalk.totalBytes(
                of: url,
                limits: limits,
                isCancelled: { Task.isCancelled }
            )
            await MainActor.run { [weak self] in
                self?.finishFolderWalk(itemID: itemID, in: shelfID, url: url, size: size)
            }
        })
    }

    private func finishFolderWalk(
        itemID: UUID,
        in shelfID: UUID,
        url: URL,
        size: FolderWalk.Size
    ) {
        // Only the walk that still owns the slot releases it; a superseded one
        // must not clear the walk that replaced it.
        if folderWalks[itemID]?.url == url { folderWalks[itemID] = nil }
        // A bounded or unreadable walk carries no total, so it leaves the
        // cached value alone. nil renders as "Folder" via `displayMeta`, which
        // is honest; a partial sum would render as an exact size that is wrong.
        guard case .exact(let bytes) = size else { return }
        applyFolderSize(itemID: itemID, in: shelfID, bytes: bytes)
    }

    private func applyFolderSize(itemID: UUID, in shelfID: UUID, bytes: Int64) {
        guard let sIdx = index(of: shelfID),
              let iIdx = shelves[sIdx].items.firstIndex(where: { $0.id == itemID })
        else { return }
        let old = shelves[sIdx].items[iIdx]
        guard old.cachedFolderBytes != bytes else { return }
        shelves[sIdx].items[iIdx] = old.with(
            persistedPath: .some(nil),
            cachedFolderBytes: bytes
        )
    }

    @discardableResult
    func addText(_ text: String, to shelfID: UUID) -> ShelfItem? {
        guard index(of: shelfID) != nil else { return nil }
        // Stage a backing temp .txt so Open / Reveal-in-Finder work. The
        // snippet preview still renders from `textContent`; the fileURL is
        // there purely to make the standard file actions reachable.
        let url = ShelfItem.writeTextToTemp(text)
        let item = ShelfItem(type: .text, fileURL: url, textContent: text)
        addItem(item, to: shelfID)
        return item
    }

    @discardableResult
    func addFromClipboard(to shelfID: UUID) -> Int {
        guard !ClipboardImporter.isConcealed(.general) else {
            concealedClipboardRejected.send(shelfID)
            return 0
        }
        return ClipboardImporter.addFromClipboard(
            addFile: { url in
                addFile(url: url, to: shelfID)
            },
            addText: { text in
                addText(text, to: shelfID)
            }
        )
    }

    // MARK: - Thumbnails

    private func requestThumbnail(for url: URL, replacing id: UUID) {
        ThumbnailProvider.generateThumbnail(for: url) { [weak self] image, isIcon in
            self?.updateThumbnail(id: id, image: image, isIcon: isIcon)
        }
    }

    private func updateThumbnail(id: UUID, image: NSImage, isIcon: Bool) {
        for (sIdx, shelf) in shelves.enumerated() {
            if let iIdx = shelf.items.firstIndex(where: { $0.id == id }) {
                let old = shelves[sIdx].items[iIdx]
                let new = old.with(
                    persistedPath: .some(nil),
                    thumbnail: image,
                    thumbnailIsIcon: isIcon
                )
                // Crossfade the skeleton/icon → real preview swap so it
                // doesn't read as a hard pop.
                withAnimation(Design.Motion.state) {
                    shelves[sIdx].items[iIdx] = new
                }
                return
            }
        }
    }

    /// ADR 0001's bound on the managed cache. Named so the eviction default
    /// and anything that talks about the budget share one number. Nonisolated
    /// because a default parameter value is evaluated outside the actor.
    nonisolated static let managedCacheBudgetBytes: Int64 = 500 * 1_024 * 1_024

    /// The files the cache subsystem governs: regular, non-symlink files
    /// directly inside `ManagedFiles`, from a direct listing of that directory
    /// and nowhere else (empty when the root is missing or is a symlink).
    /// Shared by the eviction and the cache-size display, so the number the
    /// user sees counts exactly the set Clear Cache is allowed to touch.
    private func managedCacheContents() -> [(url: URL, size: Int64, modified: Date)] {
        let root = store.managedFilesDirectory.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(keys)
              )
        else { return [] }

        return entries.compactMap { url in
            guard url.deletingLastPathComponent().standardizedFileURL == root,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize
            else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
    }

    /// What the managed cache holds right now, in bytes. Read by the Settings
    /// cache row and the diagnostics report. Deliberately not gated on the
    /// store having loaded: the display must stay honest even in the read-only
    /// states where eviction refuses to run.
    func managedCacheBytes() -> Int64 {
        managedCacheContents().reduce(0) { $0 + $1.size }
    }

    /// The Clear Cache button in Settings. Deliberately nothing but the
    /// bounded eviction with a zero budget: ADR 0001 allows exactly one
    /// deletion path, and giving this button its own would re-grow the
    /// per-item deletion subsystem that twice nearly deleted a user's file.
    /// Everything the eviction refuses, this refuses identically — copies a
    /// shelf still references are kept, nothing outside `ManagedFiles` is
    /// listed, and a non-authoritative store load keeps it a no-op.
    func clearManagedCache() {
        evictManagedCacheIfNeeded(budgetBytes: 0)
    }

    /// Every eviction candidate comes from a direct listing of ManagedFiles.
    func evictManagedCacheIfNeeded(
        budgetBytes: Int64 = ShelfManager.managedCacheBudgetBytes
    ) {
        evictManagedCacheIfNeeded(budgetBytes: budgetBytes, reserving: reservedIngestPaths)
    }

    /// `reserving` names files being written *right now*. They are unreferenced
    /// by definition — no card points at a copy that has not finished — so
    /// without this a drop big enough to blow the budget could reclaim its own
    /// staging file mid-write and lose the file it was taking in.
    func evictManagedCacheIfNeeded(budgetBytes: Int64, reserving reserved: Set<String>) {
        guard loadedStoreIsAuthoritative else { return }
        let files = managedCacheContents()
        let limit = max(0, budgetBytes)
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        let referenced = Set(shelves.flatMap(\.items).compactMap { item -> String? in
            if let url = item.fileURL { return Self.pathKey(url) }
            return item.persistedPath.map { Self.pathKey(URL(fileURLWithPath: $0)) }
        }).union(reserved)
        for file in files.sorted(by: { $0.modified < $1.modified }) where total > limit {
            guard !referenced.contains(Self.pathKey(file.url)) else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.size
            } catch {
                NSLog("Shelf: managed-cache eviction failed — \(error)")
            }
        }
    }

    private static func pathKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// The copy for the "Clear Recent Shelves" confirmation, composed here (pure)
/// so a test can hold the counts against the nine tables: the dialog must
/// name what is about to go, not ask a yes/no in the abstract.
enum ClearAllShelvesConfirmation {
    static func summary(shelfCount: Int, itemCount: Int) -> String {
        let shelves = shelfCount == 1
            ? L("shelf-count.one")
            : String(format: L("shelf-count.many"), shelfCount)
        let files = itemCount == 1
            ? L("1 file")
            : String(format: L("%lld files"), itemCount)
        return String(format: L("alert.clear-all.body"), shelves, files)
    }
}

/// A bounded recursive size walk. `FileManager.enumerator` has no depth cap,
/// no entry cap and no deadline, and a directory item is re-walked at every
/// launch, so one folder on the shelf could otherwise cost minutes of disk
/// churn per launch forever. Past a bound the walk stops and reports what it
/// had, which the caller treats as "no answer" rather than as a size.
enum FolderWalk {
    struct Limits: Sendable {
        let maxEntries: Int
        let deadline: TimeInterval

        /// Generous for a folder a person would put on a shelf, cheap for one
        /// they wouldn't.
        static let `default` = Limits(maxEntries: 20_000, deadline: 2.0)
    }

    enum Stop: Sendable, Equatable {
        case entryCap
        case deadline
        case cancelled
    }

    enum Size: Sendable, Equatable {
        /// The whole tree was walked.
        case exact(Int64)
        /// Stopped at a bound; `bytes` is only what had been counted by then.
        case partial(bytes: Int64, stop: Stop)
        /// The directory could not be enumerated at all.
        case unavailable
    }

    static func totalBytes(
        of url: URL,
        limits: Limits = .default,
        now: () -> Date = Date.init,
        isCancelled: () -> Bool = { false }
    ) -> Size {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return .unavailable }

        let start = now()
        var total: Int64 = 0
        var entries = 0
        for case let fileURL as URL in enumerator {
            // Checked per entry rather than per batch: reading the clock costs
            // far less than the `resourceValues` stat below it, and per-entry
            // is the only bound that holds on a tree of very large files.
            if isCancelled() { return .partial(bytes: total, stop: .cancelled) }
            if entries >= limits.maxEntries {
                return .partial(bytes: total, stop: .entryCap)
            }
            if now().timeIntervalSince(start) >= limits.deadline {
                return .partial(bytes: total, stop: .deadline)
            }
            entries += 1
            let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return .exact(total)
    }
}
