import AppKit
import Foundation

/// What a shelf looks like on the pasteboard.
///
/// One copy, two audiences. A file-aware target (Finder, a mail composer)
/// reads the `.fileURL` flavours and attaches every item. A text-only target
/// — the composer of the chat the user is already in — reads the `.string`
/// flavour and gets a readable block of absolute paths it can act on without
/// anyone retyping a path.
///
/// The layout is the load-bearing detail, and two obvious shapes are both
/// wrong. `writeObjects([url, url, …])` followed by `setString(block, forType:
/// .string)` puts the block on item 0 and leaves items 1…n-1 with an empty
/// string flavour, so a receiver concatenating every item's string gets the
/// block plus N-1 blanks. Putting *both* flavours on item 0 fixes that and
/// breaks the other direction: a receiver that walks items preferring text eats
/// item 0 as the block and attaches only the remaining N-1 files, silently
/// losing the first one every time.
///
/// So: **one flavour per item.** One file item per URL in shelf order, then the
/// whole text block on a single trailing item. Neither kind of reader loses
/// anything, and a text-only target still finds the block because the
/// non-item-based `pasteboard.string(forType:)` scans items in order.
enum ShelfClipboardPayload {
    /// Per-snippet cap on inlined text, in UTF-8 bytes. A shelf can hold a
    /// pasted log; pasting the whole of it into a chat composer would bury the
    /// paths that are the point of the block.
    static let snippetByteCap = 4096
    static let truncationMarker = "[truncated]"

    /// One line's worth of shelf. A file contributes its path; a text snippet
    /// contributes its content, because its path is a hash-named temp file
    /// that means nothing to a reader. A snippet keeps that file anyway: it is
    /// what a *file* target has always received for a text item, and dropping
    /// it would quietly make Copy do less than it used to.
    enum Entry: Equatable {
        case path(URL)
        case snippet(String, file: URL?)
    }

    // MARK: - Model → entries

    static func entries(
        for items: [ShelfItem],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [Entry] {
        items.compactMap { item in
            let existingFile = item.fileURL.flatMap { fileExists($0) ? $0 : nil }
            if item.type == .text, let text = item.textContent {
                return .snippet(text, file: existingFile)
            }
            if let existingFile {
                return .path(existingFile)
            }
            if let text = item.textContent {
                return .snippet(text, file: nil)
            }
            return nil
        }
    }

    /// Every file a file-aware target should receive, in shelf order.
    static func attachmentURLs(for entries: [Entry]) -> [URL] {
        entries.compactMap { entry in
            switch entry {
            case .path(let url): return url
            case .snippet(_, let file): return file
            }
        }
    }

    // MARK: - The text block

    static func textBlock(
        for items: [ShelfItem],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> String {
        textBlock(for: entries(for: items, fileExists: fileExists))
    }

    /// Deliberately English and unlocalized, like `HandoffPrompt`: the reader
    /// is the agent on the other side of the paste, not the UI.
    static func textBlock(for entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "" }

        var lines = [header(for: entries)]
        for entry in entries {
            switch entry {
            case .path(let url):
                lines.append("- \(url.path)")
            case .snippet(let text, _):
                lines.append(contentsOf: snippetLines(text))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "3 files on my Magpie shelf:" — but a pasted snippet is not a file, so
    /// a mixed or text-only shelf says "items" instead. Calling a snippet a
    /// file would be the kind of small lie that makes a reader distrust the
    /// rest of the block.
    private static func header(for entries: [Entry]) -> String {
        let onlyFiles = entries.allSatisfy { if case .path = $0 { return true } else { return false } }
        let singular = entries.count == 1
        let noun: String
        switch (onlyFiles, singular) {
        case (true, true): noun = "file"
        case (true, false): noun = "files"
        case (false, true): noun = "item"
        case (false, false): noun = "items"
        }
        return "\(entries.count) \(noun) on my Magpie shelf:"
    }

    private static func snippetLines(_ text: String) -> [String] {
        let (capped, wasTruncated) = capped(text, toBytes: snippetByteCap)
        let trimmed = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["- text snippet: (empty)"] }

        var lines = ["- text snippet:"]
        lines += trimmed.components(separatedBy: .newlines).map { "  \($0)" }
        if wasTruncated { lines.append("  \(truncationMarker)") }
        return lines
    }

    /// Cuts at a character boundary inside a UTF-8 byte budget — slicing raw
    /// bytes would split a multi-byte character and produce mojibake at the
    /// cut, which is exactly where the reader looks.
    static func capped(_ text: String, toBytes limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var out = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > limit { break }
            out.append(character)
            used += width
        }
        return (out, true)
    }

    // MARK: - Pasteboard

    static func pasteboardItems(for entries: [Entry]) -> [NSPasteboardItem] {
        guard !entries.isEmpty else { return [] }

        let urls = attachmentURLs(for: entries)

        // One flavour per item. Putting `.string` on the first file item as
        // well looks tidier, but a reader that walks items and prefers text
        // then consumes item 0 as the block and attaches only the remaining
        // N-1 files — silently losing the first one, every time. Giving the
        // block its own trailing item costs nothing: the non-item-based
        // `pasteboard.string(forType:)` scans items in order, so a text-only
        // target still finds the block here.
        let fileItems = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        let textItem = NSPasteboardItem()
        textItem.setString(textBlock(for: entries), forType: .string)
        return fileItems + [textItem]
    }

    /// Returns false and leaves the pasteboard untouched when there is nothing
    /// to write — clearing it for an empty shelf would silently destroy
    /// whatever the user had copied a moment ago.
    @discardableResult
    static func write(
        items: [ShelfItem],
        to pasteboard: NSPasteboard,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Bool {
        let pasteboardItems = pasteboardItems(for: entries(for: items, fileExists: fileExists))
        guard !pasteboardItems.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems)
    }
}
