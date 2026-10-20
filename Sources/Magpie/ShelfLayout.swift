import AppKit
import SwiftUI

/// Where the shelf's geometry lives — once.
///
/// A shelf is an AppKit window wrapped around a SwiftUI tree, so how big the
/// window is and how big its contents are get decided in two different places.
/// They used to be maintained by hand and separately: `App.swift` carried
/// `let chrome: CGFloat = 130` and its own copy of the grid's column
/// arithmetic, while `ExpandedShelfView` carried the real spacings and card
/// sizes. Nothing held the two together, so every change to the shelf's
/// vertical rhythm broke one of them silently — which is the reason the rhythm
/// was never changed.
///
/// Everything a panel size depends on is named here, and **both sides read
/// it**: the window asks this file how tall to be, and the views lay
/// themselves out from the same figures. A drift is now a compile error or a
/// red test rather than a panel that is 30pt too short.
///
/// `Design` keeps the *vocabulary* — colour, type, radius, the spacing rhythm.
/// This keeps the *geometry* that vocabulary is arranged into. That is the
/// split `DesignTokens.swift` already declares at the top of the file:
/// "geometry is not vocabulary".
enum ShelfLayout {

    // MARK: - Shared

    /// The margin every shelf state puts between the panel edge and its
    /// content. Applied by `ShelfContainerView` to each branch, and counted
    /// again here because the window has to include it.
    static let margin = Design.Space.lg

    // MARK: - Collapsed: the strip

    /// The shelf is a narrow vertical strip, and its height is a function of
    /// how much is on it. It used to be a 210pt square with the contents
    /// floating in the middle of it, which is how three files came to read as
    /// one object: nothing about the panel changed when the shelf did.
    ///
    /// 240, up from 180. At 180 a macOS screenshot's own name ("Screenshot
    /// 2026-10-16 at 14.02.15.png") was cut in the middle to "Screensh…t
    /// 14.02.png", so every screenshot on the shelf read as the same file.
    static let stripWidth: CGFloat = 240
    /// The chrome line above the rows: the count, and the quiet controls.
    static let stripHeaderHeight = Design.Size.chromeButton
    static let stripHeaderGap = Design.Space.sm
    /// One row: a thumbnail chip, with the file's name and its kind and size
    /// stacked beside it.
    static let rowThumb = Design.Size.stripThumb
    static let rowPadding = Design.Space.xs
    static let rowHeight = rowThumb + rowPadding * 2
    static let rowSpacing = Design.Space.hair
    /// Past this the strip stops growing and scrolls. Eight rows is already a
    /// tall column; a shelf that grows to the height of the screen stops being
    /// a shelf.
    static let maxVisibleRows = 8
    /// The empty state: two short lines of hint, no rows.
    static let stripEmptyBodyHeight: CGFloat = 88

    /// The height `itemCount` rows occupy, before any chrome.
    static func stripBodyHeight(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return stripEmptyBodyHeight }
        let rows = min(itemCount, maxVisibleRows)
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }

    /// The strip of panel the magpie stands in, under the last row. The bird
    /// stands on the bottom edge at the right, 58 points tall above it; the
    /// margin plus this keeps its head clear of the last file's name, so the
    /// bird never covers what the shelf is for. Given back when the bird is
    /// sent away.
    static let perchClearance: CGFloat = 50

    /// The collapsed panel, sized to what is actually on the shelf, with room
    /// for the magpie when it is on the shelf.
    static func collapsedSize(itemCount: Int, perch: Bool = false) -> CGSize {
        CGSize(
            width: stripWidth,
            height: margin * 2
                + stripHeaderHeight
                + stripHeaderGap
                + stripBodyHeight(itemCount: itemCount)
                + (perch ? perchClearance : 0)
        )
    }

    // MARK: - Docked

    static let docked = CGSize(width: 44, height: 150)
    /// How far the panel's right-hand curve is pushed past the screen edge, so
    /// the visible side reads flush rather than rounded.
    static let dockedOffscreen: CGFloat = 18

    // MARK: - Expanded: the grid

    /// The adaptive grid's column bounds. `ExpandedShelfView` hands these to
    /// `LazyVGrid`, `ShelfFocus` uses the minimum to work out how far ↓ moves,
    /// and the panel sizing uses both — three readers, one number.
    static let gridColumnMinimum: CGFloat = 96
    static let gridColumnMaximum: CGFloat = 116
    static let gridColumnSpacing = Design.Space.gutter
    static let gridRowSpacing = Design.Space.row
    /// The `.padding(.vertical:)` on the grid itself, inside the scroll view.
    static let gridVerticalInset = Design.Space.xs

    // MARK: - Expanded: one card

    /// A grid tile's fixed vertical slot for its card face — a landscape card
    /// sits at the bottom of it so every label in a row shares a baseline.
    static let tileCardSlot = Design.Size.tileLongSide
    /// The tile's own padding, and the gap between its card and its labels.
    static let tilePadding = Design.Space.md
    static let tileInternalSpacing = Design.Space.md
    /// The two label lines under a card: name, a hair of spacing, metadata.
    ///
    /// The one figure here that is a measurement rather than a constant the
    /// views also use, because a SwiftUI `Font` will not tell you its line
    /// height. `ShelfLayoutTests` measures a real rendered tile and fails if
    /// this drifts from it, which is the only thing keeping it honest.
    static let tileLabelHeight: CGFloat = 30

    /// The full height of one grid cell. Derived, so retuning the tile's
    /// padding moves the panel with it.
    static let tileHeight: CGFloat =
        tilePadding * 2 + tileCardSlot + tileInternalSpacing + tileLabelHeight

    // MARK: - Expanded: the panel

    /// Three columns rather than four. The expanded browser is the same shelf
    /// opened up, not a different app: 520pt beside a 180pt strip read as two
    /// unrelated windows.
    static let expandedWidth: CGFloat = 400
    static let expandedMaxHeight: CGFloat = 480
    static let expandedMinHeight: CGFloat = 240

    /// The expanded header — title line over subtitle line, with the back
    /// button and the view-mode toggle beside them.
    static let expandedHeaderHeight: CGFloat = 32
    /// The gap between header, content and footer in the expanded VStack.
    static let expandedOuterSpacing = Design.Space.lg
    /// The Reveal in Finder / Select All row.
    static let expandedFooterHeight = Design.Size.pillHeight

    /// Everything in an expanded panel that is not a card. Every term is a
    /// figure the views lay themselves out with; the incumbent's unexplained
    /// 8pt of slack is gone rather than carried forward.
    static let expandedChrome: CGFloat =
        margin * 2
        + expandedHeaderHeight
        + expandedOuterSpacing * 2
        + expandedFooterHeight
        + gridVerticalInset * 2

    /// The width the grid actually gets, once the panel's margins are gone.
    static let expandedContentWidth = expandedWidth - margin * 2

    /// How many cards fit across the expanded grid. Delegates to `ShelfFocus`
    /// rather than repeating the arithmetic, so the panel and the ↓ key can
    /// never disagree about how wide a row is.
    static var expandedColumnCount: Int {
        ShelfFocus.columnCount(
            availableWidth: expandedContentWidth,
            minimum: gridColumnMinimum,
            spacing: gridColumnSpacing
        )
    }

    /// The panel size that hugs `itemCount` cards, capped so the shelf never
    /// grows taller than the screen wants it to; the scroll view inside takes
    /// the overflow.
    static func expandedSize(itemCount: Int) -> CGSize {
        let columns = expandedColumnCount
        let rows = max(1, (max(itemCount, 1) + columns - 1) / columns)
        let content = CGFloat(rows) * tileHeight
            + CGFloat(rows - 1) * gridRowSpacing
        let height = min(expandedChrome + content, expandedMaxHeight)
        return CGSize(width: expandedWidth, height: max(height, expandedMinHeight))
    }
}
