import Foundation

/// The global Copy For Chat command has no focused Magpie surface to supply a
/// selection. Its subject is therefore the resolved shelf, not a hidden pick
/// left behind by a collapsed strip.
@MainActor
enum ShelfChatCopy {
    /// Resolve the global command to the whole shelf. A narrowed strip may
    /// still be visible in another panel, but its selection is view-local and
    /// cannot safely become the meaning of a hotkey fired from a chat window.
    static func items(for manager: ShelfManager, shelfID: UUID) -> [ShelfItem] {
        manager.items(of: shelfID)
    }
}
