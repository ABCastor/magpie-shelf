import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Magpie

/// The toast used to be a fixed 300×56 box with `lineLimit(2)`, so a German or
/// Japanese message was silently cut in half — the user saw "One or more items
/// is already present in the…" and had no way to recover the rest. The panel is
/// now sized from the message.
///
/// **These tests measure the arithmetic, and the arithmetic was never wrong.**
/// A previous fix shrank the numbers here, watched every test below go green,
/// and shipped an enormous dark box with the text at the bottom of it. What
/// nobody measured was the window. `ToastWindowTests`, at the foot of this
/// file, is the test that would have caught it.
final class ToastMetricsTests: XCTestCase {

    // MARK: - Folding the hard line breaks

    /// The `.strings` files break their lines by hand for the old two-line box.
    /// The toast picks its own width now, so those breaks are folded away.
    func test_normalized_folds_a_hand_placed_line_break() {
        XCTAssertEqual(
            ToastMetrics.normalized("One or more items is\nalready present in the shelf"),
            "One or more items is already present in the shelf"
        )
    }

    func test_normalized_trims_stray_edges_and_blank_lines() {
        XCTAssertEqual(ToastMetrics.normalized("  Nothing was added.\n\nTry again.  "),
                       "Nothing was added. Try again.")
        XCTAssertEqual(ToastMetrics.normalized("\n"), "")
    }

    /// French and Japanese punctuation leans on no-break spaces. Folding line
    /// breaks must not quietly turn one into an ordinary space and hand the
    /// layout a place to break that the translator forbade.
    func test_normalized_leaves_a_no_break_space_alone() {
        let french = "Échec de la conversion\u{202F}: impossible de lire la source."
        XCTAssertEqual(ToastMetrics.normalized(french), french)
    }

    func test_a_folded_message_is_sized_exactly_like_the_flat_one() {
        XCTAssertEqual(
            ToastMetrics.panelSize(for: "Nothing to copy —\nthe shelf is empty."),
            ToastMetrics.panelSize(for: "Nothing to copy — the shelf is empty.")
        )
    }

    // MARK: - Sizing

    /// **The reported defect, pinned.** A short message gets a panel the size
    /// of the short message. It used to get a 210pt one whatever it said,
    /// because the floor was matched to the width of the old square shelf —
    /// so "OCR cancelled." was drawn at the left edge of a box with a hundred
    /// points of nothing beside it, which is what the owner saw and called
    /// ridiculous.
    func test_a_short_message_gets_a_panel_the_size_of_the_short_message() {
        let text = "OCR cancelled."
        let size = ToastMetrics.panelSize(for: text)
        let natural = ToastMetrics.measureText(text, width: ToastMetrics.unboundedWidth).width

        XCTAssertEqual(
            size.width, natural + ToastMetrics.fitTolerance + ToastMetrics.chromeWidth,
            accuracy: 1,
            "the panel is not hugging its message"
        )
        XCTAssertLessThan(
            size.width - natural, 60,
            """
            a \(Int(natural))pt sentence was given a \(Int(size.width))pt panel — \
            that empty region is the bug
            """
        )
        XCTAssertLessThan(size.height, 40, "one line of text does not need two lines of panel")
    }

    /// The panel's height is the sentence's height plus its own padding, with
    /// nothing under it. There was a floor, set two lines deep, so a one-line
    /// message was drawn in a box with a spare line beneath it.
    func test_a_one_line_message_is_one_line_tall() {
        let text = "Shelf copied."
        let size = ToastMetrics.panelSize(for: text)
        let line = ToastMetrics.measureText(
            text, width: size.width - ToastMetrics.chromeWidth
        ).height
        XCTAssertEqual(
            size.height,
            line + ToastMetrics.verticalPadding * 2 + ToastMetrics.heightSlack,
            accuracy: 0.5,
            "the toast is taller than the sentence inside it"
        )
    }

    /// The width floor is a floor, not the operative width: only a message
    /// with nothing in it should ever reach it. That stopped being true when
    /// it was set to the width of the old square shelf, and every ordinary
    /// message got a panel a hundred points wider than its own sentence.
    func test_the_width_floor_catches_only_a_degenerate_message() {
        XCTAssertEqual(ToastMetrics.panelSize(for: "").width, ToastMetrics.minWidth)
        XCTAssertGreaterThan(
            ToastMetrics.panelSize(for: "OCR cancelled.").width, ToastMetrics.minWidth,
            "an ordinary message is still being sized by the floor rather than by itself"
        )
    }

    /// Between the two bounds a message sizes to itself: the panel widens and
    /// the text stays on one line. Built by measurement rather than written
    /// out, so the test does not depend on how wide a given sentence renders.
    func test_a_medium_message_grows_wider_before_it_grows_taller() {
        var text = "Copied"
        while ToastMetrics.measureText(text, width: ToastMetrics.unboundedWidth).width
            + ToastMetrics.chromeWidth < ToastMetrics.minWidth {
            text += " and copied"
        }
        let size = ToastMetrics.panelSize(for: text)
        XCTAssertGreaterThan(size.width, ToastMetrics.minWidth)
        XCTAssertLessThan(size.width, ToastMetrics.maxWidth)
        XCTAssertEqual(
            size.height, ToastMetrics.panelSize(for: "Copied").height, "still one line"
        )
    }

    func test_width_stops_at_the_maximum_and_the_panel_grows_downwards() {
        let long = String(repeating: "wrap ", count: 60)
        let size = ToastMetrics.panelSize(for: long)
        XCTAssertEqual(size.width, ToastMetrics.maxWidth)
        XCTAssertGreaterThan(size.height, ToastMetrics.panelSize(for: "Copied").height)
    }

    func test_height_grows_with_the_message_and_is_capped() {
        let one = ToastMetrics.panelSize(for: "Shelf copied.").height
        XCTAssertLessThan(one, 40, "a one-line toast should be one line tall")
        let many = ToastMetrics.panelSize(for: String(repeating: "wrap ", count: 40)).height
        let absurd = ToastMetrics.panelSize(for: String(repeating: "wrap ", count: 4000)).height
        XCTAssertGreaterThan(many, one)
        XCTAssertGreaterThan(absurd, many)
        XCTAssertEqual(absurd, ToastMetrics.maxHeight, "a toast never becomes a wall")
    }

    /// The arithmetic, away from real type: chrome is subtracted from the
    /// panel before the message is measured, and the tolerance is spent making
    /// the measurement meaner than the room the layout will offer.
    func test_panel_size_reserves_the_chrome_around_a_stubbed_measurement() {
        var offered: [CGFloat] = []
        let size = ToastMetrics.panelSize(for: "x") { _, width in
            offered.append(width)
            return CGSize(width: 200, height: 60)
        }
        XCTAssertEqual(offered.first, ToastMetrics.unboundedWidth)
        XCTAssertEqual(size.width, 200 + ToastMetrics.fitTolerance + ToastMetrics.chromeWidth)
        XCTAssertEqual(
            offered.last,
            size.width - ToastMetrics.chromeWidth - ToastMetrics.fitTolerance
        )
        XCTAssertEqual(
            size.height,
            60 + ToastMetrics.verticalPadding * 2 + ToastMetrics.heightSlack
        )
        XCTAssertEqual(offered.count, 2, "the message is measured twice: natural, then wrapped")
    }

    // MARK: - The real messages, in all nine languages

    /// Every string that can reach `ToastPresenter`. A key that stops being
    /// shown as a toast should leave this list; a new one should join it.
    private static let toastKeys = [
        "toast.hotkey-unavailable",
        "toast.duplicate",
        "toast.concealed-clipboard",
        "toast.chat-copied",
        "toast.chat-copy-empty",
        "toast.link-refused",
        "toast.link-rate-limited",
        "routes.finished",
        "handoff.staging-failed",
        "handoff.nothing-to-send",
        "handoff.no-claude",
        "handoff.no-receipt",
        "ocr.error.source-missing",
        "ocr.error.source-unreadable",
        "ocr.error.destination-unwritable",
        "ocr.error.recognition-failed",
        "ocr.error.no-text",
        "ocr.error.cancelled",
        "conversion.error.source-missing",
        "conversion.error.source-unreadable",
        "conversion.error.destination-unwritable",
        "conversion.error.encoding-failed",
        "conversion.error.cancelled",
    ]

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    /// What each `%@` is really filled with by the time the user reads it:
    /// the longest hotkey display name, a route the owner named, and the kind
    /// of detail Vision and AVFoundation hand back.
    private static let fillers = [
        "toast.hotkey-unavailable": "⌃⌥⌘S",
        "routes.finished": "Compress with Ghostscript",
        "ocr.error.recognition-failed": "the image is too small to read",
        "conversion.error.encoding-failed": "the encoder ran out of memory",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    /// The same corpus, reachable from `ToastLayoutTests`, which has to lay
    /// every real message out for real.
    static func everyRealMessage() throws -> [(language: String, key: String, text: String)] {
        try ToastMetricsTests().messages()
    }

    fileprivate func messages() throws -> [(language: String, key: String, text: String)] {
        var all: [(String, String, String)] = []
        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            for key in Self.toastKeys {
                let raw = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                let text = raw.replacingOccurrences(
                    of: "%@", with: Self.fillers[key] ?? ""
                )
                all.append((language, key, text))
            }
        }
        return all
    }

    /// The defect, pinned: for every real message in every language, the panel
    /// the metrics ask for is big enough for the whole message, so nothing has
    /// to be cut off and no line has to be dropped.
    func test_every_real_toast_message_fits_its_panel_whole() throws {
        for (language, key, text) in try messages() {
            let size = ToastMetrics.panelSize(for: text)
            let textWidth = size.width - ToastMetrics.chromeWidth
            let drawn = ToastMetrics.measureText(ToastMetrics.normalized(text), width: textWidth)
            XCTAssertLessThanOrEqual(
                drawn.width, textWidth,
                "\(language)/\(key) overflows its column"
            )
            XCTAssertLessThanOrEqual(
                drawn.height + ToastMetrics.verticalPadding * 2, size.height,
                "\(language)/\(key) is taller than the panel sized for it"
            )
            XCTAssertLessThan(
                size.height, ToastMetrics.maxHeight,
                "\(language)/\(key) hit the height cap — no real message should"
            )
            XCTAssertLessThanOrEqual(size.width, ToastMetrics.maxWidth)
            XCTAssertGreaterThanOrEqual(size.width, ToastMetrics.minWidth)
        }
    }

    /// The longest real string in the app: German's hotkey-unavailable. It is
    /// three lines wide at the maximum toast width, which the old fixed 56pt
    /// two-line box could not show — this is the reported bug, in numbers.
    func test_the_longest_real_message_needs_more_than_the_old_fixed_box() throws {
        // Measured after folding, because that is what the toast lays out: a
        // hand-placed break otherwise hides how long a sentence really is.
        func rendered(_ text: String) -> CGFloat {
            ToastMetrics.measureText(
                ToastMetrics.normalized(text), width: ToastMetrics.unboundedWidth
            ).width
        }
        let all = try messages()
        let longest = try XCTUnwrap(all.max { rendered($0.text) < rendered($1.text) })
        XCTAssertEqual(longest.language, "de")
        XCTAssertEqual(longest.key, "toast.hotkey-unavailable")

        let size = ToastMetrics.panelSize(for: longest.text)
        XCTAssertEqual(size.width, ToastMetrics.maxWidth)
        XCTAssertGreaterThan(size.height, 56, "the box this defect was reported against")

        let lineHeight = ToastMetrics.measureText("One line", width: ToastMetrics.unboundedWidth).height
        let lines = (size.height - ToastMetrics.verticalPadding * 2) / lineHeight
        XCTAssertGreaterThanOrEqual(lines, 3)
    }

    // MARK: - Hover

    private let frame = NSRect(x: 100, y: 100, width: 320, height: 71)

    func test_a_resting_pointer_over_the_toast_holds_it_open() {
        XCTAssertTrue(
            ToastMetrics.isHolding(pointer: NSPoint(x: 260, y: 130), frame: frame, buttonsDown: false)
        )
    }

    func test_a_pointer_elsewhere_does_not_hold_it() {
        XCTAssertFalse(
            ToastMetrics.isHolding(pointer: NSPoint(x: 260, y: 400), frame: frame, buttonsDown: false)
        )
        XCTAssertFalse(
            ToastMetrics.isHolding(pointer: NSPoint(x: 20, y: 130), frame: frame, buttonsDown: false)
        )
    }

    /// The regression that matters: the toast sits in the corridor a drag out
    /// of the shelf travels down. A held button is that drag, and it must not
    /// pin a banner under the cursor for the length of it.
    func test_a_drag_crossing_the_toast_never_holds_it() {
        XCTAssertFalse(
            ToastMetrics.isHolding(pointer: NSPoint(x: 260, y: 130), frame: frame, buttonsDown: true)
        )
    }

    // MARK: - Dismissal

    func test_hover_suspends_the_countdown() {
        let now = Date()
        XCTAssertEqual(
            ToastDismissal.deadline(now: now, holding: true, wasHolding: false, current: now),
            .distantFuture
        )
        XCTAssertEqual(
            ToastDismissal.deadline(now: now, holding: true, wasHolding: true, current: .distantFuture),
            .distantFuture
        )
    }

    func test_leaving_restarts_a_short_countdown() {
        let now = Date()
        let deadline = ToastDismissal.deadline(
            now: now, holding: false, wasHolding: true, current: .distantFuture
        )
        XCTAssertEqual(
            deadline.timeIntervalSince(now), ToastDismissal.afterHover, accuracy: 0.001
        )
        XCTAssertLessThan(ToastDismissal.afterHover, ToastDismissal.visible)
    }

    /// A toast nobody touches keeps the deadline it was shown with, tick after
    /// tick — sampling the pointer must not extend its life.
    func test_an_untouched_toast_keeps_its_original_deadline() {
        let shown = Date()
        var deadline = shown.addingTimeInterval(ToastDismissal.visible)
        for tick in 1...5 {
            deadline = ToastDismissal.deadline(
                now: shown.addingTimeInterval(Double(tick) * ToastDismissal.sampleInterval),
                holding: false,
                wasHolding: false,
                current: deadline
            )
        }
        XCTAssertEqual(
            deadline.timeIntervalSince(shown), ToastDismissal.visible, accuracy: 0.001
        )
    }
}

/// `ToastMetrics` measures with TextKit and `ToastView` draws with SwiftUI,
/// and the two can disagree. They did: an HStack splits its width between two
/// flexible children, so a `Spacer(minLength: 0)` beside the message took part
/// of the column the panel had been sized for and wrapped sentences that
/// fitted. The 210pt floor hid it for as long as it was there; the moment the
/// panel started hugging its message, every short toast wrapped.
///
/// So the arithmetic is not enough on its own — something has to lay the real
/// view out at the size the real panel will be and check it still fits.
@MainActor
final class ToastLayoutTests: XCTestCase {

    /// The height SwiftUI gives the real toast, laid out at the width the
    /// panel will actually be.
    private func renderedHeight(of message: String, width: CGFloat) -> CGFloat {
        let host = NSHostingView(
            rootView: ToastView(
                message: ToastMetrics.normalized(message),
                symbol: "exclamationmark.circle.fill"
            )
            .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Every real message, in every language, laid out for real: the drawn
    /// toast fits the panel `ToastMetrics` asked for. A message that wraps one
    /// line further than the metrics predicted comes back taller than its
    /// panel, and this is the only thing in the gate that can see it.
    func test_the_drawn_toast_fits_the_panel_it_was_sized_for() throws {
        for (language, key, text) in try ToastMetricsTests.everyRealMessage() {
            let size = ToastMetrics.panelSize(for: text)
            let drawn = renderedHeight(of: text, width: size.width)
            XCTAssertLessThanOrEqual(
                drawn, size.height + 1,
                """
                \(language)/\(key) draws \(drawn)pt tall in a \(size.height)pt panel — \
                SwiftUI wrapped it further than the metrics predicted
                """
            )
        }
    }

    /// The shape the owner asked for, checked rather than asserted: a short
    /// message is a small pop-up, not a block of text in an empty box.
    func test_a_short_message_is_a_small_pop_up() {
        let size = ToastMetrics.panelSize(for: "OCR cancelled.")
        let drawn = renderedHeight(of: "OCR cancelled.", width: size.width)
        XCTAssertLessThanOrEqual(drawn, size.height, "the toast overflows its panel")
        XCTAssertGreaterThanOrEqual(
            drawn, size.height - ToastMetrics.heightSlack - 1,
            "a one-line message is not being drawn on one line"
        )
        XCTAssertLessThan(size.width, 160, "the panel is wider than the sentence needs")
        XCTAssertLessThan(size.height, 40, "the panel is taller than one line needs")
    }
}

/// The test the last toast fix needed and did not have.
///
/// `ToastMetricsTests` above measures `ToastMetrics.panelSize` — the *view's*
/// idea of how big the toast should be — and it has been right for two rounds
/// of this defect. The owner's screenshot showed a very large dark rounded
/// rectangle with the sentence sitting at the bottom of it, because the panel
/// on screen was never that size: `ToastView` ends in
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)`, the hosting view was
/// pinned to the content view with required constraints, and an `NSWindow`
/// resizes itself to satisfy required constraints in its content view. AppKit
/// asked the SwiftUI view how big it would like to be, was told "as big as you
/// like", and grew the window past the `setFrame` that had just run.
///
/// Measured on the presented panel before the repair: "OCR cancelled." was
/// sized 134×37 and shown in a 134×**215** window; a one-sentence notice was
/// sized 260×52 and shown in a 260×**710** window.
///
/// So this asks the window, not the view. It can: `ToastPresenter` really
/// presents a real `NSPanel` under `swift test`, which is the one thing that
/// makes this defect testable at all.
@MainActor
final class ToastWindowTests: XCTestCase {

    private var anchor: NSWindow!
    private var presenter: ToastPresenter!
    private var presented: [NSPanel] = []

    override func setUp() {
        super.setUp()
        anchor = NSWindow(
            contentRect: NSRect(x: 400, y: 600, width: ShelfLayout.stripWidth, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        presenter = ToastPresenter()
    }

    override func tearDown() {
        for panel in presented { panel.orderOut(nil) }
        presented = []
        super.tearDown()
    }

    /// Presents `message` and hands back the panel that appeared.
    private func present(_ message: String) throws -> NSPanel {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        presenter.show(message, near: anchor)
        let panel = try XCTUnwrap(
            NSApp.windows.lazy
                .compactMap { $0 as? NSPanel }
                .first { !before.contains(ObjectIdentifier($0)) },
            "showing a toast put no new panel on screen"
        )
        presented.append(panel)
        return panel
    }

    // MARK: - The defect

    /// THE assertion. The window is the size the message was measured for, and
    /// nothing is allowed to grow it afterwards.
    func test_the_presented_window_is_the_size_the_message_was_measured_for() throws {
        for message in [
            "OCR cancelled.",
            L("toast.duplicate"),
            L("toast.drag-copied-instead.one"),
            L("toast.concealed-clipboard"),
        ] {
            let expected = ToastMetrics.panelSize(for: message)
            let frame = try present(message).frame
            XCTAssertEqual(
                frame.size, expected,
                """
                the toast WINDOW is \(frame.size) for a message measured at \
                \(expected) — the view's size is right and the panel on screen \
                is not, which is exactly the box the owner photographed
                """
            )
        }
    }

    /// Said again as the user sees it, and with a bound rather than an equality,
    /// so this still fails if the metrics themselves are ever loosened.
    func test_a_short_message_does_not_get_a_tall_window() throws {
        let frame = try present("OCR cancelled.").frame
        XCTAssertLessThan(
            frame.height, 44,
            "a three-word toast is \(frame.height)pt tall — that is a box with a sentence in the corner of it, not a pop-up"
        )
        XCTAssertLessThan(
            frame.width, 160,
            "a three-word toast is \(frame.width)pt wide"
        )
    }

    /// The ceiling `ToastMetrics` promises has to hold for the window too. This
    /// is the one that catches a *new* way of growing the panel, whatever it is.
    func test_no_message_in_any_language_gets_a_window_past_the_ceiling() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        for language in ["Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans"] {
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: resources
                    .appendingPathComponent("\(language).lproj")
                    .appendingPathComponent("Localizable.strings")) as? [String: String]
            )
            // The longest real toast this language can produce — the only one
            // whose window could reach the ceiling.
            let longest = try XCTUnwrap(
                table.filter { $0.key.hasPrefix("toast.") }.values.max(by: { $0.count < $1.count }),
                "\(language) defines no toast strings"
            )
            let frame = try present(longest).frame
            XCTAssertLessThanOrEqual(
                frame.height, ToastMetrics.maxHeight,
                "\(language)'s longest toast is presented \(frame.height)pt tall, past the \(ToastMetrics.maxHeight)pt ceiling"
            )
            XCTAssertLessThanOrEqual(
                frame.width, ToastMetrics.maxWidth,
                "\(language)'s longest toast is presented \(frame.width)pt wide, past the \(ToastMetrics.maxWidth)pt ceiling"
            )
        }
    }

    // MARK: - Where it lands

    /// A panel taller than it should be also lands in the wrong place, because
    /// the origin is derived from the size. Worth one assertion: the toast sits
    /// under the shelf with a gap, not overlapping it.
    func test_the_window_sits_below_the_shelf_it_is_anchored_to() throws {
        let panel = try present("OCR cancelled.")
        XCTAssertLessThanOrEqual(
            panel.frame.maxY, anchor.frame.minY,
            "the toast overlaps the shelf it is reporting about"
        )
    }
}
