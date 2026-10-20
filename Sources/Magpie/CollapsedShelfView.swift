import SwiftUI

/// The shelf at rest: a narrow vertical strip, one row per file.
///
/// It used to be a stack of overlapping paper cards floating in the middle of
/// a 210pt square, with two large circular buttons and a grab handle above it
/// and a file-count pill below. Three files on the shelf read as *one object*,
/// because nothing about the panel changed when the shelf did, and the loudest
/// things on screen were controls the user touches once a session.
///
/// So the theatre is gone and the set is shown: **N items look like N items**,
/// the panel is the height of its contents (`ShelfLayout.collapsedSize`), and
/// the chrome is a line of quiet glyphs that gain a fill under the pointer
/// rather than four filled circles competing with the files. Nothing lost a
/// keyboard path or an accessibility label in the process — every control is
/// still present, still hit-testable and still named.
struct CollapsedShelfView: View {
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    var items: [ShelfItem] = []
    var isDragging: Bool = false
    /// What the modifiers are asking for, live, while a drag is in flight. Only
    /// read when `isDragging`; the header shows the mode instead of the count.
    var dragIntent: DragIntent = .copy
    /// Owned by the parent so the flag survives the expanded↔collapsed
    /// view swap. Lets us show the X on the empty state after the user
    /// has emptied a shelf, while keeping it hidden during an in-flight
    /// shake gesture (shelf starts empty and items haven't landed yet).
    var showCloseWhenEmpty: Bool = false
    /// The rows the user has explicitly picked out. **Empty is not "nothing":
    /// it is the whole shelf** — see `ShelfSelection`, which is where every
    /// rule about it lives. Held by the container so it survives the
    /// collapsed↔expanded swap. Nothing is highlighted in that default state;
    /// the header says `5 Files` instead.
    var selection: Set<UUID> = ShelfSelection.wholeShelf
    /// The keyboard cursor, as an index into the displayed rows. Not the
    /// selection: a row can be under the cursor without being selected, which
    /// is why the ring and the fill are different tokens.
    var focusedIndex: Int? = nil
    var onClose: () -> Void = {}
    var onOpenDocuments: () -> Void = {}
    var onDock: () -> Void = {}
    /// A click on a row, with its modifiers, for the container to turn into a
    /// selection. The strip reports; `ShelfSelection` decides.
    var onSelectRow: (UUID, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// A drag that started on a row. Carries the row so the container can apply
    /// Finder's rule — a drag off an unselected row narrows to it first.
    var onDragStart: (UUID) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    /// The files a destination moved away, so their rows can go with them.
    var onMovedOut: ([URL]) -> Void = { _ in }
    /// A click that landed on the panel rather than on a row: the header, the
    /// margins, the gap above the rows. Getting back to "everything" has to be
    /// as forgiving as picking a row was accidental, so every part of the strip
    /// that is not itself a row or a control undoes the pick.
    var onClearSelection: () -> Void = {}

    @State private var hovering = false

    // The trigger preferences, read so the empty state can name what is
    // actually switched on. Defaults mirror the `register(defaults:)` call in
    // `App.swift` — both say "on until the user says otherwise".
    @AppStorage("shelf.trigger.shake") private var triggerShake: Bool = true
    @AppStorage("shelf.trigger.hotkey") private var triggerHotkey: Bool = true
    @AppStorage("shelf.trigger.hotkeyPreset") private var hotkeyPreset: HotkeyPreset = .optionShiftS

    private var shelf: Shelf? { manager.shelf(id: shelfID) }

    /// Every row on the strip, as ids. The claim and the fill are both derived
    /// from this one list.
    private var rowIDs: [UUID] { items.map(\.id) }

    /// What a drag off this strip would take, right now.
    private var claim: ShelfSelection.Claim {
        ShelfSelection.claim(explicit: selection, ids: rowIDs)
    }

    /// What the header says. `5 Files` when a drag takes all five, `1 of 5` the
    /// moment the user has picked one — the sentence is the whole answer to
    /// what a drag will carry, so it is never computed here. See
    /// `ShelfStripHeader`.
    private var headerTitle: String {
        ShelfStripHeader.title(name: shelf?.name, claim: claim)
    }

    var body: some View {
        VStack(spacing: ShelfLayout.stripHeaderGap) {
            header
            if items.isEmpty {
                emptyBody
            } else {
                rows
            }
        }
        .environment(\.shelfChromeRevealed, hovering)
        .onHover { hovering = $0 }
    }

    // MARK: - Header

    /// The chrome line: normally the count and the quiet controls, and for the
    /// length of a drag the mode bar instead.
    ///
    /// The bar goes *here* rather than over the rows, and that is the whole of
    /// the fix. A drag used to fade the rows out and drop a two-line coral block
    /// on the middle of the panel — so the one moment the user most wants to see
    /// what is leaving was the one moment the shelf showed nothing. The controls
    /// it replaces cannot be clicked mid-drag anyway, and the count it replaces
    /// is restated by the rows themselves, which are now visible throughout.
    @ViewBuilder
    private var header: some View {
        if isDragging {
            DragModeBar(intent: dragIntent, visible: true)
                .frame(height: ShelfLayout.stripHeaderHeight)
        } else {
            restingHeader
        }
    }

    private var restingHeader: some View {
        HStack(spacing: Design.Space.xs) {
            if !items.isEmpty || showCloseWhenEmpty {
                ShelfChromeButton(
                    systemName: "xmark",
                    label: L("a11y.close-shelf"),
                    action: onClose
                )
            }

            Text(headerTitle)
                .font(Design.Text.stripHeader)
                .foregroundStyle(Design.Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let accent = shelf?.accent {
                ShelfAccentBadge(accent: accent, size: 7)
            }
            if shelf?.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Design.Ink.glyph)
                    .accessibilityLabel(L("a11y.pinned"))
                    .help(L("a11y.pinned"))
            }

            Spacer(minLength: Design.Space.hair)

            if !items.isEmpty {
                ShelfChromeButton(
                    systemName: "arrow.right.to.line",
                    label: L("a11y.dock-shelf"),
                    action: onDock
                )
                ShelfActionMenu(manager: manager, shelfID: shelfID)
                ShelfChromeButton(
                    systemName: "chevron.right",
                    label: L("a11y.open-shelf"),
                    action: onOpenDocuments
                )
            }
        }
        .frame(height: ShelfLayout.stripHeaderHeight)
        // Clicking the line that says `1 of 5` puts the shelf back to `5
        // Files`. A row picked by accident has to be undoable without aiming,
        // and the header is the thing the user is already looking at to find
        // out what a drag will take.
        //
        // **The gesture is on the header and not on the whole strip**, which is
        // what it was first written as. A row's `DragInitiatorView` is an
        // AppKit subview, not a SwiftUI gesture, so it does *not* stop an
        // ancestor's `TapGesture` from also recognising: a click on a row fired
        // the row's selection and this clear, one immediately undoing the
        // other, and the strip could never be narrowed at all with the pointer.
        // `StripClearOnClickTests` drives both clicks through a real panel
        // because that is the only way that failure is visible.
        .contentShape(Rectangle())
        .onTapGesture(perform: onClearSelection)
    }

    // MARK: - Body

    private var emptyBody: some View {
        let hint = EmptyShelfHint.from(
            shakeEnabled: triggerShake,
            hotkeyEnabled: triggerHotkey,
            hotkeyPreset: hotkeyPreset
        )
        // A drop well rather than two floating lines: a dashed outline says
        // "put it here" before a word is read, and the tray glyph gives the
        // empty panel a centre of gravity instead of a stray caption.
        return VStack(spacing: Design.Space.xs) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: Design.Size.emptyGlyph, weight: .light))
                .foregroundStyle(Design.Ink.glyph)
                .padding(.bottom, Design.Space.hair)
                .accessibilityHidden(true)
            Text(hint.title)
                .font(Design.Text.item)
                .foregroundStyle(Design.Ink.secondary)
            if let subtitle = hint.subtitle {
                Text(subtitle)
                    .font(Design.Text.meta)
                    .foregroundStyle(Design.Ink.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: ShelfLayout.stripEmptyBodyHeight)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.face, style: .continuous)
                .strokeBorder(
                    Design.Line.hairline,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
    }

    /// Newest at the top, the same order the expanded grid draws in, so the
    /// row that just landed is the one the eye is already on.
    ///
    /// **Each row is its own drag surface now.** It used to be one overlay over
    /// the whole stack — the contract the paper cards had, invisible while three
    /// files were drawn as one object and plainly wrong once they were drawn as
    /// three rows: the owner dragged one row and got all eleven. What a row
    /// carries is `ShelfSelection.beginDrag`.
    ///
    /// **The fill is `ShelfSelection.highlighted`, which is nothing at rest.**
    /// It was `effective`, so an untouched shelf drew every row in solid accent
    /// — honest, and rejected by the owner as the opposite of minimal. The
    /// claim it was making now lives in the header as a sentence, and the fill
    /// is spent where it is worth its noise: for the length of a drag, on
    /// exactly the rows being carried, while there is still time to abort.
    private var rows: some View {
        let displayed = ShelfDisplayOrder.displayed(items)
        let ids = displayed.map(\.id)
        let selected = ShelfSelection.highlighted(
            explicit: selection, ids: ids, isDragging: isDragging
        )
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: ShelfLayout.rowSpacing) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                    ShelfStripRow(
                        item: item,
                        isSelected: selected.contains(item.id),
                        isFocused: focusedIndex == index,
                        // Inside the scroll view, not over it.
                        // `DragInitiatorView` does not override `scrollWheel`,
                        // so the event walks its *superview* chain: an overlay
                        // outside the ScrollView never reaches the NSScrollView
                        // and a shelf past eight files could not be scrolled.
                        dragOverlay: ShelfDragOverlay(
                            // Resolved at drag-start, and side-effect free —
                            // `hitTest` calls this too. The narrowing is applied
                            // by `onStart`, from the same pure call, so the two
                            // cannot come out different.
                            provider: {
                                let start = ShelfSelection.beginDrag(
                                    from: item.id, explicit: selection, ids: ids
                                )
                                return ShelfDisplayOrder
                                    .displayed(items, selecting: start.dragged)
                                    .compactMap { $0.fileURL }
                            },
                            onStart: { onDragStart(item.id) },
                            onEnd: onDragEnd,
                            onMovedOut: onMovedOut,
                            // **The menu answers to the header, like the
                            // drag.** It used to be built with no selection at
                            // all, so every row of it acted on the whole shelf:
                            // with `1 of 5` on screen its Move to Trash
                            // recycled five of the user's files. The selection
                            // goes in, `ShelfSelection.carried` resolves it,
                            // and the row titles are built from the same set.
                            menuBuilder: { [manager, shelfID, selection] in
                                ShelfActionMenuBuilder.make(
                                    manager: manager,
                                    shelfID: shelfID,
                                    selection: selection
                                )
                            },
                            onClick: { modifiers in onSelectRow(item.id, modifiers) }
                        )
                    )
                }
            }
        }
        .frame(height: ShelfLayout.stripBodyHeight(itemCount: items.count))
        .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                .fill(Design.Surface.rowHover.opacity(hovering ? 1 : 0))
        )
        // The rows stay. They used to fade to nothing for the length of a drag,
        // which is what made room for the old centred hint — and it meant the
        // shelf went blank exactly when the user was checking what they had
        // hold of. The drag is signalled by the header bar and by the card
        // under the cursor; the set itself stays legible.
        .animation(Design.Motion.state, value: isDragging)
        .animation(Design.Motion.state, value: hovering)
        // A group that CONTAINS its rows, where it used to ignore them. ADR
        // 0010 recorded the gap it leaves as owed: VoiceOver heard "3 Files"
        // for the whole strip while a sighted user read three names, and the
        // reason given was that per-row labels wanted the per-row drag contract
        // decided first. It is decided (ADR 0012), so the rows are elements.
        .accessibilityElement(children: .contain)
        // The same claim the header states, not a bare count. At rest no row
        // carries the `.isSelected` trait any more, so a count alone would
        // leave a VoiceOver user with no way at all to hear that a drag is
        // about to take one file out of five.
        .accessibilityLabel(ShelfStripHeader.title(name: nil, claim: claim))
    }
}

/// One file on the shelf: a thumbnail, the name, and under it the kind and
/// size. At 180pt the second line was judged noise; at 240pt it is what tells
/// two screenshots with near-identical names apart.
///
/// It is a selectable, draggable, individually spoken row now. The fill it
/// wears is `SelectionColor`'s pair — the same two colours every other
/// selectable cell in the app uses, resolved against whether this panel is the
/// key window — and the ring is the keyboard cursor, which says *where the
/// keyboard is* rather than *what will leave*.
struct ShelfStripRow: View {
    let item: ShelfItem
    var isSelected: Bool = false
    var isFocused: Bool = false
    /// Handed in rather than built here so a snapshot can render a row without
    /// an AppKit drag session behind it.
    var dragOverlay: ShelfDragOverlay? = nil

    @Environment(\.controlActiveState) private var controlActiveState
    private var isEmphasized: Bool { controlActiveState == .key }

    var body: some View {
        HStack(spacing: Design.Space.sm) {
            ShelfThumbnailChip(item: item)
                .frame(width: ShelfLayout.rowThumb, height: ShelfLayout.rowThumb)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(Design.Text.stripName)
                    .foregroundStyle(
                        isSelected
                            ? SelectionColor.text(emphasized: isEmphasized)
                            : Design.Ink.strong
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.displayMeta.isEmpty {
                    Text(item.displayMeta)
                        .font(Design.Text.meta)
                        .foregroundStyle(
                            isSelected
                                ? SelectionColor.text(emphasized: isEmphasized)
                                : Design.Ink.tertiary
                        )
                        .lineLimit(1)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.sm)
        // Vertical padding, not an explicit height: the row is as tall as a
        // chip plus its inset, and `ShelfLayout.rowHeight` says the same thing
        // in arithmetic. Pinning the frame instead would make the test that
        // compares the two unable to fail.
        .padding(.vertical, ShelfLayout.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                .fill(SelectionColor.fill(emphasized: isEmphasized).opacity(isSelected ? 1 : 0))
        )
        .focusRing(isFocused, cornerRadius: Design.Radius.row)
        .overlay { dragOverlay }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L("a11y.item.hint"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(Design.Motion.state, value: isSelected)
    }

    /// Spoken from what the row shows, name and then the kind-and-size line:
    /// the rule `ShelfItemAccessibility` states.
    private var accessibilityLabel: String {
        ShelfItemAccessibility.itemLabel(
            name: item.displayName,
            kind: ShelfItemAccessibility.kind(isDirectory: item.isDirectory, type: item.type),
            meta: item.displayMeta
        )
    }
}

/// Whether the panel under the pointer wants its chrome to step forward.
///
/// The controls never disappear — a control whose contrast nobody can measure
/// is a control nobody has checked, and `AppearanceTests` measures every ink
/// in this app. So at rest they are a bare secondary-ink glyph, and this is
/// what promotes them to a filled control when the pointer is on the panel.
private struct ShelfChromeRevealedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var shelfChromeRevealed: Bool {
        get { self[ShelfChromeRevealedKey.self] }
        set { self[ShelfChromeRevealedKey.self] = newValue }
    }
}

/// A shelf control, drawn as quietly as a control can be drawn and still be
/// found.
///
/// This replaces the 30pt filled circle that used to be the first thing the
/// eye landed on. Close and dock and expand are touched once a session; the
/// files are why the panel is on screen. At rest: a glyph on the secondary
/// ink ladder, no fill, no stroke. Under the pointer, or anywhere on the
/// panel: full ink and its own fill.
struct ShelfChromeButton: View {
    let systemName: String
    /// Spoken and hovered name. A glyph is not a label.
    let label: String
    let action: () -> Void

    @Environment(\.shelfChromeRevealed) private var revealed
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Design.Size.chromeGlyph, weight: .semibold))
                .foregroundStyle(revealed || hovering ? Design.Ink.primary : Design.Ink.glyph)
                .frame(width: Design.Size.chromeButton, height: Design.Size.chromeButton)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .fill(hovering ? Design.Surface.controlHover : Design.Surface.control)
                        .opacity(hovering ? 1 : 0)
                )
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .onHover { hovering = $0 }
        .animation(Design.Motion.state, value: hovering)
        .animation(Design.Motion.state, value: revealed)
    }
}

enum ShelfMatchedGeometry {
    static let card = "shelf.card"
}
