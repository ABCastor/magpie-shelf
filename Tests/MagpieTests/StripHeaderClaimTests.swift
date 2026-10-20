import AppKit
import XCTest
@testable import Magpie

/// **The header is the feature.**
///
/// ADR 0012 shipped a strip that drew every row selected at rest, so that what
/// a drag would take was visible. The owner rejected the picture — five files
/// were five solid bars of accent — and asked the question the picture was
/// there to answer: *"if they are not highlighted and I click on one, will it
/// carry just that outside or will it carry all of them?"*
///
/// The answer is now a sentence in a header that already existed: `5 Files`, or
/// `1 of 5`. Which means the sentence is load-bearing in a way a decoration
/// never is — **a header that disagrees with the drag is worse than no header,
/// because the user has stopped counting rows and started reading it.** Every
/// test here exists to make that disagreement impossible.
final class StripHeaderClaimTests: XCTestCase {

    private let ids = (0..<5).map { _ in UUID() }

    /// Every way a five-row shelf can be narrowed, including the two that mean
    /// the same thing (nothing picked, everything picked).
    private var everySelectionState: [Set<UUID>] {
        (0..<(1 << ids.count)).map { mask in
            Set(ids.indices.filter { mask & (1 << $0) != 0 }.map { ids[$0] })
        }
    }

    /// The integers a rendered header actually states, in the order they are
    /// printed. Read off the string rather than off the counts it was built
    /// from: a format string that dropped a slot, or a table that filled the
    /// two slots the wrong way round, is precisely the failure a check on the
    /// inputs cannot see.
    private func statedNumbers(in title: String) -> [Int] {
        title
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { $0.isEmpty ? nil : Int($0) }
    }

    // MARK: - The one invariant

    /// **What the header says and what a drag takes are the same number, in
    /// every state a shelf can be in.**
    ///
    /// Both sides are read the way the app reads them: the claim through
    /// `ShelfStripHeader.title`, rendered to the actual string the user sees
    /// and parsed back; the payload through `beginDrag`, from each row the user
    /// could plausibly grab. If those two ever differ the app has lied about
    /// what is leaving, which is the whole thing this design exists to prevent.
    func test_the_header_states_exactly_what_a_drag_would_carry() {
        for explicit in everySelectionState {
            let claim = ShelfSelection.claim(explicit: explicit, ids: ids)
            let title = ShelfStripHeader.title(name: nil, claim: claim)
            let stated = statedNumbers(in: title)

            XCTAssertTrue(
                stated.contains(claim.carried),
                "the header reads \"\(title)\" while a drag would carry \(claim.carried) files — the one number the user is reading instead of counting rows is not on screen"
            )
            if !claim.isWholeShelf {
                // The two counts, in the order this language puts them. Pins
                // the call site as well as the number: swapping the arguments
                // turns "1 of 5" into "5 of 1", which still contains both.
                XCTAssertEqual(
                    title, String(format: L("selection.of-total"), claim.carried, claim.total),
                    "the header reads \"\(title)\" for \(claim.carried) of \(claim.total) — the picked count and the shelf total are the wrong way round, so the header states the opposite of what leaves"
                )
            }

            for id in ShelfSelection.effective(explicit: explicit, ids: ids) {
                let dragged = ShelfSelection.beginDrag(
                    from: id, explicit: explicit, ids: ids
                ).dragged
                XCTAssertEqual(
                    dragged.count, claim.carried,
                    "the header reads \"\(title)\" but a drag off a picked row takes \(dragged.count) files — the header and the drag disagree about what leaves the shelf"
                )
            }
        }
    }

    /// The other half of the same claim: the total. A header reading `1 of 4`
    /// over a five-row shelf is a header nobody can act on.
    func test_the_header_states_how_many_files_the_shelf_holds() {
        for explicit in everySelectionState {
            let claim = ShelfSelection.claim(explicit: explicit, ids: ids)
            guard !claim.isWholeShelf else { continue }
            let title = ShelfStripHeader.title(name: nil, claim: claim)
            XCTAssertTrue(
                statedNumbers(in: title).contains(ids.count),
                "the header reads \"\(title)\" on a shelf of \(ids.count) files, so \"of five\" is a number the user has to count for themselves"
            )
        }
    }

    /// A row that leaves the shelf takes its claim with it. Otherwise the
    /// header keeps promising a file that is no longer there.
    func test_a_removed_file_leaves_the_headers_claim() {
        let claim = ShelfSelection.claim(explicit: [ids[0], ids[1]], ids: [ids[0], ids[2]])
        XCTAssertEqual(claim.carried, 1)
        XCTAssertEqual(claim.total, 2)
        XCTAssertEqual(
            ShelfStripHeader.title(name: nil, claim: claim),
            String(format: L("selection.of-total"), 1, 2),
            "the header counts files that are no longer on the shelf, or states the picked count and the total the wrong way round"
        )
    }

    // MARK: - The resting state

    /// The acceptance criterion in words: nothing is picked, so nothing is
    /// highlighted, and the header carries the whole claim on its own.
    func test_an_untouched_shelf_highlights_nothing_and_says_so() {
        XCTAssertEqual(
            ShelfSelection.highlighted(
                explicit: ShelfSelection.wholeShelf, ids: ids, isDragging: false
            ),
            [],
            "a shelf nobody has clicked draws rows in the selection colour — the wall of accent bars the owner rejected"
        )
        XCTAssertEqual(
            ShelfStripHeader.title(
                name: nil,
                claim: ShelfSelection.claim(explicit: ShelfSelection.wholeShelf, ids: ids)
            ),
            String(format: L("%lld Files"), ids.count),
            "the resting header does not say how many files a drag would take, and nothing else on the quiet strip does either"
        )
    }

    /// Select-all is deliberately not the resting state. The payload is the
    /// same five rows, but the explicit state must stay visible in both the
    /// fill and the header so a user can tell "I selected all" from "I have
    /// not touched this shelf".
    func test_an_explicit_select_all_is_visible_without_changing_what_leaves() {
        let all = Set(ids)
        let claim = ShelfSelection.claim(explicit: all, ids: ids)

        XCTAssertEqual(
            ShelfSelection.highlighted(explicit: all, ids: ids, isDragging: false),
            all,
            "an explicit select-all is stored but the rows remain unhighlighted, so it looks identical to the untouched shelf"
        )
        XCTAssertEqual(
            ShelfStripHeader.title(name: nil, claim: claim),
            String(format: L("selection.of-total"), ids.count, ids.count),
            "an explicit select-all still uses the quiet whole-shelf header, so the user cannot tell it apart from the untouched shelf"
        )

        for id in ids {
            XCTAssertEqual(
                ShelfSelection.beginDrag(from: id, explicit: all, ids: ids).dragged,
                all,
                "select-all visibly claims every row but a drag from row \(id) carries a different set"
            )
        }
    }

    /// Picking a row is a visible event in two places at once, and clearing it
    /// undoes both. This is the loop the owner has to be able to run without
    /// thinking.
    func test_picking_a_row_and_clearing_it_are_visible_in_the_header() {
        let picked = ShelfSelection.click(
            id: ids[2], modifiers: [], explicit: ShelfSelection.wholeShelf,
            anchor: nil, ids: ids
        ).selection
        let narrowed = ShelfStripHeader.title(
            name: nil, claim: ShelfSelection.claim(explicit: picked, ids: ids)
        )
        let resting = ShelfStripHeader.title(
            name: nil,
            claim: ShelfSelection.claim(explicit: ShelfSelection.wholeShelf, ids: ids)
        )
        XCTAssertNotEqual(
            narrowed, resting,
            "clicking a row leaves the header saying exactly what it said before, so nothing on screen answers \"will this carry one file or five\""
        )
        XCTAssertEqual(
            ShelfSelection.highlighted(explicit: picked, ids: ids, isDragging: false),
            [ids[2]],
            "the row the user just clicked is not drawn picked"
        )
    }

    /// A named shelf keeps its name only while nothing is withheld. The moment
    /// a pick exists the name gives way — the name cannot say what is leaving
    /// and the count must.
    func test_a_named_shelf_yields_its_name_to_the_claim() {
        let resting = ShelfStripHeader.title(
            name: "Invoices",
            claim: ShelfSelection.claim(explicit: ShelfSelection.wholeShelf, ids: ids)
        )
        XCTAssertEqual(resting, "Invoices")

        let narrowed = ShelfStripHeader.title(
            name: "Invoices",
            claim: ShelfSelection.claim(explicit: [ids[0]], ids: ids)
        )
        XCTAssertTrue(
            statedNumbers(in: narrowed) == [1, ids.count] || statedNumbers(in: narrowed) == [ids.count, 1],
            "a named shelf keeps saying its name after the user has picked one row, so the header on a narrowed shelf says nothing about what a drag takes"
        )
    }

    // MARK: - The drag

    /// **The highlight appears when it is useful and matches what is leaving.**
    /// Mid-drag is the moment of truth — before the drop, while the user can
    /// still abort — so the rows lit up must be exactly the rows travelling.
    func test_a_drag_highlights_exactly_the_files_it_is_carrying() {
        for explicit in everySelectionState {
            for id in ids {
                let start = ShelfSelection.beginDrag(from: id, explicit: explicit, ids: ids)
                XCTAssertEqual(
                    ShelfSelection.highlighted(
                        explicit: start.selection, ids: ids, isDragging: true
                    ),
                    start.dragged,
                    "a drag off this row lights up a different set of rows than it is carrying — the one moment the user can still abort shows them the wrong files"
                )
            }
        }
    }

    /// And the highlight is spent *only* there. A resting strip that lights up
    /// rows it did not have to is the thing that was reversed.
    func test_the_highlight_is_never_louder_than_the_pick_at_rest() {
        for explicit in everySelectionState {
            XCTAssertEqual(
                ShelfSelection.highlighted(explicit: explicit, ids: ids, isDragging: false),
                explicit.intersection(ids),
                "a resting strip draws rows the user did not pick"
            )
        }
    }

    // MARK: - Nine languages, 180 points

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    private func table(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language).lproj/Localizable.strings did not parse"
        )
    }

    func test_every_language_defines_the_claim() throws {
        for language in Self.languages {
            let value = try table(language)["selection.of-total"]
            XCTAssertNotNil(value, "\(language) is missing selection.of-total")
            XCTAssertNotEqual(
                value, "selection.of-total", "\(language) left selection.of-total untranslated"
            )
            XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty selection.of-total")
        }
    }

    /// Both slots, positional, in every table. A translation that drops one
    /// leaves the header claiming a number with nothing to measure it against;
    /// a translation that writes `%lld` twice cannot reorder for the languages
    /// that need the total first, and would silently print the same number in
    /// both places.
    func test_every_language_keeps_both_positional_slots() throws {
        for language in Self.languages {
            let value = try XCTUnwrap(table(language)["selection.of-total"])
            XCTAssertTrue(
                value.contains("%1$lld"),
                "\(language) lost the picked-count slot in selection.of-total"
            )
            XCTAssertTrue(
                value.contains("%2$lld"),
                "\(language) lost the shelf-total slot in selection.of-total"
            )
        }
    }

    /// The golden. Each language's rendering of "one of five", written out, so
    /// a re-translation that swaps the two slots — which reads perfectly well
    /// as a string and is a lie on screen — cannot land quietly. Japanese
    /// states the total first on purpose; that is why the slots are positional.
    /// Chinese takes the ratio form ("已选 1/5", *1 of 5 picked*) because the
    /// literal phrase does not fit a 180pt header — measured below, not guessed.
    func test_one_of_five_reads_correctly_in_every_language() throws {
        let expected = [
            "Base": "1 of 5",
            "en": "1 of 5",
            "de": "1 von 5",
            "es": "1 de 5",
            "fr": "1 sur 5",
            "it": "1 di 5",
            "ja": "5 件中 1 件",
            "pl": "1 z 5",
            "zh-Hans": "已选 1/5",
        ]
        for language in Self.languages {
            let format = try XCTUnwrap(table(language)["selection.of-total"])
            XCTAssertEqual(
                String(format: format, 1, 5), expected[language],
                "\(language) renders \"one file of five\" as something else — if the two counts are the wrong way round the header states the opposite of the truth"
            )
        }
    }

    /// **The strip's width, minus a close button, three glyphs and their gaps.** The
    /// header the claim shares is the narrowest text in the app, and it is set
    /// to truncate in the middle — so a claim that overruns does not overflow,
    /// it silently becomes `12 o…99`, which is a sentence the user cannot act
    /// on and cannot tell from one they could.
    ///
    /// Measured at two digits either side, because a shelf scrolls past eight
    /// rows and "12 of 99" is a state a real shelf reaches. The arithmetic
    /// comes from the tokens the header is actually laid out with, so retuning
    /// the chrome re-runs this rather than invalidating it. It does **not**
    /// model the optional accent dot and pin glyph; that case is recorded in
    /// ADR 0012's consequences, and it already truncated the plain count.
    func test_the_claim_fits_the_strip_in_every_language() throws {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Text.stripHeaderMeasuring
        ]
        // Six elements in the header line — close, the text, the spacer, dock,
        // actions, expand — so five gaps at `Space.xs` plus the spacer's floor.
        let chrome = Design.Size.chromeButton * 4
        let gaps = Design.Space.xs * 5 + Design.Space.hair
        let budget = ShelfLayout.stripWidth - ShelfLayout.margin * 2 - chrome - gaps

        for language in Self.languages {
            let format = try XCTUnwrap(table(language)["selection.of-total"])
            let claim = String(format: format, 12, 99)
            let width = (claim as NSString).size(withAttributes: attributes).width
            XCTAssertLessThanOrEqual(
                width, budget,
                "\(language): \"\(claim)\" is \(Int(width))pt in a \(Int(budget))pt header, so the one sentence that says what a drag takes truncates"
            )
        }
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// A claim nothing renders is not a claim. The strip's header must be built
    /// by the one function above and must not count anything itself — a second
    /// expression of "how many files" beside the tested one is exactly how the
    /// header and the drag come apart again.
    func test_the_strip_builds_its_header_from_the_claim() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/CollapsedShelfView.swift"))
        XCTAssertTrue(text.contains("ShelfStripRow("), "read the wrong file")
        XCTAssertTrue(
            text.contains("ShelfStripHeader.title("),
            "the strip writes its own header, so what it says is untested and can drift from what a drag takes"
        )
        XCTAssertTrue(
            text.contains("ShelfSelection.claim("),
            "the header's counts are not the ones the drag is derived from"
        )
        XCTAssertFalse(
            text.contains("L(\"1 File\")"),
            "the strip still formats a file count of its own beside the claim — two sentences about the same thing, one of them untested"
        )
    }
}
