import AppKit
import XCTest
@testable import Magpie

/// The global shortcut has no focused Magpie panel, so a strip selection must
/// not become a hidden global selection. The focused row menu has the opposite
/// contract and is checked separately below.
@MainActor
final class CopyForChatTests: XCTestCase {

    private var scratch: URL!
    private var manager: ShelfManager!
    private var firstShelf: UUID!
    private var secondShelf: UUID!

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("copy-for-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        manager = ShelfManager(
            store: ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        )
        firstShelf = try XCTUnwrap(manager.shelves.first?.id)
        secondShelf = manager.createShelf()
        for (shelfID, names) in [
            (firstShelf!, ["first-a.txt", "first-b.txt"]),
            (secondShelf!, ["second.txt"])
        ] {
            for name in names {
                let url = scratch.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                _ = manager.addFile(url: url, to: shelfID)
            }
        }
        manager.setCurrentShelf(id: firstShelf)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func test_global_copy_for_chat_ignores_a_narrowed_strip_even_with_another_shelf_open() throws {
        let firstItems = manager.items(of: firstShelf)
        manager.stripSelections[firstShelf] = [try XCTUnwrap(firstItems.first?.id)]
        var copiedItems: [ShelfItem] = []

        let delegate = AppDelegate(
            manager: manager,
            flushOnTermination: {},
            chatCopyWriter: { items in
                copiedItems = items
                return true
            }
        )
        delegate.copyShelfForChat()

        XCTAssertEqual(
            copiedItems.map(\.displayName),
            ["first-a.txt", "first-b.txt"],
            "Copy For Chat followed a hidden one-row strip selection instead of copying the whole resolved shelf while another shelf was open"
        )
        XCTAssertEqual(manager.shelvesWithNarrowedSelection, [firstShelf])
    }

    func test_focused_row_copy_uses_the_narrowed_menu_subject() throws {
        let items = manager.items(of: firstShelf)
        let picked = try XCTUnwrap(items.last)
        var copiedItems: [ShelfItem] = []
        let target = ShelfActionTargets(
            manager: manager,
            shelfID: firstShelf,
            selection: [picked.id],
            copyWriter: { copiedItems = $0; return true }
        )
        target.copyAll()

        XCTAssertEqual(
            copiedItems.map(\.displayName),
            ["first-b.txt"],
            "the focused Copy row ignored the header's narrowed subject and copied the whole shelf"
        )
    }
}
