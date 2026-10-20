import AppKit
import SwiftUI

/// ⌘K, built out of the menu it is a palette for.
///
/// There is no second list of actions in this file. The palette asks the same
/// two builders the pointer already uses — `ShelfContextMenu.make` for a
/// selection, `ShelfActionMenuBuilder.make` for the whole shelf — for a real
/// `NSMenu`, and flattens it. **That is the seam.** A row added to either
/// builder appears here with no edit, a row removed disappears, a conversion
/// target or a route id rides through in `representedObject`, and the
/// enablement each builder already computes is the enablement the palette
/// shows, because the palette has no opinion of its own about what exists.
///
/// The alternative — a parallel action registry both surfaces render from — is
/// a second place to say the same thing that then has to stay in sync, which is
/// the argument this codebase already makes against a route editor.
enum ShelfActionPalette {

    /// One runnable row. `menuItem` is owned by the menu the caller holds, and
    /// that menu is also what keeps the builders' `@objc` target objects alive —
    /// drop the menu and every row here stops working.
    struct Entry: Identifiable {
        /// Position in the flattened menu order. Stable for one open palette,
        /// which is all a highlight needs.
        let id: Int
        /// The row's own title.
        let title: String
        /// The submenu titles above it, outermost first. Empty at top level.
        let path: [String]
        let isEnabled: Bool
        let menuItem: NSMenuItem

        /// "All Actions › Convert to", or "" for a top-level row.
        var breadcrumb: String { path.joined(separator: " › ") }
    }

    /// Pure: every runnable leaf in a menu tree, depth-first, in menu order.
    ///
    /// Separators are skipped. A row carrying a submenu is a container, not an
    /// action, so it contributes its title to the path and nothing else. A row
    /// with no action at all and no submenu is a section header (the builders
    /// make those disabled and restyled) and is dropped.
    static func entries(in menu: NSMenu) -> [Entry] {
        var out: [Entry] = []

        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items {
                if item.isSeparatorItem { continue }
                if let submenu = item.submenu {
                    walk(submenu, path: path + [item.title])
                    continue
                }
                guard let action = item.action else { continue }
                // The row that opens this palette is not an action inside it.
                // It carried a submenu until the menu was reorganised, and a
                // submenu row is already skipped above; without this it would
                // start listing itself, offering the user a row whose only
                // effect is to reopen the window they are looking at.
                if action == #selector(ShelfActionTargets.openPalette) { continue }
                out.append(Entry(
                    id: out.count,
                    title: item.title,
                    path: path,
                    isEnabled: item.isEnabled,
                    menuItem: item
                ))
            }
        }

        walk(menu, path: [])
        return out
    }

    /// Pure: the rows worth offering for `query`, best first.
    ///
    /// Disabled rows are dropped rather than greyed: a menu shows them so the
    /// user learns the action exists, but a palette is a list of what is
    /// available right now, and a row that cannot run is noise between the
    /// query and the row that can. An empty query keeps menu order, which is
    /// the order the user already knows.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let available = entries.filter(\.isEnabled)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return available }

        return available
            .compactMap { entry -> (entry: Entry, rank: Int)? in
                guard let rank = rank(entry, query: needle) else { return nil }
                return (entry, rank)
            }
            .sorted { $0.rank == $1.rank ? $0.entry.id < $1.entry.id : $0.rank < $1.rank }
            .map(\.entry)
    }

    /// Pure. Lower is better; nil is "not this row".
    ///
    /// Every whitespace-separated token has to appear somewhere in the row, so
    /// "conv png" finds `All Actions › Convert to › PNG` and "png conv" finds it
    /// too. The rank then answers the only question left: how close is the first
    /// token to the row's own name.
    static func rank(_ entry: Entry, query needle: String) -> Int? {
        let tokens = needle.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return 0 }

        let title = entry.title.lowercased()
        let full = (entry.path + [entry.title]).joined(separator: " ").lowercased()
        guard tokens.allSatisfy({ full.contains($0) || isSubsequence($0, of: full) }) else {
            return nil
        }

        if title.hasPrefix(first) { return 0 }
        if title.contains(first) { return 1 }
        if full.contains(first) { return 2 }
        return 3
    }

    /// Pure: the characters of `needle` appear in `haystack` in order, not
    /// necessarily adjacent — "cpdf" reaches "Create PDF". This is what makes a
    /// palette worth typing into rather than scrolling.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var characters = haystack.makeIterator()
        for wanted in needle {
            var found = false
            while let next = characters.next() {
                if next == wanted {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    /// Fires the row exactly as AppKit would: the same target, the same
    /// selector, the same `sender`, so a parameterised row reads its
    /// `representedObject` off the item it was built with and cannot tell the
    /// difference between this and a click.
    @MainActor
    static func perform(_ entry: Entry) {
        let item = entry.menuItem
        guard item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

// MARK: - The overlay

/// The palette itself: a query field, and the rows that survive it.
struct ActionPaletteOverlay: View {
    let entries: [ShelfActionPalette.Entry]
    @Binding var query: String
    @Binding var highlighted: Int
    let onRun: (ShelfActionPalette.Entry) -> Void
    let onMove: (Int) -> Void
    let onDismiss: () -> Void

    private var visible: [ShelfActionPalette.Entry] {
        ShelfActionPalette.filter(entries, query: query)
    }

    var body: some View {
        ZStack {
            // A click anywhere outside the card closes it, the same way a click
            // outside a menu does.
            Design.Surface.scrim
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                queryRow
                Divider().overlay(Design.Line.hairlineFaint)
                rows
            }
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                    .fill(Design.Surface.toast)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                    .strokeBorder(Design.Line.hairline, lineWidth: Design.Line.hairlineWidth)
            )
            .shelfShadow(Design.Depth.hover)
            .padding(.horizontal, Design.Space.rhythm)
            .padding(.vertical, Design.Space.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("palette.title"))
    }

    private var queryRow: some View {
        HStack(spacing: Design.Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Design.Ink.secondary)
                .accessibilityHidden(true)
            PaletteQueryField(
                query: $query,
                placeholder: L("palette.placeholder"),
                onMove: onMove,
                onRun: { if let entry = highlightedEntry { onRun(entry) } },
                onDismiss: onDismiss
            )
            .frame(height: 20)
        }
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.lg)
    }

    private var highlightedEntry: ShelfActionPalette.Entry? {
        let rows = visible
        guard rows.indices.contains(highlighted) else { return rows.first }
        return rows[highlighted]
    }

    @ViewBuilder
    private var rows: some View {
        let rows = visible
        if rows.isEmpty {
            Text(L("palette.no-matches"))
                .font(Design.Text.item)
                .foregroundStyle(Design.Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.xl)
                .padding(.vertical, Design.Space.rhythm)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Design.Space.hair) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            PaletteRow(entry: entry, isHighlighted: index == highlighted)
                                .id(entry.id)
                                .onTapGesture { onRun(entry) }
                        }
                    }
                    .padding(.horizontal, Design.Space.md)
                    .padding(.vertical, Design.Space.md)
                }
                .frame(maxHeight: 220)
                .onChange(of: highlighted) { index in
                    guard rows.indices.contains(index) else { return }
                    withAnimation(Design.Motion.state) {
                        proxy.scrollTo(rows[index].id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct PaletteRow: View {
    let entry: ShelfActionPalette.Entry
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: Design.Space.md) {
            // The menu's own glyph, not a second icon table: the row is the
            // menu row, so it looks like the menu row.
            if let image = entry.menuItem.image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .foregroundStyle(isHighlighted ? SelectionInk.text : Design.Ink.glyph)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Text(entry.title)
                .font(Design.Text.item)
                .foregroundStyle(isHighlighted ? SelectionInk.text : Design.Ink.strong)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Design.Space.sm)
            if !entry.breadcrumb.isEmpty {
                Text(entry.breadcrumb)
                    .font(Design.Text.meta)
                    .foregroundStyle(isHighlighted ? SelectionInk.text : Design.Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, Design.Space.lg)
        .padding(.vertical, Design.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                .fill(SelectionInk.fill.opacity(isHighlighted ? 1 : 0))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.breadcrumb.isEmpty
                            ? entry.title
                            : "\(entry.title), \(entry.breadcrumb)")
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}

/// The selection pair AppKit guarantees legible together. Same values as the
/// shelf cells use; named separately because this file cannot see theirs.
private enum SelectionInk {
    static let fill = Color(nsColor: .selectedContentBackgroundColor)
    static let text = Color(nsColor: .alternateSelectedControlTextColor)
}

/// The palette's query field.
///
/// AppKit rather than SwiftUI's `TextField` for two reasons. This panel is a
/// `.nonactivatingPanel`, which is not a place to bet a feature on SwiftUI
/// focus behaving; and the arrow keys have to be read *before* the field editor
/// swallows them, which `NSTextField` offers as `doCommandBy` selectors and
/// SwiftUI on macOS 13 has no equivalent for.
///
/// If the field never takes first responder, nothing here breaks: the app-level
/// key monitor bails out only *while* a field editor holds it, so with no focus
/// it still drives the highlight, Return still runs, Escape still closes. Only
/// typed filtering would be lost.
/// A text field that takes first responder the moment it joins a window.
///
/// The palette is a keyboard surface: ⌘K then type. Requiring a click first
/// makes the shortcut slower than the right-click it replaces, which is the
/// whole point gone.
///
/// `viewDidMoveToWindow` is the earliest moment a window exists to become
/// first responder OF, and it is called by AppKit rather than by a SwiftUI
/// re-render, so it cannot be skipped the way the old `updateNSView` claim was.
final class FocusOnAppearTextField: NSTextField {
    private var hasClaimedFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasClaimedFocus else { return }
        hasClaimedFocus = true
        // Not synchronously: `makeFirstResponder` installs the field editor,
        // which re-enters the view hierarchy this call is still inside.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}

private struct PaletteQueryField: NSViewRepresentable {
    @Binding var query: String
    let placeholder: String
    /// -1 for up, +1 for down.
    let onMove: (Int) -> Void
    let onRun: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusOnAppearTextField(string: query)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onRun = onRun
        context.coordinator.onDismiss = onDismiss
        if nsView.stringValue != query { nsView.stringValue = query }
        // Focus is claimed by the field itself, in `viewDidMoveToWindow`.
        //
        // It used to be claimed here, and that is why ⌘K opened a palette you
        // had to CLICK before you could type. On the first `updateNSView` the
        // field is not in the window yet, so `nsView.window` is nil and the
        // claim is skipped — and with nothing else changing, SwiftUI has no
        // reason to call `updateNSView` again. The retry never came. Claiming
        // from the view removes the dependency on a re-render that may not
        // happen.
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        // Hand first responder back to the panel's content view, which is what
        // puts `QuickLookController` back in the space bar's path. Leaving it
        // on a removed field would strand the responder chain at the window.
        guard let window = nsView.window else { return }
        let editor = nsView.currentEditor()
        guard window.firstResponder === nsView || window.firstResponder === editor else { return }
        window.makeFirstResponder(window.contentView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(query: $query, onMove: onMove, onRun: onRun, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let query: Binding<String>
        var onMove: (Int) -> Void
        var onRun: () -> Void
        var onDismiss: () -> Void
        var claimedFocus = false

        init(
            query: Binding<String>,
            onMove: @escaping (Int) -> Void,
            onRun: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.query = query
            self.onMove = onMove
            self.onRun = onRun
            self.onDismiss = onDismiss
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            query.wrappedValue = field.stringValue
        }

        /// The field editor offers every navigation key here before acting on
        /// it. Claiming these four is what lets the palette be driven entirely
        /// from the keyboard without the query losing a single character.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                onRun()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onDismiss()
                return true
            default:
                return false
            }
        }
    }
}
