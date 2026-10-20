import AppKit
import SwiftUI

/// The shelf's visual vocabulary, in one place.
///
/// Every value here is the literal that was previously inline at the call
/// site, moved verbatim. Nothing was retuned, merged, or rounded onto a scale:
/// the point of this file is to make the system *visible and changeable*, not
/// to change it. Where the incumbent contradicts itself — seven radii for six
/// kinds of surface, six hover fills for one class of control, two snippet
/// inks 0.03 apart — the token names it in a comment and leaves it alone.
/// Repairing those is a later, deliberate pass that needs an owner's eye.
///
/// The namespace is `Design` rather than the `Shelf` used in
/// `docs/UX-REDESIGN-SCOPE.md` because `Shelf` is already the model struct.
///
/// **What is deliberately *not* a token.** Geometry is not vocabulary: frame
/// sizes, offsets, icon glyph point sizes, rotation tables, and shadow blur
/// radii stay at their call sites. `Design.Size` carries only the handful of
/// figures that were duplicated across two files and would otherwise drift.
enum Design {

    // MARK: - Appearance

    /// A colour that resolves differently in Light and Dark.
    ///
    /// The shelf's translucent chrome is the reason this exists. A control fill
    /// of `white.opacity(0.10)` is a legible raise on a dark panel and is
    /// *invisible* on a light one — verified by rendering the real views under
    /// both appearances, where the close button, the disclosure chevron and the
    /// file-count pill all vanished. The alphas below are the incumbent's,
    /// unchanged; only the polarity flips.
    ///
    /// Prefer a real AppKit semantic colour (`labelColor` and friends) wherever
    /// one carries the meaning. Those track Increase Contrast as well as
    /// appearance, which a hand-mixed pair never will.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// A translucent raise over the panel: white on dark, black on light, at
    /// the same alpha. `lightAlpha` defaults lower because black-on-light reads
    /// heavier than white-on-dark at equal alpha.
    static func raise(_ alpha: CGFloat, lightAlpha: CGFloat? = nil) -> Color {
        adaptive(
            light: NSColor(calibratedWhite: 0, alpha: lightAlpha ?? alpha * 0.7),
            dark: NSColor(calibratedWhite: 1, alpha: alpha)
        )
    }

    // MARK: - Brand

    /// The app's own two colours, and the only two it has: Castor's
    /// terracotta and teal, the studio's pair (castor-identity, SIGNATURE.md).
    ///
    /// Everything else in this file is either an AppKit semantic or a neutral
    /// raise, deliberately: those follow the appearance, Increase Contrast and
    /// the user's own accent for free, and a brand colour follows nothing. So
    /// these are spent only where the app is saying something that is its own
    /// rather than the system's: terracotta on a card leaving the shelf under
    /// the command key and on the magpie's spark, teal on the rows the user
    /// picked and on the ring that says files are arriving. Warm goes out,
    /// cool comes in.
    ///
    /// Terracotta survives both appearances as given (3.85:1 on the light
    /// panel, 3.25:1 on the dark one, against the 3:1 a stroke carrying state
    /// has to clear). Teal does not: it is a deep colour, 2.2:1 on the dark
    /// panel, so it carries a twin lifted a quarter of the way to white for
    /// Dark, a straight lightness move along the same hue, so it stays
    /// recognisably the same colour rather than becoming a second one.
    enum Brand {
        /// Castor terracotta, `#C4552A`, as on the website.
        static let terracottaValue = NSColor(srgbRed: 0xC4 / 255, green: 0x55 / 255, blue: 0x2A / 255, alpha: 1)
        /// Castor teal, `#006770`, as on the website.
        static let tealValue = NSColor(srgbRed: 0x00 / 255, green: 0x67 / 255, blue: 0x70 / 255, alpha: 1)
        /// Teal lifted a quarter of the way to white, `#408D94`: 3.9:1 on the
        /// dark panel.
        static let tealOnDark = NSColor(srgbRed: 0x40 / 255, green: 0x8D / 255, blue: 0x94 / 255, alpha: 1)

        /// Terracotta, legible in both appearances. Files going out.
        static let terracotta = Color(nsColor: terracottaValue)
        /// Teal, legible in both appearances. Files coming in.
        static let teal = adaptive(light: tealValue, dark: tealOnDark)
    }

    // MARK: - Radius

    /// Seven radii for six kinds of surface, with no relationship between the
    /// values and no nesting rule: a document card is `card` in the collapsed
    /// stack and `face` in the expanded grid, and its selection background is
    /// `tile` in the grid but `row` in the list. Named here as found.
    enum Radius {
        /// The 22×22 thumbnail chip in a list row.
        static let chip: CGFloat = 5
        /// Selection and hover background on a list row.
        static let row: CGFloat = 7
        /// Card faces, skeleton placeholders, the progress-overlay clip.
        static let face: CGFloat = 10
        /// Grid-tile selection background, and the toast.
        static let tile: CGFloat = 14
        /// One invisible `Color.clear` container: the matched-geometry anchor
        /// behind the grid. Deleted rather than mapped in a later pass.
        static let gridAnchor: CGFloat = 16
        /// The panel layer, its inner stroke, the drop-target overlay, and the
        /// docked tab highlight. Fixed by `FloatingPanel`'s root layer.
        ///
        /// 16, not 22. A 22pt radius on a 180pt-wide vertical strip is a
        /// lozenge; the panel is a tall rectangle now and wants a corner, not
        /// a curve.
        static let panel: CGFloat = 16
    }

    // MARK: - Space

    /// The rhythm is 2, 3, 4, 6, 8, 10, 12, 14, 16, 18: not a scale — there is
    /// no consistent interval, and 16 and 18 sit side by side in one grid.
    /// Applied to stack spacing and padding only.
    enum Space {
        static let hair: CGFloat = 2
        /// One site: the list row's vertical inset.
        static let micro: CGFloat = 3
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        /// Tile padding and internal stack spacing.
        static let md: CGFloat = 8
        /// State margins, header spacing, capsule padding.
        static let lg: CGFloat = 10
        /// The preview inset on a paper card, and the toast's vertical padding.
        static let xl: CGFloat = 12
        /// The expanded shelf's outer vertical rhythm and capsule padding.
        static let rhythm: CGFloat = 14
        /// Grid column spacing, and the grab handle's horizontal hit padding.
        static let gutter: CGFloat = 16
        /// Grid row spacing — 2pt off the column gutter it sits beside.
        static let row: CGFloat = 18
    }

    // MARK: - Ink

    /// Foregrounds, on AppKit's semantic label ladder.
    ///
    /// The incumbent was thirteen hand-mixed steps of `Color.white`, which made
    /// the whole app invisible in Light and inert under Increase Contrast. The
    /// four `*LabelColor` roles carry the same hierarchy, adapt to both
    /// appearances, and respond to Increase Contrast and to Differentiate
    /// Without Colour for free.
    ///
    /// The four glyph steps (0.85 / 0.75 / 0.70 / 0.65) and the three "strong"
    /// steps (0.92 / 0.95 / 0.98) did the same job as each other, so they
    /// collapse onto the same roles. The names survive so no call site changes;
    /// what they point at is now determined rather than chosen.
    enum Ink {
        /// Expanded header title; the light half of the grid remove glyph.
        static let primary = Color(nsColor: .labelColor)
        /// The de facto body colour: item names, button glyphs, toast body,
        /// enabled pill text.
        static let strong = Color(nsColor: .labelColor)
        /// Documents-pill title, docked-tab chevron on hover, list remove glyph.
        static let emphasis = Color(nsColor: .labelColor)
        /// The active view-mode segment's glyph.
        static let active = Color(nsColor: .labelColor)

        /// Toast icon, inline chevron at rest, segment glyph on hover.
        static let glyphBright = Color(nsColor: .labelColor)
        /// Pin indicator in the collapsed header.
        static let glyphStrong = Color(nsColor: .secondaryLabelColor)
        /// Folder and pin indicators, list-thumbnail placeholder glyphs.
        static let glyph = Color(nsColor: .secondaryLabelColor)
        /// Docked-tab chevron at rest.
        static let glyphDim = Color(nsColor: .secondaryLabelColor)

        /// Header subtitle, empty-state prompts, segment glyph at rest.
        static let secondary = Color(nsColor: .secondaryLabelColor)
        /// Item metadata — size and kind under a filename.
        ///
        /// `secondaryLabelColor`, not `tertiaryLabelColor`. Tertiary is
        /// AppKit's *decorative* step and measures 1.86:1 in Light and 2.24:1
        /// in Dark against the panel, well under the 3:1 floor. This is
        /// content the user reads to tell two files apart, so it sits at the
        /// same weight as a subtitle. Caught by
        /// `testSecondaryAndTertiaryInkClearLargeTextContrast`.
        static let tertiary = Color(nsColor: .secondaryLabelColor)
        /// Disabled pill text.
        static let disabled = Color(nsColor: .disabledControlTextColor)
        /// Empty-folder tray glyph.
        static let quaternary = Color(nsColor: .quaternaryLabelColor)

        // There is no paper in the shelf any more (ADR 0010), so there are no
        // inks that have to survive being drawn on it. The two below are not
        // paper: they are the dark half of a two-tone `xmark.circle.fill`,
        // whose light half is `primary` — the glyph is a hole punched in a
        // filled disc, and the disc has to stay dark in both appearances or
        // the cross disappears into it.

        /// Dark half of the grid tile's remove glyph.
        static let removeGlyph = Color.black.opacity(0.6)
        /// Dark half of the list row's remove glyph — the same control, so the
        /// same value; it was 0.10 adrift.
        static let removeGlyphList = Color.black.opacity(0.6)
    }

    // MARK: - Surface

    /// Fills, as translucent raises over whatever the panel material resolves
    /// to. Polarity follows the appearance; the alphas are the incumbent's.
    ///
    /// Six hover fills (0.06, 0.10, 0.16, 0.18, 0.20, 0.22) served controls
    /// that all read as one class. They collapse to three steps — rest, hover,
    /// and a quiet row highlight — because a shelf read in two seconds is read
    /// faster when fewer things vary. The names survive; the values no longer
    /// disagree with each other.
    enum Surface {
        /// Circular buttons at rest, the toggle track, thumbnail placeholder
        /// grounds, the documents pill at rest.
        static let control = raise(0.10)
        /// Circular button on hover.
        static let controlHover = raise(0.20)
        /// The active segment in the view-mode toggle.
        static let controlActive = raise(0.20)
        /// A view-mode segment on hover.
        static let segmentHover = raise(0.10)

        /// Reveal in Finder and Select All, at rest.
        static let pill = raise(0.10)
        /// The same two pills, on hover.
        static let pillHover = raise(0.20)
        /// The collapsed documents pill on hover.
        static let documentsPillHover = raise(0.20)

        /// The inline folder-navigate chevron.
        static let chevron = raise(0.10)
        static let chevronHover = raise(0.20)

        /// A list row under the pointer.
        static let rowHover = raise(0.06)

        /// The placeholder shown while Quick Look renders a real thumbnail.
        static let skeleton = raise(0.08)

        /// A whisper of tint over the panel's visual-effect view.
        ///
        /// Was a flat 20% black. That wash sat on top of a `.sidebar` material
        /// under a forced `.vibrantDark` — three grounds fighting, which is
        /// what made the panel read as a bespoke slab instead of a system
        /// surface. Dropping it to a hint is the single change that most
        /// alters how the shelf reads in Dark.
        static let panelWash = adaptive(
            light: NSColor(calibratedWhite: 1, alpha: 0.10),
            dark: NSColor(calibratedWhite: 0, alpha: 0.04)
        )
        /// Behind a conversion or OCR progress overlay.
        static let scrim = adaptive(
            light: NSColor(calibratedWhite: 1, alpha: 0.55),
            dark: NSColor(calibratedWhite: 0, alpha: 0.45)
        )
        /// The toast is the one surface that uses no material at all.
        static let toast = Color(nsColor: .controlBackgroundColor)
        /// The card the magpie carries in to ask its one question. Solid, as
        /// a system alert is, because the bird carries it as a picture and the
        /// picture has to be the card it then sets down.
        static let question = Color(nsColor: .windowBackgroundColor)
    }

    // MARK: - Line

    /// Strokes, drawn wherever two surfaces of similar luminance meet. Four
    /// white opacities (0.08, 0.10, 0.16, 0.18) collapse to two steps, and
    /// both flip polarity with the appearance.
    enum Line {
        /// Capsules and circular buttons.
        static let hairline = raise(0.16)
        /// The toggle track and the toast.
        static let hairlineFaint = raise(0.08)
        /// The Quick Look skeleton placeholder.
        static let skeleton = raise(0.08)
        /// The panel's inner stroke.
        static let panel = adaptive(
            light: NSColor(calibratedWhite: 0, alpha: 0.12),
            dark: NSColor(calibratedWhite: 1, alpha: 0.10)
        )
        /// The inline chevron and the shelf accent badge.
        static let badge = raise(0.16)

        /// The edge drawn on a photo or paper card so it separates from the
        /// panel behind it. Carries real weight in Light, where a white card
        /// sits on a light panel and the shadow alone cannot separate them;
        /// stays a whisper in Dark, where the contrast already does the work.
        static let edge = adaptive(
            light: NSColor(calibratedWhite: 0, alpha: 0.16),
            dark: NSColor(calibratedWhite: 0, alpha: 0.06)
        )

        /// The keyboard focus ring. The one colour in the shelf that is
        /// semantic before it is anything else: `keyboardFocusIndicatorColor`
        /// follows the user's accent, both appearances and Increase Contrast,
        /// and it is what every other Mac app draws — a focus ring has to be
        /// recognised before it is read.
        ///
        /// Deliberately not the selection fill. An item can be focused without
        /// being selected, and the two states must never look like one: the
        /// ring says *where the keyboard is*, the fill says *what will be acted
        /// on*.
        static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)
        static let focusRingWidth: CGFloat = 2.5

        /// The ring the drag-out pill wears while ⌘ is held.
        ///
        /// It was `focusRing` — the system accent — on the reasoning that ⌘ is
        /// the keyboard speaking. That reasoning was fine and the colour is
        /// now wrong for a different reason: this is the app's own strongest
        /// statement about a user's file, and it should be the app's own
        /// colour rather than one borrowed from the system. Deliberately *not*
        /// `focusRing` any more, so a focused card and a moving one cannot be
        /// confused — those are different claims and now different colours.
        static let moveRing = Design.Brand.terracotta

        /// The ring drawn when files are being dropped *onto* the shelf, on
        /// the panel and on its docked tab. Was an inline `Color.accentColor`,
        /// which ADR 0006 forbids and which no token named. Teal rather than
        /// terracotta so the two directions never read alike: terracotta is a
        /// file leaving, this is a file arriving.
        static let dropTarget = Design.Brand.teal

        static let hairlineWidth: CGFloat = 0.5
        static let panelWidth: CGFloat = 0.75
        /// The drop-target ring on the panel, and its thinner docked-tab variant.
        static let dropTargetWidth: CGFloat = 3
        static let dockedDropWidth: CGFloat = 2
    }

    // MARK: - Depth

    /// Depth is drawn, not tonal: a raised surface is not a lighter surface,
    /// it is a surface with a shadow under it. Every shadow in the shelf sits
    /// at x: 0, so a token carries only colour, blur and vertical offset.
    enum Depth {
        struct Style {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        /// A card at rest in the expanded grid; also the back card of the
        /// collapsed paper stack, which uses these exact three values.
        static let rest = Style(color: .black.opacity(0.14), radius: 12, y: 6)
        /// The same shadow deepened and dropped under the pointer.
        static let hover = Style(color: .black.opacity(0.22), radius: 18, y: 10)
        /// The tight second shadow that makes a card read as resting on a
        /// surface rather than floating above it.
        static let contact = Style(color: .black.opacity(0.06), radius: 2, y: 1)

    }

    // MARK: - Text

    /// Fixed point sizes, never system text styles, so nothing responds to the
    /// user's text-size preference. Icon glyph sizes are deliberately absent:
    /// they are geometry, not type.
    enum Text {
        /// The expanded shelf's primary header line.
        static let title = Font.system(size: 15, weight: .semibold)
        /// List-row item names, the header subtitle, folder captions.
        static let item = Font.system(size: 12)
        /// Text on both pill buttons and in the toast.
        static let control = Font.system(size: 12, weight: .medium)
        /// The AppKit twin of `control`, kept beside it so the two cannot
        /// drift: `ToastMetrics` measures a message with this font to decide
        /// how tall the toast has to be, and `ToastView` draws it with
        /// `control`. Retune one and the toast is sized for the other.
        static let controlMeasuring = NSFont.systemFont(ofSize: 12, weight: .medium)
        /// Grid-tile item names and the loading caption.
        static let label = Font.system(size: 11)
        /// A file's name on the collapsed strip: the one line the shelf is for.
        static let stripName = Font.system(size: 13)
        /// The strip's header sentence, which says what a drag will take.
        static let stripHeader = Font.system(size: 11, weight: .medium)
        /// The AppKit twin of `stripHeader`; see `metaMeasuring`.
        static let stripHeaderMeasuring = NSFont.systemFont(ofSize: 11, weight: .medium)
        /// Item metadata under a tile and in a list row.
        static let meta = Font.system(size: 10)
        /// The AppKit twin of `meta`, kept beside it for the same reason as
        /// `controlMeasuring`: the collapsed strip's header is 180pt wide and
        /// carries the one sentence that says what a drag will take, so a test
        /// measures that sentence in nine languages against the space it has.
        /// Retune one and the measurement is taken for the other.
        static let metaMeasuring = NSFont.systemFont(ofSize: 10)
        /// The count on a multi-file drag image. AppKit-only and deliberately
        /// so: the drag preview is a bitmap composed by `NSImage`, so unlike
        /// `controlMeasuring` there is no SwiftUI twin it could drift from.
        static let countBadge = NSFont.systemFont(ofSize: 11, weight: .semibold)
    }

    // MARK: - Size

    /// Only the figures that were written out in two places and would drift.
    enum Size {
        /// The standard circular button.
        static let iconButton: CGFloat = 30
        /// Reveal in Finder and Select All.
        static let pillHeight: CGFloat = 32
        /// The expanded list-row thumbnail chip.
        static let rowThumb: CGFloat = 22
        /// The collapsed strip's thumbnail. Larger than the list's because the
        /// strip row carries two lines, and a screenshot has to be told from
        /// its neighbour at a glance rather than by reading its name.
        static let stripThumb: CGFloat = 32
        /// The expanded grid card's long-side cap, and the label column that
        /// keeps titles aligned under narrow cards.
        static let tileLongSide: CGFloat = 100
        static let tileLabelMinWidth: CGFloat = 90
        /// A non-image tile, which has no aspect to honour.
        static let tileFallback = CGSize(width: 78, height: 100)
        /// A shelf control — close, dock, expand, actions. 18pt of hit area
        /// around a 10pt glyph, against the 30pt filled circle it replaces:
        /// chrome that is found when looked for and ignored otherwise.
        static let chromeButton: CGFloat = 22
        static let chromeGlyph: CGFloat = 11
        /// The tray glyph that anchors the empty strip.
        static let emptyGlyph: CGFloat = 22
    }

    // MARK: - Transparency

    /// Reduce Transparency, handled the same shape as `Motion` handles Reduce
    /// Motion: one live read, consulted at the call site, never cached.
    enum Transparency {
        /// Read live at every call site rather than cached, so a change made
        /// while the app is running takes effect on the next apply without
        /// anything having to be invalidated.
        static var isReduced: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }

        /// The opaque ground drawn in place of the panel's material when
        /// Reduce Transparency is on. Semantic on purpose (ADR 0006): it
        /// follows the appearance and Increase Contrast, which a hand-mixed
        /// light/dark pair never would. `AppearanceTests` holds every ink and
        /// fill to the same contrast floors over this ground that they meet
        /// over the material's approximation.
        static let opaquePanelGround = NSColor.windowBackgroundColor
    }

    // MARK: - Motion

    /// Ten curves collapse to six: four SwiftUI roles and the two AppKit panel
    /// timings, which do a different job and keep their own values.
    ///
    /// The merges are `.easeOut(0.2)` and `.easeInOut(0.18)` into `state`, and
    /// `.spring(0.28, 0.7)` with `.spring(0.32, 0.72)` into `hover`, and
    /// `.spring(0.4, 0.85)` with `.spring(0.42, 0.85)` into `transform`. Each
    /// pair was perceptually the same motion applied to the same kind of
    /// change. `shelfState` is kept apart on purpose: it is the one SwiftUI
    /// animation that runs in lockstep with the AppKit panel resize, so its
    /// duration answers to a different constraint.
    ///
    /// **The shelf gesture is faster than it was**, and deliberately less
    /// bouncy: 0.5s/0.78 became 0.34s/0.86, in lockstep with the panel resize
    /// dropping from 0.45s to 0.3s. A shelf is touched for two seconds at a
    /// time, and half a second of spring is a third of that spent watching a
    /// window arrive.
    enum Motion {
        enum Role {
            /// Binary state flips: hover fills, selection, active segment,
            /// drop target, drag fade, thumbnail crossfade.
            case state
            /// A control or card responding to the pointer — scale and lift.
            case hover
            /// Content moving: folder push and pop, item insertion and undo.
            case transform
            /// Collapsed ↔ expanded ↔ docked.
            case shelfState
        }

        enum PanelRole {
            /// Expand, collapse, dock, drag-restore.
            case frame
            /// The auto-park glide to the top-right corner, deliberately
            /// slower and softer so the panel glides rather than snaps.
            case glide
        }

        /// An AppKit panel-frame animation. `nil` from `panelTiming` means the
        /// caller should set the frame outright with no animation at all.
        struct PanelTiming: Equatable {
            let duration: TimeInterval
            let c0: Float
            let c1: Float
            let c2: Float
            let c3: Float

            var mediaTimingFunction: CAMediaTimingFunction {
                CAMediaTimingFunction(controlPoints: c0, c1, c2, c3)
            }
        }

        /// When Reduce Motion is on, anything that moves, springs or slides is
        /// replaced by this or by nothing at all. Short enough to read as a
        /// change of state rather than as travel.
        static let crossfade = Animation.easeOut(duration: 0.1)

        /// Pure: the animation for a role, given whether Reduce Motion is on.
        /// `nil` means "apply the change instantly".
        static func animation(_ role: Role, reduceMotion: Bool) -> Animation? {
            if reduceMotion {
                switch role {
                // A lift is scale and offset with nothing else to show, so
                // under Reduce Motion it simply does not animate.
                case .hover: return nil
                case .state, .transform, .shelfState: return crossfade
                }
            }
            switch role {
            case .state: return .easeOut(duration: 0.15)
            case .hover: return .spring(response: 0.30, dampingFraction: 0.72)
            case .transform: return .spring(response: 0.42, dampingFraction: 0.85)
            case .shelfState: return .spring(response: 0.34, dampingFraction: 0.86)
            }
        }

        /// Pure: the AppKit panel timing for a role. `nil` under Reduce Motion,
        /// where the panel lands at its new frame without gliding there.
        static func panelTiming(_ role: PanelRole, reduceMotion: Bool) -> PanelTiming? {
            if reduceMotion { return nil }
            switch role {
            case .frame:
                return PanelTiming(duration: 0.3, c0: 0.25, c1: 0.9, c2: 0.3, c3: 1.0)
            case .glide:
                return PanelTiming(duration: 0.95, c0: 0.32, c1: 0.0, c2: 0.18, c3: 1.0)
            }
        }

        /// Read live at every call site rather than cached, so a change made
        /// while the app is running takes effect on the next animation without
        /// anything having to be invalidated.
        static var isReduced: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        static var state: Animation? { animation(.state, reduceMotion: isReduced) }
        static var hover: Animation? { animation(.hover, reduceMotion: isReduced) }
        static var transform: Animation? { animation(.transform, reduceMotion: isReduced) }
        static var shelfState: Animation? { animation(.shelfState, reduceMotion: isReduced) }
        static var panelFrame: PanelTiming? { panelTiming(.frame, reduceMotion: isReduced) }
        static var panelGlide: PanelTiming? { panelTiming(.glide, reduceMotion: isReduced) }
    }
}

/// Republishes when the user changes an accessibility display option, so a
/// panel that is already on screen picks up a Reduce Motion toggle straight
/// away instead of at its next state change. The value itself is never cached
/// — `Design.Motion.isReduced` reads the setting — so this only ever nudges
/// SwiftUI to re-evaluate.
@MainActor
final class AccessibilityDisplayMonitor: ObservableObject {
    static let shared = AccessibilityDisplayMonitor()

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }
}

extension View {
    /// Applies a depth token. Every shadow in the shelf sits at x: 0.
    func shelfShadow(_ depth: Design.Depth.Style) -> some View {
        shadow(color: depth.color, radius: depth.radius, x: 0, y: depth.y)
    }

    /// Draws the keyboard focus ring around a cell, tracing the same shape its
    /// selection background fills so focused-and-selected reads as one card
    /// with two things said about it rather than as two overlapping highlights.
    ///
    /// Always present, only transparent when unfocused: adding and removing the
    /// overlay instead would change the cell's layout on every arrow key.
    func focusRing(_ focused: Bool, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    focused ? Design.Line.focusRing : Color.clear,
                    lineWidth: Design.Line.focusRingWidth
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .animation(Design.Motion.state, value: focused)
    }
}
