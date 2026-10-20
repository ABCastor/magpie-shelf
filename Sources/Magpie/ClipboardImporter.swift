import AppKit
import Foundation

enum ClipboardImporter {
    /// Password managers (1Password, Bitwarden) flag their pasteboard items
    /// with this so tools like this one decline them.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Reads `types` only — never the contents, which is what triggers the
    /// system's "pasted from" banner. Only Concealed is honoured: Transient
    /// targets clipboard-history recorders, and every import here is a
    /// deliberate user paste, so skipping it would swallow legitimate ones.
    static func isConcealed(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(concealedType) == true
    }

    static func addFromClipboard(
        from pasteboard: NSPasteboard = .general,
        addFile: (URL) -> Void,
        addText: (String) -> Void
    ) -> Int {
        guard !isConcealed(pasteboard) else { return 0 }

        var added = 0

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            for url in fileURLs {
                addFile(url)
                added += 1
            }
            return added
        }

        let images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        if !images.isEmpty {
            for image in images {
                guard
                    let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Shelf-\(UUID().uuidString).png")
                do {
                    try png.write(to: url)
                    addFile(url)
                    added += 1
                } catch {
                    NSLog("Shelf: failed to save clipboard image: \(error)")
                }
            }
            if added > 0 { return added }
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(text)
            added += 1
        }

        return added
    }
}
