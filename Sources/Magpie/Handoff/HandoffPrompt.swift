import Foundation

/// The two pieces of text a handoff produces: the `SHELF.md` inventory written
/// into the drop, and the prompt pre-filled in Claude.
///
/// Both are deliberately vault-agnostic. Magpie states what the items are,
/// where they came from and how they must be handled; it never says where they
/// should end up. That knowledge belongs to the receiving skill, and keeping it
/// out of the app is what lets the app be published.
enum HandoffPrompt {
    /// Claude's `code/new` handler slices `q` at `1024*16 - 2*1024`. Read out
    /// of the app's own bundle — the public docs round this to "about 14,000".
    static let queryLimit = 14336
    /// Names listed inline before the prompt switches to "…and N more".
    static let namesInPrompt = 20

    // MARK: - SHELF.md

    static func manifest(_ drop: HandoffDrop, createdAt: Date = Date()) -> String {
        let clock = readableFormatter()
        // Unlike the shelf UI this counts bytes too: a 34-byte note reported
        // as "0 KB" tells the reader nothing about what it is holding.
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        var lines = [
            "# Magpie drop",
            "",
            "Created: \(clock.string(from: createdAt))",
            "Items: \(drop.copied) copied · \(drop.referenced) referenced in place · \(drop.skipped) skipped",
            "",
            "Every file listed here is a COPY, and the originals on disk are untouched — leave them that way.",
            "This folder is temporary: Magpie deletes drops older than 7 days.",
            "Do not link or reference these paths in anything durable — copy an item to its destination first, then reference the destination.",
            "",
            "| # | Name | In this drop | Original | Kind | Size | Added to shelf |",
            "|---|------|--------------|----------|------|------|----------------|",
        ]

        for (index, entry) in drop.entries.enumerated() {
            let inDrop: String
            switch entry.placement {
            case .inDrop(let url): inDrop = url.lastPathComponent
            case .referenced: inDrop = "(not copied — referenced in place)"
            }
            let original: String
            switch entry.origin {
            case .path(let path): original = path
            case .magpieCache: original = "(unknown — Magpie cache copy)"
            case .pastedText: original = "(pasted text — no original file)"
            }
            let size = entry.byteSize.map { bytes.string(fromByteCount: $0) } ?? "unknown"
            let cells = [
                "\(index + 1)", entry.name, inDrop, original,
                entry.kind, size, clock.string(from: entry.addedAt),
            ]
            lines.append("| " + cells.map(cell).joined(separator: " | ") + " |")
        }

        lines += [
            "",
            "When you have read this file, create an empty file named \(HandoffBundle.receiptName) in this folder.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - The prompt

    /// Plain English, no leading slash: a slash would be read as a command by
    /// the receiver rather than as a request.
    static func prompt(folder: URL, names: [String], totalItems: Int) -> String {
        var shown = min(names.count, namesInPrompt)
        while true {
            let text = compose(
                folder: folder,
                names: Array(names.prefix(shown)),
                totalItems: totalItems
            )
            if text.count <= queryLimit || shown == 0 { return text }
            shown -= 1
        }
    }

    private static func compose(folder: URL, names: [String], totalItems: Int) -> String {
        var inventory = "\(totalItems) item\(totalItems == 1 ? "" : "s")"
        if names.isEmpty {
            inventory += "."
        } else {
            inventory += ": " + names.joined(separator: ", ")
            let remaining = totalItems - names.count
            inventory += remaining > 0 ? " …and \(remaining) more." : "."
        }
        return """
        Use my shelf skill to file this Magpie drop: \(folder.path)
        \(inventory)
        Read \(HandoffBundle.manifestName) in that folder first — it lists every item, where it came from, and the rules for handling copies.
        If I have no shelf skill, just read \(HandoffBundle.manifestName) and follow it.
        """
    }

    // MARK: - Helpers

    /// A cell can carry a filename, and a filename can carry a pipe or a
    /// newline; either would break the table row it sits in.
    private static func cell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func readableFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }
}
