import AppKit
import Foundation

private struct PersistedShelfItem: Codable {
    let id: UUID
    let type: String          // "file" | "image" | "text"
    let bookmark: Data?
    let path: String?
    let text: String?
    let createdAt: Date
}

private struct PersistedShelf: Codable {
    let id: UUID
    let createdAt: Date
    let items: [PersistedShelfItem]
    // Added in v3 — optional so v2 payloads decode cleanly.
    let name: String?
    let pinned: Bool?
    let accent: ShelfAccent?
}

private struct PersistedStore: Codable {
    let version: Int
    let shelves: [PersistedShelf]
    let currentShelfID: UUID?
}

private struct PersistedStoreVersion: Decodable {
    let version: Int
}

struct ShelfStoreContents {
    let shelves: [Shelf]
    let currentShelfID: UUID?
    let isAuthoritative: Bool
    /// What happened, in words a person can be told. Deliberately alongside
    /// `isAuthoritative` and not folded into it: that bool is the condition the
    /// fail-closed eviction guard in `ShelfManager` reads (ADR 0001 §3), and a
    /// single merged enum would make it possible to open that path for a case
    /// by accident. One says whether we may write; this one says what to show.
    let outcome: ShelfStore.LoadOutcome
}

final class ShelfStore {
    static let currentVersion = 4

    /// Why a load produced what it produced.
    ///
    /// The store has always detected all of these and said nothing, which is
    /// how "every shelf vanished one morning" reached the user with no words
    /// attached. Payload-free apart from the preserved file, so it can be
    /// handed to the diagnostics report without carrying a path into it.
    enum LoadOutcome: Equatable {
        /// The store was read, or there was nothing to read yet.
        case healthy
        /// The bytes did not decode. The file was moved aside, intact, to here.
        case quarantined(preservedAt: URL)
        /// Written by a newer Magpie. Readable or not, it is never overwritten,
        /// so nothing will be saved for as long as this build runs.
        case readOnlyNewerSchema
        /// Could not be read, and could not be set aside either.
        case unreadable

        /// A stable, unlocalized identifier. Not for display — it exists so the
        /// diagnostics report reads the same in every language.
        var key: String {
            switch self {
            case .healthy: return "healthy"
            case .quarantined: return "quarantined"
            case .readOnlyNewerSchema: return "read-only-newer-schema"
            case .unreadable: return "unreadable"
            }
        }
    }

    typealias BookmarkResolution = (url: URL?, isStale: Bool)
    typealias BookmarkResolver = (Data) -> BookmarkResolution
    typealias BookmarkMaker = (URL) -> Data?

    private let storeURL: URL
    let managedFilesDirectory: URL
    private let bookmarkResolver: BookmarkResolver
    private let bookmarkMaker: BookmarkMaker
    private var isReadOnly = false
    /// The two reasons `isReadOnly` can be true, kept apart because they are
    /// completely different sentences to a user: one is "a newer Magpie owns
    /// this", the other is "this file cannot be read at all".
    private var isNewerSchema = false
    /// Where the last load preserved bytes it could not decode, if it did.
    private var quarantinedURL: URL?

    /// The directory everything the app persists lives in. Exposed so Settings
    /// can reveal it without deriving the path a second time.
    var directory: URL { storeURL.deletingLastPathComponent() }

    /// What `canOverwriteStore` last decided, and the fingerprint of the file
    /// it decided against. Re-deciding reads and double-decodes the whole
    /// store, so doing it on every autosave was pure waste; the fingerprint is
    /// what keeps the newer-schema protection intact anyway, because a store
    /// replaced underneath us no longer matches and is inspected again.
    private var overwriteVerdict: Bool?
    private var verdictStamp: FileStamp?

    /// Counts full read-and-decode inspections of the store. It exists to pin
    /// "a save does not re-decode the store" in a test; nothing reads it.
    private(set) var storeInspectionCount = 0

    /// Bookmarks this store minted, keyed by item id with the path they were
    /// minted for. Creating one is expensive and a locator only goes stale
    /// when the item's path changes, so a save that moved nothing mints
    /// nothing. Pruned to the live items on every save.
    private var mintedBookmarks: [UUID: (path: String, data: Data)] = [:]

    private struct FileStamp: Equatable {
        let size: Int64
        let modified: Date
    }

    /// The default resolves the directory through `StoreLocation`, the one
    /// place `storeURL` and `managedFilesDirectory` may be derived from —
    /// see the reasoning at the top of `StoreLocation`.
    init(storeURL: URL = StoreLocation.applicationSupportDirectory()
        .appendingPathComponent(StoreLocation.storeFileName),
         bookmarkResolver: BookmarkResolver? = nil, bookmarkMaker: BookmarkMaker? = nil) {
        self.storeURL = storeURL
        self.managedFilesDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("ManagedFiles", isDirectory: true)
        self.bookmarkResolver = bookmarkResolver ?? Self.resolveBookmark
        self.bookmarkMaker = bookmarkMaker ?? Self.makeBookmark
    }

    // MARK: - Save

    func save(shelves: [Shelf], currentShelfID: UUID?) {
        guard canOverwriteStore else {
            NSLog("Shelf: refusing to overwrite a newer or unresolved store")
            return
        }
        let liveItemIDs = Set(shelves.flatMap(\.items).map(\.id))
        mintedBookmarks = mintedBookmarks.filter { liveItemIDs.contains($0.key) }
        let records = shelves.map { shelf in
            PersistedShelf(
                id: shelf.id,
                createdAt: shelf.createdAt,
                items: shelf.items.map(persist),
                name: shelf.name,
                pinned: shelf.pinned ? true : nil,
                accent: shelf.accent
            )
        }
        let payload = PersistedStore(
            version: Self.currentVersion,
            shelves: records,
            currentShelfID: currentShelfID
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: storeURL, options: .atomic)
            // Our own bytes are authoritative, so record their fingerprint:
            // without this the next save would see a changed file and inspect
            // it again, which is the cost this cache exists to remove.
            overwriteVerdict = true
            verdictStamp = Self.stamp(of: storeURL)
        } catch {
            NSLog("Shelf: save failed — \(error)")
        }
    }

    private func persist(_ item: ShelfItem) -> PersistedShelfItem {
        let bookmark: Data? = {
            // Text snippets are backed by a temp `.txt` that's regenerated
            // from the snippet content on load — persisting a bookmark to
            // that path would resolve to a missing file (temp dir is wiped
            // between sessions) and the item would silently drop on load.
            if item.type == .text { return nil }
            guard let url = item.fileURL else { return item.bookmarkData }
            // An item that already carries a bookmark carries one that
            // resolved to this very URL: `load` drops a stale one and
            // `renameItem` clears it, so a retained bookmark is by
            // construction current. A bookmark this store minted is good for
            // as long as the item's path is unchanged.
            if let existing = item.bookmarkData { return existing }
            if let minted = mintedBookmarks[item.id], minted.path == url.path {
                return minted.data
            }
            guard let fresh = bookmarkMaker(url) else { return item.bookmarkData }
            mintedBookmarks[item.id] = (url.path, fresh)
            return fresh
        }()
        return PersistedShelfItem(
            id: item.id,
            type: typeKey(item.type),
            bookmark: bookmark,
            path: item.type == .text ? nil : (item.fileURL?.path ?? item.persistedPath),
            text: item.textContent,
            createdAt: item.createdAt
        )
    }

    /// The two app-owned directories an ingest needs, as plain values a
    /// background task can hold. Everything about where an ingested file lands
    /// lives in `ManagedIngest`, which touches none of this object's mutable
    /// state — that is what makes a drop safe to run off the main thread.
    var ingestLocations: ManagedIngest.Locations {
        ManagedIngest.Locations(
            storeDirectory: storeURL.deletingLastPathComponent(),
            managedFilesDirectory: managedFilesDirectory
        )
    }

    /// The synchronous door, still used by every ingest that arrives one file
    /// at a time (clipboard, inbound link, a finished conversion or route).
    /// A drop goes through `ShelfManager.addFiles` instead, which runs the same
    /// code off the main thread with a cancel behind it.
    func prepareForIngest(_ sourceURL: URL) throws -> URL {
        try ManagedIngest.prepare(
            sourceURL,
            locations: ingestLocations,
            stagingURL: ManagedIngest.stagingURL(in: managedFilesDirectory)
        )
    }

    // MARK: - Load

    func load() -> ShelfStoreContents {
        isReadOnly = false
        isNewerSchema = false
        quarantinedURL = nil
        // Every early return below leaves this nil on purpose: no verdict is
        // safer than one carried over from before this load.
        overwriteVerdict = nil
        verdictStamp = nil
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return ShelfStoreContents(
                shelves: [], currentShelfID: nil, isAuthoritative: true, outcome: .healthy
            )
        }
        guard let data = try? Data(contentsOf: storeURL) else {
            isReadOnly = true
            return ShelfStoreContents(
                shelves: [], currentShelfID: nil, isAuthoritative: false, outcome: .unreadable
            )
        }
        let header = try? JSONDecoder().decode(PersistedStoreVersion.self, from: data)
        if let header, header.version > Self.currentVersion {
            isReadOnly = true
            isNewerSchema = true
        }
        guard let payload = try? JSONDecoder().decode(PersistedStore.self, from: data) else {
            if !isReadOnly { quarantineCorruptStore() }
            return ShelfStoreContents(
                shelves: [], currentShelfID: nil,
                isAuthoritative: false, outcome: failureOutcome()
            )
        }

        var resolvedShelves: [Shelf] = []
        var anyStale = false
        var hadUninterpretableRecord = false
        let fm = FileManager.default

        for shelfRecord in payload.shelves {
            var items: [ShelfItem] = []
            for record in shelfRecord.items {
                let url: URL
                let retainedBookmark: Data?
                if let bookmark = record.bookmark {
                    let resolution = bookmarkResolver(bookmark)
                    guard let resolvedURL = resolution.url else {
                        let type: ShelfItem.ItemType = (record.type == "image") ? .image : .file
                        items.append(ShelfItem(
                            id: record.id,
                            type: type,
                            bookmarkData: bookmark,
                            persistedPath: record.path,
                            createdAt: record.createdAt
                        ))
                        continue
                    }
                    url = resolvedURL
                    retainedBookmark = resolution.isStale ? nil : bookmark
                    if resolution.isStale { anyStale = true }
                } else if let path = record.path {
                    url = URL(fileURLWithPath: path)
                    retainedBookmark = nil
                } else if let text = record.text {
                    items.append(ShelfItem(
                        id: record.id,
                        type: .text,
                        fileURL: ShelfItem.writeTextToTemp(text),
                        textContent: text,
                        thumbnail: nil,
                        createdAt: record.createdAt
                    ))
                    continue
                } else {
                    hadUninterpretableRecord = true
                    continue
                }

                let availability = Self.fileAvailability(at: url, fileManager: fm)
                guard availability != .confirmedMissing else { continue }
                let type: ShelfItem.ItemType = (record.type == "image") ? .image : .file
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let pixelSize = (type == .image && availability.isReachable)
                    ? ShelfItem.readImagePixelSize(url: url) : nil
                let isPDF = url.pathExtension.lowercased() == "pdf"
                let pageCount = (isPDF && availability.isReachable)
                    ? ShelfItem.readPDFPageCount(url: url) : nil
                items.append(ShelfItem(
                    id: record.id,
                    type: type,
                    fileURL: url,
                    bookmarkData: retainedBookmark,
                    textContent: nil,
                    thumbnail: icon,
                    createdAt: record.createdAt,
                    pixelSize: pixelSize,
                    pageCount: pageCount,
                    isDirectory: availability.isDirectory
                ))
            }
            resolvedShelves.append(Shelf(
                id: shelfRecord.id,
                items: items,
                createdAt: shelfRecord.createdAt,
                name: shelfRecord.name,
                pinned: shelfRecord.pinned ?? false,
                accent: shelfRecord.accent
            ))
        }

        // Quarantine first, so the outcome below can name the file it left —
        // `isAuthoritative` is unaffected by the reorder, because the only case
        // that quarantines here already fails the `!hadUninterpretableRecord`
        // half of the condition.
        if hadUninterpretableRecord && !isReadOnly { quarantineCorruptStore() }
        let isAuthoritative = !isReadOnly && !hadUninterpretableRecord
        let contents = ShelfStoreContents(
            shelves: resolvedShelves,
            currentShelfID: payload.currentShelfID,
            isAuthoritative: isAuthoritative,
            outcome: isAuthoritative ? .healthy : failureOutcome()
        )

        if !isReadOnly && (anyStale || hadUninterpretableRecord) {
            save(shelves: resolvedShelves, currentShelfID: contents.currentShelfID)
        }

        // Load just answered the same question `save` asks, against the same
        // bytes. Recording it here is what stops the first save from reading
        // and decoding the file all over again.
        overwriteVerdict = !isReadOnly
        verdictStamp = Self.stamp(of: storeURL)

        return contents
    }

    enum FileAvailability: Equatable {
        case reachable(isDirectory: Bool)
        case confirmedMissing
        case unavailable

        var isReachable: Bool {
            if case .reachable = self { return true }
            return false
        }

        var isDirectory: Bool {
            if case .reachable(let isDirectory) = self { return isDirectory }
            return false
        }
    }

    static func fileAvailability(
        at url: URL,
        fileManager fm: FileManager = .default
    ) -> FileAvailability {
        do {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            return .reachable(isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory)
        } catch let error as NSError {
            let isMissing = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError
                    || error.code == NSFileReadNoSuchFileError)
            guard isMissing else { return .unavailable }
            do {
                _ = try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)
                return .confirmedMissing
            } catch {
                return .unavailable
            }
        }
    }

    private var canOverwriteStore: Bool {
        guard !isReadOnly else { return false }
        // Stamped before the inspection, never after: a file that changes
        // mid-inspection then leaves a verdict attributed to the older
        // fingerprint, which costs one redundant inspection instead of
        // caching an answer that was decided on bytes that are already gone.
        let stamp = Self.stamp(of: storeURL)
        if let overwriteVerdict, stamp == verdictStamp { return overwriteVerdict }
        let verdict = inspectStoreForOverwrite()
        overwriteVerdict = verdict
        verdictStamp = stamp
        return verdict
    }

    /// A store this build cannot interpret — a newer schema, or bytes that no
    /// longer decode — is never overwritten. Unchanged; only how often it runs
    /// changed.
    private func inspectStoreForOverwrite() -> Bool {
        storeInspectionCount += 1
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return true }
        guard let data = try? Data(contentsOf: storeURL),
              let header = try? JSONDecoder().decode(PersistedStoreVersion.self, from: data),
              header.version <= Self.currentVersion,
              (try? JSONDecoder().decode(PersistedStore.self, from: data)) != nil
        else { return false }
        return true
    }

    /// Deliberately `attributesOfItem` and not `URL.resourceValues`: NSURL
    /// caches resource values on the URL object, and `storeURL` is a stored
    /// property, so the second read would hand back the first read's answer
    /// and every store would look unchanged forever.
    private static func stamp(of url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return FileStamp(size: size.int64Value, modified: modified)
    }

    /// What to tell the user about a load that produced nothing it could trust.
    /// Ordered by what the user can act on: bytes they can still get at, a store
    /// a newer Magpie owns, or a file this build simply could not read.
    private func failureOutcome() -> LoadOutcome {
        if let quarantinedURL { return .quarantined(preservedAt: quarantinedURL) }
        if isNewerSchema { return .readOnlyNewerSchema }
        return .unreadable
    }

    private func quarantineCorruptStore() {
        let fm = FileManager.default
        let stem = storeURL.deletingPathExtension().lastPathComponent
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let preferred = storeURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).corrupt-\(timestamp).json")
        let backupURL = UniqueDestination.url(preferred: preferred, fileManager: fm)
        do {
            try fm.moveItem(at: storeURL, to: backupURL)
            quarantinedURL = backupURL
        } catch {
            isReadOnly = true
            NSLog("Shelf: failed to preserve corrupt store — \(error)")
        }
    }

    private static func makeBookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolveBookmark(_ bookmark: Data) -> BookmarkResolution {
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = candidate.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        let rootComponents = root.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }

    private func typeKey(_ type: ShelfItem.ItemType) -> String {
        switch type {
        case .file: return "file"
        case .image: return "image"
        case .text: return "text"
        }
    }
}

/// Decides whether a load outcome has already been said out loud.
///
/// Without this the app becomes a nag. `.readOnlyNewerSchema` is a *permanent*
/// state — the store on disk stays newer until the user installs the newer
/// build or deletes their data, so an unconditional launch alert would fire at
/// every single login forever. A quarantine is a one-shot event, but a second,
/// different quarantine months later is genuinely new and has to speak again.
///
/// So what is remembered is not "we warned once" but *which* event was
/// reported. A healthy load forgets, so the next real failure is heard.
enum StoreOutcomeNotice {
    static let defaultsKey = "shelf.store.lastReportedOutcome"

    /// What identifies one event. Quarantine is identified by the file it left
    /// behind, so a different one is a different event; the other two are
    /// single states and identify themselves.
    static func signature(for outcome: ShelfStore.LoadOutcome) -> String? {
        switch outcome {
        case .healthy:
            return nil
        case .quarantined(let url):
            return "quarantined:\(url.lastPathComponent)"
        case .readOnlyNewerSchema, .unreadable:
            return outcome.key
        }
    }

    /// Pure, so the nag case is testable without launching anything.
    static func shouldPresent(_ outcome: ShelfStore.LoadOutcome, lastReported: String?) -> Bool {
        guard let signature = signature(for: outcome) else { return false }
        return signature != lastReported
    }
}
