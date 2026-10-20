import Foundation

/// One staged shelf item, as the manifest sees it.
struct HandoffEntry {
    enum Placement {
        /// Copied (or written) into the drop folder.
        case inDrop(URL)
        /// Left where it is — copying it would cross volumes and it is large.
        case referenced(URL)
    }

    /// Where the item came from. `magpieCache` exists because
    /// `ShelfStore.prepareForIngest` rewrites `fileURL` to a `ManagedFiles/`
    /// copy for anything arriving from tmp or caches (browser drags, Mail
    /// attachments, promise drops): printing that as the original would be a
    /// lie, and would invite linking a path the cache eviction later deletes.
    enum Origin {
        case path(String)
        case magpieCache
        case pastedText
    }

    let name: String
    let placement: Placement
    let origin: Origin
    let kind: String
    let byteSize: Int64?
    let addedAt: Date
}

struct HandoffDrop {
    let folder: URL
    let entries: [HandoffEntry]
    let skipped: Int

    var copied: Int {
        entries.reduce(0) { total, entry in
            if case .inDrop = entry.placement { return total + 1 }
            return total
        }
    }

    var referenced: Int { entries.count - copied }
}

/// Stages a shelf into a self-contained drop folder. Every decision lives
/// here so it can be tested against an injected `FileManager` and a temp root.
///
/// The only mutating file operations are `copyItem` into the drop and
/// `removeItem` on a drop folder the sweep itself named — never `linkItem`
/// (APFS forbids directory hardlinks, an atomic save by another app would
/// diverge the inodes, and unlinking the last name destroys the user's file
/// outright, bypassing the Bin — ADR 0001), never `moveItem`.
enum HandoffBundle {
    static let rootName = "Handoff"
    static let manifestName = "SHELF.md"
    static let receiptName = "RECEIVED"
    static let dropLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// On one APFS volume `copyItem` clones, so copying is near-free. Across
    /// volumes it is real bytes, and above this a large item is referenced in
    /// place instead. An unknown size counts as small and is copied.
    static let crossVolumeCopyLimit: Int64 = 100 * 1024 * 1024

    private static let folderNameFormat = "yyyyMMdd-HHmmss"
    private static let hexDigits = Set("0123456789abcdef")
    private static let decimalDigits = Set("0123456789")

    // MARK: - Staging

    /// `Handoff/` sits beside `ManagedFiles/` under the app's own Application
    /// Support directory — never in the user's own folders, which may be
    /// synced, backed up or under version control.
    static func root(besideManagedFiles managedFilesDirectory: URL) -> URL {
        managedFilesDirectory.deletingLastPathComponent()
            .appendingPathComponent(rootName, isDirectory: true)
    }

    /// `<yyyyMMdd-HHmmss>-<6 random hex>`. The random suffix means two clicks
    /// in the same second cannot collide, so no live session's folder is ever
    /// reused or wiped.
    static func folderName(now: Date = Date(), suffix: String = randomSuffix()) -> String {
        "\(timestampFormatter().string(from: now))-\(suffix)"
    }

    static func randomSuffix() -> String {
        String(format: "%06x", UInt32.random(in: 0..<0x100_0000))
    }

    static func stage(
        items: [ShelfItem],
        in root: URL,
        managedFilesDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> HandoffDrop {
        let folder = root.appendingPathComponent(folderName(now: now), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let dropVolume = volumeIdentifier(of: folder)
        var entries: [HandoffEntry] = []
        var skipped = 0
        var noteIndex = 0

        for item in items {
            // Text with no backing file becomes a note in the drop; there is
            // nothing on disk to copy.
            if item.type == .text, item.fileURL == nil {
                guard let text = item.textContent, !text.isEmpty else {
                    skipped += 1
                    continue
                }
                noteIndex += 1
                let destination = UniqueDestination.url(
                    preferred: folder.appendingPathComponent("note-\(noteIndex).md"),
                    fileManager: fileManager
                )
                do {
                    try text.write(to: destination, atomically: true, encoding: .utf8)
                } catch {
                    NSLog("Magpie: handoff could not write a note — \(error)")
                    skipped += 1
                    continue
                }
                entries.append(HandoffEntry(
                    name: destination.lastPathComponent,
                    placement: .inDrop(destination),
                    origin: .pastedText,
                    kind: "Text",
                    byteSize: Int64(text.utf8.count),
                    addedAt: item.createdAt
                ))
                continue
            }

            // A last path component is the only thing appended to the drop
            // folder, and it can never hold a separator — so with "." and ".."
            // refused, nothing staged can be written outside the drop.
            guard let source = item.fileURL,
                  fileManager.fileExists(atPath: source.path),
                  !["", ".", ".."].contains(source.lastPathComponent) else {
                skipped += 1
                continue
            }

            let origin: HandoffEntry.Origin = ShelfStore.contains(source, in: managedFilesDirectory)
                ? .magpieCache
                : .path(source.path)

            if shouldReferenceInPlace(
                byteSize: item.byteSize,
                crossesVolume: crossesVolume(source, from: dropVolume)
            ) {
                entries.append(HandoffEntry(
                    name: source.lastPathComponent,
                    placement: .referenced(source),
                    origin: origin,
                    kind: kind(of: item, url: source),
                    byteSize: item.byteSize,
                    addedAt: item.createdAt
                ))
                continue
            }

            let destination = UniqueDestination.url(
                preferred: folder.appendingPathComponent(source.lastPathComponent),
                fileManager: fileManager
            )
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                NSLog("Magpie: handoff could not copy \(source.lastPathComponent) — \(error)")
                skipped += 1
                continue
            }
            entries.append(HandoffEntry(
                name: destination.lastPathComponent,
                placement: .inDrop(destination),
                origin: origin,
                kind: kind(of: item, url: source),
                byteSize: item.byteSize,
                addedAt: item.createdAt
            ))
        }

        return HandoffDrop(folder: folder, entries: entries, skipped: skipped)
    }

    // MARK: - Sweep

    /// Deletes drops older than `dropLifetime`. Structurally confined to
    /// `root`: it enumerates only root's direct children by *name*, rebuilds
    /// each candidate as `root + name` (never a path read from anywhere else,
    /// and a name can never contain a separator), accepts only names this app
    /// generates, refuses symlinks at both the root and the candidate, and
    /// takes each drop's age from its own name rather than from filesystem
    /// attributes an outsider could set.
    @discardableResult
    static func sweep(
        root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else { return [] }
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }

        let formatter = timestampFormatter()
        var removed: [URL] = []
        for name in names {
            guard let created = date(fromFolderName: name, formatter: formatter),
                  now.timeIntervalSince(created) > dropLifetime else { continue }
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            let values = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            do {
                try fileManager.removeItem(at: candidate)
                removed.append(candidate)
            } catch {
                NSLog("Magpie: handoff sweep could not remove \(name) — \(error)")
            }
        }
        return removed
    }

    /// Parses a drop folder name back to its creation time. Returns nil for
    /// anything this app did not name — which is what keeps the sweep from
    /// touching a folder a user or another tool put in `Handoff/`.
    static func date(
        fromFolderName name: String,
        formatter: DateFormatter? = nil
    ) -> Date? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 8, parts[0].allSatisfy(decimalDigits.contains),
              parts[1].count == 6, parts[1].allSatisfy(decimalDigits.contains),
              parts[2].count == 6, parts[2].allSatisfy(hexDigits.contains)
        else { return nil }
        return (formatter ?? timestampFormatter()).date(from: "\(parts[0])-\(parts[1])")
    }

    // MARK: - Helpers

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = folderNameFormat
        return formatter
    }

    /// An unknown size counts as small, so it is copied: a clone on the same
    /// volume costs nothing, and referencing an item the agent then cannot
    /// reach is worse than copying one it did not need.
    static func shouldReferenceInPlace(byteSize: Int64?, crossesVolume: Bool) -> Bool {
        crossesVolume && (byteSize ?? 0) > crossVolumeCopyLimit
    }

    private static func volumeIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    /// Unknown on either side counts as same-volume, so the item is copied.
    private static func crossesVolume(_ url: URL, from dropVolume: (any NSObjectProtocol)?) -> Bool {
        guard let dropVolume, let sourceVolume = volumeIdentifier(of: url) else { return false }
        return !sourceVolume.isEqual(dropVolume)
    }

    private static func kind(of item: ShelfItem, url: URL) -> String {
        if item.isDirectory { return "Folder" }
        let ext = url.pathExtension
        var parts = [ext.isEmpty ? defaultKind(for: item.type) : ext.uppercased()]
        if let pages = item.pageCount { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
        if let pixels = item.pixelSize {
            parts.append("\(Int(pixels.width))x\(Int(pixels.height)) px")
        }
        return parts.joined(separator: ", ")
    }

    private static func defaultKind(for type: ShelfItem.ItemType) -> String {
        switch type {
        case .file: return "File"
        case .image: return "Image"
        case .text: return "Text"
        }
    }
}
