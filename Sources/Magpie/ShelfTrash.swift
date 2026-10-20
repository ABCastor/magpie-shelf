import AppKit
import Foundation

/// The one place a shelf action puts a user's file in the Bin.
///
/// Three surfaces reach for it — the shelf menu, an item's own menu, and ⌘⌫ —
/// and two of them used to carry their own copy of the recycle. A third copy,
/// written on the only path in this app that touches a file the user owns, is
/// how ADR 0001 gets broken by accident rather than by decision: copies drift,
/// and the one that drifts is the one nobody re-read. `NSWorkspace.recycle`
/// now appears in exactly one shelf action, so the invariant is checkable by
/// reading one short file.
///
/// **One rule, and it covers every item:** if there is a file on disk, it goes
/// to the Bin and its row goes with it; if there is not — a pasted text
/// snippet, or a row whose file someone already deleted from Finder — only the
/// row goes, recorded as a removal so ⌘Z reads *Undo Remove from Shelf* rather
/// than naming a Bin trip that never happened.
///
/// Recoverable at both ends, which is what makes it safe enough to put on a
/// keystroke: the file is in the Bin rather than unlinked, and `⌘Z` moves it
/// back out to where it was (`ShelfManager.performUndo`).
@MainActor
enum ShelfTrash {
    /// Set by tests so the recycle can be observed without a real Bin.
    /// The shape mirrors `NSWorkspace.recycle`'s completion: the map is
    /// original URL → the URL inside the Bin, which is what undo restores from.
    static var recycleForTesting: (([URL], @escaping ([URL: URL], Error?) -> Void) -> Void)?

    static func move(items: [ShelfItem], in shelfID: UUID, manager: ShelfManager) {
        let onDisk = items.filter { item in
            guard let url = item.fileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        let rowOnly = items.filter { item in
            guard let url = item.fileURL else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }

        guard !onDisk.isEmpty else {
            ShelfKeyboardRemove.removeFromShelf(items: rowOnly, in: shelfID, manager: manager)
            return
        }

        let urls = onDisk.compactMap(\.fileURL)
        let recycle = recycleForTesting ?? { urls, completion in
            NSWorkspace.shared.recycle(urls) { trashed, error in
                completion(trashed, error)
            }
        }

        recycle(urls) { trashed, error in
            Task { @MainActor in
                // The rows with nothing on disk behind them leave in their own
                // right, whatever the recycle did — their fate never depended
                // on it.
                if !rowOnly.isEmpty {
                    ShelfKeyboardRemove.removeFromShelf(
                        items: rowOnly, in: shelfID, manager: manager
                    )
                }
                if let failure = manager.finishMoveToTrash(
                    items: onDisk,
                    trashedURLs: trashed,
                    error: error,
                    in: shelfID
                ) {
                    presentTrashError(failure)
                }
            }
        }
    }
}
