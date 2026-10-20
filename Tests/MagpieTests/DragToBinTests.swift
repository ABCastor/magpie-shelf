import AppKit
import XCTest
@testable import Magpie

/// Dragging a card onto the Dock's Bin puts the file in the Bin.
///
/// This is the one place in the app where a **reported** `NSDragOperation`
/// decides something, and ADR 0011 says in as many words that trusting a
/// reported operation is "the wrong thing to start trusting in the one place
/// that deletes". The carve-out is argued in ADR 0018 and rests on two facts
/// that are pinned here: `.delete` is a request addressed to the source rather
/// than a claim about the destination, and the worst case is bounded by
/// `ShelfTrash` recycling instead of deleting.
@MainActor
final class DragToBinTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragToBin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ShelfTrash.recycleForTesting = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The measured truth table, as assertions. Raw values are spelled out
    /// because the whole decision rests on `delete` (32) not being reachable
    /// from the offered mask (`.copy`, 1): `32 & 1 == 0`.
    func test_only_a_delete_operation_bins_the_source() {
        XCTAssertTrue(DragOutcome.binsSourceAfterDrag(operation: .delete))
        XCTAssertEqual(NSDragOperation.delete.rawValue, 32)
        XCTAssertEqual(DragModePolicy.sourceMask.rawValue, 1)
        XCTAssertEqual(
            NSDragOperation.delete.rawValue & DragModePolicy.sourceMask.rawValue, 0,
            "delete became reachable from the offered mask, so it is no longer a signal distinct from what we offered"
        )

        // Everything the probe measured at a destination that is not the Bin.
        XCTAssertFalse(
            DragOutcome.binsSourceAfterDrag(operation: .copy),
            "a Finder window's copy would bin the user's file"
        )
        XCTAssertFalse(
            DragOutcome.binsSourceAfterDrag(operation: .move),
            "a reported move would bin the user's file, and a move is exactly what an unverifiable destination over-reports"
        )
        XCTAssertFalse(
            DragOutcome.binsSourceAfterDrag(operation: []),
            "an abandoned drag would bin the user's file"
        )
        XCTAssertFalse(DragOutcome.binsSourceAfterDrag(operation: .generic))
        XCTAssertFalse(DragOutcome.binsSourceAfterDrag(operation: .link))
        XCTAssertFalse(DragOutcome.binsSourceAfterDrag(operation: [.copy, .move, .generic, .link]))
    }

    /// The notice the owner actually saw. It said the destination had copied
    /// the owner's file; the Bin had not copied anything, and now the drop does
    /// something, so there is nothing left to explain.
    func test_a_bin_drop_never_shows_the_copied_instead_notice() {
        XCTAssertNil(
            DragOutcome.copyInsteadNotice(
                intent: .move, accepted: true, survivingCount: 1, operation: .delete
            ),
            "the Bin drop still claims the destination copied the file"
        )
        // And the notice it exists for is untouched: a destination that took
        // the file URL, copied from the original, and left it sitting there.
        XCTAssertEqual(
            DragOutcome.copyInsteadNotice(
                intent: .move, accepted: true, survivingCount: 1, operation: .copy
            ),
            .copiedInstead(count: 1)
        )
    }

    /// No modifier is required and none can be: the Bin reports `delete`
    /// identically with ⌘, without it, and with ⌘ held before the drag starts,
    /// because `ignoreModifierKeys` is true and AppKit applies no filter. The
    /// decision therefore takes no intent at all, and this pins that shape —
    /// adding one back would make a plain drag to the Bin silently do nothing.
    func test_the_decision_does_not_depend_on_the_modifier() {
        // Same operation, and there is no intent parameter to vary. If someone
        // adds one, this file stops compiling, which is the intended alarm.
        let binned = DragOutcome.binsSourceAfterDrag(operation: .delete)
        XCTAssertTrue(binned)
        XCTAssertEqual(
            DragModePolicy.intent(modifiers: []), .copy,
            "a plain drag stopped being a copy, so the Bin drop is now reading a different gesture than the one measured"
        )
        XCTAssertEqual(DragModePolicy.intent(modifiers: .command), .move)
    }

    /// End to end through the real path: the file goes somewhere retrievable,
    /// the row leaves with it, and ⌘Z brings both back. This is the entire
    /// safety argument for letting a plain drag do it.
    func test_a_binned_drop_is_recoverable_by_undo() async throws {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf.json")
        ))
        let shelfID = try XCTUnwrap(manager.shelves.first?.id)
        let fileURL = tempDir.appendingPathComponent("dropped-on-the-bin.txt")
        try Data("recoverable".utf8).write(to: fileURL)
        let item = try XCTUnwrap(manager.addFile(url: fileURL, to: shelfID))

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
        for _ in 0..<8 { await Task.yield() }

        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bin.appendingPathComponent("dropped-on-the-bin.txt").path),
            "the file was destroyed rather than binned — the whole argument for allowing a plain drag to do this"
        )

        XCTAssertTrue(manager.canUndo)
        manager.performUndo()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(manager.items(of: shelfID).map(\.id), [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Wiring. The decision above is correct and inert unless the drag source
    /// asks it, and unless the app answers the hook — the failure this repo has
    /// already shipped once, as a shortcut that was dead for a whole release.
    func test_the_bin_drop_is_wired_from_the_drag_source_to_the_app() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Magpie")
        let drag = try String(
            contentsOf: sources.appendingPathComponent("ShelfDragSource.swift"), encoding: .utf8
        )
        let app = try String(
            contentsOf: sources.appendingPathComponent("App.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            drag.contains("DragOutcome.binsSourceAfterDrag(operation: operation)"),
            "the drag source never asks whether the drop was on the Bin"
        )
        XCTAssertTrue(
            drag.contains("DragBin.handler?(draggedURLs, window)"),
            "the drag source recognises the Bin drop and tells nobody"
        )
        XCTAssertTrue(
            app.contains("DragBin.handler = "),
            "nothing answers the Bin hook, so every drop on the Bin is silently dropped"
        )
        XCTAssertTrue(
            app.contains("ShelfTrash.move(items: items, in: shelfID, manager: manager)"),
            "the Bin drop stopped going through ShelfTrash, which is what makes it undoable"
        )
    }
}
