import AppKit
import Foundation
import XCTest
@testable import Magpie

final class ShelfClipboardPayloadTests: XCTestCase {
    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let localizedKeys = [
        "toast.chat-copied",
        "toast.chat-copy-empty",
    ]

    private func fileItem(_ path: String, isDirectory: Bool = false) -> ShelfItem {
        ShelfItem(
            type: .file,
            fileURL: URL(fileURLWithPath: path),
            isDirectory: isDirectory
        )
    }

    private func textItem(_ text: String) -> ShelfItem {
        ShelfItem(type: .text, textContent: text)
    }

    /// Every entry in these tests is a path that does not exist on disk, so the
    /// existence filter is stubbed rather than staging fixtures for what is a
    /// pure string question.
    private let allExist: (URL) -> Bool = { _ in true }

    // MARK: - The text block

    func test_files_render_as_unquoted_absolute_paths() {
        let block = ShelfClipboardPayload.textBlock(
            for: [fileItem("/Users/someone/Desktop/report.pdf"), fileItem("/Users/someone/shot.png")],
            fileExists: allExist
        )
        XCTAssertEqual(block, """
        2 files on my Magpie shelf:
        - /Users/someone/Desktop/report.pdf
        - /Users/someone/shot.png
        """)
    }

    func test_a_single_file_is_not_pluralised() {
        let block = ShelfClipboardPayload.textBlock(
            for: [fileItem("/Users/someone/a.pdf")],
            fileExists: allExist
        )
        XCTAssertTrue(block.hasPrefix("1 file on my Magpie shelf:"), block)
    }

    func test_directories_render_as_their_path_like_any_other_item() {
        let block = ShelfClipboardPayload.textBlock(
            for: [fileItem("/Users/someone/Projects", isDirectory: true), fileItem("/Users/someone/a.pdf")],
            fileExists: allExist
        )
        XCTAssertEqual(block, """
        2 files on my Magpie shelf:
        - /Users/someone/Projects
        - /Users/someone/a.pdf
        """)
    }

    func test_text_items_are_inlined_and_the_header_stops_saying_files() {
        // A pasted snippet is not a file; calling it one in the header is the
        // kind of small lie that makes the reader distrust the paths too.
        let block = ShelfClipboardPayload.textBlock(
            for: [
                fileItem("/Users/someone/a.pdf"),
                textItem("Meeting notes\nship the thing"),
                fileItem("/Users/someone/b.png"),
            ],
            fileExists: allExist
        )
        XCTAssertEqual(block, """
        3 items on my Magpie shelf:
        - /Users/someone/a.pdf
        - text snippet:
          Meeting notes
          ship the thing
        - /Users/someone/b.png
        """)
    }

    /// The format contract, pinned verbatim. Anything that changes the shape
    /// of what lands in a chat composer should have to change this line by
    /// line and look at what it is doing.
    func test_golden_block_for_two_files_and_a_snippet() {
        let block = ShelfClipboardPayload.textBlock(
            for: [
                fileItem("/Users/someone/Desktop/Q3 invoice.pdf"),
                fileItem("/Users/someone/Downloads/screenshot 2026-07-27.png"),
                textItem("ship the payload before the hotkey\nask about the 4 KB cap"),
            ],
            fileExists: allExist
        )
        XCTAssertEqual(block, """
        3 items on my Magpie shelf:
        - /Users/someone/Desktop/Q3 invoice.pdf
        - /Users/someone/Downloads/screenshot 2026-07-27.png
        - text snippet:
          ship the payload before the hotkey
          ask about the 4 KB cap
        """)
    }

    func test_a_text_item_inlines_its_content_but_keeps_its_file_for_attachment() {
        // Text items are backed by a hash-named temp .txt so Open and Reveal
        // work. That path is meaningless in the block — but it is what a file
        // target has always received for a text item, so it stays attached.
        let file = URL(fileURLWithPath: "/tmp/Snippet-deadbeef.txt")
        let item = ShelfItem(type: .text, fileURL: file, textContent: "hello")

        let entries = ShelfClipboardPayload.entries(for: [item], fileExists: allExist)
        let block = ShelfClipboardPayload.textBlock(for: entries)

        XCTAssertFalse(block.contains("Snippet-deadbeef"), block)
        XCTAssertTrue(block.contains("  hello"), block)
        XCTAssertEqual(ShelfClipboardPayload.attachmentURLs(for: entries), [file])
    }

    func test_a_text_item_whose_temp_file_vanished_still_carries_its_content() {
        let item = ShelfItem(
            type: .text,
            fileURL: URL(fileURLWithPath: "/tmp/Snippet-gone.txt"),
            textContent: "still here"
        )
        let entries = ShelfClipboardPayload.entries(for: [item], fileExists: { _ in false })

        XCTAssertEqual(entries, [.snippet("still here", file: nil)])
        XCTAssertTrue(ShelfClipboardPayload.attachmentURLs(for: entries).isEmpty)
        XCTAssertTrue(ShelfClipboardPayload.textBlock(for: entries).contains("  still here"))
    }

    func test_a_five_kilobyte_snippet_is_capped_and_marked_truncated() {
        let long = String(repeating: "a", count: 5 * 1024)
        let block = ShelfClipboardPayload.textBlock(for: [textItem(long)], fileExists: allExist)
        let lines = block.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 4, block.prefix(120).description)
        XCTAssertEqual(lines[0], "1 item on my Magpie shelf:")
        XCTAssertEqual(lines[1], "- text snippet:")
        // Two spaces of indent, then exactly the cap's worth of content.
        XCTAssertEqual(lines[2].dropFirst(2).utf8.count, ShelfClipboardPayload.snippetByteCap)
        XCTAssertEqual(lines[3], "  \(ShelfClipboardPayload.truncationMarker)")
        // The cap bounds the snippet, not the block, so allow the header,
        // the bullet, the indent and the marker on top of it.
        XCTAssertLessThan(block.utf8.count, ShelfClipboardPayload.snippetByteCap + 200)
    }

    func test_a_snippet_just_under_the_cap_is_not_marked() {
        let text = String(repeating: "b", count: ShelfClipboardPayload.snippetByteCap)
        let block = ShelfClipboardPayload.textBlock(for: [textItem(text)], fileExists: allExist)
        XCTAssertFalse(block.contains(ShelfClipboardPayload.truncationMarker))
    }

    func test_capping_cuts_on_a_character_boundary_not_a_byte_boundary() {
        // "é" is two UTF-8 bytes; a raw byte slice at an odd limit would leave
        // half a character and produce mojibake exactly where the eye lands.
        let (capped, truncated) = ShelfClipboardPayload.capped("ééé", toBytes: 3)
        XCTAssertTrue(truncated)
        XCTAssertEqual(capped, "é")
        XCTAssertLessThanOrEqual(capped.utf8.count, 3)
    }

    func test_an_empty_shelf_produces_no_block() {
        XCTAssertEqual(ShelfClipboardPayload.textBlock(for: [], fileExists: allExist), "")
        XCTAssertTrue(ShelfClipboardPayload.entries(for: [], fileExists: allExist).isEmpty)
    }

    func test_a_file_that_no_longer_exists_is_left_out() {
        let entries = ShelfClipboardPayload.entries(
            for: [fileItem("/Users/someone/gone.pdf"), fileItem("/Users/someone/here.pdf")],
            fileExists: { $0.lastPathComponent == "here.pdf" }
        )
        XCTAssertEqual(entries, [.path(URL(fileURLWithPath: "/Users/someone/here.pdf"))])
    }

    // MARK: - Pasteboard layout

    func test_each_item_carries_exactly_one_flavour_so_no_file_is_ever_lost() {
        // Two bugs this shape exists to prevent, one on each side.
        //
        // writeObjects(urls) then setString(block) puts the block on item 0 and
        // leaves items 1…n-1 with an empty string flavour, so a receiver that
        // concatenates every item's string gets the block plus N-1 blanks.
        //
        // Putting BOTH flavours on item 0 fixes that but breaks the other
        // direction: a reader that walks items and prefers text consumes item 0
        // as the block and attaches only the remaining N-1 files, silently
        // losing the first one every time. One flavour per item is the only
        // layout where neither reader loses anything.
        let entries: [ShelfClipboardPayload.Entry] = [
            .path(URL(fileURLWithPath: "/Users/someone/a.pdf")),
            .path(URL(fileURLWithPath: "/Users/someone/b.png")),
            .path(URL(fileURLWithPath: "/Users/someone/c.txt")),
        ]
        let items = ShelfClipboardPayload.pasteboardItems(for: entries)

        XCTAssertEqual(items.count, 4, "3 file items plus one text item")
        for (index, item) in items.enumerated() {
            let url = item.string(forType: .fileURL)
            let text = item.string(forType: .string)
            XCTAssertTrue(
                (url == nil) != (text == nil),
                "item \(index) must carry exactly one flavour, not both and not neither"
            )
        }

        // Every file survives a per-item walk, in shelf order.
        XCTAssertEqual(
            items.compactMap { $0.string(forType: .fileURL) },
            ShelfClipboardPayload.attachmentURLs(for: entries).map(\.absoluteString)
        )
        // And a text-only reader still finds the block, on the trailing item.
        XCTAssertEqual(
            items.compactMap { $0.string(forType: .string) },
            [ShelfClipboardPayload.textBlock(for: entries)]
        )
    }

    func test_a_text_only_shelf_still_writes_the_block_on_a_single_item() {
        let items = ShelfClipboardPayload.pasteboardItems(for: [.snippet("just text", file: nil)])
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].string(forType: .fileURL))
        XCTAssertTrue(items[0].string(forType: .string)?.contains("just text") == true)
    }

    func test_write_round_trips_urls_and_the_block_through_a_real_pasteboard() throws {
        // A private pasteboard — never the general one, which is the user's.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfClipboardPayloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data("1".utf8).write(to: first)
        try Data("2".utf8).write(to: second)

        let wrote = ShelfClipboardPayload.write(
            items: [
                ShelfItem(type: .file, fileURL: first),
                ShelfItem(type: .file, fileURL: second),
                textItem("a note"),
            ],
            to: pasteboard
        )
        XCTAssertTrue(wrote)

        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["first.txt", "second.txt"])

        let string = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(string.hasPrefix("3 items on my Magpie shelf:"), string)
        XCTAssertTrue(string.contains(first.path), string)
        XCTAssertTrue(string.contains("  a note"), string)
    }

    func test_an_empty_shelf_leaves_the_pasteboard_untouched() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what the user copied a moment ago", forType: .string)

        XCTAssertFalse(ShelfClipboardPayload.write(items: [], to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user copied a moment ago")
    }

    // MARK: - Strings

    func test_every_language_parses_and_defines_the_chat_copy_strings() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")

        for language in Self.languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            for key in Self.localizedKeys {
                let value = table[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
                // English keys legitimately equal their English value; any
                // other language leaving them identical means untranslated.
                if language != "Base", language != "en" {
                    XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                }
            }
        }
    }
}
