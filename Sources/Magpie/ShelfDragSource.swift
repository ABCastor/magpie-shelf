import AppKit
import SwiftUI

/// Decides whether a card leaves the shelf once its drag-out finished.
///
/// The `NSDragOperation` AppKit reports is not evidence. A destination that
/// cannot move — a browser, an upload zone, a cloud target — takes its own copy
/// of the file and can still report `.move`, while the original sits untouched.
/// The only thing trusted here is whether the source file is still on disk: a
/// real move leaves nothing to point at. Nothing is deleted either way; the
/// destination moves the file, never us (ADR 0001, ADR 0009).
enum DragOutcome {
    static func shouldRemoveCardAfterDrag(
        sourceURL: URL?,
        fileExists: (URL) -> Bool
    ) -> Bool {
        guard let sourceURL else { return false }
        return !fileExists(sourceURL)
    }

    /// Whether a finished drag should also take the cards off the shelf,
    /// because the user asked for a shelf that empties itself (the
    /// `shelf.clearAfterDragOut` preference, off unless switched on).
    ///
    /// The case it is for: a file goes to the Desktop only so it can be
    /// attached to something, and the shelf it came from is litter a moment
    /// later. Off by default, because the opposite case is just as real — a
    /// shelf you drag *from* repeatedly, into several places.
    ///
    /// **`accepted` is load-bearing and is the only guard against losing the
    /// shelf to a fumble.** A drag the user abandoned, or one a destination
    /// refused, reports an empty operation and must leave the shelf exactly as
    /// it was. It is read here only in the negative, which is the one thing
    /// `NSDragOperation` is trusted for anywhere in this file.
    ///
    /// **`.move` is excluded, and not because it should not clear.** A ⌘-move
    /// already drops its cards, through `settleMove`, and only once the
    /// destination has confirmed and the source has actually gone (ADR 0011).
    /// Clearing here as well would take the card away *before* that evidence
    /// exists — so a move that turned out to be unverifiable would leave the
    /// user with no card and a file still sitting where it was.
    ///
    /// Nothing is deleted by any of this. The dragged file is at its
    /// destination and still at its origin; what leaves is the shelf's
    /// reference to it.
    static func clearsShelfAfterDrag(
        intent: DragIntent,
        accepted: Bool,
        enabled: Bool
    ) -> Bool {
        guard enabled, accepted else { return false }
        return intent != .move
    }

    /// Whether the drop landed on something asking the **source** to remove
    /// the file, which in practice means the Dock's Bin.
    ///
    /// `NSDragOperation.delete` is the one operation whose contract assigns the
    /// removal to us rather than to the destination, so unlike every other
    /// reported operation it is not a claim about what the destination did. It
    /// is a request. That is why this is the single place in this file where a
    /// reported operation is allowed to decide something (ADR 0018).
    ///
    /// **Measured, not assumed.** A 69-run probe found the Dock Bin reports
    /// `delete` (32) with the source mask exactly as shipped (`.copy`, raw 1) —
    /// `32 & 1 == 0`, so it does not come from the offered mask and the mask
    /// needs no change. A drop with no destination reports 0, a Finder window
    /// reports `copy`, and two other Dock tiles and an Electron window reported
    /// nothing at all. Four destinations is not a proof that only the Bin ever
    /// sends this, which is why what bounds a wrong answer is the Bin itself:
    /// `ShelfTrash` recycles, so the worst case is one trip to the Bin.
    ///
    /// **No modifier is required, and none can be.** The Bin reports `delete`
    /// identically with ⌘, without it, and with ⌘ held before the drag starts —
    /// `ignoreModifierKeys` is true, so AppKit applies no modifier filter.
    /// Gating on ⌘ would leave a plain drag to the Bin doing nothing while
    /// showing a notice saying the destination copied the file, which is false.
    /// This matches Finder, where dragging anything to the Bin bins it.
    static func binsSourceAfterDrag(operation: NSDragOperation) -> Bool {
        operation.contains(.delete)
    }

    /// How long to wait before believing a move did not happen.
    ///
    /// The session ends the instant the mouse comes up, which can be *before*
    /// the destination has finished. A same-volume move is a rename and is
    /// already done; a cross-volume one copies first and unlinks after. Asking
    /// again half a second later is the difference between an honest notice
    /// and calling a slow move a copy.
    static let settleDelay: TimeInterval = 0.6

    /// Whether to tell the user their ⌘ did not produce a move.
    ///
    /// `accepted` is the one thing the reported `NSDragOperation` is trusted
    /// for, and only in the negative: an empty operation means no destination
    /// took the drop at all, so there is nothing to explain and a drag the user
    /// abandoned must not be reported as a refused move. It is never read as
    /// proof that a move *happened* — that question is only ever answered by
    /// the source file being gone.
    static func copyInsteadNotice(
        intent: DragIntent,
        accepted: Bool,
        survivingCount: Int,
        operation: NSDragOperation = []
    ) -> DragNotice? {
        // A drop on the Bin is the one accepted drop this notice must never
        // describe. It was the notice the owner actually saw, and it said the
        // destination had copied the owner's file, which the Bin had not done
        // and never does. Magpie handles that drop itself now, so there is nothing left
        // to explain and the source is about to go.
        guard !binsSourceAfterDrag(operation: operation) else { return nil }
        guard intent == .move, accepted, survivingCount > 0 else { return nil }
        return .copiedInstead(count: survivingCount)
    }

}

/// What a drag out has to say for itself.
///
/// A drag whose every source file is unreachable used to be a silent no-op —
/// the user drags, nothing happens, and the app looks broken. The store already
/// knows the difference between "this file is gone" and "this file's volume is
/// not mounted", so the message can be honest about which one it is. The same
/// channel now carries the other silence worth breaking: a ⌘-drag the
/// destination answered with a copy.
enum DragNotice: Equatable {
    /// Every dragged file is confirmed gone from disk.
    case missing(count: Int)
    /// At least one dragged file sits on a volume that cannot be reached
    /// right now (ejected disk, disconnected network share). Chosen over
    /// `.missing` for a mixed set because "gone" is the stronger claim and
    /// an unreachable volume may simply come back.
    case unavailable(count: Int)
    /// The user held ⌘, a destination took the file, and the original is still
    /// where it was — so no move happened. Under ADR 0011 that means the
    /// destination read the file URL off the pasteboard and copied from the
    /// original itself, rather than taking the promise that would have told
    /// Magpie where the copy landed; with nothing to verify against, the source
    /// is left alone. A browser upload zone is the everyday example.
    case copiedInstead(count: Int)

    var count: Int {
        switch self {
        case .missing(let count), .unavailable(let count), .copiedInstead(let count):
            return count
        }
    }

    var messageKey: String {
        switch self {
        case .missing(let count):
            return count <= 1 ? "toast.drag-missing.one" : "toast.drag-missing.many"
        case .unavailable(let count):
            return count <= 1 ? "toast.drag-unavailable.one" : "toast.drag-unavailable.many"
        case .copiedInstead(let count):
            return count <= 1
                ? "toast.drag-copied-instead.one"
                : "toast.drag-copied-instead.many"
        }
    }
}

/// Pure: which of the offered URLs can actually be dragged, and — when none
/// can — what the user should be told. `notice` is nil whenever the drag can
/// proceed (even partially): a mixed drag still moves the live files, and a
/// toast over a working drag would read as an error that didn't happen.
enum StaleDrag {
    static func partition(
        urls: [URL],
        availability: (URL) -> ShelfStore.FileAvailability
    ) -> (live: [URL], notice: DragNotice?) {
        var live: [URL] = []
        var anyUnavailable = false
        for url in urls {
            switch availability(url) {
            case .reachable: live.append(url)
            case .unavailable: anyUnavailable = true
            case .confirmedMissing: break
            }
        }
        guard live.isEmpty, !urls.isEmpty else { return (live, nil) }
        return (live, anyUnavailable
            ? .unavailable(count: urls.count)
            : .missing(count: urls.count))
    }
}

/// One process-wide hook instead of a closure threaded through five overlay
/// call sites: the app delegate owns the toast presenter, sets this once at
/// launch, and the drag source hands it the panel the drag started from so
/// the toast lands where the user is looking.
@MainActor
enum DragToast {
    static var handler: ((DragNotice, NSWindow?) -> Void)?
}

/// A drop on the Bin, handed to whoever can act on it.
///
/// Same shape and same reason as `DragToast`: the drag source knows a `.delete`
/// arrived and which panel it came from, and knows nothing about shelves or the
/// store. The app delegate owns both, sets this once at launch, and resolves
/// the window back to a shelf. A closure threaded through the view tree would
/// have to cross the strip, the grid and the list, three layers that have no
/// business carrying it.
///
/// The handler is expected to route through `ShelfTrash`, which is what makes
/// the drop undoable and what keeps `NSWorkspace.recycle` in one file.
@MainActor
enum DragBin {
    static var handler: (([URL], NSWindow?) -> Void)?
}

/// The accessibility decisions a shelf cell makes. Pure, because the AppKit
/// side of them (`DragInitiatorView`'s overrides) can't be reached from a unit
/// test and a VoiceOver pass is the only other place they'd ever be checked.
enum ShelfCellAccessibility {
    /// The operations a pointer already gets from `DragInitiatorView`, offered
    /// to VoiceOver through the same closures the mouse path calls. A cell
    /// offers only what its call site wired up — an announced action that does
    /// nothing is worse than a missing one.
    enum Action: CaseIterable {
        /// Double-click: opens the file, or descends into the folder.
        case open
        /// Right-click: the item menu on a tile, the shelf menu on the stack.
        case showMenu
        /// Command-click: puts this cell into the selection, or takes it out.
        case toggleSelection

        var title: String {
            switch self {
            case .open: return L("Open")
            case .showMenu: return L("a11y.action.show-menu")
            case .toggleSelection: return L("a11y.action.toggle-selection")
            }
        }
    }

    static func actions(
        canOpen: Bool,
        canShowMenu: Bool,
        canSelect: Bool
    ) -> [Action] {
        var actions: [Action] = []
        if canOpen { actions.append(.open) }
        if canShowMenu { actions.append(.showMenu) }
        if canSelect { actions.append(.toggleSelection) }
        return actions
    }

    /// Spoken name for the operable element, from the only thing the overlay
    /// knows about itself: what it would drag. Deliberately just the name —
    /// the SwiftUI cell around it already announces kind, size and selection,
    /// so restating them here would say every cell twice.
    static func label(forDraggedURLs urls: [URL]) -> String? {
        switch urls.count {
        case 0: return nil
        case 1: return urls[0].lastPathComponent
        default: return String(format: L("%lld Files"), urls.count)
        }
    }
}

/// What a mouse-up on a shelf cell means.
///
/// Pure, and separate from `DragInitiatorView` for the reason every rule in
/// this area is: the AppKit handler cannot be reasoned about, only driven. Both
/// rules here were measured through real `NSEvent`s at a real `NSPanel`, and
/// both replace behaviour that silently lost the user's click.
///
/// **A multi-click is not automatically an open.** `mouseUp` used to hand any
/// `clickCount >= 2` to `onDoubleClick`, and a strip row wires no such closure
/// — so the second of two quick clicks on the strip went *nowhere at all*. That
/// is the owner's *"many times it doesn't work… sometimes it does work"*: click
/// a row, then ⇧-click a neighbour before the double-click interval is up, and
/// the range never happens. Measured: `clickCount: 2` reached `mouseUp` and no
/// closure ran.
///
/// **A modified click is always a selection click.** ⇧ and ⌘ mean *extend* and
/// *toggle* at every click count, which is also what Finder does — a
/// ⌘-double-click there adds a second file, it does not open one. Without this
/// a user building a selection by clicking quickly gets files opened in their
/// default app instead.
///
/// **⌃ is a secondary click and never touches the selection.** macOS routes
/// ⌃-click to the context menu, and where a cell offers one AppKit intercepts
/// it before `mouseDown` — measured. Where a cell offers *no* menu (the folder
/// browser's cells) the event fell through to `mouseUp` and was read as a plain
/// click, so ⌃-click silently replaced the selection there. One rule, both
/// places: the menu's click is not the selection's click.
enum CellClick: Equatable {
    /// Change the selection, with exactly these modifiers.
    case select(NSEvent.ModifierFlags)
    /// Open the item — an unmodified multi-click on a cell that offers opening.
    case open
    /// The context menu's click. Leaves the selection exactly as it found it.
    case secondary

    static func intent(
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int,
        offersOpen: Bool
    ) -> CellClick {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { return .secondary }
        let picksFiles = flags.contains(.shift) || flags.contains(.command)
        if clickCount >= 2, offersOpen, !picksFiles { return .open }
        return .select(flags)
    }
}

/// How a drag of N files is drawn, and where it is offered to land.
///
/// Both halves were wrong, and the owner photographed both. Every dragging item
/// was given its own picture at its own offset (`index * 4`), so eleven files
/// trailed eleven overlapping thumbnails down the screen, which the owner
/// reasonably read as the app copying everything eleven times. A destination
/// places each item at the point its dragging frame names, so those same offsets
/// scattered the files across the destination window instead of landing them
/// together.
///
/// One picture for the set with a count on it, and **one frame shared by every
/// item**, is the fix for both: Finder's own multi-file drag, and a single drop
/// point. `formation` is `.none` for the same reason the frames are explicit —
/// `.stack` asks AppKit to re-lay the items out, which is how they got spread
/// apart in the first place.
///
/// Pure, because the only place this could otherwise be checked is a live
/// tracking loop no test can enter.
enum DragPreviewPlan {

    struct Plan: Equatable {
        /// One frame per dragged file, all identical: N files, one drop point.
        let frames: [NSRect]
        /// The single item that carries the picture. Nil only for an empty drag.
        let imagedIndex: Int?
        /// What the badge says, or nil when one file speaks for itself.
        let badge: String?
        let formation: NSDraggingFormation
    }

    static func make(count: Int, previewFrame: NSRect) -> Plan {
        guard count > 0 else {
            return Plan(frames: [], imagedIndex: nil, badge: nil, formation: .none)
        }
        return Plan(
            frames: Array(repeating: previewFrame, count: count),
            imagedIndex: 0,
            badge: badgeText(count: count),
            formation: .none
        )
    }

    /// A bare numeral, the way Finder badges a multi-file drag. Nil for one
    /// file: a badge reading "1" over a picture of that one file says nothing
    /// the picture did not already say.
    static func badgeText(count: Int) -> String? {
        guard count > 1 else { return nil }
        return "\(count)"
    }
}

/// Draws the count onto the drag picture.
///
/// The badge wears `SelectionColor`'s active pair rather than a colour of its
/// own — it is a statement about how many rows are *selected*, and that pair is
/// the one AppKit guarantees legible together under every accent, both
/// appearances and Increase Contrast (see `SelectionColor`). Colours are
/// resolved inside the drawing handler, so the badge follows the appearance the
/// image is actually drawn under.
enum DragPreviewImage {
    /// Geometry, not vocabulary: the padding around the numeral, at the call
    /// site the way `DesignTokens.swift` asks for.
    private static let badgePadding: CGFloat = 5

    static func badged(_ image: NSImage, badge: String?) -> NSImage {
        guard let badge, !badge.isEmpty else { return image }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        return NSImage(size: size, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Design.Text.countBadge,
                .foregroundColor: SelectionColor.textColor(emphasized: true),
            ]
            let text = badge as NSString
            let textSize = text.size(withAttributes: attributes)
            let diameter = max(
                textSize.height + badgePadding * 2,
                textSize.width + badgePadding * 2
            )
            // Top-trailing, inside the picture's own bounds so nothing is
            // clipped by the dragging frame.
            let badgeRect = NSRect(
                x: max(0, size.width - diameter),
                y: max(0, size.height - diameter),
                width: min(diameter, size.width),
                height: min(diameter, size.height)
            )
            SelectionColor.fillColor(emphasized: true).setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            text.draw(
                at: NSPoint(
                    x: badgeRect.midX - textSize.width / 2,
                    y: badgeRect.midY - textSize.height / 2
                ),
                withAttributes: attributes
            )
            return true
        }
    }
}

/// A transparent NSView overlay that starts a real NSDraggingSession with one
/// or more file URLs. Works inside a non-activating NSPanel where SwiftUI's
/// `.onDrag` silently fails.
struct ShelfDragOverlay: NSViewRepresentable {
    /// Resolved at drag-start time so callers can vend the latest items.
    let provider: () -> [URL]
    let onStart: () -> Void
    let onEnd: () -> Void
    /// The cards that should leave the shelf now.
    ///
    /// Two callers, one meaning. Usually it is the dragged URLs whose source
    /// file is gone — the destination really moved them. It is also every
    /// dragged URL when the user has switched on "clear the shelf after
    /// dragging out", where the files are untouched and only the cards go.
    var onMovedOut: (([URL]) -> Void)? = nil
    var menuBuilder: (() -> NSMenu?)? = nil
    var onClick: ((NSEvent.ModifierFlags) -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    /// Optional explicit visible card size, in points. When the SwiftUI
    /// hosting view sizes the overlay larger than the actual card (because
    /// of shadows, scale effects, or sibling overlays), this lets us
    /// snapshot only the card and avoid pulling in the dark panel backdrop.
    var visibleCardSize: (() -> CGSize)? = nil

    func makeNSView(context: Context) -> DragInitiatorView {
        let view = DragInitiatorView()
        view.provider = provider
        view.onStart = onStart
        view.onEnd = onEnd
        view.onMovedOut = onMovedOut
        view.menuBuilder = menuBuilder
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.visibleCardSize = visibleCardSize
        return view
    }

    func updateNSView(_ nsView: DragInitiatorView, context: Context) {
        nsView.provider = provider
        nsView.onStart = onStart
        nsView.onEnd = onEnd
        nsView.onMovedOut = onMovedOut
        nsView.menuBuilder = menuBuilder
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
        nsView.visibleCardSize = visibleCardSize
    }
}

extension View {
    /// **Keeps a cell's click away from an ancestor's tap gesture.**
    ///
    /// `ShelfDragOverlay` is an `NSView`, not a SwiftUI gesture, so it does not
    /// stop an ancestor `TapGesture` from recognising the same click — twice
    /// now this repo has believed otherwise and shipped a selection that
    /// cleared itself the instant it was made (ADR 0012's amendment for the
    /// strip; `ExpandedTileClickTests` for the browser). A SwiftUI gesture on
    /// the cell *does* stop it, because the innermost gesture wins.
    ///
    /// So this is that gesture, and it is empty on purpose: the click is
    /// already handled by the AppKit overlay above it, and the only job here is
    /// to stop the panel underneath handling it a second time. Applied over
    /// exactly the overlay's own frame, so the parts of a cell the overlay does
    /// not cover behave exactly as they did.
    func claimsClickFromAncestors() -> some View {
        onTapGesture { }
    }
}

final class DragInitiatorView: NSView, NSDraggingSource {
    var provider: (() -> [URL])?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var onMovedOut: (([URL]) -> Void)?
    /// Reads the "clear the shelf after dragging out" preference. A closure so
    /// a test can answer it without writing to the user's defaults; the default
    /// reads the unregistered key, where absent means off (`DefaultPreferences`).
    var clearAfterDragOut: () -> Bool = {
        UserDefaults.standard.bool(forKey: "shelf.clearAfterDragOut")
    }
    var menuBuilder: (() -> NSMenu?)?
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var visibleCardSize: (() -> CGSize)?

    private var mouseDownPoint: NSPoint?
    private var sessionActive = false
    /// The URLs the in-flight session started with, so the end handler can ask
    /// whether they are still on disk.
    private var draggedURLs: [URL] = []
    /// The pasteboard writers of the in-flight session. Each one holds the
    /// destination the receiver asked the promise to be written to, which is
    /// the only evidence ADR 0011 accepts before a source may be trashed.
    private var sessionProviders: [ShelfFilePromiseProvider] = []
    /// What the drag ended as, once it has ended. A promise can be fulfilled
    /// either side of that moment, so both orders have to work.
    private var completedIntent: DragIntent?
    private var completedAccepted = false
    /// Sources this session has already put in the Trash. `NSWorkspace.recycle`
    /// is asynchronous, so the filesystem is not a reliable witness for the
    /// first moments after it is called.
    private var trashedSources: Set<URL> = []
    private let dragThreshold: CGFloat = 4

    override func menu(for event: NSEvent) -> NSMenu? {
        menuBuilder?()
    }

    override var isFlipped: Bool { false }

    // Keep the window-background drag (isMovableByWindowBackground) from stealing
    // our tile's mouse gesture.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim hits when we can drag or when we offer a context menu.
        let hasDrag = !(provider?() ?? []).isEmpty
        let hasMenu = menuBuilder != nil
        return (hasDrag || hasMenu) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !sessionActive, let start = mouseDownPoint else { return }
        let loc = event.locationInWindow
        let distance = hypot(loc.x - start.x, loc.y - start.y)
        if distance > dragThreshold {
            mouseDownPoint = nil
            beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = mouseDownPoint, !sessionActive {
            let loc = event.locationInWindow
            let distance = hypot(loc.x - start.x, loc.y - start.y)
            if distance < dragThreshold {
                // Every rule about what a click means lives in `CellClick`, so
                // there is one place to read and one place to break.
                switch CellClick.intent(
                    modifiers: event.modifierFlags,
                    clickCount: event.clickCount,
                    offersOpen: onDoubleClick != nil
                ) {
                case .open: onDoubleClick?()
                case .select(let modifiers): onClick?(modifiers)
                case .secondary: break
                }
            }
        }
        mouseDownPoint = nil
    }

    /// **A shelf is usually clicked while it is not the key window.** It is
    /// summoned over whatever the user was doing and it does not activate the
    /// app, so the click that reaches for a row is nearly always the first one.
    /// Without this AppKit spends that click on making the panel key and the row
    /// never sees it — the owner's *"I was clicking on a file and instead of
    /// clicking in the file, it just clicked on the whole app"*.
    ///
    /// Finder's rows do the same thing, which is why dragging a file out of a
    /// background window works there. It does not widen what a drag may do: the
    /// mask is still `DragModePolicy.sourceMask` and ADR 0011 still needs ⌘ held
    /// plus a verified copy before any source is trashed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Accessibility
    //
    // Selecting, opening and opening the menu all live in this view, so the
    // SwiftUI cell above can be announced but not operated without these.
    // Every override below routes into the same closure the mouse handlers
    // call — there is no second implementation of any of it.

    private var offeredActions: [ShelfCellAccessibility.Action] {
        ShelfCellAccessibility.actions(
            canOpen: onDoubleClick != nil,
            canShowMenu: menuBuilder != nil,
            canSelect: onClick != nil
        )
    }

    override func isAccessibilityElement() -> Bool { !offeredActions.isEmpty }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        ShelfCellAccessibility.label(forDraggedURLs: provider?() ?? [])
    }

    /// Nothing of ours sits below this view, so the cell's label — set by the
    /// SwiftUI content underneath — is announced once, not once per child.
    override func accessibilityChildren() -> [Any]? { [] }

    /// Return / Space. The same plain click `mouseUp` sends.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick([])
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool { showMenu() }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let actions = offeredActions
        guard !actions.isEmpty else { return nil }
        return actions.map { action in
            NSAccessibilityCustomAction(name: action.title) { [weak self] in
                self?.perform(action) ?? false
            }
        }
    }

    private func perform(_ action: ShelfCellAccessibility.Action) -> Bool {
        switch action {
        case .open:
            guard let onDoubleClick else { return false }
            onDoubleClick()
            return true
        case .showMenu:
            return showMenu()
        case .toggleSelection:
            guard let onClick else { return false }
            onClick(.command)
            return true
        }
    }

    /// The same menu `menu(for:)` hands the right-click. `popUp` runs its own
    /// tracking loop, so the local reference outlives the presentation.
    private func showMenu() -> Bool {
        guard let menu = menuBuilder?() else { return false }
        return menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.midX, y: bounds.midY),
            in: self
        )
    }

    private func beginDrag(with event: NSEvent) {
        let (urls, notice) = StaleDrag.partition(urls: provider?() ?? []) {
            ShelfStore.fileAvailability(at: $0)
        }
        guard !urls.isEmpty else {
            // A drag that will move nothing must not stay silent: without
            // this the user drags, nothing happens, and there is no way to
            // tell a stale card from a broken app.
            if let notice { DragToast.handler?(notice, window) }
            return
        }

        // Snapshot the actual rendered tile *before* notifying the source
        // (which fades the tile out). Use the caller-provided visible card
        // size when available — SwiftUI's overlay host can be larger than
        // the visible card (because of sibling overlays / hover effects),
        // so snapshotting plain `bounds` would pull in the dark panel
        // backdrop and surround the drag preview with a black frame.
        let cardSize = visibleCardSize?() ?? bounds.size
        let cw = min(cardSize.width, bounds.width)
        let ch = min(cardSize.height, bounds.height)
        let snapshotRect = NSRect(
            x: (bounds.width - cw) / 2,
            y: (bounds.height - ch) / 2,
            width: cw,
            height: ch
        )
        let dragImage = snapshotTile(rectInSelf: snapshotRect)
            ?? NSWorkspace.shared.icon(forFile: urls[0].path)

        // One picture for the set, one frame for every item. See
        // `DragPreviewPlan` — the per-item offsets this replaces are what
        // stacked N previews on the cursor and cascaded N files across the
        // destination window.
        let plan = DragPreviewPlan.make(count: urls.count, previewFrame: snapshotRect)
        let previewImage = DragPreviewImage.badged(dragImage, badge: plan.badge)

        var draggingItems: [NSDraggingItem] = []
        var providers: [ShelfFilePromiseProvider] = []
        for (index, url) in urls.enumerated() {
            // The user's own file URL *and* a promise — see
            // `ShelfDragPasteboard`. Whichever the destination takes it can
            // only ever copy; the promise is how it tells us where.
            let writer = ShelfDragPasteboard.writer(for: url)
            if let provider = writer as? ShelfFilePromiseProvider {
                provider.onFulfilled = { [weak self] in self?.settleMove() }
                providers.append(provider)
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let frame = plan.frames.indices.contains(index) ? plan.frames[index] : snapshotRect
            // Only one item is drawn. The rest still carry the shared frame,
            // because that frame is the point the destination drops them at.
            item.setDraggingFrame(frame, contents: index == plan.imagedIndex ? previewImage : nil)
            draggingItems.append(item)
        }

        sessionActive = true
        draggedURLs = urls
        sessionProviders = providers
        completedIntent = nil
        completedAccepted = false
        trashedSources = []
        DragModeMonitor.shared.begin()
        onStart?()
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        // `.stack` re-lays the items out and undoes the shared frame above,
        // which is the spread the owner photographed at the destination.
        session.draggingFormation = plan.formation
    }

    /// Renders the underlying SwiftUI tile (everything beneath this transparent
    /// overlay) into a bitmap so the drag preview matches the visible UI
    /// instead of a generic file icon.
    private func snapshotTile(rectInSelf: NSRect) -> NSImage? {
        guard let window = window,
              let rootLayer = window.contentView?.layer
        else { return nil }
        guard rectInSelf.width > 0, rectInSelf.height > 0 else { return nil }

        let scale = window.backingScaleFactor
        let pixelW = Int(ceil(rectInSelf.width * scale))
        let pixelH = Int(ceil(rectInSelf.height * scale))
        guard pixelW > 0, pixelH > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)

        // Translate so the snapshot rect's origin (in window coords) becomes (0,0).
        let rectInWindow = convert(rectInSelf, to: nil)
        ctx.translateBy(x: -rectInWindow.minX, y: -rectInWindow.minY)

        rootLayer.render(in: ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: rectInSelf.size)
    }

    // MARK: - NSDraggingSource

    /// **The whole of the ⌘ repair, and it is a `true`.**
    ///
    /// AppKit filters the source's mask by the live modifier keys before any
    /// destination sees it. With a `.copy`-only mask that filter leaves nothing
    /// under ⌘, so Finder refused the drop outright — the no-drop cursor the
    /// owner photographed. Measured: `.copy` under ⌘ → refused; `.copy` under ⌘
    /// with this returning `true` → the drop lands and Finder copies.
    ///
    /// Turning the filter off is what lets the shelf keep the only mask that is
    /// safe (`DragModePolicy.sourceMask`, copy and nothing else) while ⌘ still
    /// means something. What it means is decided here, not by the destination.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Deliberately not a function of the modifiers, in either context.
        // Reading `NSEvent.modifierFlags` here is what the two previous
        // attempts did, and AppKit latches the mask at session setup, so
        // widening it when ⌘ goes down mid-drag changed nothing except that
        // the drop was then refused. `DragModePolicy.sourceMask` carries the
        // measurements.
        DragModePolicy.sourceMask
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let intent = DragModeMonitor.shared.end()
        sessionActive = false
        onEnd?()
        // `operation` is not read as proof that anything moved — see
        // DragOutcome — only as the answer to "did any destination take this
        // drop at all", which is the difference between a copy worth
        // reporting and a drag the user simply abandoned.
        completedIntent = intent
        completedAccepted = operation != []
        // The Bin, and nothing else in this method, is handled before the move
        // and clear paths get a look: it is the one drop where the destination
        // has asked *us* to remove the file, so neither of those two — which
        // both exist to work out what a destination did on its own — has
        // anything to decide. Returning early also keeps the "destination
        // copied instead" notice off a drop that never copied anything.
        if DragOutcome.binsSourceAfterDrag(operation: operation) {
            DragBin.handler?(draggedURLs, window)
            return
        }
        settleMove()
        settle(
            draggedURLs,
            intent: intent,
            accepted: completedAccepted,
            operation: operation
        )
        if DragOutcome.clearsShelfAfterDrag(
            intent: intent,
            accepted: completedAccepted,
            enabled: clearAfterDragOut()
        ) {
            // Same channel as a real move, because every caller of it means
            // the same thing to the shelf: drop these cards. What differs is
            // why, and that is decided above rather than downstream.
            onMovedOut?(draggedURLs)
        }
    }

    /// The ADR 0011 gate, run once per dragged file.
    ///
    /// Called at the end of the drag *and* again each time a promise completes,
    /// because a receiver can finish writing after the session has ended — and
    /// the destination path it writes to is the evidence this whole decision
    /// rests on. Every condition lives in `DragMovePolicy.decideEach`; this is
    /// only the wiring, so what the tests pin is what runs.
    ///
    /// **Each file is judged against its own destination.** A multi-file
    /// ⌘-drag is N independent moves, so one file failing verification can
    /// never reach another file's original, and one file verifying can never
    /// vouch for a file that did not.
    private func settleMove() {
        guard let intent = completedIntent, intent == .move, completedAccepted else { return }
        let pending = sessionProviders.filter { !$0.consumed }
        let decisions = DragMovePolicy.decideEach(
            intent: intent,
            files: pending.map { (source: $0.sourceURL, destination: $0.fulfilledDestination) },
            sizeOf: DragMovePolicy.contentSize(of:)
        )
        var trashed: [URL] = []
        for (provider, decision) in zip(pending, decisions) {
            guard decision == .trashSource else { continue }
            provider.consumed = true
            trashedSources.insert(provider.sourceURL)
            DragMoveExecutor.trashSource(at: provider.sourceURL)
            trashed.append(provider.sourceURL)
        }
        // The card leaves now rather than on the filesystem's say-so: the
        // recycle is asynchronous, so the file can still be at its old path for
        // a moment and `report(movedOutAmong:)` would call it a survivor.
        guard !trashed.isEmpty else { return }
        onMovedOut?(trashed)
    }

    /// What the drag actually did, asked of the filesystem rather than of the
    /// destination: twice, because the second answer is the honest one. The
    /// delay also gives a promise still being written time to land, since the
    /// source only goes to the Trash once it has.
    private func settle(
        _ urls: [URL],
        intent: DragIntent,
        accepted: Bool,
        operation: NSDragOperation = []
    ) {
        let survivors = report(movedOutAmong: urls)
        guard intent == .move, accepted, !survivors.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + DragOutcome.settleDelay) {
            [weak self] in
            guard let self else { return }
            self.settleMove()
            let stillHere = self.report(movedOutAmong: survivors)
                .filter { !self.trashedSources.contains($0) }
            guard let notice = DragOutcome.copyInsteadNotice(
                intent: intent,
                accepted: accepted,
                survivingCount: stillHere.count,
                operation: operation
            ) else { return }
            DragToast.handler?(notice, self.window)
        }
    }

    /// Hands back the cards whose file has gone, and returns the ones still on
    /// disk. Nothing is deleted here or anywhere near here: a vanished source
    /// is the *evidence* that the destination moved it (ADR 0001, ADR 0009).
    private func report(movedOutAmong urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        var survivors: [URL] = []
        for url in urls {
            if DragOutcome.shouldRemoveCardAfterDrag(
                sourceURL: url,
                fileExists: { fm.fileExists(atPath: $0.path) }
            ) {
                moved.append(url)
            } else {
                survivors.append(url)
            }
        }
        if !moved.isEmpty { onMovedOut?(moved) }
        return survivors
    }
}
