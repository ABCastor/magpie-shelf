import XCTest
import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers
@testable import Magpie

final class PDFMergeTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A real PDF with real, extractable text on every page — the only fixture
    /// that can tell a page copy apart from a rasterizing one.
    @discardableResult
    private func makePDF(named name: String, pageTexts: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw NSError(domain: "PDFMergeTests", code: -1) }
        for text in pageTexts {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont(name: "Helvetica", size: 24)
                    ?? NSFont.systemFont(ofSize: 24)]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func text(of url: URL) throws -> String {
        try XCTUnwrap(PDFDocument(url: url)?.string)
    }

    // MARK: - The gate

    func test_offered_for_two_or_more_pdfs() {
        XCTAssertTrue(PDFMerge.shouldOffer(forSourceUTIs: [.pdf, .pdf]))
        XCTAssertTrue(PDFMerge.shouldOffer(forSourceUTIs: [.pdf, .pdf, .pdf]))
    }

    /// One PDF is not a merge — the row would offer a copy under another name.
    func test_not_offered_for_a_single_pdf() {
        XCTAssertFalse(PDFMerge.shouldOffer(forSourceUTIs: [.pdf]))
    }

    func test_not_offered_for_empty_selection() {
        XCTAssertFalse(PDFMerge.shouldOffer(forSourceUTIs: []))
    }

    /// The all-PDF half of the gate is what lets `merge` stay a page copy with
    /// no image fallback. If a non-PDF can reach it, the rasterizing trap is one
    /// autocomplete away.
    func test_not_offered_when_any_input_is_not_a_pdf() {
        XCTAssertFalse(PDFMerge.shouldOffer(forSourceUTIs: [.pdf, .png]))
        XCTAssertFalse(PDFMerge.shouldOffer(forSourceUTIs: [.png, .jpeg]))
        XCTAssertFalse(PDFMerge.shouldOffer(forSourceUTIs: [.pdf, .plainText]))
    }

    func test_gate_over_shelf_items_resolves_types_from_disk() throws {
        let first = try makePDF(named: "a", pageTexts: ["A"])
        let second = try makePDF(named: "b", pageTexts: ["B"])
        let notPDF = tempDir.appendingPathComponent("c.txt")
        try Data("hello".utf8).write(to: notPDF)

        XCTAssertTrue(PDFMerge.shouldOffer(for: [item(first), item(second)]))
        XCTAssertFalse(PDFMerge.shouldOffer(for: [item(first), item(notPDF)]))
        // A text snippet has no fileURL at all: it disqualifies the selection
        // rather than being silently dropped from the merge.
        XCTAssertFalse(PDFMerge.shouldOffer(for: [
            item(first), item(second), ShelfItem(type: .text, textContent: "note"),
        ]))
    }

    private func item(_ url: URL) -> ShelfItem {
        ShelfItem(type: .file, fileURL: url)
    }

    // MARK: - The merge

    /// Both halves of the rasterize trap in one assertion pair: routing this
    /// through `ImageActions.createPDF` collapses each input to a single
    /// image-only page, so page count AND extracted text both go red.
    func test_merge_keeps_every_page_and_every_page_of_text() throws {
        let first = try makePDF(named: "first", pageTexts: ["ALPHA", "BRAVO", "CHARLIE"])
        let second = try makePDF(named: "second", pageTexts: ["DELTA", "ECHO"])
        let destination = tempDir.appendingPathComponent("out.pdf")

        try PDFMerge.merge(inputs: [first, second], into: destination)

        let merged = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(merged.pageCount, 5, "pages were dropped — every input page must survive")
        let extracted = try text(of: destination)
        for word in ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"] {
            XCTAssertTrue(
                extracted.contains(word),
                "\(word) lost its text layer — the merge rasterized instead of copying pages"
            )
        }
    }

    /// Page order is the order handed in, verbatim. Nothing about "insertion
    /// order" or "newest first" is decided inside the merge.
    func test_pages_come_out_in_the_order_the_inputs_were_given() throws {
        let first = try makePDF(named: "one", pageTexts: ["PAGE1", "PAGE2"])
        let second = try makePDF(named: "two", pageTexts: ["PAGE3"])
        let forward = tempDir.appendingPathComponent("forward.pdf")
        let backward = tempDir.appendingPathComponent("backward.pdf")

        try PDFMerge.merge(inputs: [first, second], into: forward)
        try PDFMerge.merge(inputs: [second, first], into: backward)

        let forwardDoc = try XCTUnwrap(PDFDocument(url: forward))
        XCTAssertTrue(forwardDoc.page(at: 0)?.string?.contains("PAGE1") == true)
        XCTAssertTrue(forwardDoc.page(at: 2)?.string?.contains("PAGE3") == true)

        let backwardDoc = try XCTUnwrap(PDFDocument(url: backward))
        XCTAssertTrue(backwardDoc.page(at: 0)?.string?.contains("PAGE3") == true)
        XCTAssertTrue(backwardDoc.page(at: 2)?.string?.contains("PAGE2") == true)
    }

    /// A merge quietly missing pages is the failure the user files away without
    /// noticing, so an input that will not open aborts the whole thing and no
    /// document is written at all.
    func test_unreadable_input_aborts_and_writes_nothing() throws {
        let good = try makePDF(named: "good", pageTexts: ["GOOD"])
        let corrupt = tempDir.appendingPathComponent("corrupt.pdf")
        try Data("this is not a pdf".utf8).write(to: corrupt)
        let destination = tempDir.appendingPathComponent("aborted.pdf")

        XCTAssertThrowsError(try PDFMerge.merge(inputs: [good, corrupt], into: destination)) {
            XCTAssertEqual($0 as? PDFMerge.Failure, .unreadable(name: "corrupt.pdf"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a short document was written for a merge that failed"
        )
    }

    /// The reachable half of the same failure: a password-protected PDF opens
    /// perfectly happily — `PDFDocument(url:)` returns a document that reports
    /// its page count — it just cannot be read. Without the `isLocked` check the
    /// merge would insert pages it can never render.
    func test_password_locked_input_is_named_and_aborts() throws {
        let plain = try makePDF(named: "plain", pageTexts: ["SECRET"])
        let locked = tempDir.appendingPathComponent("locked.pdf")
        let source = try XCTUnwrap(PDFDocument(url: plain))
        XCTAssertTrue(source.write(to: locked, withOptions: [
            .userPasswordOption: "hunter2",
            .ownerPasswordOption: "hunter2",
        ]))
        // The precondition this test exists for: it loads, and it looks fine.
        let reloaded = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(reloaded.isLocked)
        XCTAssertGreaterThan(reloaded.pageCount, 0)

        let good = try makePDF(named: "real", pageTexts: ["REAL"])
        let destination = tempDir.appendingPathComponent("out.pdf")
        XCTAssertThrowsError(try PDFMerge.merge(inputs: [locked, good], into: destination)) {
            XCTAssertEqual($0 as? PDFMerge.Failure, .unreadable(name: "locked.pdf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - The ordering rule

    /// The shelf draws newest-first while storage is append-at-end, so the merge
    /// cannot read order off the raw item array.
    func test_display_order_is_newest_first() {
        let oldest = ShelfItem(type: .file, fileURL: URL(fileURLWithPath: "/tmp/1.pdf"))
        let middle = ShelfItem(type: .file, fileURL: URL(fileURLWithPath: "/tmp/2.pdf"))
        let newest = ShelfItem(type: .file, fileURL: URL(fileURLWithPath: "/tmp/3.pdf"))

        XCTAssertEqual(
            ShelfDisplayOrder.displayed([oldest, middle, newest]).map(\.id),
            [newest.id, middle.id, oldest.id]
        )
    }

    /// A selection is a `Set<UUID>` with no drag-reorder anywhere in the app, so
    /// screen position is the only order the user can express.
    func test_selected_subset_keeps_screen_order_not_storage_order() {
        let oldest = ShelfItem(type: .file, fileURL: URL(fileURLWithPath: "/tmp/1.pdf"))
        let middle = ShelfItem(type: .file, fileURL: URL(fileURLWithPath: "/tmp/2.pdf"))
        let newest = ShelfItem(type: .file, fileURL: URL(fileURLWithPath: "/tmp/3.pdf"))

        let selected = ShelfDisplayOrder.displayed(
            [oldest, middle, newest], selecting: [oldest.id, newest.id]
        )
        XCTAssertEqual(selected.map(\.id), [newest.id, oldest.id])
    }

    /// The other half of "one expression of order": the views must go through
    /// the same rule. A bare `Array(items.reversed())` re-introduced anywhere in
    /// the container is a second definition that can drift from this one, and
    /// the drift is silent — a merged PDF simply comes out backwards.
    func test_the_container_draws_through_the_shared_ordering_rule() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfContainerView.swift"),
            encoding: .utf8
        )
        // The rule's own body is the one place allowed to say it.
        let body = "static func displayed(_ items: [ShelfItem]) -> [ShelfItem] {\n"
            + "        Array(items.reversed())\n    }"
        XCTAssertTrue(source.contains(body), "the shared ordering rule moved or changed shape")
        let occurrences = source.components(separatedBy: "Array(items.reversed())").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "the grid, the list or the focus cursor reverses items itself again — "
                + "that is a second definition of display order the merge cannot see"
        )
        for site in ["let displayed = ShelfDisplayOrder.displayed(items)",
                     "private var displayedItems: [ShelfItem] { ShelfDisplayOrder.displayed(items) }"] {
            XCTAssertTrue(source.contains(site), "a draw site stopped using the shared rule: \(site)")
        }
    }

    /// The merge action must derive its order from the shelf through that rule,
    /// not from `selectedItems` — which arrives in storage order from the
    /// context menu and in display order from the ⌘K palette.
    func test_the_merge_action_orders_through_the_shared_rule() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfContextMenu.swift"),
            encoding: .utf8
        )
        let action = source
            .components(separatedBy: "@objc func mergePDFs()")
            .dropFirst().first?
            .components(separatedBy: "@MainActor").first ?? ""
        XCTAssertFalse(action.isEmpty, "could not find the merge action")
        XCTAssertTrue(
            action.contains("ShelfDisplayOrder.displayed("),
            "the merge no longer orders its inputs through the shared display rule"
        )
        XCTAssertTrue(
            action.contains("ImageActions.uniqueURL(at: chosen)"),
            "the merge writes to the panel's URL directly — that overwrites a user file (ADR 0001)"
        )
    }

    // MARK: - Localisation

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    /// A key present but carrying the value of its NEIGHBOUR passes a
    /// presence-only check; that one-slot shift has shipped here once already.
    /// So: presence, non-emptiness, distinctness, and the exact placeholder each
    /// call site formats with.
    func test_every_language_defines_the_merge_strings_with_the_right_placeholders() throws {
        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            let title = try XCTUnwrap(table["Merge %lld PDFs…"], "\(language) is missing the merge row")
            let order = try XCTUnwrap(table["merge.order.label"], "\(language) is missing merge.order.label")
            let failure = try XCTUnwrap(
                table["alert.merge.unreadable"], "\(language) is missing alert.merge.unreadable"
            )

            for (key, value) in [
                ("Merge %lld PDFs…", title),
                ("merge.order.label", order),
                ("alert.merge.unreadable", failure),
            ] {
                XCTAssertFalse(value.isEmpty, "\(language) has an empty \(key)")
                if language != "en", language != "Base" {
                    XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                }
            }

            XCTAssertEqual(
                Set([title, order, failure]).count, 3,
                "\(language) repeats one merge value across keys — the one-slot shift again"
            )
            XCTAssertEqual(
                title.components(separatedBy: "%lld").count - 1, 1,
                "\(language) lost the count in the merge row title"
            )
            XCTAssertEqual(
                failure.components(separatedBy: "%@").count - 1, 1,
                "\(language) lost the filename in alert.merge.unreadable — "
                    + "the alert would not say WHICH file failed"
            )
            XCTAssertFalse(
                order.contains("%"),
                "\(language) added a placeholder to merge.order.label, which is formatted with none"
            )
        }
    }
}
