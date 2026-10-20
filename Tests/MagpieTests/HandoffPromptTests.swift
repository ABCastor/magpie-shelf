import Foundation
import XCTest
@testable import Magpie

final class HandoffPromptTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandoffPromptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(
        name: String,
        placement: HandoffEntry.Placement? = nil,
        origin: HandoffEntry.Origin = .path("/Users/someone/Downloads/x"),
        kind: String = "PDF",
        byteSize: Int64? = 1024
    ) -> HandoffEntry {
        HandoffEntry(
            name: name,
            placement: placement ?? .inDrop(tempDir.appendingPathComponent(name)),
            origin: origin,
            kind: kind,
            byteSize: byteSize,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Realistic shelf: the kind of pile that actually lands here — statements,
    /// scans, screenshots, exports — at realistic name lengths.
    private func realisticNames(_ count: Int) -> [String] {
        let templates = [
            "Barclays Statement 2026-06 personal current account.pdf",
            "Screenshot 2026-07-27 at 21.43.08.png",
            "invoice+scan LMN-4821 (final, signed).pdf",
            "CV — Rosa Whitfield (2026, long form).docx",
            "meeting recording 2026-07-14 stand-up with the team.m4a",
            "Council Tax Reduction — evidence bundle scan 03.jpeg",
        ]
        return (0..<count).map { "\($0 + 1) \(templates[$0 % templates.count])" }
    }

    // MARK: - SHELF.md

    func test_manifest_states_the_rules_and_asks_for_the_receipt() {
        let drop = HandoffDrop(
            folder: tempDir,
            entries: [entry(name: "a.pdf")],
            skipped: 2
        )
        let manifest = HandoffPrompt.manifest(drop)

        XCTAssertTrue(manifest.contains("COPY"))
        XCTAssertTrue(manifest.contains("originals on disk are untouched"))
        XCTAssertTrue(manifest.contains("7 days"))
        XCTAssertTrue(manifest.contains("Do not link or reference these paths"))
        XCTAssertTrue(manifest.contains("create an empty file named RECEIVED"))
        XCTAssertTrue(manifest.contains("1 copied · 0 referenced in place · 2 skipped"))
    }

    /// Magpie must stay publishable: it knows nothing about where these files
    /// are going, only what they are.
    func test_manifest_says_nothing_about_a_vault() {
        let drop = HandoffDrop(folder: tempDir, entries: [entry(name: "a.pdf")], skipped: 0)
        let manifest = HandoffPrompt.manifest(drop).lowercased()
        for term in ["obsidian", "vault", "second brain", "/ingest"] {
            XCTAssertFalse(manifest.contains(term), "manifest leaked \(term)")
        }
    }

    func test_manifest_marks_an_item_referenced_in_place() {
        let big = URL(fileURLWithPath: "/Volumes/Archive/raw footage.mov")
        let drop = HandoffDrop(
            folder: tempDir,
            entries: [entry(
                name: "raw footage.mov",
                placement: .referenced(big),
                origin: .path(big.path),
                kind: "MOV",
                byteSize: 8_000_000_000
            )],
            skipped: 0
        )
        let manifest = HandoffPrompt.manifest(drop)

        XCTAssertTrue(manifest.contains("(not copied — referenced in place)"))
        XCTAssertTrue(manifest.contains(big.path))
        XCTAssertEqual(drop.referenced, 1)
        XCTAssertEqual(drop.copied, 0)
    }

    func test_manifest_row_survives_a_pipe_in_a_filename() {
        let drop = HandoffDrop(
            folder: tempDir,
            entries: [entry(name: "a|b.pdf")],
            skipped: 0
        )
        let row = HandoffPrompt.manifest(drop)
            .split(separator: "\n")
            .first { $0.hasPrefix("| 1 ") }
        XCTAssertNotNil(row)
        // Seven columns means the escaped pipe did not split the row.
        XCTAssertEqual(row?.components(separatedBy: " | ").count, 7)
    }

    // MARK: - The prompt

    func test_prompt_points_at_the_drop_and_the_manifest() {
        let folder = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Magpie/Handoff/20260727-224500-a1b2c3")
        let text = HandoffPrompt.prompt(folder: folder, names: ["a.pdf"], totalItems: 1)

        XCTAssertTrue(text.hasPrefix("Use my shelf skill to file this Magpie drop: "))
        XCTAssertFalse(text.hasPrefix("/"), "a leading slash would read as a command")
        XCTAssertTrue(text.contains(folder.path))
        XCTAssertTrue(text.contains("1 item: a.pdf."))
        XCTAssertTrue(text.contains("Read SHELF.md in that folder first"))
        XCTAssertTrue(text.contains("If I have no shelf skill"))
    }

    func test_prompt_names_twenty_then_counts_the_rest() {
        let names = realisticNames(31)
        let text = HandoffPrompt.prompt(
            folder: tempDir, names: names, totalItems: names.count
        )
        XCTAssertTrue(text.contains("31 items: "))
        XCTAssertTrue(text.contains(names[19]))
        XCTAssertFalse(text.contains(names[20]))
        XCTAssertTrue(text.contains("…and 11 more."))
    }

    func test_prompt_stays_under_the_query_cap_for_a_realistic_shelf() {
        for count in [1, 3, 20, 60, 400] {
            let names = realisticNames(count)
            let text = HandoffPrompt.prompt(
                folder: tempDir, names: names, totalItems: count
            )
            XCTAssertLessThanOrEqual(
                text.count, HandoffPrompt.queryLimit,
                "prompt for \(count) items exceeded the q cap"
            )
        }
    }

    /// Pathological but reachable: macOS allows 255-byte filenames, and 20 of
    /// them would blow the cap if the budget were only advisory.
    func test_prompt_drops_names_until_a_long_named_shelf_fits() {
        let names = (0..<20).map { String(repeating: "x", count: 250) + "-\($0).pdf" }
        let text = HandoffPrompt.prompt(folder: tempDir, names: names, totalItems: 20)
        XCTAssertLessThanOrEqual(text.count, HandoffPrompt.queryLimit)
        XCTAssertTrue(text.contains("20 items"))
    }

    // MARK: - The deep link

    func test_url_is_code_new_with_exactly_q_and_folder() throws {
        let url = try XCTUnwrap(ClaudeLink.url(
            prompt: "file this",
            folder: URL(fileURLWithPath: "/Users/someone")
        ))
        XCTAssertEqual(url.scheme, "claude")
        XCTAssertEqual(url.host, "code")
        XCTAssertEqual(url.path, "/new")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.map(\.name), ["q", "folder"])
        XCTAssertEqual(items[0].value, "file this")
        XCTAssertEqual(items[1].value, "/Users/someone")
        // `file=` is read but never forwarded by the code/new handler — a
        // build that sent it would look correct and attach nothing.
        XCTAssertFalse(url.absoluteString.contains("file="))
    }

    func test_url_percent_encodes_a_literal_plus() throws {
        let url = try XCTUnwrap(ClaudeLink.url(
            prompt: "invoice+scan.pdf and a space",
            folder: URL(fileURLWithPath: "/Users/someone/My Files+Archive")
        ))
        let query = try XCTUnwrap(url.query)
        // The receiver parses with URLSearchParams, which turns a bare "+"
        // into a space. Neither the prompt nor the folder may contain one.
        XCTAssertFalse(query.contains("+"))
        XCTAssertTrue(query.contains("%2B"))

        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(items[0].value, "invoice+scan.pdf and a space")
        XCTAssertEqual(items[1].value, "/Users/someone/My Files+Archive")
    }

    func test_a_filename_full_of_query_syntax_cannot_split_the_query() throws {
        let hostile = "Q1 & Q2 = final?draft#2 100% .pdf"
        let prompt = HandoffPrompt.prompt(
            folder: tempDir, names: [hostile], totalItems: 1
        )
        let url = try XCTUnwrap(ClaudeLink.url(
            prompt: prompt, folder: URL(fileURLWithPath: "/Users/someone")
        ))
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(items.map(\.name), ["q", "folder"])
        XCTAssertEqual(items[0].value, prompt)
        XCTAssertNil(url.fragment)
    }

    func test_url_for_a_realistic_shelf_keeps_q_under_the_cap() throws {
        for count in [3, 60, 400] {
            let names = realisticNames(count)
            let prompt = HandoffPrompt.prompt(
                folder: tempDir.appendingPathComponent("20260727-224500-a1b2c3"),
                names: names,
                totalItems: count
            )
            let url = try XCTUnwrap(ClaudeLink.url(
                prompt: prompt,
                folder: FileManager.default.homeDirectoryForCurrentUser
            ))
            let items = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            )
            let q = try XCTUnwrap(items.first { $0.name == "q" }?.value)
            XCTAssertLessThanOrEqual(q.count, HandoffPrompt.queryLimit)
            XCTAssertEqual(items.filter { $0.name == "folder" }.count, 1)
        }
    }
}
