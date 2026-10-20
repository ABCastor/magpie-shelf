import AppKit
import XCTest
@testable import Magpie

/// ⌫ is the one new key that could break ADR 0001, and it is the key most
/// likely to be "improved" later into the thing the ADR forbids: Finder trains
/// everyone that Delete on a file means Move to Trash, and this app's entire
/// file-safety invariant exists because two review rounds found paths that
/// deleted a real user file.
///
/// So the invariant is pinned twice. Once behaviourally, on the exact function
/// the key runs, with a real file on disk; and once by reading the sources,
/// because a future rewrite that reaches for `FileManager` would pass any
/// behavioural test written against today's implementation.
final class ShelfKeyboardInvariantTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfKeyboardInvariant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { ShelfTrash.recycleForTesting = nil }
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    private func makeManager() -> ShelfManager {
        ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf-\(UUID().uuidString).json")
        ))
    }

    @MainActor
    func test_delete_takes_the_row_and_leaves_the_file_exactly_where_it_was() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("precious.txt")
        try Data("do not delete me".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))

        ShelfKeyboardRemove.removeFromShelf(items: [item], in: shelfID, manager: manager)

        XCTAssertTrue(manager.items(of: shelfID).isEmpty, "the row should be gone")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "⌫ removed the user's file from disk — ADR 0001 forbids exactly this"
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "do not delete me",
            "the file was left in place but not left intact"
        )
    }

    @MainActor
    func test_delete_leaves_every_file_of_a_multi_selection_on_disk() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let urls = try (0..<4).map { index -> URL in
            let url = tempDir.appendingPathComponent("keep-\(index).txt")
            try Data("keep".utf8).write(to: url)
            return url
        }
        let items = try urls.map { try XCTUnwrap(manager.addFile(url: $0, to: shelfID)) }

        ShelfKeyboardRemove.removeFromShelf(items: items, in: shelfID, manager: manager)

        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
        for url in urls {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "⌫ deleted \(url.lastPathComponent) from disk"
            )
        }
    }

    /// `ShelfManager.removeItem` deliberately captures nothing, so the pointer
    /// routes through it keep behaving as they did. The keyboard path is the one
    /// that has to leave a way back, because a key that makes cards vanish with
    /// no undo behind it is the same key Finder uses to trash things.
    @MainActor
    func test_delete_is_undoable_and_the_undo_puts_the_rows_back() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("undo-me.txt")
        try Data("undo".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))

        ShelfKeyboardRemove.removeFromShelf(items: [item], in: shelfID, manager: manager)
        XCTAssertTrue(manager.canUndo, "⌫ left nothing for ⌘Z to reverse")

        manager.performUndo()

        XCTAssertEqual(manager.items(of: shelfID).map(\.id), [item.id])
        XCTAssertFalse(manager.canUndo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// The undo title is the only thing telling the user what ⌘Z is about to
    /// reverse. "Undo Move to Trash" on a key that never went near the Trash
    /// would be a lie about the one operation this app is careful with.
    @MainActor
    func test_the_undo_title_says_removal_and_not_trash() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let item = ShelfItem(type: .text, textContent: "snippet")
        manager.addItem(item, to: shelfID)

        ShelfKeyboardRemove.removeFromShelf(items: [item], in: shelfID, manager: manager)

        XCTAssertEqual(manager.undoSnapshot?.menuTitle, L("undo.remove-from-shelf"))
    }

    @MainActor
    func test_removing_nothing_does_not_clobber_an_earlier_undo() throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        manager.addItem(ShelfItem(type: .text, textContent: "kept"), to: shelfID)
        manager.clear(shelfID: shelfID)
        let before = manager.undoSnapshot?.menuTitle

        ShelfKeyboardRemove.removeFromShelf(items: [], in: shelfID, manager: manager)

        XCTAssertEqual(manager.undoSnapshot?.menuTitle, before)
    }

    // MARK: - The source-level half

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie")
    }

    /// The same shape as `RouteTriggerInvariantTests`: the property is about
    /// what the keyboard path is allowed to call, and no runtime assertion can
    /// reach a call that has not been written yet.
    func test_no_file_on_the_keyboard_path_can_touch_a_file_on_disk() throws {
        let forbidden = [
            "removeItem(at:",
            "removeItem(atPath:",
            "trashItem",
            "recycle",
            "moveItem(at:",
            "replaceItemAt",
            "unlink(",
            "createFile(",
        ]
        for name in ["ShelfKeyboard.swift", "ShelfActionPalette.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8
            )
            for call in forbidden {
                XCTAssertFalse(
                    text.contains(call),
                    "\(name) reached for \(call) — the keyboard path may never touch a user file (ADR 0001)"
                )
            }
        }
    }

    /// ⌘⌫ is Finder's Move to Trash, and it is bound (ADR 0017, reversing the
    /// earlier decision to leave it unbound). What is pinned here is the shape
    /// of the reversal, because the earlier reasoning was not wrong about the
    /// risk — ⌘⌫ really does sit one thumb-slip from plain ⌫, the most
    /// frequent key in this app. It is acceptable only because the slip is
    /// recoverable twice over: the file goes to the Bin rather than being
    /// deleted, and ⌘Z takes it back out. Both halves are asserted below.
    ///
    /// ⇧ stays unbound: in Finder that is Empty Bin, the one neighbouring
    /// gesture whose real-world meaning is not recoverable.
    func test_command_delete_means_move_to_bin_and_shift_stays_unbound() {
        XCTAssertEqual(
            ShelfKey.command(keyCode: ShelfKey.Code.delete, modifiers: .command),
            .moveToTrash
        )
        XCTAssertEqual(
            ShelfKey.command(keyCode: ShelfKey.Code.forwardDelete, modifiers: .command),
            .moveToTrash
        )
        XCTAssertNil(
            ShelfKey.command(keyCode: ShelfKey.Code.delete, modifiers: [.command, .shift]),
            "⌘⇧⌫ is Finder's Empty Bin — the one thing near this key that no undo could reverse"
        )
        XCTAssertEqual(
            ShelfKey.command(keyCode: ShelfKey.Code.delete, modifiers: []),
            .removeFromShelf,
            "plain ⌫ stopped meaning the harmless thing — the whole risk calculation above depends on it"
        )
    }

    /// The state the key is actually wanted in.
    ///
    /// A shelf spends most of its life as a collapsed pill: a file dropped on
    /// the desktop, used, and then unwanted is looked at as a strip, never as
    /// an expanded panel. A Move to Bin that only answered when expanded would
    /// be a dead key — which this repo has shipped once already, for a whole
    /// release, and is the reason `isCollapsedStripCommand` is exhaustive.
    func test_the_collapsed_strip_answers_command_delete() {
        XCTAssertTrue(
            ShelfKey.isCollapsedStripCommand(.moveToTrash, hasNarrowedSelection: false),
            "⌘⌫ is dead on a resting strip — the state a shelf is usually in"
        )
        XCTAssertTrue(
            ShelfKey.isCollapsedStripCommand(.moveToTrash, hasNarrowedSelection: true)
        )
    }

    /// The recoverability the reversal rests on, measured rather than argued:
    /// the file is somewhere retrievable and not gone, the row leaves with it,
    /// and ⌘Z puts both back.
    @MainActor
    func test_command_delete_puts_the_file_in_the_bin_and_undo_brings_it_back() async throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("binned.txt")
        try Data("recoverable".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))

        // Stands in for the real Bin: the point of the assertion is that the
        // bytes went somewhere they can be fetched back from, which is exactly
        // what `NSWorkspace.recycle` promises and `unlink` does not.
        let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        ShelfTrash.recycleForTesting = { urls, completion in
            var moved: [URL: URL] = [:]
            for url in urls {
                let destination = bin.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.moveItem(at: url, to: destination)
                moved[url] = destination
            }
            completion(moved, nil)
        }

        ShelfTrash.move(items: [item], in: shelfID, manager: manager)
        await drainMainActor()

        XCTAssertTrue(manager.items(of: shelfID).isEmpty, "the row outlived the file")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "⌘⌫ left the file where it was — it is supposed to move it"
        )
        let binned = bin.appendingPathComponent("binned.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: binned.path),
            "the file is not in the Bin either — it was destroyed, which ADR 0001 forbids"
        )
        XCTAssertEqual(try String(contentsOf: binned, encoding: .utf8), "recoverable")

        XCTAssertTrue(manager.canUndo, "⌘⌫ left nothing for ⌘Z to reverse")
        manager.performUndo()
        await drainMainActor()

        XCTAssertEqual(manager.items(of: shelfID).map(\.id), [item.id], "undo did not restore the row")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "undo restored the row but not the file — the row now points at nothing"
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "recoverable")
    }

    /// A text snippet has no file behind it, so there is nothing to move; only
    /// the row goes, and ⌘Z must not offer to undo a Bin trip that never
    /// happened. Without this, the same key means two things and says one.
    @MainActor
    func test_command_delete_on_a_row_with_no_file_is_recorded_as_a_removal() async throws {
        let manager = makeManager()
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let item = ShelfItem(type: .text, textContent: "snippet")
        manager.addItem(item, to: shelfID)

        ShelfTrash.recycleForTesting = { _, _ in
            XCTFail("a row with no file on disk reached NSWorkspace.recycle")
        }

        ShelfTrash.move(items: [item], in: shelfID, manager: manager)
        await drainMainActor()

        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
        XCTAssertEqual(manager.undoSnapshot?.menuTitle, L("undo.remove-from-shelf"))
    }

    /// `ShelfTrash.move`'s completion hops back to the main actor through a
    /// `Task`, so state written there is not visible on the line after the call.
    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// **One door to the Bin.** Every shelf surface that offers Move to Bin —
    /// the shelf menu, an item's own menu, and now ⌘⌫ — goes through
    /// `ShelfTrash`, and only `ShelfTrash` names the call that does it.
    ///
    /// Two of those surfaces used to carry their own copy, and they had already
    /// drifted apart: one filtered to files that still existed on disk and the
    /// other did not. A third copy, written for a keystroke, is how ADR 0001
    /// gets broken by accident rather than by decision. This is the invariant
    /// that makes "where can this app move a user's file" answerable by reading
    /// one short file.
    ///
    /// `DragMove.swift` is excluded and is the only exclusion: ADR 0011 gives
    /// the ⌘-drag its own, separately argued path, with its own five
    /// preconditions and its own test that no other mutating call appears
    /// beside it.
    func test_only_ShelfTrash_puts_a_shelf_file_in_the_bin() throws {
        // Enumerated from disk, never listed: a named list silently stops
        // covering a file the moment someone adds or renames one, and the file
        // it stops covering is the new one nobody has reviewed yet.
        let files = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 40, "the source walk found almost nothing — it is not looking where it thinks")

        let permitted = ["ShelfTrash.swift", "DragMove.swift"]
        var callers: [String] = []
        for file in files where file.lastPathComponent.hasSuffix(".swift") {
            let text = try String(contentsOf: file, encoding: .utf8)
            // The open paren matters: without it this matches prose. Written
            // first without one, it caught `ShelfManager`'s doc comment about
            // the map `recycle` returns and called it a third door to the Bin.
            // A guard that reads comments is a guard that will one day be
            // silenced by editing a comment.
            if text.contains(".recycle(") {
                callers.append(file.lastPathComponent)
            }
        }

        XCTAssertEqual(
            Set(callers), Set(permitted),
            "the set of files that can move a user's file to the Bin changed. Expected exactly \(permitted) — ShelfTrash for every shelf surface, DragMove for the ⌘-drag that ADR 0011 argues separately. Found \(callers.sorted())"
        )
    }

    /// The removal the ⌫ handler performs must go through the one named
    /// function this file tests, not straight to `manager.removeItem` — which
    /// would silently drop the undo snapshot and route around the pin above.
    func test_the_key_handler_removes_through_the_pinned_function() throws {
        let view = try String(
            contentsOf: sources.appendingPathComponent("ShelfContainerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            view.contains("ShelfKeyboardRemove.removeFromShelf("),
            "the ⌫ handler stopped going through ShelfKeyboardRemove"
        )
    }
}
