import CryptoKit
import QuickLookThumbnailing
import SwiftUI

/// The selection pairs AppKit guarantees legible together, across every accent
/// colour, both appearances, and Increase Contrast. A hand-mixed white-on-accent
/// fill cannot be: white at 92% over the yellow accent measures ~1.5:1 against a
/// 4.5:1 requirement, and no opacity tuning fixes that for all eight accents.
///
/// Two pairs, not one. `emphasized` is whether the cell's panel is the key
/// window: the accent fill is AppKit's claim that keystrokes land here, so a
/// shelf that is not key shows the unemphasized grey instead — with two
/// shelves open, the selection colour is what says which one the keyboard
/// will hit, and this app has no title bars to say it. Text on the
/// unemphasized fill stays on the normal label ladder, as AppKit's own lists
/// do. Parameters rather than a second static pair so a call site cannot
/// compile without answering the question.
///
/// The AppKit halves are the same two colours, not a second pair: the count
/// badge on a multi-file drag image is drawn into a bitmap by `NSImage`, which
/// has no SwiftUI to hand. Deriving the `Color`s from the `NSColor`s is what
/// keeps the badge and the rows from ever being two different blues.
enum SelectionColor {
    static func fillColor(emphasized: Bool) -> NSColor {
        emphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
    }

    static func textColor(emphasized: Bool) -> NSColor {
        emphasized ? .alternateSelectedControlTextColor : .labelColor
    }

    static func fill(emphasized: Bool) -> Color {
        Color(nsColor: fillColor(emphasized: emphasized))
    }

    static func text(emphasized: Bool) -> Color {
        Color(nsColor: textColor(emphasized: emphasized))
    }
}

/// The one place that says what order a shelf is drawn in.
///
/// Storage is append-at-end (oldest first); the grid and the list both draw
/// newest-first so the just-dropped tile lands at the top where the user is
/// looking. Anything that has to agree with what the eye sees — the focus
/// cursor, and the PDF merge that turns cards into pages — asks here rather
/// than writing `reversed()` again, because a second expression of "order" is
/// a second thing that can silently disagree with the screen.
enum ShelfDisplayOrder {
    /// Top-left card first.
    static func displayed(_ items: [ShelfItem]) -> [ShelfItem] {
        Array(items.reversed())
    }

    /// The selected subset, in the order it appears on screen. Selection is a
    /// `Set<UUID>` with no drag-reorder anywhere in the app, so screen position
    /// is the *only* order a user can express — and it must not be read off the
    /// selection array, which arrives in storage order from the context menu
    /// and in display order from the ⌘K palette.
    static func displayed(_ items: [ShelfItem], selecting ids: Set<UUID>) -> [ShelfItem] {
        displayed(items).filter { ids.contains($0.id) }
    }
}

/// Composes the spoken label for an item cell. Pure so the phrasing is tested
/// rather than eyeballed; `meta` is the same string the cell already shows, so
/// the visible and spoken descriptions cannot drift apart.
enum ShelfItemAccessibility {
    static func itemLabel(name: String, kind: String, meta: String) -> String {
        // A text snippet's name is its first 40 characters, newlines and all.
        let flatName = name
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // VoiceOver reads "·" as nothing, so "1.2 MB · PDF" runs together.
        let detail = meta.replacingOccurrences(of: " · ", with: ", ")
        var parts = [flatName, kind]
        // A folder whose size hasn't been computed yet shows "Folder" as its
        // meta line too — don't say it twice.
        if detail != kind { parts.append(detail) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func kind(isDirectory: Bool, type: ShelfItem.ItemType) -> String {
        if isDirectory { return L("Folder") }
        switch type {
        case .image: return L("a11y.kind.image")
        case .text: return L("a11y.kind.text")
        case .file: return L("File")
        }
    }
}

// MARK: - Progress overlay (ingest, conversion & OCR)

/// The one thing in the app that says "this is taking a moment, and you can
/// stop it". Drawn over a single card for a conversion or an OCR run, and over
/// the whole panel for a drop that is still landing — same bar, same cancel,
/// so there is one progress idea in the app rather than two.
private struct ProgressOverlay: View {
    let progress: Double?
    /// Named above the bar when the work is not attached to a card, where the
    /// card itself would otherwise be the only clue what is happening.
    var label: String? = nil
    var cornerRadius: CGFloat = Design.Radius.face
    let onCancel: () -> Void

    var body: some View {
        if let progress {
            ZStack {
                Design.Surface.scrim
                    .allowsHitTesting(false)
                VStack(spacing: Design.Space.sm) {
                    if let label {
                        Text(label)
                            .font(Design.Text.label)
                            .foregroundStyle(.white)
                    }
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 76)
                        .tint(.white)
                        .accessibilityLabel(label ?? "")
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Cancel"))
                    .help(L("Cancel"))
                }
                .padding(Design.Space.md)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .transition(.opacity)
        }
    }
}

struct ShelfContainerView: View {
    @ObservedObject var manager: ShelfManager
    var conversionService: ConversionService
    var ocrService: OCRService
    var routeService: RouteService
    let shelfID: UUID
    /// True for shake-created shelves, which auto-close via the shake-release
    /// watcher and shouldn't show an X in their fresh-empty state. Menu-created
    /// shelves have no auto-close path, so they always need the X.
    var isEphemeral: Bool = false
    /// Where ⌘C writes. Injectable for one reason: the only honest test of
    /// "does this key do anything from the state the shelf is actually in" has
    /// to drive the key and then read what landed, and doing that on the real
    /// clipboard would take the user's. Every caller in the app takes the
    /// default.
    var copyPasteboard: NSPasteboard = .general
    var onClose: () -> Void = {}
    var onResize: (_ expanded: Bool) -> Void = { _ in }
    var onDockChanged: (_ docked: Bool) -> Void = { _ in }

    @Namespace private var ns
    /// Observed only so that flipping Reduce Motion in System Settings
    /// re-evaluates this tree straight away. The flag itself is read live from
    /// `Design.Motion`, never stored here.
    @ObservedObject private var accessibilityDisplay = AccessibilityDisplayMonitor.shared
    /// Republishes while a drag-out is in flight, so the hint can follow ⌘
    /// being pressed and released mid-drag.
    @ObservedObject private var dragMode = DragModeMonitor.shared
    @State private var isExpanded = false
    @State private var isDocked = false
    @State private var dropTargeted = false
    @State private var selection: Set<UUID> = []
    // Sticky once true: lets the collapsed view show its X close button
    // after the user empties a populated shelf, but stays hidden while a
    // shake gesture is mid-flight (shelf created empty, no items yet).
    @State private var hasEverHadItems = false
    /// ⌘K arrived while this shelf was collapsed or docked. `ExpandedShelfView`
    /// is the only thing that can show the palette, and it does not exist in
    /// those states — so the request is parked here, the shelf expands, and the
    /// expanded view picks it up when it appears.
    @State private var palettePending = false
    /// Whether the pointer is anywhere on this panel. The shelf's controls are
    /// drawn as quietly as a control can be and still be found; this is what
    /// brings them forward when the user is actually looking at the panel.
    @State private var panelHovered = false
    /// Where a ⇧-click counts a range from. The last row a plain click or a
    /// ⌘-click landed on, exactly as in any macOS list.
    @State private var selectionAnchor: UUID?
    /// The collapsed strip's keyboard cursor, as an index into the displayed
    /// rows. Held here rather than in the strip so it can be registered with
    /// `shelvesWithKeyboardFocus`, which is what keeps the space bar meaning
    /// Quick Look for anyone who has not started navigating with the keyboard.
    @State private var stripFocusedIndex: Int?
    /// "Clear the shelf after dragging out", off unless the user switched it
    /// on. Unregistered in `DefaultPreferences` on purpose: an unset key
    /// reading false *is* the default, and registering it would be the way to
    /// switch a shelf-emptying behaviour on for everybody.
    @AppStorage("shelf.clearAfterDragOut") private var clearAfterDragOut: Bool = false

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    /// The rows in the order the strip draws them, which is the only order a
    /// ⇧-click range or an arrow key can mean.
    private var stripRowIDs: [UUID] { ShelfDisplayOrder.displayed(items).map(\.id) }

    private var transitionAnimation: Animation? { Design.Motion.shelfState }

    var body: some View {
        ZStack {
            if isDocked {
                DockedTabView(
                    onExpand: { toggleDock(to: false) },
                    dropTargeted: dropTargeted
                )
                .transition(.opacity)
            } else if isExpanded {
                ExpandedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    selection: $selection,
                    palettePending: $palettePending,
                    onCollapse: { toggle(to: false) },
                    onClose: onClose,
                    onDock: { toggleDock(to: true) }
                )
                .padding(ShelfLayout.margin)
                .environment(\.shelfChromeRevealed, panelHovered)
                .transition(.opacity)
            } else {
                CollapsedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    items: items,
                    isDragging: manager.isDragging,
                    dragIntent: dragMode.intent,
                    showCloseWhenEmpty: hasEverHadItems || !isEphemeral,
                    selection: selection,
                    focusedIndex: stripFocusedIndex,
                    onClose: onClose,
                    onOpenDocuments: { toggle(to: true) },
                    onDock: { toggleDock(to: true) },
                    onSelectRow: { id, modifiers in
                        handleStripClick(id: id, modifiers: modifiers)
                    },
                    onDragStart: { id in beginStripDrag(from: id) },
                    onDragEnd: { manager.isDragging = false },
                    onMovedOut: { urls in
                        manager.removeItemsAfterDragOut(
                            withFileURLs: urls,
                            from: shelfID,
                            closeWhenEmpty: clearAfterDragOut
                        )
                    },
                    onClearSelection: clearStripSelection
                )
                .padding(ShelfLayout.margin)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { panelHovered = $0 }
        .overlay {
            if !isDocked {
                DropTargetOverlay(active: dropTargeted && !manager.isDragging)
            }
        }
        // Expanded only, and along the bottom edge under the footer row. The
        // collapsed strip carries the bar in its own header instead (see
        // `CollapsedShelfView.header`), because an overlay there covered the
        // rows — which are the whole reason the panel is on screen.
        .overlay(alignment: .bottom) {
            if isExpanded, !isDocked {
                DragModeBar(
                    intent: dragMode.intent,
                    visible: manager.isDragging
                )
                .padding(.horizontal, ShelfLayout.margin)
                .padding(.bottom, Design.Space.md)
            }
        }
        // AppKit-level drop target — keeps the green "+" copy badge from
        // showing up on the cursor (SwiftUI's `.onDrop` always negotiates as
        // `.copy`, which paints the badge; we want a clean cursor instead).
        .overlay(
            ShelfDropTarget(
                isTargeted: $dropTargeted,
                allowDrop: { !manager.isDragging },
                onDrop: handleDrop
            )
        )
        // A drop that is still landing. Panel-level rather than per-card
        // because there is no card yet — that is the whole point: a cancelled
        // ingest leaves nothing behind, so nothing can be drawn on.
        .overlay {
            ProgressOverlay(
                progress: manager.ingestProgress[shelfID],
                label: L("ingest.importing"),
                cornerRadius: Design.Radius.panel,
                onCancel: { manager.cancelIngest(shelfID: shelfID) }
            )
        }
        // ⌘K from a collapsed or docked shelf. `ExpandedShelfView` carries the
        // palette and has its own subscriber, but it is not in the tree in
        // those states, so the event landed nowhere and ⌘K appeared dead — the
        // state a summoned shelf actually starts in. Expand, and hand the
        // request over for the expanded view to run when it appears.
        .onReceive(manager.paletteRequested) { id in
            guard id == shelfID, !isExpanded || isDocked else { return }
            palettePending = true
            if isDocked { toggleDock(to: false) }
            if !isExpanded { toggle(to: true) }
        }
        .onReceive(manager.undockRequested) { id in
            guard id == shelfID, isDocked else { return }
            withAnimation(transitionAnimation) { isDocked = false }
        }
        // The collapsed strip's keyboard. `ExpandedShelfView` owns these while
        // it is on screen and is not in the tree otherwise, so the guard is
        // what keeps exactly one of them answering.
        .onReceive(manager.keyCommandRequested) { request in
            guard request.shelfID == shelfID, !isExpanded, !isDocked else { return }
            handleStripKeyCommand(request.command)
        }
        .onReceive(manager.selectAllRequested) { id in
            // ⌘A is an explicit selection, even when it contains every row.
            // The untouched empty set remains the quiet whole-shelf default;
            // these two states carry the same files but must not look alike.
            guard id == shelfID, !isExpanded, !isDocked else { return }
            selectAllStripSelection()
        }
        .onReceive(manager.copyRequested) { id in
            // ⌘C on a strip. The key monitor swallows this press unconditionally
            // and only `ExpandedShelfView` was listening, so on a **collapsed**
            // shelf — the state a shelf spends most of its life in — ⌘C was a
            // dead key that ate itself. It copies what a drag would carry, from
            // the same `effective` the header states in words, so the clipboard
            // and the drag can never disagree about what "this" means.
            guard id == shelfID, !isExpanded else { return }
            copyStripSelection()
        }
        // Two things outside this view need the strip's pick and neither can
        // see `@State`: the key monitor, which must not swallow Escape on a
        // strip with nothing to clear, and Quick Look's URL provider on the app
        // delegate, which would otherwise preview the whole shelf over a header
        // reading `1 of 5`. Published on every change of the selection itself —
        // not merely of *whether* there is one, which would leave a pick
        // growing from one row to three unnoticed. Only a visible strip counts:
        // in the expanded view the same `selection` means something else and
        // Escape already means "collapse".
        .onChange(of: selection) { publishStripSelection($0, expanded: isExpanded, docked: isDocked) }
        .onChange(of: isExpanded) { publishStripSelection(selection, expanded: $0, docked: isDocked) }
        .onChange(of: isDocked) { publishStripSelection(selection, expanded: isExpanded, docked: $0) }
        // The space bar belongs to Quick Look until a cursor exists, and this
        // is the only place that knows whether the strip has one.
        .onChange(of: stripFocusedIndex) { newValue in
            if newValue == nil {
                manager.shelvesWithKeyboardFocus.remove(shelfID)
            } else {
                manager.shelvesWithKeyboardFocus.insert(shelfID)
            }
        }
        .onReceive(manager.collapseRequested) { id in
            // External nudge (e.g. outside-click setting) — only act if the
            // signal is for our shelf and we're currently expanded. Going
            // through the normal toggle path keeps the panel resize +
            // SwiftUI animation in lockstep.
            guard id == shelfID, isExpanded else { return }
            toggle(to: false)
        }
        // Empty-but-expanded is a dead-end UX (nothing to do, nothing to
        // show), so fall back to collapsed and let that view handle the
        // empty case.
        .onChange(of: items.count) { newCount in
            if newCount == 0, isExpanded {
                toggle(to: false)
            }
            if newCount > 0 { hasEverHadItems = true }
            // A cursor left pointing past the end of a shorter shelf would ring
            // a row that is no longer there.
            if let index = stripFocusedIndex {
                stripFocusedIndex = newCount == 0 ? nil : min(index, newCount - 1)
            }
        }
        .onChange(of: dropTargeted) { newValue in
            manager.setDropTargeted(shelfID: shelfID, newValue)
        }
        .onAppear {
            if !items.isEmpty { hasEverHadItems = true }
        }
        .onDisappear {
            // Make sure a panel that closes mid-drop doesn't leave its
            // shelf marked as a drop target forever.
            manager.setDropTargeted(shelfID: shelfID, false)
            manager.shelvesWithKeyboardFocus.remove(shelfID)
            manager.stripSelections.removeValue(forKey: shelfID)
        }
        .environmentObject(conversionService)
        .environmentObject(ocrService)
        .environmentObject(routeService)
    }

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        if manager.isDragging { return false }
        let target = shelfID

        // 1. File URLs — covers both files and folders. Finder always vends
        // `.fileURL` for folders to AppKit destinations, so we don't need the
        // separate `public.folder` branch the SwiftUI version had to carry.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            // Off the main thread from here: a pile from Finder is metadata
            // reads per file, and a pile from a purgeable location is a copy
            // and a duplicate comparison per file. Both used to run inline on
            // the drop, which is why a big drop beachballed.
            manager.addFiles(urls, to: target)
            return true
        }

        // 2. File promises — sources like Mail, Photos, and some browsers
        // vend the file lazily via NSFilePromiseReceiver. The receiver writes
        // the real bytes into our temp dir, then we add it to the shelf.
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            let dest = FileManager.default.temporaryDirectory
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: dest,
                    options: [:],
                    operationQueue: queue
                ) { url, error in
                    if let error {
                        NSLog("Shelf: file promise failed — \(error)")
                        return
                    }
                    Task { @MainActor in manager.addFiles([url], to: target) }
                }
            }
            return true
        }

        // 3. Image data without a fileURL — e.g. dragging an image straight
        // out of a webpage. Stage as PNG with a content-hash filename so a
        // repeat drop hits the shelf's duplicate guard.
        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self], options: nil
        ) as? [NSImage], !images.isEmpty {
            var staged = false
            for image in images {
                guard
                    let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                let hash = SHA256.hash(data: png)
                    .map { String(format: "%02x", $0) }
                    .joined().prefix(16)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shelf-\(hash).png")
                do {
                    if !FileManager.default.fileExists(atPath: tmp.path) {
                        try png.write(to: tmp)
                    }
                    manager.addFiles([tmp], to: target)
                    staged = true
                } catch {
                    NSLog("Shelf: failed to write dropped image: \(error)")
                }
            }
            if staged { return true }
        }

        // 4. Plain text — pasted/dragged snippets. addText takes care of
        // staging a backing temp .txt so Open / Reveal work.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manager.addText(text, to: target)
            return true
        }

        return false
    }

    // MARK: - The collapsed strip's selection

    /// A click on a row. The strip reports the row and its modifiers;
    /// `ShelfSelection` decides what that means, so the pointer path and the
    /// keyboard path below run the same rules.
    private func handleStripClick(id: UUID, modifiers: NSEvent.ModifierFlags) {
        clearStripFocus()
        let outcome = ShelfSelection.click(
            id: id,
            modifiers: modifiers,
            explicit: selection,
            anchor: selectionAnchor,
            ids: stripRowIDs
        )
        selection = outcome.selection
        selectionAnchor = outcome.anchor
    }

    /// Finder's rule, applied at the moment a drag leaves a row: a drag off a
    /// row that is not selected narrows to it first. The strip's `provider`
    /// asks the same function for what to carry, so the narrowing and the
    /// payload are one decision read twice rather than two decisions.
    private func beginStripDrag(from id: UUID) {
        let start = ShelfSelection.beginDrag(
            from: id, explicit: selection, ids: stripRowIDs
        )
        if start.selection != selection {
            selection = start.selection
            selectionAnchor = id
        }
        manager.isDragging = true
    }

    /// The pointer has taken over, so the cursor goes — a ring nobody is
    /// driving is a second highlight competing with the selection.
    private func clearStripFocus() {
        guard stripFocusedIndex != nil else { return }
        stripFocusedIndex = nil
    }

    /// Back to "a drag takes the whole shelf", and back to a header that says
    /// so. Escape, ⌘A, and a click on the header or any empty part of the panel
    /// all land here — a pick made by accident has to be undoable without the
    /// user working out which of them is the right one.
    ///
    /// Guarded, so a strip nobody has narrowed never writes state: a click on
    /// the panel of a resting shelf stays the no-op it has always been.
    private func clearStripSelection() {
        guard !selection.isEmpty else { return }
        selection = ShelfSelection.wholeShelf
        selectionAnchor = nil
    }

    /// An explicit select-all is feedback, not the quiet resting default.
    /// Escape and the header use `clearStripSelection` to return to the latter.
    private func selectAllStripSelection() {
        let ids = stripRowIDs
        guard !ids.isEmpty else { return }
        selection = Set(ids)
        selectionAnchor = nil
    }

    /// ⌘C from a collapsed strip: the same files a drag off it would carry.
    ///
    /// Built from `ShelfSelection.effective`, which is what `beginDrag` and the
    /// header's claim are both built from — so the three cannot come out
    /// different. It writes the same payload the expanded view's ⌘C and the
    /// menu's Copy row write, so a paste lands identically whichever route the
    /// user took.
    private func copyStripSelection() {
        let carried = ShelfSelection.effective(explicit: selection, ids: stripRowIDs)
        // An empty shelf writes nothing rather than clearing: `write` returns
        // false and leaves whatever the user had copied a moment ago alone.
        ShelfClipboardPayload.write(
            items: ShelfDisplayOrder.displayed(items, selecting: carried),
            to: copyPasteboard
        )
    }

    /// Hands the strip's pick to the manager, or takes it back when there is
    /// none to hand over.
    ///
    /// The three inputs arrive as arguments rather than being read off `self`
    /// because each caller is an `onChange` that knows its own fresh value; the
    /// other two cannot have changed in the same update. An entry exists only
    /// while a **visible collapsed strip** is narrowed — the expanded view reads
    /// the same `selection` as a literal selection, and a docked tab shows no
    /// rows at all — so "there is an entry" and "Escape has something to clear"
    /// stay the same fact, which is what `shelvesWithNarrowedSelection` reads.
    private func publishStripSelection(
        _ selection: Set<UUID>, expanded: Bool, docked: Bool
    ) {
        if selection.isEmpty || expanded || docked {
            manager.stripSelections.removeValue(forKey: shelfID)
        } else {
            manager.stripSelections[shelfID] = selection
        }
    }

    /// Arrow keys, ⇧-arrows and the space bar, in a collapsed shelf.
    ///
    /// Only the commands `ShelfKey.isCollapsedStripCommand` admits reach here;
    /// anything else was never swallowed by the monitor and still behaves as it
    /// always did.
    private func handleStripKeyCommand(_ command: ShelfKey.Command) {
        let ids = stripRowIDs
        guard !ids.isEmpty else { return }
        switch command {
        case .move(let direction):
            guard let next = ShelfFocus.move(
                direction, from: stripFocusedIndex, count: ids.count, columns: 1
            ) else { return }
            stripFocusedIndex = next
        case .extend(let direction):
            guard let next = ShelfFocus.move(
                direction, from: stripFocusedIndex, count: ids.count, columns: 1
            ) else { return }
            extendStripSelection(to: next, ids: ids)
            stripFocusedIndex = next
        case .toggleSelection:
            guard let index = stripFocusedIndex, ids.indices.contains(index) else { return }
            let outcome = ShelfSelection.toggle(
                id: ids[index], explicit: selection, anchor: selectionAnchor, ids: ids
            )
            selection = outcome.selection
            selectionAnchor = outcome.anchor
        case .exit:
            // Only ever forwarded here when there is a narrowing to undo —
            // `ShelfKey.isCollapsedStripCommand` asks first, so a resting strip
            // never swallows Escape.
            clearStripSelection()
        case .moveToTrash:
            moveStripSelectionToTrash(ids: ids)
        case .activate, .ascend, .removeFromShelf, .quickLook:
            break
        }
    }

    /// ⌘⌫ on the collapsed strip, which is where it is actually wanted: the
    /// file dropped on the desktop, used, and now unwanted is looked at as a
    /// pill, not as an expanded panel.
    ///
    /// Same subject rule as everywhere else on this strip — the pick when it is
    /// narrowed, the whole shelf when it is not — so what leaves is what the
    /// header says (ADR 0012, ADR 0014). Resolved against `stripRowIDs`, the
    /// rows actually on screen, rather than against storage.
    private func moveStripSelectionToTrash(ids: [UUID]) {
        let live = ShelfSelection.effective(explicit: selection, ids: ids)
        let doomed = manager.items(of: shelfID).filter { live.contains($0.id) }
        guard !doomed.isEmpty else { return }
        ShelfTrash.move(items: doomed, in: shelfID, manager: manager)
        selection.subtract(doomed.map(\.id))
        stripFocusedIndex = nil
    }

    /// ⇧-arrow. The range grows out of what is **explicitly** selected, not out
    /// of the effective set: the default is the whole shelf, and a range that
    /// starts by already containing every row could never narrow to anything.
    private func extendStripSelection(to newIndex: Int, ids: [UUID]) {
        let base: Set<Int> = selection.isEmpty
            ? []
            : Set(ids.indices.filter { selection.contains(ids[$0]) })
        let indices = ShelfFocus.extendedSelection(
            base, from: stripFocusedIndex, to: newIndex
        )
        selection = ShelfSelection.narrowed(
            to: Set(indices.compactMap { ids.indices.contains($0) ? ids[$0] : nil }),
            ids: ids
        )
    }

    private func toggle(to expanded: Bool) {
        guard expanded != isExpanded else { return }
        onResize(expanded)
        clearStripFocus()
        withAnimation(transitionAnimation) {
            isExpanded = expanded
        }
    }

    private func toggleDock(to docked: Bool) {
        guard docked != isDocked else { return }
        onDockChanged(docked)
        clearStripFocus()
        withAnimation(transitionAnimation) {
            isDocked = docked
        }
    }
}

private struct DockedTabView: View {
    let onExpand: () -> Void
    let dropTargeted: Bool

    @State private var hovering = false

    var body: some View {
        Color.clear
            .overlay {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        dropTargeted
                            ? Design.Ink.primary
                            : (hovering ? Design.Ink.emphasis : Design.Ink.glyphDim)
                    )
                    // Nudge the chevron to match the visible portion of the
                    // panel (right side is clipped past the screen edge).
                    .offset(x: -6)
            }
            .contentShape(Rectangle())
            // Trace the panel's actual outer corner radius (22, set on the
            // FloatingPanel rootLayer) so the highlight hugs the visible
            // capsule instead of an inset rectangle. Negative padding pulls
            // the stroke flush with the panel's outline; the right edge is
            // clipped offscreen by the dock offset and never shows anyway.
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                    .strokeBorder(
                        Design.Line.dropTarget.opacity(dropTargeted ? 1 : 0),
                        lineWidth: Design.Line.dockedDropWidth
                    )
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
            .onTapGesture(perform: onExpand)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("a11y.expand-shelf"))
            .accessibilityAddTraits(.isButton)
            .help(L("a11y.expand-shelf"))
            .animation(Design.Motion.state, value: dropTargeted)
            .animation(Design.Motion.state, value: hovering)
    }
}

enum ShelfViewMode: String {
    case grid
    case list
}

/// What the Reveal in Finder pill hands to Finder.
///
/// Pure, because the only other way to check it is to watch a Finder window
/// open. It used to be `items` and nothing else: a user who had picked three
/// files out of eight got all eight revealed, which made the pill the one
/// control on the panel that ignored the selection the panel exists to let you
/// make. Nothing picked still means the whole shelf — the same reading the
/// strip's own default has.
enum ShelfReveal {
    static func urls(picked: [URL], fallback: [URL]) -> [URL] {
        picked.isEmpty ? fallback : picked
    }
}

/// Internal rather than file-private so a test can host it in a real panel and
/// drive real clicks at its tiles. The claim this view carried about SwiftUI
/// gesture precedence was wrong for the strip (ADR 0012's amendment) and could
/// only ever be settled by driving events, not by reading source.
struct ExpandedShelfView: View {
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    @Binding var selection: Set<UUID>
    /// Set by the container when ⌘K arrived while collapsed or docked. Consumed
    /// exactly once, on appear, after the AppKit panel has finished resizing.
    @Binding var palettePending: Bool
    let onCollapse: () -> Void
    let onClose: () -> Void
    let onDock: () -> Void

    @AppStorage("shelf.viewMode") private var viewModeRaw: String = ShelfViewMode.grid.rawValue
    /// "Clear the shelf after dragging out". Read here as well as in the
    /// container because the grid and the list drag out on their own; the two
    /// read one key, so they cannot disagree about what a drag should do.
    @AppStorage("shelf.clearAfterDragOut") private var clearAfterDragOut: Bool = false
    @State private var draggingIDs: Set<UUID> = []
    @EnvironmentObject private var conversionService: ConversionService
    @EnvironmentObject private var ocrService: OCRService
    @EnvironmentObject private var routeService: RouteService

    // Folder navigation: empty stack = shelf root (showing ShelfItems);
    // non-empty stack's `last` is the currently-displayed folder, with its
    // children cached in `folderContents`. The cache survives pop/push so
    // navigating back is instant.
    @State private var folderStack: [URL] = []
    @State private var folderContents: [URL: [FolderEntry]] = [:]
    @State private var loadingFolders: Set<URL> = []
    @State private var navDirection: NavDirection = .forward
    /// Selection inside the folder browser — keyed by `FolderEntry.id`.
    /// Cleared on push/pop because each level renders a fresh entry list
    /// with new UUIDs, so carrying selection across levels would just hold
    /// stale identifiers.
    @State private var folderSelection: Set<UUID> = []

    /// The keyboard cursor, as an index into whatever is on screen — the
    /// reversed items at shelf root, `currentEntries` inside a folder. It is
    /// **not** the selection: an item can be focused without being selected,
    /// which is why the ring and the fill are different tokens. Nil until the
    /// user presses an arrow key, and nil is what keeps every pointer-only
    /// session byte-identical to how it behaved before.
    @State private var focusedIndex: Int?
    /// The content area's own width, measured rather than assumed, because the
    /// column count of an adaptive `LazyVGrid` is a function of it and ↓ has to
    /// move by exactly one row.
    @State private var contentWidth: CGFloat = 0
    /// The live menu the ⌘K palette is rendering. Holding it is what keeps the
    /// builders' `@objc` target objects alive for as long as a row can be run.
    @State private var paletteMenu: NSMenu?
    @State private var paletteQuery: String = ""
    @State private var paletteHighlight: Int = 0

    private var viewMode: ShelfViewMode {
        get { ShelfViewMode(rawValue: viewModeRaw) ?? .grid }
    }

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    // Adaptive columns let the row pack as many cards as fit; LazyVGrid's
    // .center alignment then centers the row when there are fewer items than
    // columns (so 1 or 2 files don't pin to the left).
    //
    // The bounds come from `ShelfLayout` because three things need the same
    // numbers: this grid, `ShelfFocus` (so ↓ moves by exactly one row), and the
    // panel-height arithmetic. A second copy of the minimum is a panel sized
    // for a different grid than the one drawn in it.
    private var columns: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: ShelfLayout.gridColumnMinimum,
                maximum: ShelfLayout.gridColumnMaximum
            ),
            spacing: ShelfLayout.gridColumnSpacing,
            alignment: .top
        )]
    }

    private var shelf: Shelf? { manager.shelf(id: shelfID) }

    private var currentFolderURL: URL? { folderStack.last }
    private var inFolder: Bool { !folderStack.isEmpty }
    private var currentEntries: [FolderEntry] {
        currentFolderURL.flatMap { folderContents[$0] } ?? []
    }
    private var isCurrentFolderLoading: Bool {
        guard let url = currentFolderURL else { return false }
        return folderContents[url] == nil && loadingFolders.contains(url)
    }

    private var countTitle: String {
        items.count == 1
            ? L("1 File")
            : String(format: L("%lld Files"), items.count)
    }

    private var headerPrimary: String {
        if let url = currentFolderURL { return url.lastPathComponent }
        if let n = shelf?.name, !n.isEmpty { return n }
        return countTitle
    }

    private var headerSubtitle: String {
        if inFolder {
            let shelfTitle = (shelf?.name?.isEmpty == false ? shelf?.name : nil) ?? L("shelf.default-name")
            let parents = folderStack.dropLast().map(\.lastPathComponent)
            let crumbs = ([shelfTitle] + parents).joined(separator: " › ")
            let countLabel: String
            if isCurrentFolderLoading {
                countLabel = L("Loading…")
            } else {
                let n = currentEntries.count
                countLabel = n == 1
                    ? L("1 file")
                    : String(format: L("%lld files"), n)
            }
            return "\(crumbs) · \(countLabel)"
        }
        let size = manager.displayTotalSize(of: shelfID)
        if shelf?.name?.isEmpty == false {
            return size == "—" ? countTitle : "\(countTitle) · \(size)"
        }
        return size
    }

    var body: some View {
        VStack(spacing: ShelfLayout.expandedOuterSpacing) {
            header
            content
            Spacer(minLength: 0)
            revealButton
        }
        // Clear the selection on a click that landed on the panel rather than
        // on a cell: the space between tiles, the margins, the area under the
        // last row.
        //
        // **This is an ancestor gesture and it really does fire on cell clicks
        // too.** It used to carry a comment saying the opposite — that
        // "ShelfDragOverlay's NSView consumes tile clicks before they reach
        // this gesture" — which is the same false claim about SwiftUI gesture
        // precedence that ADR 0012's amendment already had to reverse for the
        // collapsed strip. Measured here by driving real clicks at real tiles
        // and watching every write to the selection binding: one click wrote
        // the selection twice, `[]` then `[tile]`. A plain click survived that
        // by luck, because the clear runs first and the pick overwrites it. A
        // ⌘-click did not: the clear emptied the selection the toggle was about
        // to add to, so **a second file could not be added with the pointer at
        // all**.
        //
        // What stops it is not moving this gesture but giving the cells one of
        // their own: the innermost SwiftUI gesture wins, so a cell that claims
        // its click keeps it (`claimsClickFromAncestors`, applied at every
        // `ShelfDragOverlay` in this view). Measured against the alternatives —
        // a `.background` gesture and an AppKit catcher both fix the tile but
        // lose the clear inside the scroll view, because the scroll view
        // occludes them. `ExpandedTileClickTests` drives all three cases.
        .contentShape(Rectangle())
        .onTapGesture {
            selection.removeAll()
            folderSelection.removeAll()
            clearFocusCursor()
        }
        .overlay {
            if let menu = paletteMenu {
                ActionPaletteOverlay(
                    entries: ShelfActionPalette.entries(in: menu),
                    query: $paletteQuery,
                    highlighted: $paletteHighlight,
                    onRun: runPaletteEntry,
                    onMove: movePaletteHighlight,
                    onDismiss: closePalette
                )
                .transition(.opacity)
            }
        }
        .onReceive(manager.keyCommandRequested) { request in
            guard request.shelfID == shelfID else { return }
            handleKeyCommand(request.command)
        }
        .onReceive(manager.paletteRequested) { id in
            guard id == shelfID else { return }
            openPalette()
        }
        // A ⌘K that arrived while the shelf was collapsed or docked. The menu
        // is popped relative to the panel's frame, so it has to wait for the
        // AppKit resize to finish or it lands over the old, smaller rect. The
        // wait is read from the same token that drives that animation, so the
        // two cannot drift apart, and it is zero under Reduce Motion because
        // there is no animation to wait for.
        .onAppear {
            guard palettePending else { return }
            palettePending = false
            let settle = Design.Motion
                .panelTiming(.frame, reduceMotion: Design.Motion.isReduced)?.duration ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                openPalette()
            }
        }
        // The key monitor has to know whether a cursor exists before it decides
        // what the space bar means, and this is the only place that knows.
        .onChange(of: focusedIndex) { newValue in
            if newValue == nil {
                manager.shelvesWithKeyboardFocus.remove(shelfID)
            } else {
                manager.shelvesWithKeyboardFocus.insert(shelfID)
            }
        }
        // A cursor left pointing past the end of a shorter shelf would ring a
        // card that is no longer there.
        .onChange(of: focusCount) { newCount in
            guard let index = focusedIndex else { return }
            focusedIndex = newCount == 0 ? nil : min(index, newCount - 1)
        }
        .onDisappear {
            manager.shelvesWithKeyboardFocus.remove(shelfID)
        }
        .onReceive(manager.selectAllRequested) { id in
            // Cmd-A from the app-level key monitor. Routes to the right
            // selection set depending on what the user is actually looking at.
            guard id == shelfID else { return }
            if inFolder {
                folderSelection = Set(currentEntries.map(\.id))
            } else {
                selection = Set(items.map(\.id))
            }
        }
        .onReceive(manager.copyRequested) { id in
            // Cmd-C: the same payload the Copy row and the chat hotkey write,
            // so all three routes paste identically — a file target attaches
            // the files, a text target gets the readable block. Empty
            // selection is a no-op so we don't clobber the user's clipboard.
            guard id == shelfID else { return }
            let entries: [ShelfClipboardPayload.Entry]
            if inFolder {
                entries = currentEntries
                    .filter { folderSelection.contains($0.id) }
                    .map { .path($0.url) }
            } else {
                entries = ShelfClipboardPayload.entries(
                    for: items.filter { selection.contains($0.id) }
                )
            }
            let pasteboardItems = ShelfClipboardPayload.pasteboardItems(for: entries)
            guard !pasteboardItems.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(pasteboardItems)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Design.Space.md) {
            ShelfChromeButton(
                systemName: "chevron.left",
                label: inFolder ? L("a11y.back") : L("a11y.collapse-shelf"),
                action: handleBack
            )
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                HStack(spacing: Design.Space.sm) {
                    if inFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Design.Ink.glyph)
                            .accessibilityHidden(true)
                    } else if let accent = shelf?.accent {
                        ShelfAccentBadge(accent: accent, size: 10)
                    }
                    Text(headerPrimary)
                        .font(Design.Text.title)
                        .foregroundStyle(Design.Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !inFolder, shelf?.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Design.Ink.glyph)
                            .accessibilityLabel(L("a11y.pinned"))
                            .help(L("a11y.pinned"))
                    }
                }
                Text(headerSubtitle)
                    .font(Design.Text.item)
                    .foregroundStyle(Design.Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            // Quick-dock to the right edge — same animation as the grab
            // handle in the collapsed view, surfaced here so the user
            // doesn't need to collapse first to park the panel. Sized
            // smaller than the primary back button so it sits comfortably
            // alongside the view-mode toggle.
            ShelfChromeButton(
                systemName: "arrow.right.to.line",
                label: L("a11y.dock-shelf"),
                action: onDock
            )
            ViewModeToggle(
                mode: Binding(
                    get: { viewMode },
                    set: { viewModeRaw = $0.rawValue }
                )
            )
            if !inFolder {
                ShelfActionMenu(manager: manager, shelfID: shelfID)
            }
        }
        .frame(height: ShelfLayout.expandedHeaderHeight)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if inFolder {
                folderContentBody
                    .id(currentFolderURL?.path ?? "folder-root")
                    .transition(navTransition)
            } else {
                shelfContentBody
                    .id("shelf-root")
                    .transition(navTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // The adaptive grid's column count is a function of this width, and ↓
        // has to move by exactly one row. Measured, never assumed.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { contentWidth = $0 }
            }
            .allowsHitTesting(false)
        )
    }

    private var navTransition: AnyTransition {
        // The slide is the whole point of this transition — it says which way
        // you just moved through the folder tree. Under Reduce Motion there is
        // nothing left to say it with, so it becomes a plain crossfade.
        if Design.Motion.isReduced { return .opacity }
        switch navDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .back:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    @ViewBuilder
    private var shelfContentBody: some View {
        switch viewMode {
        case .grid: shelfGrid
        case .list: shelfList
        }
    }

    @ViewBuilder
    private var folderContentBody: some View {
        if isCurrentFolderLoading {
            VStack(spacing: Design.Space.lg) {
                ProgressView().progressViewStyle(.circular)
                Text(L("Loading…"))
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentEntries.isEmpty {
            VStack(spacing: Design.Space.md) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Design.Ink.quaternary)
                    .accessibilityHidden(true)
                Text(L("Empty folder"))
                    .font(Design.Text.item)
                    .foregroundStyle(Design.Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewMode {
            case .grid: folderGrid
            case .list: folderList
            }
        }
    }

    /// A drag-out whose source file is gone was a real move, so the card has
    /// nothing left to point at and goes. Rows only — no file is touched here
    /// (ADR 0001); the managed copy, if any, is left to cache eviction.
    private func dragSet(for itemID: UUID) -> Set<UUID> {
        if selection.contains(itemID) && selection.count > 1 {
            return selection
        }
        return [itemID]
    }

    // MARK: - Folder navigation

    private func handleBack() {
        if inFolder {
            popFolder()
        } else {
            onCollapse()
        }
    }

    private func enterFolder(_ url: URL) {
        guard folderStack.last != url else { return }
        navDirection = .forward
        loadFolderIfNeeded(url)
        withAnimation(Design.Motion.transform) {
            folderStack.append(url)
            selection.removeAll()
            folderSelection.removeAll()
            // Each level is a fresh list, so the index means something else on
            // the other side — the same reason folderSelection is cleared here.
            focusedIndex = nil
        }
    }

    private func popFolder() {
        guard !folderStack.isEmpty else { return }
        navDirection = .back
        withAnimation(Design.Motion.transform) {
            _ = folderStack.removeLast()
            folderSelection.removeAll()
            focusedIndex = nil
        }
    }

    private func handleEntryDoubleClick(_ entry: FolderEntry) {
        if entry.isDirectory {
            enterFolder(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func loadFolderIfNeeded(_ url: URL) {
        if folderContents[url] != nil || loadingFolders.contains(url) { return }
        loadingFolders.insert(url)
        Task.detached(priority: .userInitiated) {
            let entries = readDirectory(url: url)
            await MainActor.run {
                folderContents[url] = entries
                loadingFolders.remove(url)
            }
        }
    }

    private var shelfGrid: some View {
        let target = shelfID
        let sel = $selection
        // Newest-first in the expanded view so the just-dropped tile lands at
        // the top of the grid where the user is looking. Storage order stays
        // append-at-end (the collapsed stack still puts the newest tile on top).
        let displayed = ShelfDisplayOrder.displayed(items)
        return ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: ShelfLayout.gridRowSpacing) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                    DocumentGridItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        isFocused: focusedIndex == index,
                        isBeingDragged: draggingIDs.contains(item.id),
                        selectedURLsProvider: {
                            // If clicked tile is part of a multi-selection, drag all.
                            let selectedIDs = sel.wrappedValue
                            if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
                                return manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                                    .compactMap { $0.fileURL }
                            }
                            return item.fileURL.map { [$0] } ?? []
                        },
                        contextMenuBuilder: {
                            let selectedShelfItems = ShelfSelection.itemMenuSubject(
                                rightClicked: item.id,
                                explicit: sel.wrappedValue,
                                items: manager.items(of: target)
                            )
                            return ShelfContextMenu.make(
                                for: item,
                                selectedItems: selectedShelfItems,
                                shelfID: target,
                                manager: manager,
                                conversionService: conversionService,
                                ocrService: ocrService,
                                routeService: routeService
                            )
                        },
                        onRemove: { manager.removeItemUndoably(id: item.id, from: target) },
                        onClick: { modifiers in handleClick(itemID: item.id, modifiers: modifiers) },
                        onDragStart: {
                            manager.isDragging = true
                            draggingIDs = dragSet(for: item.id)
                        },
                        onDragEnd: {
                            manager.isDragging = false
                            draggingIDs.removeAll()
                        },
                        onMovedOut: { urls in
                            manager.removeItemsAfterDragOut(
                                withFileURLs: urls,
                                from: target,
                                closeWhenEmpty: clearAfterDragOut
                            )
                        },
                        onNavigateInto: {
                            if let url = item.fileURL { enterFolder(url) }
                        }
                    )
                }
            }
            .padding(.vertical, ShelfLayout.gridVerticalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.gridAnchor, style: .continuous)
                .fill(Color.clear)
                .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
        )
        .onChange(of: focusedIndex) { _ in scrollToFocus(proxy) }
        }
        .environmentObject(conversionService)
        .environmentObject(ocrService)
        .environmentObject(routeService)
    }

    /// Arrow keys that walk off the visible area are useless, so the cursor
    /// drags the scroll view along with it.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = focusedID else { return }
        withAnimation(Design.Motion.state) { proxy.scrollTo(id, anchor: .center) }
    }

    private var shelfList: some View {
        let target = shelfID
        let sel = $selection
        let displayed = ShelfDisplayOrder.displayed(items)
        return ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: Design.Space.hair) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                    DocumentListItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        isFocused: focusedIndex == index,
                        isBeingDragged: draggingIDs.contains(item.id),
                        selectedURLsProvider: {
                            let selectedIDs = sel.wrappedValue
                            if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
                                return manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                                    .compactMap { $0.fileURL }
                            }
                            return item.fileURL.map { [$0] } ?? []
                        },
                        contextMenuBuilder: {
                            let selectedShelfItems = ShelfSelection.itemMenuSubject(
                                rightClicked: item.id,
                                explicit: sel.wrappedValue,
                                items: manager.items(of: target)
                            )
                            return ShelfContextMenu.make(
                                for: item,
                                selectedItems: selectedShelfItems,
                                shelfID: target,
                                manager: manager,
                                conversionService: conversionService,
                                ocrService: ocrService,
                                routeService: routeService
                            )
                        },
                        onRemove: { manager.removeItemUndoably(id: item.id, from: target) },
                        onClick: { modifiers in handleClick(itemID: item.id, modifiers: modifiers) },
                        onDragStart: {
                            manager.isDragging = true
                            draggingIDs = dragSet(for: item.id)
                        },
                        onDragEnd: {
                            manager.isDragging = false
                            draggingIDs.removeAll()
                        },
                        onMovedOut: { urls in
                            manager.removeItemsAfterDragOut(
                                withFileURLs: urls,
                                from: target,
                                closeWhenEmpty: clearAfterDragOut
                            )
                        },
                        onNavigateInto: {
                            if let url = item.fileURL { enterFolder(url) }
                        }
                    )
                }
            }
            .padding(.vertical, ShelfLayout.gridVerticalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: focusedIndex) { _ in scrollToFocus(proxy) }
        }
        .environmentObject(conversionService)
        .environmentObject(ocrService)
        .environmentObject(routeService)
    }

    private var folderGrid: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .center, spacing: ShelfLayout.gridRowSpacing) {
                ForEach(Array(currentEntries.enumerated()), id: \.element.id) { index, entry in
                    FolderEntryGridCell(
                        entry: entry,
                        isSelected: folderSelection.contains(entry.id),
                        isFocused: focusedIndex == index,
                        onClick: { modifiers in handleFolderClick(entry: entry, modifiers: modifiers) },
                        onDoubleClick: { handleEntryDoubleClick(entry) },
                        onNavigateInto: { enterFolder(entry.url) },
                        urlsProvider: { selectedFolderURLs(draggedEntry: entry) }
                    )
                }
            }
            .padding(.vertical, ShelfLayout.gridVerticalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: focusedIndex) { _ in scrollToFocus(proxy) }
        }
    }

    private var folderList: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: Design.Space.hair) {
                ForEach(Array(currentEntries.enumerated()), id: \.element.id) { index, entry in
                    FolderEntryListItem(
                        entry: entry,
                        isSelected: folderSelection.contains(entry.id),
                        isFocused: focusedIndex == index,
                        onClick: { modifiers in handleFolderClick(entry: entry, modifiers: modifiers) },
                        onDoubleClick: { handleEntryDoubleClick(entry) },
                        onNavigateInto: { enterFolder(entry.url) },
                        urlsProvider: { selectedFolderURLs(draggedEntry: entry) }
                    )
                }
            }
            .padding(.vertical, ShelfLayout.gridVerticalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: focusedIndex) { _ in scrollToFocus(proxy) }
        }
    }

    private func handleFolderClick(entry: FolderEntry, modifiers: NSEvent.ModifierFlags) {
        clearFocusCursor()
        if modifiers.contains(.command) {
            if folderSelection.contains(entry.id) {
                folderSelection.remove(entry.id)
            } else {
                folderSelection.insert(entry.id)
            }
        } else {
            folderSelection = [entry.id]
        }
    }

    /// URLs to drag when the user starts a drag from `draggedEntry`. If the
    /// drag started on a tile that's part of a multi-selection, all selected
    /// entries ride along; otherwise just the single dragged entry.
    private func selectedFolderURLs(draggedEntry: FolderEntry) -> [URL] {
        if folderSelection.contains(draggedEntry.id) && folderSelection.count > 1 {
            return currentEntries
                .filter { folderSelection.contains($0.id) }
                .map { $0.url }
        }
        return [draggedEntry.url]
    }

    // MARK: - Keyboard

    /// The pointer has taken over, so the ring goes: a cursor nobody is driving
    /// is a second highlight competing with the selection.
    ///
    /// Guarded rather than assigned outright so that a session which never
    /// touches the keyboard never writes this state at all — a pointer user's
    /// click is the same click it was before there was a focus model.
    private func clearFocusCursor() {
        guard focusedIndex != nil else { return }
        focusedIndex = nil
    }

    /// How many cells the cursor can land on right now.
    private var focusCount: Int { inFolder ? currentEntries.count : items.count }

    /// Newest-first, the order the grid and the list both draw. The cursor
    /// indexes this, so it matches what the eye sees rather than storage order.
    private var displayedItems: [ShelfItem] { ShelfDisplayOrder.displayed(items) }

    private var columnCount: Int {
        guard viewMode == .grid else { return 1 }
        return ShelfFocus.columnCount(
            availableWidth: contentWidth,
            minimum: ShelfLayout.gridColumnMinimum,
            spacing: ShelfLayout.gridColumnSpacing
        )
    }

    /// The id of the focused cell, for scrolling it back into view.
    private var focusedID: UUID? {
        guard let index = focusedIndex else { return nil }
        if inFolder {
            return currentEntries.indices.contains(index) ? currentEntries[index].id : nil
        }
        let displayed = displayedItems
        return displayed.indices.contains(index) ? displayed[index].id : nil
    }

    private func handleKeyCommand(_ command: ShelfKey.Command) {
        // While the palette is up it owns the keyboard. It only gets here at
        // all when its query field failed to take first responder — with the
        // field focused, the monitor bails before sending anything.
        if paletteMenu != nil {
            handlePaletteCommand(command)
            return
        }
        switch command {
        case .move(let direction):
            guard let next = ShelfFocus.move(
                direction, from: focusedIndex, count: focusCount, columns: columnCount
            ) else { return }
            focusedIndex = next
        case .extend(let direction):
            guard let next = ShelfFocus.move(
                direction, from: focusedIndex, count: focusCount, columns: columnCount
            ) else { return }
            extendSelection(to: next)
            focusedIndex = next
        case .toggleSelection:
            toggleSelectionAtFocus()
        case .activate:
            activateFocused()
        case .ascend:
            if inFolder { popFolder() }
        case .removeFromShelf:
            removeFocusedFromShelf()
        case .moveToTrash:
            moveSelectionToTrash()
        case .quickLook:
            quickLookFocused()
        case .exit:
            if inFolder { popFolder() } else { onCollapse() }
        }
    }

    private var selectedIndices: Set<Int> {
        if inFolder {
            return Set(currentEntries.indices.filter {
                folderSelection.contains(currentEntries[$0].id)
            })
        }
        let displayed = displayedItems
        return Set(displayed.indices.filter { selection.contains(displayed[$0].id) })
    }

    private func extendSelection(to newIndex: Int) {
        let indices = ShelfFocus.extendedSelection(
            selectedIndices, from: focusedIndex, to: newIndex
        )
        if inFolder {
            folderSelection = Set(indices.compactMap {
                currentEntries.indices.contains($0) ? currentEntries[$0].id : nil
            })
        } else {
            let displayed = displayedItems
            selection = Set(indices.compactMap {
                displayed.indices.contains($0) ? displayed[$0].id : nil
            })
        }
    }

    private func toggleSelectionAtFocus() {
        guard let index = focusedIndex else { return }
        if inFolder {
            guard currentEntries.indices.contains(index) else { return }
            let id = currentEntries[index].id
            if folderSelection.contains(id) {
                folderSelection.remove(id)
            } else {
                folderSelection.insert(id)
            }
        } else {
            let displayed = displayedItems
            guard displayed.indices.contains(index) else { return }
            let id = displayed[index].id
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        }
    }

    /// Return and ⌘↓, taking the same two branches a double-click already
    /// takes: a folder is descended into, anything else is handed to the system.
    private func activateFocused() {
        guard let index = focusedIndex else { return }
        if inFolder {
            guard currentEntries.indices.contains(index) else { return }
            handleEntryDoubleClick(currentEntries[index])
            return
        }
        let displayed = displayedItems
        guard displayed.indices.contains(index), let url = displayed[index].fileURL else { return }
        if displayed[index].isDirectory {
            enterFolder(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// ⌘Y, Finder's other half of the Quick Look pair. Previews from the focused
    /// card rather than from the newest one, which is what the space bar does
    /// when there is no cursor.
    private func quickLookFocused() {
        let urls = items.compactMap(\.fileURL)
        guard !urls.isEmpty else { return }
        let focusedURL: URL? = {
            guard !inFolder, let index = focusedIndex else { return nil }
            let displayed = displayedItems
            return displayed.indices.contains(index) ? displayed[index].fileURL : nil
        }()
        let start = ShelfItemActions.quickLookStartIndex(for: focusedURL, in: urls)
        QuickLookController.shared.toggle(startingAt: start)
    }

    /// ⌫. Rows only — the file is never touched (ADR 0001); the removal goes
    /// through `ShelfKeyboardRemove`, which is where that invariant is pinned.
    private func removeFocusedFromShelf() {
        // Folder browsing shows the user's real directory, not the shelf. There
        // is no row there to take off anything, and the only other reading of
        // this key is the one ADR 0001 forbids.
        guard !inFolder, let index = focusedIndex else { return }
        let displayed = displayedItems
        guard displayed.indices.contains(index) else { return }
        let target = displayed[index]
        // If the focused card is part of a multi-selection, the whole selection
        // goes — the same rule the drag and the context menu already use.
        let doomed = selection.contains(target.id) && selection.count > 1
            ? displayed.filter { selection.contains($0.id) }
            : [target]
        ShelfKeyboardRemove.removeFromShelf(items: doomed, in: shelfID, manager: manager)
        selection.subtract(doomed.map(\.id))
        // `items` is already the post-removal list. Holding the cursor at the
        // same slot lets a run of ⌫ keep deleting forwards, and it falls away
        // when the last card goes.
        let remaining = items.count
        focusedIndex = remaining > 0 ? min(index, remaining - 1) : nil
    }

    /// ⌘⌫. The file itself goes to the Bin — the one command on this keyboard
    /// that touches something the user owns, which is why it does not do the
    /// touching: `ShelfTrash` owns the only `recycle` a shelf action makes, and
    /// the Bin means ⌘Z can put the file back where it was.
    ///
    /// The subject is what the header already claims a drag would take — the
    /// pick when the strip is narrowed, the whole shelf when it is not (ADR
    /// 0012, ADR 0014). Deliberately not the focus cursor that ⌫ uses: a shelf
    /// the user has only ever pointed at has no cursor, and that is the state
    /// this key is wanted in.
    private func moveSelectionToTrash() {
        // Folder browsing shows the user's real directory, not the shelf.
        // There are no shelf rows on screen for this to name, and the only
        // other reading of the key is "recycle what I am looking inside",
        // which is not something a keystroke in this app may ever mean.
        guard !inFolder else { return }
        let doomed = ShelfSelection.carried(displayedItems, explicit: selection)
        guard !doomed.isEmpty else { return }
        ShelfTrash.move(items: doomed, in: shelfID, manager: manager)
        selection.subtract(doomed.map(\.id))
        focusedIndex = nil
    }

    // MARK: - Action palette

    /// ⌘K. The menu is built by the same builder the pointer uses, so the
    /// palette lists exactly what a right-click would offer: the item menu when
    /// something is focused or selected, the shelf menu otherwise.
    private func openPalette() {
        // Folder browsing shows the user's directory, and neither builder
        // describes actions on it. ⌘K stays quiet there rather than offering
        // shelf actions that would act somewhere the user is not looking.
        guard !inFolder else { return }
        let selected = displayedItems.filter { selection.contains($0.id) }
        let focused: ShelfItem? = {
            guard let index = focusedIndex else { return nil }
            let displayed = displayedItems
            return displayed.indices.contains(index) ? displayed[index] : nil
        }()
        let subject = focused ?? selected.first
        let menu: NSMenu
        if let subject {
            let subjectItems = ShelfSelection.itemMenuSubject(
                rightClicked: subject.id,
                explicit: selection,
                items: displayedItems
            )
            menu = ShelfContextMenu.make(
                for: subject,
                selectedItems: subjectItems,
                shelfID: shelfID,
                manager: manager,
                conversionService: conversionService,
                ocrService: ocrService,
                routeService: routeService
            )
        } else {
            menu = ShelfActionMenuBuilder.make(
                manager: manager, shelfID: shelfID, routeService: routeService
            )
        }
        paletteQuery = ""
        paletteHighlight = 0
        withAnimation(Design.Motion.state) { paletteMenu = menu }
    }

    private func closePalette() {
        withAnimation(Design.Motion.state) { paletteMenu = nil }
        paletteQuery = ""
        paletteHighlight = 0
        // Put first responder back on the panel's content view, which is what
        // keeps `QuickLookController` in the space bar's path. A responder
        // stranded on the removed query field would leave it at the window.
        if let window = NSApp.keyWindow, window.contentView?.acceptsFirstResponder == true {
            window.makeFirstResponder(window.contentView)
        }
    }

    private var paletteEntries: [ShelfActionPalette.Entry] {
        guard let menu = paletteMenu else { return [] }
        return ShelfActionPalette.filter(
            ShelfActionPalette.entries(in: menu), query: paletteQuery
        )
    }

    private func movePaletteHighlight(_ delta: Int) {
        let count = paletteEntries.count
        guard count > 0 else { return }
        paletteHighlight = max(0, min(count - 1, paletteHighlight + delta))
    }

    private func runPaletteEntry(_ entry: ShelfActionPalette.Entry) {
        // Close first: several rows put up a modal panel or an alert, and
        // running one from under an overlay that is still on screen leaves the
        // palette floating over it.
        closePalette()
        ShelfActionPalette.perform(entry)
    }

    private func handlePaletteCommand(_ command: ShelfKey.Command) {
        switch command {
        case .move(.up), .extend(.up):
            movePaletteHighlight(-1)
        case .move(.down), .extend(.down):
            movePaletteHighlight(1)
        case .activate:
            let rows = paletteEntries
            guard rows.indices.contains(paletteHighlight) else { return }
            runPaletteEntry(rows[paletteHighlight])
        case .exit:
            closePalette()
        default:
            break
        }
    }

    private func handleClick(itemID: UUID, modifiers: NSEvent.ModifierFlags) {
        // Card clicks always go to selection. Folders are entered via the
        // inline chevron button rendered next to their name — that's the
        // only navigation affordance, so a stray card click can't accidentally
        // descend into a folder while the user is just trying to select it.
        clearFocusCursor()
        if modifiers.contains(.command) {
            if selection.contains(itemID) {
                selection.remove(itemID)
            } else {
                selection.insert(itemID)
            }
        } else {
            selection = [itemID]
        }
    }

    private var revealButton: some View {
        return HStack(spacing: Design.Space.md) {
            Spacer()
            if inFolder {
                let allSelected = !currentEntries.isEmpty
                    && folderSelection.count == currentEntries.count
                let someSelected = !folderSelection.isEmpty
                SelectAllButton(
                    allSelected: allSelected,
                    someSelected: someSelected,
                    enabled: !currentEntries.isEmpty,
                    action: {
                        if allSelected {
                            folderSelection.removeAll()
                        } else {
                            folderSelection = Set(currentEntries.map(\.id))
                        }
                    }
                )
            } else {
                let allSelected = !items.isEmpty && selection.count == items.count
                let someSelected = !selection.isEmpty
                SelectAllButton(
                    allSelected: allSelected,
                    someSelected: someSelected,
                    enabled: !items.isEmpty,
                    action: {
                        if allSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(items.map(\.id))
                        }
                    }
                )
            }
            RevealInFinderButton(enabled: revealEnabled, action: revealAction)
            Spacer()
        }
    }

    private var revealEnabled: Bool {
        if inFolder { return currentFolderURL != nil }
        return !items.isEmpty
    }

    /// Reveals what the user picked, and the whole shelf only when they have
    /// picked nothing.
    ///
    /// It used to reveal every file on the shelf unconditionally, so a user who
    /// had selected three of eight got eight windows' worth of Finder selection
    /// — the pill was the one control on this panel that ignored the selection
    /// the panel exists to let you make.
    private func revealAction() {
        if let url = currentFolderURL {
            let picked = currentEntries.filter { folderSelection.contains($0.id) }.map(\.url)
            NSWorkspace.shared.activateFileViewerSelecting(
                ShelfReveal.urls(picked: picked, fallback: [url])
            )
            return
        }
        let urls = ShelfReveal.urls(
            picked: ShelfDisplayOrder.displayed(items, selecting: selection)
                .compactMap { $0.fileURL },
            fallback: items.compactMap { $0.fileURL }
        )
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private enum NavDirection {
    case forward, back
}

/// Small circular chevron button rendered next to a folder name in the grid
/// label area (below the card). Clicking it descends into the folder; the
/// surrounding card click is reserved for selection so users can pick up a
/// folder without accidentally navigating into it.
private struct InlineNavigateChevron: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? Design.Ink.primary : Design.Ink.glyphBright)
                .frame(width: 14, height: 14)
                .background(
                    Circle()
                        .fill(hovering ? Design.Surface.chevronHover : Design.Surface.chevron)
                )
                .overlay(
                    Circle().strokeBorder(Design.Line.badge, lineWidth: Design.Line.hairlineWidth)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("a11y.open-folder"))
        .help(L("a11y.open-folder"))
        .onHover { hovering = $0 }
        .animation(Design.Motion.state, value: hovering)
    }
}

/// Lightweight description of a single child inside a folder being browsed.
/// Created on-demand when the user navigates into a folder; not persisted.
struct FolderEntry: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    let displayName: String
    let byteSize: Int64?
    let pixelSize: CGSize?

    init(
        id: UUID = UUID(),
        url: URL,
        isDirectory: Bool,
        displayName: String,
        byteSize: Int64? = nil,
        pixelSize: CGSize? = nil
    ) {
        self.id = id
        self.url = url
        self.isDirectory = isDirectory
        self.displayName = displayName
        self.byteSize = byteSize
        self.pixelSize = pixelSize
    }
}

/// Synchronously enumerates the immediate children of `url`. Intended to be
/// called from a detached task — it's blocking I/O. Hidden files are skipped
/// to match Finder's default view. We deliberately don't pass
/// `.skipsPackageDescendants` because the user explicitly clicked the
/// chevron to descend; macOS would otherwise return `[]` for any directory
/// it considers a package (`.app`, `.bundle`, but also some user-named dirs
/// with extensions registered as packages — e.g. a folder called `dist.js`
/// shows zero children even when it has gigabytes of content).
private func readDirectory(url: URL) -> [FolderEntry] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentTypeKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
    } catch {
        NSLog("Shelf: readDirectory failed for %@ — %@",
              url.path as NSString, error as NSError)
        return []
    }
    let entries = urls.map { childURL -> FolderEntry in
        let values = try? childURL.resourceValues(forKeys: Set(keys))
        let isDir = values?.isDirectory ?? false
        let bytes: Int64? = isDir ? nil : values?.fileSize.map(Int64.init)
        // Pull pixel dimensions for image children so the grid cell can pre-size
        // itself before the QL thumbnail arrives — keeps the layout from
        // jumping when previews crossfade in.
        let pixelSize: CGSize? = {
            guard !isDir,
                  let type = values?.contentType,
                  type.conforms(to: .image)
            else { return nil }
            return ShelfItem.readImagePixelSize(url: childURL)
        }()
        return FolderEntry(
            url: childURL,
            isDirectory: isDir,
            displayName: childURL.lastPathComponent,
            byteSize: bytes,
            pixelSize: pixelSize
        )
    }
    return entries.sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

/// Grid cell for a single child inside a folder being browsed. Mirrors
/// DocumentGridItem's visual language (card shadow, hover lift, label below)
/// but loads its thumbnail lazily and has no shelf-specific affordances
/// (no remove button, no shelf context menu).
struct FolderEntryGridCell: View {
    let entry: FolderEntry
    let isSelected: Bool
    /// Where the keyboard cursor is. Separate from `isSelected` on purpose: an
    /// entry can be focused without being selected, and the ring and the fill
    /// say different things.
    let isFocused: Bool
    /// Receives the click's modifier flags so the caller can implement
    /// cmd-click toggling. Plain click selects only this entry; navigating
    /// into a folder requires the inline chevron next to the name.
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onNavigateInto: () -> Void
    /// Resolved at drag-start time. When this entry is part of a multi-selection,
    /// returns every selected entry's URL so the drag carries them all.
    let urlsProvider: () -> [URL]

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var thumbnailIsIcon = true
    /// `.key` only while this cell's panel is the key window. Selection flips
    /// to its unemphasized pair otherwise — see `SelectionColor`.
    @Environment(\.controlActiveState) private var controlActiveState
    private var isEmphasized: Bool { controlActiveState == .key }

    private static let cardLongSide = Design.Size.tileLongSide
    private static let labelMinWidth = Design.Size.tileLabelMinWidth

    private var cardSize: CGSize {
        if let s = entry.pixelSize, s.width > 0, s.height > 0 {
            let aspect = s.width / s.height
            if aspect.isFinite, aspect > 0 {
                if aspect >= 1 {
                    return CGSize(width: Self.cardLongSide, height: Self.cardLongSide / aspect)
                } else {
                    return CGSize(width: Self.cardLongSide * aspect, height: Self.cardLongSide)
                }
            }
        }
        return Design.Size.tileFallback
    }

    var body: some View {
        let size = cardSize
        VStack(spacing: Design.Space.md) {
            cardFace(size: size)
                .frame(width: size.width, height: size.height)
                .shelfShadow(hovering ? Design.Depth.hover : Design.Depth.rest)
                .shelfShadow(Design.Depth.contact)
                .scaleEffect(hovering ? 1.03 : 1.0)
                .offset(y: hovering ? -3 : 0)
                .overlay(
                    ShelfDragOverlay(
                        provider: urlsProvider,
                        onStart: {},
                        onEnd: {},
                        onClick: onClick,
                        onDoubleClick: onDoubleClick,
                        visibleCardSize: { size }
                    )
                    .claimsClickFromAncestors()
                )
                .animation(Design.Motion.hover, value: hovering)
                .onHover { hovering = $0 }
                .frame(height: Self.cardLongSide, alignment: .bottom)

            VStack(spacing: Design.Space.hair) {
                HStack(spacing: Design.Space.xs) {
                    Text(entry.displayName)
                        .font(Design.Text.label)
                        .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.strong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityHidden(true)
                    if entry.isDirectory {
                        InlineNavigateChevron(action: onNavigateInto)
                    }
                }
                Text(metaText)
                    .font(Design.Text.meta)
                    .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .frame(width: max(size.width, Self.labelMinWidth))
        }
        .padding(.horizontal, Design.Space.md)
        .padding(.vertical, Design.Space.md)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                .fill(SelectionColor.fill(emphasized: isEmphasized).opacity(isSelected ? 1 : 0))
        )
        .focusRing(isFocused, cornerRadius: Design.Radius.tile)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L("a11y.item.hint"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onAppear { loadThumbnailIfNeeded() }
    }

    private var accessibilityLabel: String {
        ShelfItemAccessibility.itemLabel(
            name: entry.displayName,
            kind: entry.isDirectory ? L("Folder") : L("File"),
            meta: metaText
        )
    }

    private var metaText: String {
        if entry.isDirectory {
            if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
            return L("Folder")
        }
        if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? L("File") : ext.uppercased()
    }

    @ViewBuilder
    private func cardFace(size: CGSize) -> some View {
        let isImageEntry = !entry.isDirectory && entry.pixelSize != nil
        if let thumb = thumbnail {
            if isImageEntry, !thumbnailIsIcon {
                // Real photo preview: fill the whole card, rounded corners.
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous)
                            .strokeBorder(Design.Line.edge, lineWidth: Design.Line.hairlineWidth)
                    )
            } else {
                // Everything else (folder icon, app icon, document preview) —
                // render flush against the panel without a white "paper"
                // backdrop, matching the rest of the shelf's visual language.
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        } else {
            RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous)
                .fill(Design.Surface.skeleton)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous)
                        .strokeBorder(Design.Line.skeleton, lineWidth: Design.Line.hairlineWidth)
                )
        }
    }

    private func loadThumbnailIfNeeded() {
        if thumbnail != nil { return }
        // Workspace icon shows up immediately so the cell isn't a blank
        // square while QL renders. For images we then upgrade to QL's
        // photo thumbnail; for everything else we ask QL only for the
        // higher-resolution icon representation — otherwise QL renders
        // the file's contents on a white "page", which leaks into the
        // shelf's dark UI as a paper-like backdrop.
        thumbnail = NSWorkspace.shared.icon(forFile: entry.url.path)
        thumbnailIsIcon = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let isImageEntry = !entry.isDirectory && entry.pixelSize != nil
        let reprTypes: QLThumbnailGenerator.Request.RepresentationTypes =
            isImageEntry ? .all : .icon
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url,
            size: CGSize(width: 256, height: 320),
            scale: scale,
            representationTypes: reprTypes
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            let isIcon = (rep.type == .icon)
            DispatchQueue.main.async {
                self.thumbnail = image
                self.thumbnailIsIcon = isIcon
            }
        }
    }
}

/// List-view counterpart to FolderEntryGridCell.
struct FolderEntryListItem: View {
    let entry: FolderEntry
    let isSelected: Bool
    let isFocused: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onNavigateInto: () -> Void
    let urlsProvider: () -> [URL]

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.controlActiveState) private var controlActiveState
    private var isEmphasized: Bool { controlActiveState == .key }

    var body: some View {
        HStack(spacing: Design.Space.md) {
            thumbnailView
                .frame(width: Design.Size.rowThumb, height: Design.Size.rowThumb)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))

            Text(entry.displayName)
                .font(Design.Text.item)
                .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.strong)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)

            Spacer(minLength: Design.Space.sm)

            Text(metaText)
                .font(Design.Text.meta)
                .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.tertiary)
                .lineLimit(1)
                .accessibilityHidden(true)

            if entry.isDirectory {
                InlineNavigateChevron(action: onNavigateInto)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, Design.Space.sm)
        .padding(.vertical, Design.Space.micro)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                .fill(isSelected
                      ? SelectionColor.fill(emphasized: isEmphasized)
                      : Design.Surface.rowHover.opacity(hovering ? 1 : 0))
        )
        .focusRing(isFocused, cornerRadius: Design.Radius.row)
        .overlay(
            ShelfDragOverlay(
                provider: urlsProvider,
                onStart: {},
                onEnd: {},
                onClick: onClick,
                onDoubleClick: onDoubleClick
            )
            .claimsClickFromAncestors()
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L("a11y.item.hint"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering = $0 }
        .animation(Design.Motion.state, value: hovering)
        .onAppear { loadThumbnail() }
    }

    private var metaText: String {
        if entry.isDirectory {
            if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
            return L("Folder")
        }
        if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? L("File") : ext.uppercased()
    }

    private var accessibilityLabel: String {
        ShelfItemAccessibility.itemLabel(
            name: entry.displayName,
            kind: entry.isDirectory ? L("Folder") : L("File"),
            meta: metaText
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Design.Surface.control
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(Design.Space.hair)
            } else {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Design.Ink.glyph)
            }
        }
    }

    private func loadThumbnail() {
        thumbnail = NSWorkspace.shared.icon(forFile: entry.url.path)
    }
}

/// Pill that toggles selection across every item in the shelf. Once items
/// are selected, dragging any tile drags the whole selection (existing
/// behavior in DocumentGridItem / DocumentListItem).
private struct SelectAllButton: View {
    let allSelected: Bool
    let someSelected: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.sm) {
                // Hide the leading glyph entirely when nothing is selected —
                // the pill reads as a neutral "Select All" affordance until
                // the user picks at least one item.
                if someSelected {
                    Image(systemName: allSelected
                          ? "checkmark.circle.fill"
                          : "circle.dashed")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                }
                Text(allSelected ? L("Deselect All") : L("Select All"))
                    .font(Design.Text.control)
            }
            .foregroundStyle(enabled ? Design.Ink.strong : Design.Ink.disabled)
            .padding(.horizontal, Design.Space.rhythm)
            .frame(height: Design.Size.pillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering && enabled ? Design.Surface.pillHover : Design.Surface.pill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Design.Line.hairline, lineWidth: Design.Line.hairlineWidth)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(allSelected ? L("Deselect All") : L("Select All"))
        .animation(Design.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}

struct DocumentGridItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    /// Where the keyboard cursor is. Separate from `isSelected` on purpose: a
    /// card can be focused without being selected, and the ring and the fill
    /// say different things — *where the keyboard is* against *what will be
    /// acted on*.
    let isFocused: Bool
    let isBeingDragged: Bool
    let selectedURLsProvider: () -> [URL]
    let contextMenuBuilder: () -> NSMenu
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onMovedOut: ([URL]) -> Void
    /// Invoked when the user taps the inline chevron next to a directory's
    /// name. Plain card clicks do not trigger this — the chevron is the
    /// only navigation affordance.
    let onNavigateInto: () -> Void

    @EnvironmentObject var conversionService: ConversionService
    @EnvironmentObject var ocrService: OCRService
    @EnvironmentObject var routeService: RouteService
    @State private var hovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    private var isEmphasized: Bool { controlActiveState == .key }

    private static let defaultCardSize = Design.Size.tileFallback
    private static let cardLongSide = Design.Size.tileLongSide
    private static let labelMinWidth = Design.Size.tileLabelMinWidth

    private var cardSize: CGSize {
        guard item.type == .image else { return Self.defaultCardSize }
        // Prefer the file's own pixel dimensions — set synchronously in
        // ShelfManager.addFile — so the card lands at the right aspect on
        // the very first render. The thumbnail-derived aspect was wrong
        // until QL replaced the placeholder icon, causing a visible
        // resize/jitter mid-drop.
        let aspectFromMeta: CGFloat? = {
            guard let s = item.pixelSize, s.width > 0, s.height > 0 else { return nil }
            return s.width / s.height
        }()
        let aspect = aspectFromMeta
            ?? item.thumbnail.flatMap(Self.aspectRatio(of:))
            ?? 1
        guard aspect.isFinite, aspect > 0 else { return Self.defaultCardSize }
        if aspect >= 1 {
            return CGSize(width: Self.cardLongSide, height: Self.cardLongSide / aspect)
        } else {
            return CGSize(width: Self.cardLongSide * aspect, height: Self.cardLongSide)
        }
    }

    var body: some View {
        let size = cardSize
        // Spacings and paddings come from `ShelfLayout` because the panel's
        // height is computed from them: a tile that pads itself by a different
        // number than the window was sized for is exactly the drift this file
        // used to carry.
        VStack(spacing: ShelfLayout.tileInternalSpacing) {
            cardFace(size: size)
            .frame(width: size.width, height: size.height)
            .shelfShadow(hovering ? Design.Depth.hover : Design.Depth.rest)
            .shelfShadow(Design.Depth.contact)
            .scaleEffect(hovering ? 1.03 : 1.0)
            .offset(y: hovering ? -3 : 0)
            .overlay(
                ShelfDragOverlay(
                    provider: selectedURLsProvider,
                    onStart: onDragStart,
                    onEnd: onDragEnd,
                    onMovedOut: onMovedOut,
                    menuBuilder: contextMenuBuilder,
                    onClick: onClick,
                    onDoubleClick: {
                        if let url = item.fileURL {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    visibleCardSize: { size }
                )
                .claimsClickFromAncestors()
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Design.Ink.removeGlyph, Design.Ink.primary)
                            .padding(Design.Space.xs)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove from Shelf"))
                    .help(L("Remove from Shelf"))
                    .offset(x: 6, y: -6)
                }
            }
            .overlay {
                ProgressOverlay(
                    progress: ocrService.progress[item.id]
                        ?? conversionService.progress[item.id]
                        ?? routeService.progress[item.id],
                    onCancel: {
                        ocrService.cancel(itemID: item.id)
                        conversionService.cancel(itemID: item.id)
                        routeService.cancel(itemID: item.id)
                    }
                )
            }
            .animation(Design.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
            // Uniform vertical slot equal to the long-side cap so short
            // (landscape) cards sit on the same baseline as tall (portrait)
            // ones — that keeps the title/meta labels aligned across the row.
            .frame(height: ShelfLayout.tileCardSlot, alignment: .bottom)

            VStack(spacing: Design.Space.hair) {
                HStack(spacing: Design.Space.xs) {
                    Text(item.displayName)
                        .font(Design.Text.label)
                        .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.strong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityHidden(true)
                    if item.isDirectory {
                        InlineNavigateChevron(action: onNavigateInto)
                    }
                }
                Text(item.displayMeta)
                    .font(Design.Text.meta)
                    .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .frame(width: max(size.width, Self.labelMinWidth))
        }
        .padding(.horizontal, ShelfLayout.tilePadding)
        .padding(.vertical, ShelfLayout.tilePadding)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                .fill(SelectionColor.fill(emphasized: isEmphasized).opacity(isSelected ? 1 : 0))
        )
        .focusRing(isFocused, cornerRadius: Design.Radius.tile)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L("a11y.item.hint"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .opacity(isBeingDragged ? 0 : 1)
        .animation(Design.Motion.state, value: isBeingDragged)
    }

    private var accessibilityLabel: String {
        ShelfItemAccessibility.itemLabel(
            name: item.displayName,
            kind: ShelfItemAccessibility.kind(isDirectory: item.isDirectory, type: item.type),
            meta: item.displayMeta
        )
    }

    @ViewBuilder
    private func cardFace(size: CGSize) -> some View {
        if item.type == .image, item.thumbnailIsIcon {
            // Real photo preview is still being rendered by QL. Showing the
            // generic JPEG/HEIC type icon stretched into the photo's frame
            // looks like a flash of a different image, so render a quiet
            // skeleton instead and crossfade to the real thumbnail when it
            // arrives.
            RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous)
                .fill(Design.Surface.skeleton)
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous)
                        .strokeBorder(Design.Line.skeleton, lineWidth: Design.Line.hairlineWidth)
                )
                .transition(.opacity)
        } else if renderFlush, let thumb = item.thumbnail {
            if item.type == .image {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous))
                    .transition(.opacity)
            } else {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        } else {
            // No paper, and no ground either. ADR 0006 kept a white document
            // face here and ADR 0010 withdraws it: a sheet of paper is the
            // fork's signature. What replaces it is nothing at all — the same
            // flush language `FolderEntryGridCell` has always used, where a
            // document is its mark on the panel rather than an object on top
            // of it.
            //
            // A quiet fill was tried first and is wrong for a reason worth
            // recording: any raise light enough to read as a card lands within
            // a few percent of `unemphasizedSelectedContentBackgroundColor`,
            // so an unselected card looked selected on a panel that was not
            // key. Caught by `SelectionEmphasisTests`.
            previewContent
                .padding(Design.Space.lg)
        }
    }

    private static func aspectRatio(of image: NSImage) -> CGFloat? {
        if let rep = image.representations.first {
            let w = CGFloat(rep.pixelsWide)
            let h = CGFloat(rep.pixelsHigh)
            if w > 0, h > 0 { return w / h }
        }
        let s = image.size
        if s.width > 0, s.height > 0 { return s.width / s.height }
        return nil
    }

    private var renderFlush: Bool {
        if item.type == .image { return true }
        return item.thumbnailIsIcon
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: item.type == .text ? "text.alignleft" : "doc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Design.Ink.glyph)
        }
    }
}

private struct ViewModeToggle: View {
    @Binding var mode: ShelfViewMode

    var body: some View {
        HStack(spacing: Design.Space.hair) {
            ViewModeSegment(
                target: .grid,
                systemName: "square.grid.2x2.fill",
                label: L("a11y.grid-view"),
                mode: $mode
            )
            ViewModeSegment(
                target: .list,
                systemName: "list.bullet",
                label: L("a11y.list-view"),
                mode: $mode
            )
        }
        .padding(Design.Space.hair)
        .background(
            Capsule(style: .continuous)
                .fill(Design.Surface.control)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Design.Line.hairlineFaint, lineWidth: Design.Line.hairlineWidth)
        )
    }
}

private struct ViewModeSegment: View {
    let target: ShelfViewMode
    let systemName: String
    let label: String
    @Binding var mode: ShelfViewMode

    @State private var hovering = false

    var body: some View {
        let active = mode == target
        // contentShape() on the label is what makes the whole 26×22 area
        // hit-testable — without it, only the icon glyph itself catches
        // clicks and the list icon "feels dead" until hovered.
        Button {
            mode = target
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Design.Ink.active : (hovering ? Design.Ink.glyphBright : Design.Ink.secondary))
                .frame(width: 26, height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            active
                                ? Design.Surface.controlActive
                                : Design.Surface.segmentHover.opacity(hovering ? 1 : 0)
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(label)
        .onHover { hovering = $0 }
        .animation(Design.Motion.state, value: active)
        .animation(Design.Motion.state, value: hovering)
    }
}

struct DocumentListItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    let isFocused: Bool
    let isBeingDragged: Bool
    let selectedURLsProvider: () -> [URL]
    let contextMenuBuilder: () -> NSMenu
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onMovedOut: ([URL]) -> Void
    let onNavigateInto: () -> Void

    @EnvironmentObject var conversionService: ConversionService
    @EnvironmentObject var ocrService: OCRService
    @EnvironmentObject var routeService: RouteService
    @State private var hovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    private var isEmphasized: Bool { controlActiveState == .key }

    var body: some View {
        HStack(spacing: Design.Space.md) {
            thumbnail
                .frame(width: Design.Size.rowThumb, height: Design.Size.rowThumb)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))

            Text(item.displayName)
                .font(Design.Text.item)
                .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.strong)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)

            Spacer(minLength: Design.Space.sm)

            Text(item.displayMeta)
                .font(Design.Text.meta)
                .foregroundStyle(isSelected ? SelectionColor.text(emphasized: isEmphasized) : Design.Ink.tertiary)
                .lineLimit(1)
                .accessibilityHidden(true)

            ZStack {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Design.Ink.removeGlyphList, Design.Ink.emphasis)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove from Shelf"))
                    .help(L("Remove from Shelf"))
                } else if item.isDirectory {
                    InlineNavigateChevron(action: onNavigateInto)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.horizontal, Design.Space.sm)
        .padding(.vertical, Design.Space.micro)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                .fill(SelectionColor.fill(emphasized: isEmphasized).opacity(isSelected ? 1 : 0))
        )
        .focusRing(isFocused, cornerRadius: Design.Radius.row)
        .overlay(
            ShelfDragOverlay(
                provider: selectedURLsProvider,
                onStart: onDragStart,
                onEnd: onDragEnd,
                onMovedOut: onMovedOut,
                menuBuilder: contextMenuBuilder,
                onClick: onClick,
                onDoubleClick: {
                    if let url = item.fileURL {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
            .claimsClickFromAncestors()
        )
        .overlay {
            ProgressOverlay(
                progress: ocrService.progress[item.id]
                    ?? conversionService.progress[item.id]
                    ?? routeService.progress[item.id],
                onCancel: {
                    ocrService.cancel(itemID: item.id)
                    conversionService.cancel(itemID: item.id)
                    routeService.cancel(itemID: item.id)
                }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L("a11y.item.hint"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering = $0 }
        .opacity(isBeingDragged ? 0 : 1)
        .animation(Design.Motion.state, value: isBeingDragged)
    }

    private var accessibilityLabel: String {
        ShelfItemAccessibility.itemLabel(
            name: item.displayName,
            kind: ShelfItemAccessibility.kind(isDirectory: item.isDirectory, type: item.type),
            meta: item.displayMeta
        )
    }

    private var thumbnail: some View { ShelfThumbnailChip(item: item) }
}

/// The one small picture of a file the app draws, used by the collapsed
/// strip's rows and by the expanded list's. Two copies of it drifted apart
/// once already — one put the thumbnail on a white paper ground and the other
/// did not.
struct ShelfThumbnailChip: View {
    let item: ShelfItem

    var body: some View {
        ZStack {
            Design.Surface.control
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: item.type == .image ? .fill : .fit)
                    .padding(item.type == .image ? 0 : Design.Space.hair)
            } else {
                Image(systemName: item.type == .text ? "text.alignleft" : "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Design.Ink.glyph)
            }
        }
    }
}

/// What the shelf says, and shows, while a card is being dragged off it.
///
/// **It sits in the chrome, not over the files.** It used to be a two-line
/// block centred on the panel, and the strip faded its rows out to make room
/// for it — so a ⌘-drag emptied the shelf and put a large coral box where the
/// files had been, which is the opposite of what a shelf is for. Rendered and
/// looked at: the box took roughly half the panel and the three rows were gone.
/// Now it is one line in the header row the count already occupied, and the
/// rows stay where they are at full strength.
///
/// Present at all times and only transparent when no drag is running — the
/// same shape as the focus ring, and for the same reason: adding and removing
/// it would change the panel's layout at the exact moment the user is aiming.
///
/// The mode change is still said twice: the sentence swaps ("Hold ⌘ to move" ↔
/// "Release ⌘ to copy") and the pill lights up — a heavier fill, full-strength
/// ink, and the app's own coral around it. The ring was the system accent, on
/// the reasoning that ⌘ is the keyboard speaking; it is the brand's coral now,
/// because this is the app's strongest statement about a user's file and it
/// should not be borrowing the colour a focus ring wears. Every value is a
/// `Design` token.
///
/// Internal rather than private for one reason: `RenderSnapshots` is the only
/// way anyone can look at this app, and it has to be able to render both modes.
struct DragModeBar: View {
    let intent: DragIntent
    let visible: Bool

    private var isMoving: Bool { intent == .move }

    var body: some View {
        let hint = DragOutHint.from(intent: intent)
        // One line that states the mode and then teaches the switch:
        // "Moving · Release ⌘ to copy". The teaching half alone was read cold
        // as an instruction with no state, so a stranger could not tell the
        // drag was already a move. The 180pt strip had no room for both; the
        // 240pt one does, in all nine tables (`DragMoveTests` measures it).
        (Text(hint.title).fontWeight(.semibold) + Text(" · " + hint.subtitle))
            .font(Design.Text.meta)
            .foregroundStyle(isMoving ? Design.Ink.strong : Design.Ink.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Design.Space.sm)
            .padding(.vertical, Design.Space.hair)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(isMoving ? Design.Surface.controlActive : Design.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(
                                isMoving ? Design.Line.moveRing : Design.Line.hairlineFaint,
                                lineWidth: isMoving
                                    ? Design.Line.focusRingWidth
                                    : Design.Line.hairlineWidth
                            )
                    )
            )
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityLabel(hint.title)
            .accessibilityValue(hint.subtitle)
            .animation(Design.Motion.state, value: isMoving)
            .animation(Design.Motion.state, value: visible)
    }
}

/// The ring the panel wears while files are being dropped onto it.
///
/// Internal rather than private for the same reason as `DragModeBar`:
/// `RenderSnapshots` is the only thing in the toolchain that can look at this
/// app, and a colour nobody has looked at is a colour nobody has checked.
struct DropTargetOverlay: View {
    let active: Bool

    var body: some View {
        // Trace the panel's outer rounded shape directly. Earlier this
        // overlay used `.padding(-10)` to push out past FloatingPanelContent's
        // 10pt margin, but that padding has since moved into each shelf
        // branch — extending here would just clip beyond the panel bounds.
        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
            .strokeBorder(Design.Line.dropTarget.opacity(active ? 1 : 0), lineWidth: Design.Line.dropTargetWidth)
            .animation(Design.Motion.state, value: active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ShelfAccentBadge: View {
    let accent: ShelfAccent
    var size: CGFloat = 10

    var body: some View {
        // Group is layout-transparent; it only gives the two branches one
        // place to hang the label so the badge isn't a mute dot to VoiceOver.
        Group {
            switch accent {
            case .color(let hex):
                Circle()
                    .fill(Color(nsColor: NSColor(hex: hex) ?? .systemGray))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().strokeBorder(Design.Line.badge, lineWidth: Design.Line.hairlineWidth)
                    )
            case .emoji(let glyph):
                Text(glyph)
                    .font(.system(size: size + 2))
                    .frame(width: size + 4, height: size + 4)
            }
        }
        // Decoration: it restates the shelf identity it sits beside and has no
        // independent meaning, so it is hidden rather than labelled with the
        // name of the menu that sets it — which announced "Accent" and, for an
        // emoji accent, swallowed the one thing actually on screen.
        .accessibilityHidden(true)
    }
}

private struct RevealInFinderButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                Text(L("Reveal in Finder"))
                    .font(Design.Text.control)
            }
            .foregroundStyle(enabled ? Design.Ink.strong : Design.Ink.disabled)
            .padding(.horizontal, Design.Space.rhythm)
            .frame(height: Design.Size.pillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering && enabled ? Design.Surface.pillHover : Design.Surface.pill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Design.Line.hairline, lineWidth: Design.Line.hairlineWidth)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(L("Reveal in Finder"))
        .animation(Design.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}
