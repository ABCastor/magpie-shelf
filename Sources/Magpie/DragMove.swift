import AppKit
import UniformTypeIdentifiers

/// Moving a file off the shelf, and the one narrow exception to ADR 0001 that
/// makes it possible. Measure against real Finder before changing anything here.
///
/// The short version, all of it measured against a real Finder window rather
/// than reasoned about:
///
/// - A destination can only perform a move if the drag session's operation mask
///   contains `.move` when the session is **set up**. AppKit latches that mask
///   as a ceiling; widening it mid-drag is ignored, which is why ⌘ pressed
///   *during* a drag never worked and never could.
/// - A mask containing `.move` also lets Finder move an **unmodified** drag.
///   There is therefore no mask that means "plain copies, ⌘ moves".
/// - `NSDraggingSource.ignoreModifierKeys` removes AppKit's modifier filter, so
///   a `.copy`-only mask stays `.copy` under every modifier. The destination
///   copies, and it can never move or delete the user's file.
///
/// So the destination always copies, Magpie reads ⌘ itself, and Magpie moves
/// its own source **to the Trash** once the copy is verified. Every step of
/// that verification is a pure function here, so the conditions can be pinned
/// by tests instead of trusted.

/// What Magpie is allowed to do with the source file once a drag has landed.
enum DragMoveDecision: Equatable {
    /// Every condition in ADR 0011 held: the source goes to the Trash.
    case trashSource
    /// Nothing happens, and this is why.
    case leaveAlone(DragMoveRefusal)
}

/// Why a ⌘-drag did not become a move. Each case is a condition that failed,
/// named so a test can say which one it broke.
enum DragMoveRefusal: Equatable {
    /// The user was not holding ⌘ when the drag ended. A plain drag copies and
    /// is never followed by anything.
    case notAMove
    /// No destination told us where the copy landed — it read the file URL off
    /// the pasteboard and copied from the original itself. Nothing to verify,
    /// so nothing to remove.
    case noDestination
    /// The source is already gone. Nothing to do, and nothing to report.
    case sourceGone
    /// The copy landed in a temporary or cache directory: an app's scratch
    /// space, not a place the user could go and find the file. Trashing the
    /// original against that copy would be losing the file with extra steps.
    case temporaryDestination
    /// The destination file is not there. Either the copy failed or the
    /// destination cleaned up after itself.
    case destinationMissing
    /// The destination exists but does not hold the same number of bytes. A
    /// partial write, an interrupted copy, or a different file entirely.
    case sizeMismatch
}

enum DragMovePolicy {

    /// The whole of ADR 0011's invariant, as one pure function.
    ///
    /// The order matters and is deliberate: the cheapest and most decisive
    /// refusals come first, and the two that read the filesystem come last, so
    /// a plain drag never stats anything.
    static func decide(
        intent: DragIntent,
        source: URL,
        destination: URL?,
        sizeOf: (URL) -> Int64?,
        isTemporary: (URL) -> Bool = isTemporaryLocation(_:)
    ) -> DragMoveDecision {
        guard intent == .move else { return .leaveAlone(.notAMove) }
        guard let destination else { return .leaveAlone(.noDestination) }
        guard !isTemporary(destination) else { return .leaveAlone(.temporaryDestination) }
        guard let sourceSize = sizeOf(source) else { return .leaveAlone(.sourceGone) }
        guard let destinationSize = sizeOf(destination) else {
            return .leaveAlone(.destinationMissing)
        }
        guard destinationSize == sourceSize else { return .leaveAlone(.sizeMismatch) }
        return .trashSource
    }

    /// One decision per dragged file, and **no term of one file's decision ever
    /// reaches another's.**
    ///
    /// A ⌘-drag of a multi-row selection is N independent moves: N promises,
    /// N destinations, N verifications. The hazard this exists to make
    /// impossible is a shared answer — one file's verified copy vouching for a
    /// sibling whose copy is truncated, missing, or in scratch space, and that
    /// sibling's original going to the Trash on the strength of it. Each entry
    /// is handed to `decide` on its own, which is a property of this function
    /// rather than of the loop that used to live in the drag source.
    static func decideEach(
        intent: DragIntent,
        files: [(source: URL, destination: URL?)],
        sizeOf: (URL) -> Int64?,
        isTemporary: (URL) -> Bool = isTemporaryLocation(_:)
    ) -> [DragMoveDecision] {
        files.map { file in
            decide(
                intent: intent,
                source: file.source,
                destination: file.destination,
                sizeOf: sizeOf,
                isTemporary: isTemporary
            )
        }
    }

    /// Whether a path is somewhere the user could not find the file again.
    ///
    /// A file promise is fulfilled wherever the *receiver* asks for it, and not
    /// every receiver is a folder. A compose window, a preview pane or an
    /// upload widget takes the bytes into its own scratch space and may delete
    /// them the moment it is done. Trashing the original against a copy in
    /// `/var/folders` would take a file out of the user's world entirely.
    ///
    /// Pure over the path string so it can be tested without a filesystem.
    static func isTemporaryLocation(_ url: URL) -> Bool {
        isTemporaryPath(url.standardizedFileURL.path)
    }

    static func isTemporaryPath(_ path: String) -> Bool {
        // `/private` is the real location of all four of these on macOS, and a
        // URL can name either spelling, so both are listed rather than resolved.
        let temporaryRoots = [
            "/tmp/", "/private/tmp/",
            "/var/tmp/", "/private/var/tmp/",
            "/var/folders/", "/private/var/folders/",
        ]
        if temporaryRoots.contains(where: { path.hasPrefix($0) }) { return true }
        // Caches are swept without warning, wherever they live — the user's
        // own Library, a sandboxed app's container, the system's.
        return path.contains("/Library/Caches/")
    }

    /// How many bytes something holds, whether it is a file or a folder.
    ///
    /// A folder can sit on the shelf and can be dragged off it, and
    /// `.fileSizeKey` is meaningless for one — so a folder is measured by
    /// summing what is inside it. Nil means "not there", which the decision
    /// above reads as a refusal, never as a zero.
    static func contentSize(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return fileSize(of: url) }
        guard let walker = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var total: Int64 = 0
        for case let child as URL in walker {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }
}

/// The only place in the app that removes a file it was handed by a drag, and
/// the only reason ADR 0011 could be written: it puts the source in the
/// **Trash**, never `unlink`. A wrong answer anywhere upstream costs the user
/// one trip to the Bin, not a file.
@MainActor
enum DragMoveExecutor {
    /// Set by tests so the recycle can be observed without a real Trash.
    static var recycleForTesting: ((URL) -> Void)?

    static func trashSource(at url: URL) {
        if let recycleForTesting {
            recycleForTesting(url)
            return
        }
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error {
                NSLog("Shelf: drag-move could not trash \(url.lastPathComponent) — \(error)")
            }
        }
    }
}

/// What a dragged file puts on the pasteboard.
///
/// **Both** the user's own file URL and a file promise, and the pairing is the
/// feature rather than an accident:
///
/// - The URL keeps every destination that reads `public.file-url` working
///   exactly as it did — browsers, upload zones, editors, and AppKit's own
///   free bridge to the legacy `NSFilenamesPboardType` flavour.
/// - The promise is the only way a destination ever tells Magpie *where* it
///   put the copy. That path is the evidence ADR 0011 requires before the
///   source may go to the Trash. Without it there is nothing to verify against
///   and the original is left alone.
///
/// ADR 0009 removed the promise because Magpie fulfilled it and then expected a
/// *destination* to have performed a move — a contradiction. The promise is not
/// the defect; believing the destination would move was. Measured: Finder takes
/// the promise from this pasteboard and hands back the destination URL, already
/// uniquified against a name collision, so the copy never overwrites anything.
final class ShelfFilePromiseProvider: NSFilePromiseProvider {
    let sourceURL: URL
    /// Where the receiver asked for the copy, once it has been written. Read on
    /// the main actor only, and only after `onFulfilled` has fired.
    private(set) var fulfilledDestination: URL?
    /// Set by the drag source so the end of a drag can be re-judged the moment
    /// a promise completes — a receiver can finish writing after the session
    /// has already ended.
    var onFulfilled: (() -> Void)?
    /// Guards against acting twice on one drag.
    var consumed = false

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        super.init()
        fileType = UTType(filenameExtension: sourceURL.pathExtension)?.identifier
            ?? UTType.data.identifier
        delegate = ShelfFilePromiseDelegate.shared
    }

    /// The file URL comes after the promise types, but the order is not what
    /// decides: measured on a real pasteboard, `readObjects(forClasses:)`
    /// resolves in the **reader's** class order. Both flavours are offered and
    /// the destination takes whichever it prefers.
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.fileURL]
    }

    override func pasteboardPropertyList(
        forType type: NSPasteboard.PasteboardType
    ) -> Any? {
        guard type == .fileURL else {
            return super.pasteboardPropertyList(forType: type)
        }
        return (sourceURL as NSURL).pasteboardPropertyList(forType: .fileURL)
    }

    func recordFulfilment(at url: URL) {
        fulfilledDestination = url
        onFulfilled?()
    }
}

/// Fulfils the promise by copying — never moving, never replacing.
///
/// `copyItem` is the only mutating call in this file's write path and it
/// **fails** if something is already at the destination, so it cannot overwrite
/// a file Magpie does not manage (ADR 0001 §1). In practice it never has to:
/// the receiver uniquifies the name before asking, which is how a second drop
/// of `report.pdf` arrives as `report 2.pdf`.
final class ShelfFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = ShelfFilePromiseDelegate()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider as? ShelfFilePromiseProvider)?.sourceURL.lastPathComponent
            ?? L("shelf.default-name")
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let provider = filePromiseProvider as? ShelfFilePromiseProvider else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            try FileManager.default.copyItem(at: provider.sourceURL, to: url)
            Task { @MainActor in provider.recordFulfilment(at: url) }
            completionHandler(nil)
        } catch {
            NSLog("Shelf: drag-out promise write failed — \(error)")
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}
