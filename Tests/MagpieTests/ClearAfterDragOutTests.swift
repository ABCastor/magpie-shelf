import AppKit
import Combine
import XCTest
@testable import Magpie

/// "Clear the shelf after dragging out" — off unless the user switches it on.
///
/// The case it serves: a file goes to the Desktop only so it can be attached to
/// an email, and the shelf it came from is litter a minute later. The case it
/// must not break: a shelf you drag *from* repeatedly, which is why the default
/// is off and why an abandoned drag has to leave everything exactly as it was.
@MainActor
final class ClearAfterDragOutTests: XCTestCase {
    private var tempDir: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearAfterDragOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The decision

    /// The whole point of the preference, and the whole of the risk. Written as
    /// a table because the interesting cases are the ones that must answer
    /// *no*, and a table is where a missing row is visible.
    func test_when_a_finished_drag_clears_the_shelf() {
        // Switched on, a destination took it: the shelf clears.
        XCTAssertTrue(
            DragOutcome.clearsShelfAfterDrag(intent: .copy, accepted: true, enabled: true)
        )
        // Switched off: nothing changes, whatever happened.
        XCTAssertFalse(
            DragOutcome.clearsShelfAfterDrag(intent: .copy, accepted: true, enabled: false),
            "the shelf cleared itself with the preference off — this is the default, and it must be inert"
        )
        // Abandoned or refused. This is the guard against losing a shelf to a
        // fumbled drag, and it is the assertion worth keeping if all others go.
        XCTAssertFalse(
            DragOutcome.clearsShelfAfterDrag(intent: .copy, accepted: false, enabled: true),
            "a drag nobody accepted emptied the shelf — a slip of the hand must not cost the pile"
        )
        // A ⌘-move owns its own removal, and only once the destination has
        // confirmed (ADR 0011). Clearing here as well would drop the card
        // before that evidence exists.
        XCTAssertFalse(
            DragOutcome.clearsShelfAfterDrag(intent: .move, accepted: true, enabled: true),
            "the preference pre-empted a ⌘-move — the card would leave before the move is verified"
        )
        XCTAssertFalse(
            DragOutcome.clearsShelfAfterDrag(intent: .move, accepted: false, enabled: true)
        )
    }

    // MARK: - The effect

    private func makeManager() -> (ShelfManager, UUID) {
        let manager = ShelfManager(store: ShelfStore(
            storeURL: tempDir.appendingPathComponent("shelf-\(UUID().uuidString).json")
        ))
        return (manager, manager.shelves.first!.id)
    }

    private func addFile(_ name: String, to shelfID: UUID, in manager: ShelfManager) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        _ = try XCTUnwrap(manager.addFile(url: url, to: shelfID))
        return url
    }

    /// Dragging out one of several: that card goes, the shelf stays open
    /// because there is still something on it, and **the file is untouched**.
    /// The last clause is the one that matters — this preference empties a
    /// shelf, it does not delete anything.
    func test_clearing_takes_the_card_and_never_the_file() throws {
        let (manager, shelfID) = makeManager()
        let dragged = try addFile("dragged.txt", to: shelfID, in: manager)
        _ = try addFile("stays.txt", to: shelfID, in: manager)

        var closed: [UUID] = []
        manager.closeRequested.sink { closed.append($0) }.store(in: &cancellables)

        manager.removeItemsAfterDragOut(
            withFileURLs: [dragged], from: shelfID, closeWhenEmpty: true
        )

        XCTAssertEqual(manager.items(of: shelfID).count, 1, "the wrong number of cards left")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dragged.path),
            "the preference deleted the user's file — it may only drop the shelf's reference to it"
        )
        XCTAssertEqual(
            closed, [],
            "a shelf that still holds a card asked to be closed"
        )
    }

    /// The behaviour the owner described: drag the last thing out and the shelf
    /// goes away. The request is published rather than performed. The manager has
    /// never known about windows.
    func test_a_shelf_emptied_by_the_drag_asks_to_close() throws {
        let (manager, shelfID) = makeManager()
        let only = try addFile("only.txt", to: shelfID, in: manager)

        var closed: [UUID] = []
        manager.closeRequested.sink { closed.append($0) }.store(in: &cancellables)

        manager.removeItemsAfterDragOut(
            withFileURLs: [only], from: shelfID, closeWhenEmpty: true
        )

        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
        XCTAssertEqual(closed, [shelfID], "the emptied shelf did not ask to close")
    }

    /// With the preference off, an emptied shelf stays. A ⌘-move that takes the
    /// last card out leaves a shelf standing there on purpose: the user may be
    /// about to drop something else on it, and that has always been the
    /// behaviour.
    func test_with_the_preference_off_an_emptied_shelf_stays_open() throws {
        let (manager, shelfID) = makeManager()
        let only = try addFile("only.txt", to: shelfID, in: manager)

        var closed: [UUID] = []
        manager.closeRequested.sink { closed.append($0) }.store(in: &cancellables)

        manager.removeItemsAfterDragOut(
            withFileURLs: [only], from: shelfID, closeWhenEmpty: false
        )

        XCTAssertTrue(manager.items(of: shelfID).isEmpty)
        XCTAssertEqual(
            closed, [],
            "the shelf closed itself with the preference off — this is the shipped default and it must not change"
        )
    }

    // MARK: - The wiring

    /// The preference key must stay out of `DefaultPreferences`. Registering it
    /// would make the unset key read *true* and switch a shelf-emptying
    /// behaviour on for everyone who never asked for it — the same trap the
    /// file's own doc comment records for `shelf.agentSend.autoPaste`.
    func test_the_key_is_not_registered_so_absent_means_off() {
        XCTAssertNil(
            DefaultPreferences.values["shelf.clearAfterDragOut"],
            "the preference was registered — an unset key must read false, which is the default being off"
        )
        let defaults = UserDefaults(suiteName: "clear-after-drag-\(UUID().uuidString)")!
        DefaultPreferences.register(into: defaults)
        XCTAssertFalse(defaults.bool(forKey: "shelf.clearAfterDragOut"))
    }

    /// The drag source must consult the preference at all. Without this the
    /// decision function above is correct and never called — which is exactly
    /// how this repo once shipped a shortcut that was dead for a release.
    func test_the_drag_source_consults_the_preference_and_the_decision() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfDragSource.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("DragOutcome.clearsShelfAfterDrag("),
            "the drag source stopped asking whether to clear — the preference is now inert"
        )
        XCTAssertTrue(
            source.contains("shelf.clearAfterDragOut"),
            "the drag source no longer reads the preference key"
        )
    }
}
