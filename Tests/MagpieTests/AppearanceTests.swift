import AppKit
import SwiftUI
import XCTest
@testable import Magpie

/// The appearance contract: the shelf follows the system, and everything on it
/// stays readable in both appearances.
///
/// These exist because the failure they guard shipped. Every `Design.Ink`,
/// `Surface` and `Line` token was `Color.white` at an opacity over a panel
/// pinned to `.vibrantDark`, so in Light the close button, the disclosure
/// chevron and the file-count pill were white-on-white and effectively
/// invisible. No test could fail on that, because no test resolved a colour
/// under an appearance.
@MainActor
final class AppearanceTests: XCTestCase {

    // MARK: - Colour maths

    /// Resolves a dynamic `Color` to concrete sRGB components under `name`.
    private func resolve(_ color: Color, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }

    /// Source-over composite of `top` onto an opaque `bottom`.
    private func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let a = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
            green: top.greenComponent * a + bottom.greenComponent * (1 - a),
            blue: top.blueComponent * a + bottom.blueComponent * (1 - a),
            alpha: 1
        )
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// What the panel material resolves to, near enough to judge against.
    private func panelGround(_ name: NSAppearance.Name) -> NSColor {
        name == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
            : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    }

    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    // MARK: - The contract

    /// Body text on the panel clears WCAG AA in both appearances.
    func testBodyTextIsReadableOnThePanelInBothAppearances() throws {
        for name in appearances {
            let ground = panelGround(name)
            let ink = try resolve(Design.Ink.strong, in: name)
            let ratio = contrast(composite(ink, over: ground), ground)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "Design.Ink.strong on the panel is \(String(format: "%.2f", ratio)):1 in \(name.rawValue); AA body text needs 4.5:1"
            )
        }
    }

    /// Secondary text — subtitles, empty-state prompts, item metadata — is the
    /// step most likely to be tuned into unreadability.
    func testSecondaryAndTertiaryInkClearLargeTextContrast() throws {
        for name in appearances {
            let ground = panelGround(name)
            for (label, token) in [("secondary", Design.Ink.secondary), ("tertiary", Design.Ink.tertiary)] {
                let ink = try resolve(token, in: name)
                let ratio = contrast(composite(ink, over: ground), ground)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "Design.Ink.\(label) is \(String(format: "%.2f", ratio)):1 in \(name.rawValue); needs 3:1"
                )
            }
        }
    }

    /// THE regression. A control fill has to be *visible* against the panel it
    /// sits on — this is exactly what failed in Light, where every one of these
    /// was `Color.white` over a light ground and disappeared.
    func testControlFillsAreVisibleAgainstThePanelInBothAppearances() throws {
        let fills: [(String, Color)] = [
            ("control", Design.Surface.control),
            ("controlHover", Design.Surface.controlHover),
            ("pill", Design.Surface.pill),
            ("pillHover", Design.Surface.pillHover),
            ("chevron", Design.Surface.chevron),
        ]
        for name in appearances {
            let ground = panelGround(name)
            for (label, token) in fills {
                let filled = composite(try resolve(token, in: name), over: ground)
                let ratio = contrast(filled, ground)
                XCTAssertGreaterThan(
                    ratio, 1.06,
                    "Design.Surface.\(label) is \(String(format: "%.3f", ratio)):1 against the panel in \(name.rawValue) — invisible"
                )
            }
        }
    }

    /// A glyph drawn inside a control has to clear the control's own fill, not
    /// just the panel behind it.
    func testGlyphsAreReadableOnTheirOwnControlFill() throws {
        for name in appearances {
            let ground = panelGround(name)
            let fill = composite(try resolve(Design.Surface.control, in: name), over: ground)
            let glyph = composite(try resolve(Design.Ink.strong, in: name), over: fill)
            let ratio = contrast(glyph, fill)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "Ink.strong on Surface.control is \(String(format: "%.2f", ratio)):1 in \(name.rawValue); a control glyph needs 3:1"
            )
        }
    }

    /// Every adaptive token must actually differ between the two appearances.
    /// A token that resolves identically in both is one that was never made
    /// appearance-aware — the exact bug, reintroduced.
    func testAdaptiveTokensDifferBetweenAppearances() throws {
        let tokens: [(String, Color)] = [
            ("Ink.strong", Design.Ink.strong),
            ("Ink.secondary", Design.Ink.secondary),
            ("Ink.tertiary", Design.Ink.tertiary),
            ("Surface.control", Design.Surface.control),
            ("Surface.pill", Design.Surface.pill),
            ("Surface.rowHover", Design.Surface.rowHover),
            ("Line.hairline", Design.Line.hairline),
            ("Line.panel", Design.Line.panel),
            ("Line.edge", Design.Line.edge),
        ]
        for (label, token) in tokens {
            let light = try resolve(token, in: .aqua)
            let dark = try resolve(token, in: .darkAqua)
            let sameColour = abs(light.redComponent - dark.redComponent) < 0.001
                && abs(light.alphaComponent - dark.alphaComponent) < 0.001
            XCTAssertFalse(
                sameColour,
                "\(label) resolves identically in Light and Dark — it is not appearance-aware"
            )
        }
    }

    /// **The paper card is gone**, and this is what keeps it gone.
    ///
    /// ADR 0006 kept `Surface.paper` as a light document face in both
    /// appearances, with its own dark ink ladder drawn on it. ADR 0010
    /// withdraws that on the owner's instruction: the overlapping paper stack
    /// was the single most recognisable thing inherited from the fork, and a
    /// white page floating on a translucent panel is the look the owner asked
    /// to be rid of. A source scan rather than a colour assertion, because what has
    /// to stay true is that no view reaches for a paper ground at all — a
    /// token nobody references cannot be measured back into existence.
    func testNoShelfSurfaceIsDrawnOnPaper() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie")
        for file in ["ShelfContainerView.swift", "CollapsedShelfView.swift", "DesignTokens.swift"] {
            let source = try String(
                contentsOf: sources.appendingPathComponent(file), encoding: .utf8
            )
            XCTAssertFalse(source.isEmpty, "read the wrong file: \(file)")
            // Declarations as well as call sites: a token can come back by
            // being *defined* again, which no scan of the views would see.
            for token in ["Surface.paper", "Ink.onPaper", "Depth.paperFront",
                          "let paper", "onPaper", "paperFront"] {
                XCTAssertFalse(
                    source.contains(token),
                    "\(file) draws on paper again (`\(token)`); ADR 0010 withdrew the paper card"
                )
            }
        }
    }

    /// The drag-out mode indicator. The owner asked for "a colour change or
    /// something to prove to you that you are moving", so two things have to
    /// hold at once: each state is readable, and the two states cannot resolve
    /// to the same pixels. A mode change nobody can see is decoration.
    ///
    /// Asserted over both grounds — the material approximation and the opaque
    /// Reduce Transparency ground — because the pill is drawn on whichever one
    /// the panel is standing on.
    func testDragModeIndicatorIsReadableAndItsTwoModesDiffer() throws {
        for name in appearances {
            for (groundLabel, ground) in [
                ("panel", panelGround(name)),
                ("Reduce Transparency ground", try reducedTransparencyGround(name)),
            ] {
                let copyFill = composite(try resolve(Design.Surface.control, in: name), over: ground)
                let moveFill = composite(try resolve(Design.Surface.controlActive, in: name), over: ground)

                // The two inks `DragModeBar` actually draws, and only those. It
                // was a two-line block and carried three; the second line's
                // token is the one that survived, because the bar's single line
                // *is* the teaching line.
                let copyInk = composite(try resolve(Design.Ink.tertiary, in: name), over: copyFill)
                XCTAssertGreaterThanOrEqual(
                    contrast(copyInk, copyFill), 3.0,
                    "the copy mode's line is unreadable on its own pill over the \(groundLabel) in \(name.rawValue)"
                )
                let moveInk = composite(try resolve(Design.Ink.strong, in: name), over: moveFill)
                XCTAssertGreaterThanOrEqual(
                    contrast(moveInk, moveFill), 4.5,
                    "the move mode's line is unreadable on its own pill over the \(groundLabel) in \(name.rawValue)"
                )
                XCTAssertGreaterThan(
                    contrast(moveInk, copyInk), 1.2,
                    "the two drag modes ink the bar identically over the \(groundLabel) in \(name.rawValue)"
                )

                XCTAssertGreaterThan(
                    contrast(moveFill, copyFill), 1.06,
                    "the two drag modes fill the same pill over the \(groundLabel) in \(name.rawValue) — holding ⌘ changes nothing the user can see"
                )
            }
        }
    }

    // MARK: - The brand colours

    /// A stroke that carries state is a non-text component: it has to clear
    /// 3:1 against the ground it is drawn over, in both appearances and over
    /// both grounds — the material approximation and the opaque Reduce
    /// Transparency ground, because the ring is drawn on whichever the panel
    /// is standing on.
    ///
    /// **Neither raw brand value passes this on its own**, which is the whole
    /// reason `Brand` carries an adjusted twin for teal: raw teal measures
    /// 2.2:1 on the dark panel. The floor is not negotiable; the colour was
    /// moved instead.
    /// The ground the running Mac draws is only one Mac. macOS 15 draws its
    /// dark window ground at #323232, lighter than later releases, and the
    /// raw terracotta measured 2.86:1 there (CI, 2026-10-20). Checked here
    /// against that value so it fails on any Mac, not only on an old one.
    func testTheBrandStrokesClearTheOldestDarkGroundWeSupport() throws {
        let macOS15DarkGround = NSColor(srgbRed: 0x32 / 255, green: 0x32 / 255, blue: 0x32 / 255, alpha: 1)
        for (label, token) in [("Line.moveRing (brand terracotta)", Design.Line.moveRing),
                               ("Line.dropTarget (brand teal)", Design.Line.dropTarget)] {
            let stroke = composite(try resolve(token, in: .darkAqua), over: macOS15DarkGround)
            let ratio = contrast(stroke, macOS15DarkGround)
            XCTAssertGreaterThanOrEqual(ratio, 3.0,
                "\(label) is \(String(format: "%.2f", ratio)):1 over macOS 15's dark window ground; a stroke that carries state needs 3:1")
        }
    }

    func testTheBrandStrokesClearTheNonTextFloorInBothAppearances() throws {
        let strokes: [(String, Color)] = [
            ("Line.moveRing (brand terracotta)", Design.Line.moveRing),
            ("Line.dropTarget (brand teal)", Design.Line.dropTarget),
        ]
        for name in appearances {
            for (groundLabel, ground) in [
                ("panel", panelGround(name)),
                ("Reduce Transparency ground", try reducedTransparencyGround(name)),
            ] {
                for (label, token) in strokes {
                    let stroke = composite(try resolve(token, in: name), over: ground)
                    let ratio = contrast(stroke, ground)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3.0,
                        "\(label) is \(String(format: "%.2f", ratio)):1 over the \(groundLabel) in \(name.rawValue); a stroke that carries state needs 3:1"
                    )
                }
            }
        }
    }

    /// The adjustment has to actually be there. A well-meaning tidy-up that
    /// collapses each token onto its raw brand value looks like simplification
    /// and silently reintroduces the illegibility the floor above measures —
    /// in the *one* appearance the person doing the tidying is not looking at.
    func testEachBrandColourIsAdjustedInTheAppearanceThatNeededIt() throws {
        let tealRaw = try resolve(Color(nsColor: Design.Brand.tealValue), in: .darkAqua)
        let dark = try resolve(Design.Line.dropTarget, in: .darkAqua)
        XCTAssertGreaterThan(
            abs(tealRaw.redComponent - dark.redComponent)
                + abs(tealRaw.greenComponent - dark.greenComponent)
                + abs(tealRaw.blueComponent - dark.blueComponent),
            0.01,
            "the drop-target ring uses raw Castor teal in Dark, where it measures 2.2:1 against the panel: a deep colour on a dark ground"
        )
        // And the adjustment is spent only where it is needed: in Light the
        // ring is the studio's teal exactly.
        let light = try resolve(Design.Line.dropTarget, in: .aqua)
        let lightRaw = try resolve(Color(nsColor: Design.Brand.tealValue), in: .aqua)
        XCTAssertLessThan(
            abs(lightRaw.redComponent - light.redComponent)
                + abs(lightRaw.greenComponent - light.greenComponent)
                + abs(lightRaw.blueComponent - light.blueComponent),
            0.01,
            "the drop-target ring is not Castor teal in Light, where the raw value already clears the floor"
        )
    }

    /// The brand colours are spent on two opposite claims — a file leaving
    /// under ⌘, a file arriving on the shelf. If they resolve alike, the shelf
    /// says the same thing in both directions.
    ///
    /// Measured by hue, not by the WCAG ratio used everywhere else in this
    /// file. That ratio is a *lightness* comparison, and these two are close
    /// in lightness on purpose — both have to clear the same floor over the
    /// same ground. What tells them apart is that one is warm and one is cool,
    /// so that is what gets asserted: terracotta is red-dominant, teal is
    /// blue-dominant, and the gap between the channels is wide enough to
    /// survive a glance at a 2.5pt stroke.
    func testTheTwoBrandColoursAreTellableApart() throws {
        for name in appearances {
            let out = try resolve(Design.Line.moveRing, in: name)
            let into = try resolve(Design.Line.dropTarget, in: name)

            XCTAssertGreaterThan(
                out.redComponent - out.blueComponent, 0.3,
                "the move ring has stopped reading as warm in \(name.rawValue) — it is no longer Castor terracotta"
            )
            XCTAssertGreaterThan(
                into.blueComponent - into.redComponent, 0.3,
                "the drop-target ring has stopped reading as cool in \(name.rawValue) — it is no longer Castor teal"
            )
            let distance = abs(out.redComponent - into.redComponent)
                + abs(out.greenComponent - into.greenComponent)
                + abs(out.blueComponent - into.blueComponent)
            XCTAssertGreaterThan(
                distance, 0.5,
                "the move ring and the drop-target ring resolve to nearly the same colour in \(name.rawValue) — a card leaving and a file arriving look the same"
            )
        }
    }

    /// The move ring must not be the focus ring. They are different claims —
    /// where the keyboard is, versus what is about to leave the shelf — and
    /// ADR 0006 keeps the focus ring semantic on purpose, so this also guards
    /// the brand colour from being swept onto `keyboardFocusIndicatorColor`.
    func testTheMoveRingIsNotTheKeyboardFocusRing() throws {
        for name in appearances {
            let focus = try resolve(Design.Line.focusRing, in: name)
            let move = try resolve(Design.Line.moveRing, in: name)
            let identical = abs(focus.redComponent - move.redComponent) < 0.001
                && abs(focus.greenComponent - move.greenComponent) < 0.001
                && abs(focus.blueComponent - move.blueComponent) < 0.001
            XCTAssertFalse(
                identical,
                "the move indicator wears the keyboard focus ring's colour in \(name.rawValue) — a focused card and a moving one say the same thing"
            )
        }
    }

    /// No inline colour may carry the drop-target state. ADR 0006 binds the
    /// whole vocabulary to `Design`, and this is where it leaked: the ring the
    /// shelf draws when files arrive was a bare `Color.accentColor` at two
    /// call sites, named by no token and tuned by nobody.
    func testTheDropTargetRingComesFromATokenNotAnInlineColour() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfContainerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("dropTargetWidth"), "read the wrong file")
        XCTAssertFalse(
            source.contains("Color.accentColor"),
            "an inline Color.accentColor is back in the shelf; every colour is a Design token (ADR 0006)"
        )
    }

    /// The ring the move state draws around itself, and the one the copy state
    /// draws, have to be different colours as well as different widths — the
    /// stroke is the loudest half of the signal.
    func testTheMoveIndicatorsRingIsNotTheRestingHairline() throws {
        for name in appearances {
            let resting = try resolve(Design.Line.hairlineFaint, in: name)
            let moving = try resolve(Design.Line.moveRing, in: name)
            let identical = abs(resting.redComponent - moving.redComponent) < 0.001
                && abs(resting.greenComponent - moving.greenComponent) < 0.001
                && abs(resting.blueComponent - moving.blueComponent) < 0.001
                && abs(resting.alphaComponent - moving.alphaComponent) < 0.001
            XCTAssertFalse(
                identical,
                "the move indicator's ring resolves to the resting hairline in \(name.rawValue) — the drag mode is not visible"
            )
        }
    }

    // MARK: - Reduce Transparency

    /// What the panel stands on when Reduce Transparency is on. Not the
    /// material approximation above: the real, resolved semantic colour the
    /// opaque ground draws, because that ground IS the panel in that mode.
    private func reducedTransparencyGround(_ name: NSAppearance.Name) throws -> NSColor {
        try resolve(Color(nsColor: Design.Transparency.opaquePanelGround), in: name)
    }

    /// The ground that replaces the material must actually deliver what the
    /// setting promises — nothing shows through — and every ink floor above
    /// must hold over it in both appearances.
    func testInksKeepTheirFloorsOverTheReduceTransparencyGround() throws {
        for name in appearances {
            let ground = try reducedTransparencyGround(name)
            XCTAssertEqual(
                ground.alphaComponent, 1.0, accuracy: 0.001,
                "the Reduce Transparency ground is translucent in \(name.rawValue) — it defeats the setting it exists for"
            )
            let body = try resolve(Design.Ink.strong, in: name)
            XCTAssertGreaterThanOrEqual(
                contrast(composite(body, over: ground), ground), 4.5,
                "Ink.strong on the opaque Reduce Transparency ground is under 4.5:1 in \(name.rawValue)"
            )
            for (label, token) in [("secondary", Design.Ink.secondary), ("tertiary", Design.Ink.tertiary)] {
                let ink = try resolve(token, in: name)
                XCTAssertGreaterThanOrEqual(
                    contrast(composite(ink, over: ground), ground), 3.0,
                    "Ink.\(label) on the opaque Reduce Transparency ground is under 3:1 in \(name.rawValue)"
                )
            }
        }
    }

    /// The control-fill visibility floor and the glyph-on-fill floor, over the
    /// same opaque ground — the exact assertions that caught white-on-white.
    func testControlFillsAndGlyphsSurviveTheReduceTransparencyGround() throws {
        let fills: [(String, Color)] = [
            ("control", Design.Surface.control),
            ("controlHover", Design.Surface.controlHover),
            ("pill", Design.Surface.pill),
            ("chevron", Design.Surface.chevron),
        ]
        for name in appearances {
            let ground = try reducedTransparencyGround(name)
            for (label, token) in fills {
                let filled = composite(try resolve(token, in: name), over: ground)
                XCTAssertGreaterThan(
                    contrast(filled, ground), 1.06,
                    "Design.Surface.\(label) is invisible against the Reduce Transparency ground in \(name.rawValue)"
                )
            }
            let fill = composite(try resolve(Design.Surface.control, in: name), over: ground)
            let glyph = composite(try resolve(Design.Ink.strong, in: name), over: fill)
            XCTAssertGreaterThanOrEqual(
                contrast(glyph, fill), 3.0,
                "Ink.strong on Surface.control over the Reduce Transparency ground is under 3:1 in \(name.rawValue)"
            )
        }
    }

    /// The panel must not pin its own appearance. Pinning it is what gave the
    /// app two appearance models at once.
    func testPanelDoesNotForceAnAppearance() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/FloatingPanel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("NSVisualEffectView"), "read the wrong file")
        XCTAssertFalse(
            source.contains("NSAppearance(named: .vibrantDark)")
                || source.contains("NSAppearance(named: .vibrantLight)"),
            "FloatingPanel pins an appearance again; the shelf must follow the system"
        )
    }
}

/// The menu-bar mark is the app's only permanent presence, and the incumbent
/// resolved to a featureless dot on a real bar.
@MainActor
final class StatusIconTests: XCTestCase {

    private func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// Ink coverage: enough of the canvas is marked to be seen, and not so much
    /// that the mark is a solid blob with no silhouette.
    func testMarkCoversALegibleShareOfItsCanvas() throws {
        let rep = try pixels(StatusIcon.image(dropping: false, awake: false))
        var marked = 0
        var total = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                total += 1
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { marked += 1 }
            }
        }
        let share = Double(marked) / Double(total)
        XCTAssertGreaterThan(share, 0.12, "the mark is too sparse to read on a menu bar")
        XCTAssertLessThan(share, 0.55, "the mark has filled in and lost its silhouette")
    }

    /// Each state has to be distinguishable, or the state is decoration.
    func testEveryStateProducesADistinctMark() throws {
        let states: [(String, Bool, Bool)] = [
            ("rest", false, false), ("dropping", true, false), ("awake", false, true),
        ]
        var seen: [String: Data] = [:]
        for (label, dropping, awake) in states {
            let data = try XCTUnwrap(pixels(StatusIcon.image(dropping: dropping, awake: awake))
                .representation(using: .png, properties: [:]))
            for (other, otherData) in seen {
                XCTAssertNotEqual(data, otherData, "\(label) renders identically to \(other)")
            }
            seen[label] = data
        }
    }

    /// A non-template status image is the usual reason a menu-bar icon looks
    /// wrong in the other appearance or against the menu-open highlight.
    func testMarkIsATemplateImage() {
        XCTAssertTrue(StatusIcon.image(dropping: false, awake: false).isTemplate)
    }

    /// Nothing may be drawn outside the canvas: AppKit clips it, which is how a
    /// mark silently loses an edge. Leaning in included.
    func testTheMagpieSitsInsideTheCanvas() {
        let canvas = NSRect(x: 0, y: 0, width: StatusIcon.side, height: StatusIcon.side)
        for dropping in [false, true] {
            let ink = StatusIcon.inkBounds(dropping: dropping)
            XCTAssertTrue(canvas.insetBy(dx: -0.25, dy: -0.25).contains(ink),
                          "the magpie is clipped by the menu-bar canvas (dropping: \(dropping)): \(ink)")
        }
    }

    /// The bird's white is a hole the bar shows through, as the paper does on
    /// the shelf: the eye at least must read at 18 points.
    func testTheEyeIsOpenOnTheBar() throws {
        let rep = try pixels(StatusIcon.image(dropping: false, awake: false))
        let scale = CGFloat(rep.pixelsWide) / StatusIcon.side
        let eye = MascotDrawing.eyeCenter.applying(StatusIcon.transform(lean: 0))
        let alpha = rep.colorAt(x: Int(eye.x * scale), y: Int(eye.y * scale))?.alphaComponent ?? 1
        XCTAssertLessThan(alpha, 0.5, "the magpie's eye is filled in; at menu-bar size it reads as a blob")
    }
}

/// The user-choice half of the appearance decision.
@MainActor
final class AppearancePreferenceTests: XCTestCase {

    /// `.system` must map to nil. Anything else pins the app and defeats the
    /// whole point of the default.
    func testSystemInheritsAndTheOthersPin() {
        XCTAssertNil(AppearancePreference.system.appearance)
        XCTAssertEqual(AppearancePreference.light.appearance?.name, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearance?.name, .darkAqua)
    }

    /// An unset or corrupt preference must fall back to following the system,
    /// never to a pinned appearance.
    func testUnsetOrGarbageFallsBackToSystem() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: AppearancePreference.defaultsKey)
        defer {
            if let original { defaults.set(original, forKey: AppearancePreference.defaultsKey) }
            else { defaults.removeObject(forKey: AppearancePreference.defaultsKey) }
        }

        defaults.removeObject(forKey: AppearancePreference.defaultsKey)
        XCTAssertEqual(AppearancePreference.current, .system)

        defaults.set("chartreuse", forKey: AppearancePreference.defaultsKey)
        XCTAssertEqual(AppearancePreference.current, .system)

        defaults.set("dark", forKey: AppearancePreference.defaultsKey)
        XCTAssertEqual(AppearancePreference.current, .dark)
    }

    /// Every case has to be reachable from the Settings picker and carry a
    /// title, or the option exists only in code.
    func testEveryCaseIsOfferedAndTitled() {
        XCTAssertEqual(AppearancePreference.allCases.count, 3)
        for option in AppearancePreference.allCases {
            XCTAssertFalse(option.title.isEmpty, "\(option.rawValue) has no title")
        }
    }
}
