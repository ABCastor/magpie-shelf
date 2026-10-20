import AppKit
import XCTest
@testable import Magpie

/// Dragging a card out of the shelf could not move a file. It was impossible by
/// construction: every dragging item wrapped an `NSFilePromiseProvider`, and a
/// promise can only ever be *fulfilled* — Magpie copied the bytes into the
/// destination itself and the original never went anywhere, whatever the user
/// held down. Four drags of one file put four copies on the Desktop.
///
/// These tests pin the two halves of the repair: what a destination can read
/// off the pasteboard, and what the source is willing to let it do.
/// Source with every comment removed. These guards are about what the code
/// *does*; a prose line naming a banned call is a false red, and having to
/// avoid the word in a comment would stop the file explaining itself.
func magpieCodeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("//") { return "" }
            if let comment = line.range(of: "  // ") { return line[line.startIndex..<comment.lowerBound] }
            return line
        }
        .joined(separator: "\n")
}

final class DragPasteboardTests: XCTestCase {
    private var tempDir: URL!
    private var boards: [NSPasteboard] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragPasteboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for board in boards { board.releaseGlobally() }
        boards = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A private pasteboard carrying exactly what one dragged file would put on
    /// the drag pasteboard. Not the real drag pasteboard: a drag cannot be
    /// started without a live tracking loop, but the writer it is built from is
    /// the same object, so what a destination could read is the same question.
    private func board(for url: URL) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("MagpieDragTest-\(UUID().uuidString)"))
        boards.append(board)
        board.clearContents()
        board.writeObjects([ShelfDragPasteboard.writer(for: url)])
        return board
    }

    private func sampleFile() throws -> URL {
        let url = tempDir.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: url)
        return url
    }

    // MARK: - What the destination sees

    /// The destination has to receive the user's own file, at its own path. A
    /// path that is not the original is a copy Magpie manufactured, and no
    /// destination can move a file it was never given.
    func test_the_destination_receives_the_original_file_url() throws {
        let url = try sampleFile()
        let read = board(for: url).readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]

        XCTAssertEqual(
            read?.map(\.standardizedFileURL), [url.standardizedFileURL],
            "the drag does not hand the destination the original file, so nothing it does can move it"
        )
    }

    /// The promise is back, and this is the assertion that says so on purpose.
    ///
    /// ADR 0009 deleted it and `test_no_destination_can_take_a_file_promise`
    /// stood here guarding its absence. ADR 0011 reverses that, because the
    /// promise is the *only* way a destination ever tells Magpie where it put
    /// the copy — and that path is the evidence required before the original
    /// may go to the Trash. Without a promise there is no verified move, only a
    /// hopeful one.
    func test_the_pasteboard_offers_a_file_promise() throws {
        let url = try sampleFile()
        let board = board(for: url)

        XCTAssertTrue(
            board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil),
            "no promise on the drag pasteboard, so no destination can ever tell Magpie where the copy landed and a ⌘-move can never be verified"
        )
    }

    /// `public.file-url` is what browsers and web upload zones read, and the
    /// README sells dragging out to them as a headline feature.
    func test_the_pasteboard_carries_public_file_url() throws {
        let url = try sampleFile()
        let types = try XCTUnwrap(board(for: url).pasteboardItems?.first?.types)

        XCTAssertTrue(
            types.contains(.fileURL),
            "the dragged item no longer offers public.file-url — a browser upload zone reads that flavour and nothing else"
        )
    }

    /// The legacy filenames flavour, which older drop targets and several
    /// browser engines still ask for, comes free from AppKit's own bridging of
    /// `public.file-url`. Asserted because it is load-bearing and invisible:
    /// nothing in Magpie writes it.
    func test_legacy_filename_readers_still_get_the_original_path() throws {
        let url = try sampleFile()
        let filenames = board(for: url).propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String]

        XCTAssertEqual(
            filenames, [url.path],
            "a destination reading the legacy filenames flavour gets nothing from this drag"
        )
    }

}

/// What the shelf permits, and what the modifier keys mean.
final class DragModePolicyTests: XCTestCase {

    // MARK: - The modifier contract

    func test_a_plain_drag_is_a_copy() {
        XCTAssertEqual(DragModePolicy.intent(modifiers: []), .copy)
    }

    func test_command_asks_for_a_move() {
        XCTAssertEqual(DragModePolicy.intent(modifiers: .command), .move)
    }

    func test_option_is_a_copy_and_beats_command() {
        XCTAssertEqual(DragModePolicy.intent(modifiers: .option), .copy)
        XCTAssertEqual(
            DragModePolicy.intent(modifiers: [.command, .option]), .copy,
            "⌥⌘ is macOS's link gesture; reading it as a move takes the file away from where the user left it"
        )
    }

    /// Caps Lock and the function key arrive in `NSEvent.modifierFlags` and
    /// must not disturb the reading.
    func test_unrelated_modifiers_do_not_change_the_intent() {
        XCTAssertEqual(DragModePolicy.intent(modifiers: [.shift, .capsLock, .function]), .copy)
        XCTAssertEqual(DragModePolicy.intent(modifiers: [.command, .shift, .capsLock]), .move)
    }

    // MARK: - What the destination is allowed to do

    /// **The measured invariant.** The shelf permits a destination exactly one
    /// operation, under every modifier and in every context, and it is `.copy`.
    ///
    /// Two attempts before this one read `NSEvent.modifierFlags` to build the
    /// mask and widened it under ⌘. Driving a real drag into a real Finder
    /// window showed why that cannot work: AppKit latches the mask as a ceiling
    /// when the session is set up, so ⌘ pressed *mid-drag* — the gesture the
    /// shelf's own hint teaches — widened nothing and the drop was refused.
    /// Holding ⌘ from the start did move the file, and so did a **plain**
    /// unmodified drag, because Finder's answer for a same-volume drop is a
    /// move whenever `.move` is on offer.
    ///
    /// So the mask has to be a constant, and it has to be the safe one. `.copy`
    /// is the only ceiling under which no destination can take the user's file.
    func test_the_shelf_only_ever_permits_a_copy() {
        XCTAssertEqual(
            DragModePolicy.sourceMask, .copy,
            "the drag offers more than a copy; a destination is now free to move or delete the user's file on its own judgement"
        )
    }

    /// Said again as the danger rather than the value, because this is the one
    /// that loses a file. `.move` on the mask is a move Finder will perform on
    /// an unmodified drag — measured, not feared.
    func test_no_mask_ever_offers_a_move() {
        XCTAssertFalse(
            DragModePolicy.sourceMask.contains(.move),
            "the mask offers .move, so a plain drag into a same-volume Finder folder takes the file out of its folder"
        )
    }

    /// `.generic` is the destination's default operation. ADR 0009's addendum
    /// added it in the belief that ⌘ selects exactly that; measured against
    /// Finder, a generic-only offer is refused and `.move` is what ⌘ acts on.
    /// It buys nothing and it is one more thing a destination could act on.
    func test_no_mask_offers_the_generic_operation() {
        XCTAssertFalse(
            DragModePolicy.sourceMask.contains(.generic),
            "the mask offers the destination's default operation, which for a Finder folder is a move"
        )
    }

    func test_nothing_ever_offers_a_link() {
        XCTAssertFalse(
            DragModePolicy.sourceMask.contains(.link),
            "the shelf offers a link, which it cannot honour"
        )
    }

    /// The mask is safe only because ⌘ no longer filters it away. With AppKit's
    /// modifier filter on, `.copy` under ⌘ intersects to nothing and Finder
    /// refuses the drop under a no-drop cursor — which is the defect the owner
    /// photographed. `ignoreModifierKeys` returning `true` is the repair, and
    /// nothing else in the app makes it visible.
    func test_the_drag_source_turns_off_appkits_modifier_filter() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfDragSource.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("beginDraggingSession"), "read the wrong file")
        XCTAssertTrue(
            text.contains("func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }"),
            "the drag source lets AppKit filter the mask by the modifiers again — a copy-only mask under ⌘ intersects to nothing and every ⌘-drag is refused"
        )
    }

    /// And that the mask is not built from the live modifiers, which is exactly
    /// what the two failed attempts did.
    func test_the_mask_is_not_read_from_the_live_modifiers() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfDragSource.swift"),
            encoding: .utf8
        )
        let code = magpieCodeOnly(text)
        let mask = code[code.range(of: "sourceOperationMaskFor context")!.lowerBound...]
        let body = mask.prefix(while: { $0 != "}" })
        XCTAssertFalse(
            body.contains("NSEvent.modifierFlags"),
            "the operation mask is built from the live modifier flags again; AppKit latches the mask at session setup, so widening it under ⌘ only gets the drop refused"
        )
    }
}

/// What the shelf says while a card is on its way out, and — the part the owner
/// asked for by name — whether holding ⌘ visibly changes anything. A mode the
/// user cannot see is a mode they cannot trust.
final class DragOutHintTests: XCTestCase {

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "drag.mode.copying",
        "drag.mode.moving",
        "drag.mode.hold-command",
        "drag.mode.release-command",
    ]

    // MARK: - What it says

    /// The teaching requirement: whichever mode the drag is in, the hint names
    /// the other one. Discoverable from either side or not discoverable at all.
    func test_each_mode_names_the_other_one() {
        XCTAssertEqual(DragOutHint.from(intent: .copy).subtitle, L("drag.mode.hold-command"))
        XCTAssertEqual(DragOutHint.from(intent: .move).subtitle, L("drag.mode.release-command"))
    }

    func test_the_title_says_which_way_this_drag_will_land() {
        XCTAssertEqual(DragOutHint.from(intent: .copy).title, L("drag.mode.copying"))
        XCTAssertEqual(DragOutHint.from(intent: .move).title, L("drag.mode.moving"))
    }

    /// The feedback, as a property rather than a screenshot: the two modes
    /// cannot read the same. This is what fails if the hint is wired to a
    /// constant instead of to the live modifier state.
    func test_holding_command_changes_what_the_shelf_says() {
        let copying = DragOutHint.from(intent: .copy)
        let moving = DragOutHint.from(intent: .move)
        XCTAssertNotEqual(
            copying, moving,
            "the hint reads identically whether or not ⌘ is held — nothing tells the user they are moving"
        )
        XCTAssertNotEqual(copying.title, moving.title)
        for line in [copying.title, copying.subtitle, moving.title, moving.subtitle] {
            XCTAssertFalse(line.isEmpty, "the drag hint has an empty line")
        }
    }

    // MARK: - The nine tables

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    func test_every_language_defines_the_drag_mode_strings() throws {
        for language in Self.languages {
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: resources
                    .appendingPathComponent("\(language).lproj")
                    .appendingPathComponent("Localizable.strings")) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            let names = Set(table.keys)
            for key in Self.keys {
                let value = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) has an empty \(key)")
                XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                XCTAssertFalse(
                    names.contains(value),
                    "\(language): \(key) holds the name of another key (\(value)) — the table may be shifted"
                )
            }
            XCTAssertNotEqual(
                table["drag.mode.copying"], table["drag.mode.moving"],
                "\(language) says the same word for copying and moving — the mode change is invisible in that language"
            )
        }
    }

    /// The modifier has to be in the sentence, or the line teaches nothing.
    func test_every_language_names_the_command_key() throws {
        for language in Self.languages {
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: resources
                    .appendingPathComponent("\(language).lproj")
                    .appendingPathComponent("Localizable.strings")) as? [String: String]
            )
            for key in ["drag.mode.hold-command", "drag.mode.release-command"] {
                let value = try XCTUnwrap(table[key])
                XCTAssertTrue(
                    value.contains("⌘"),
                    "\(language) lost the ⌘ glyph in \(key) — the hint no longer names the key it is about"
                )
            }
        }
    }

    // MARK: - The wiring

    /// `EmptyShelfHint` shipped fully translated in nine tables while no view
    /// rendered it. Same guard, same reason.
    func test_the_shelf_actually_renders_the_hint() throws {
        let view = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfContainerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            view.contains("DragOutHint.from("),
            "nothing renders DragOutHint — the drag hint is translated in nine tables and shown in none"
        )
        XCTAssertTrue(
            view.contains("DragModeMonitor.shared"),
            "the hint is not wired to the live modifier state, so it cannot change while the drag is in flight"
        )
    }

    /// A drag runs inside an AppKit tracking loop, where a default-mode timer
    /// never fires — the lesson `ToastPresenter` already paid for. Without
    /// `.common` the hint would freeze at whatever ⌘ said when the drag began.
    func test_the_modifier_sampler_runs_in_common_mode() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/DragOut.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("DragModeMonitor"), "read the wrong file")
        XCTAssertTrue(
            source.contains("forMode: .common"),
            "the modifier sampler is not on the common run-loop mode, so it stops firing for the whole of a drag"
        )
    }
}

/// Some destinations cannot move anything: a browser, an upload widget, a cloud
/// target take a copy whatever the source offered. If the user held ⌘ and the
/// file is still where it was, the card stays and the shelf says so — pretending
/// it moved is how a tool loses someone's trust.
final class CopiedInsteadNoticeTests: XCTestCase {

    func test_a_move_that_left_the_file_behind_is_reported() {
        XCTAssertEqual(
            DragOutcome.copyInsteadNotice(intent: .move, accepted: true, survivingCount: 1),
            .copiedInstead(count: 1)
        )
    }

    func test_a_move_that_really_moved_says_nothing() {
        XCTAssertNil(
            DragOutcome.copyInsteadNotice(intent: .move, accepted: true, survivingCount: 0),
            "the file is gone, so the move happened — a notice here would be an error that didn't occur"
        )
    }

    /// The user never asked for a move, so a copy is exactly what they got.
    func test_a_plain_drag_is_never_reported() {
        XCTAssertNil(
            DragOutcome.copyInsteadNotice(intent: .copy, accepted: true, survivingCount: 3),
            "a plain drag copies by design and must not toast about it"
        )
    }

    /// The one thing the reported operation is trusted for, and only in the
    /// negative: an abandoned drag took no destination, so there is nothing to
    /// explain. Without this, ⌘-dragging onto empty space would claim a
    /// destination copied when no destination was ever involved.
    func test_an_abandoned_drag_is_never_reported() {
        XCTAssertNil(
            DragOutcome.copyInsteadNotice(intent: .move, accepted: false, survivingCount: 2),
            "a drag no destination accepted is reported as a refused move"
        )
    }

    func test_the_message_key_tracks_the_count() {
        XCTAssertEqual(DragNotice.copiedInstead(count: 1).messageKey, "toast.drag-copied-instead.one")
        XCTAssertEqual(DragNotice.copiedInstead(count: 4).messageKey, "toast.drag-copied-instead.many")
        XCTAssertEqual(DragNotice.copiedInstead(count: 4).count, 4)
    }

    /// A same-volume move is a rename and is already done when the mouse comes
    /// up; a cross-volume one copies first and unlinks after. Deciding at the
    /// instant the drag ends would call the slow one a copy.
    func test_the_answer_is_asked_for_twice() throws {
        XCTAssertGreaterThan(
            DragOutcome.settleDelay, 0,
            "the outcome is judged at the instant the drag ends, so a move still in progress reads as a copy"
        )
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfDragSource.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("DragOutcome.settleDelay"),
            "nothing waits for the settle delay — the notice is decided before a slow destination has finished"
        )
    }

    // MARK: - The nine tables

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]

    func test_every_language_defines_the_copied_instead_strings() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        for language in Self.languages {
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: resources
                    .appendingPathComponent("\(language).lproj")
                    .appendingPathComponent("Localizable.strings")) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            let names = Set(table.keys)
            for key in ["toast.drag-copied-instead.one", "toast.drag-copied-instead.many"] {
                let value = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                XCTAssertFalse(value.isEmpty, "\(language) has an empty \(key)")
                XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                XCTAssertFalse(
                    names.contains(value),
                    "\(language): \(key) holds the name of another key (\(value)) — the table may be shifted"
                )
            }
            XCTAssertTrue(
                try XCTUnwrap(table["toast.drag-copied-instead.many"]).contains("%lld"),
                "\(language) lost the count placeholder — the toast cannot say how many files it means"
            )
        }
    }
}

/// ADR 0001 is the app's whole safety story: no code path removes or overwrites
/// a file Magpie does not manage. ADR 0011 opens exactly one exception — a
/// ⌘-drag the user made, whose copy has been verified, whose source goes to the
/// **Trash** — and confines it to `DragMove.swift`. These tests read the two
/// files, because the property is about what they are allowed to contain.
final class DragOutFileSafetyTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// Unchanged from ADR 0009 and still binding: the drag source itself
    /// touches nothing. It decides, and `DragMove.swift` acts.
    func test_the_drag_source_never_mutates_the_filesystem() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/ShelfDragSource.swift"))
        XCTAssertTrue(text.contains("beginDraggingSession"), "read the wrong file")
        for call in [
            "removeItem", "moveItem", "copyItem", "replaceItemAt",
            "trashItem", "createFile", "recycle(",
        ] {
            XCTAssertFalse(
                text.contains(call),
                "ShelfDragSource calls \(call) — the file operations of a drag out belong in DragMove.swift, behind the ADR 0011 gate, not in the view that starts the drag"
            )
        }
    }

    /// The exception, fenced. `DragMove.swift` may copy (fulfilling a promise,
    /// into a path the *receiver* named) and may recycle. Everything else is a
    /// way to destroy a file that the Trash cannot undo.
    func test_the_move_path_can_only_copy_and_recycle() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/DragMove.swift"))
        XCTAssertTrue(text.contains("DragMovePolicy"), "read the wrong file")
        for call in ["removeItem", "moveItem", "replaceItemAt", "trashItem", "unlink", "linkItem"] {
            XCTAssertFalse(
                text.contains(call),
                "DragMove calls \(call) — ADR 0011 is acceptable only because the source goes to the Trash and can be got back; this cannot be undone"
            )
        }
        XCTAssertTrue(
            text.contains("NSWorkspace.shared.recycle"),
            "the move no longer goes through the Trash"
        )
    }

    /// A promise fulfilled with `copyItem` fails rather than overwriting, which
    /// is the half of ADR 0001 §1 the old promise path breached with
    /// `replaceItemAt`.
    func test_fulfilling_a_promise_can_never_overwrite() throws {
        let text = try source("Sources/Magpie/DragMove.swift")
        XCTAssertTrue(
            text.contains("try FileManager.default.copyItem(at: provider.sourceURL, to: url)"),
            "the promise write no longer uses copyItem, which is the call that refuses rather than clobbering a file already at the destination"
        )
    }
}

/// ADR 0011's five conditions, one test each, plus the ones that say what must
/// *not* happen. This is the gate between a ⌘-drag and a user's file, and every
/// case here is a way the file could have been taken without one.
final class DragMovePolicyTests: XCTestCase {

    private let source = URL(fileURLWithPath: "/Users/someone/Downloads/report.pdf")
    private let landed = URL(fileURLWithPath: "/Users/someone/Desktop/report.pdf")

    /// Sizes for a two-file world, so each test names only the number it cares
    /// about. Anything not listed does not exist.
    private func sizes(_ pairs: [URL: Int64]) -> (URL) -> Int64? {
        { pairs[$0] }
    }

    // MARK: - The one case that removes a file

    func test_a_verified_command_drag_trashes_the_source() {
        XCTAssertEqual(
            DragMovePolicy.decide(
                intent: .move,
                source: source,
                destination: landed,
                sizeOf: sizes([source: 4096, landed: 4096])
            ),
            .trashSource,
            "a ⌘-drag whose copy is on disk at the right size still does not move the file; ⌘ means nothing again"
        )
    }

    // MARK: - Every case that must not

    /// The single most important assertion in the file. A drag with no modifier
    /// is a copy, and nothing may follow it.
    func test_a_plain_drag_never_touches_the_source() {
        XCTAssertEqual(
            DragMovePolicy.decide(
                intent: .copy,
                source: source,
                destination: landed,
                sizeOf: sizes([source: 4096, landed: 4096])
            ),
            .leaveAlone(.notAMove),
            "a plain drag removes the user's file — the modifier is the whole of the consent"
        )
    }

    /// The destination read the file URL and copied from the original itself,
    /// so Magpie was never told where anything landed. No path, no evidence,
    /// no move. This is the browser-upload-zone case and it must stay quiet.
    func test_a_destination_that_never_said_where_leaves_the_file_alone() {
        XCTAssertEqual(
            DragMovePolicy.decide(
                intent: .move,
                source: source,
                destination: nil,
                sizeOf: sizes([source: 4096])
            ),
            .leaveAlone(.noDestination),
            "the source is trashed on a drop nobody verified — the copy might be nowhere"
        )
    }

    func test_a_copy_that_is_not_there_leaves_the_file_alone() {
        XCTAssertEqual(
            DragMovePolicy.decide(
                intent: .move,
                source: source,
                destination: landed,
                sizeOf: sizes([source: 4096])
            ),
            .leaveAlone(.destinationMissing),
            "the source is trashed although nothing arrived at the destination"
        )
    }

    /// A truncated write, an interrupted copy, or a different file entirely.
    func test_a_copy_of_the_wrong_size_leaves_the_file_alone() {
        XCTAssertEqual(
            DragMovePolicy.decide(
                intent: .move,
                source: source,
                destination: landed,
                sizeOf: sizes([source: 4096, landed: 12])
            ),
            .leaveAlone(.sizeMismatch),
            "a partial copy is accepted as proof of a move and the whole file goes to the Trash"
        )
    }

    func test_a_source_that_is_already_gone_is_not_chased() {
        XCTAssertEqual(
            DragMovePolicy.decide(
                intent: .move,
                source: source,
                destination: landed,
                sizeOf: sizes([landed: 4096])
            ),
            .leaveAlone(.sourceGone)
        )
    }

    /// The hazard a promise brings with it: a receiver is not always a folder.
    /// A compose window or a preview pane fulfils the promise into its own
    /// scratch space and may delete it the moment it is done, so trashing the
    /// original against that copy loses the file in a place the user cannot go.
    func test_a_copy_into_scratch_space_leaves_the_file_alone() {
        for path in [
            "/var/folders/2x/abc/T/TemporaryItems/report.pdf",
            "/private/var/folders/2x/abc/T/report.pdf",
            "/tmp/report.pdf",
            "/private/tmp/report.pdf",
            "/var/tmp/report.pdf",
            "/Users/someone/Library/Caches/com.example.app/report.pdf",
        ] {
            let temporary = URL(fileURLWithPath: path)
            XCTAssertEqual(
                DragMovePolicy.decide(
                    intent: .move,
                    source: source,
                    destination: temporary,
                    sizeOf: sizes([source: 4096, temporary: 4096])
                ),
                .leaveAlone(.temporaryDestination),
                "a copy in \(path) counts as a destination — the original is trashed against bytes the system will sweep"
            )
        }
    }

    /// And the places that are not scratch space still work, or the feature
    /// refuses everything and looks broken.
    func test_ordinary_folders_are_not_mistaken_for_scratch_space() {
        for path in [
            "/Users/someone/Desktop/report.pdf",
            "/Users/someone/Documents/Temporary/report.pdf",
            "/Volumes/Backup/tmp-archive/report.pdf",
            "/Users/someone/Library/Mobile Documents/report.pdf",
        ] {
            XCTAssertFalse(
                DragMovePolicy.isTemporaryPath(path),
                "\(path) is read as scratch space, so a ⌘-move there silently does nothing"
            )
        }
    }

    // MARK: - A multi-file ⌘-drag is N independent moves

    /// **The invariant a multi-row selection introduces.** Dragging four rows
    /// out under ⌘ is four moves, four promises and four destinations, and the
    /// hazard is a shared answer: one file's verified copy vouching for a
    /// sibling whose copy is truncated, missing, or in scratch space — and that
    /// sibling's original going to the Trash on the strength of it.
    ///
    /// The good file is deliberately first, so a decision that leaked forwards
    /// would trash all four.
    func test_one_verified_copy_never_vouches_for_another_file() {
        let good = URL(fileURLWithPath: "/Users/someone/Downloads/good.pdf")
        let goodLanded = URL(fileURLWithPath: "/Users/someone/Desktop/good.pdf")
        let short = URL(fileURLWithPath: "/Users/someone/Downloads/short.pdf")
        let shortLanded = URL(fileURLWithPath: "/Users/someone/Desktop/short.pdf")
        let unread = URL(fileURLWithPath: "/Users/someone/Downloads/unread.pdf")
        let scratched = URL(fileURLWithPath: "/Users/someone/Downloads/scratched.pdf")
        let scratch = URL(fileURLWithPath: "/var/folders/2x/abc/T/scratched.pdf")

        XCTAssertEqual(
            DragMovePolicy.decideEach(
                intent: .move,
                files: [
                    (source: good, destination: goodLanded),
                    (source: short, destination: shortLanded),
                    (source: unread, destination: nil),
                    (source: scratched, destination: scratch),
                ],
                sizeOf: sizes([
                    good: 4096, goodLanded: 4096,
                    short: 4096, shortLanded: 11,
                    unread: 4096,
                    scratched: 4096, scratch: 4096,
                ])
            ),
            [
                .trashSource,
                .leaveAlone(.sizeMismatch),
                .leaveAlone(.noDestination),
                .leaveAlone(.temporaryDestination),
            ],
            "one file's verification decided another's — a multi-file ⌘-move can now trash an original whose own copy was never checked"
        )
    }

    /// And the other direction: an early failure must not hold back a file that
    /// did verify, or a multi-file move silently half-works.
    func test_one_failed_verification_never_blocks_another_file() {
        let broken = URL(fileURLWithPath: "/Users/someone/Downloads/broken.pdf")
        let good = URL(fileURLWithPath: "/Users/someone/Downloads/good.pdf")
        let landed = URL(fileURLWithPath: "/Users/someone/Desktop/good.pdf")

        XCTAssertEqual(
            DragMovePolicy.decideEach(
                intent: .move,
                files: [
                    (source: broken, destination: nil),
                    (source: good, destination: landed),
                ],
                sizeOf: sizes([broken: 4096, good: 4096, landed: 4096])
            ),
            [.leaveAlone(.noDestination), .trashSource],
            "a file that failed verification stopped a later file's verified move from happening"
        )
    }

    /// A plain drag of a whole selection touches nothing at all, however many
    /// rows it carried.
    func test_a_plain_multi_file_drag_touches_none_of_them() {
        let files = (0..<4).map { index -> (source: URL, destination: URL?) in
            (
                source: URL(fileURLWithPath: "/Users/someone/Downloads/f\(index).pdf"),
                destination: URL(fileURLWithPath: "/Users/someone/Desktop/f\(index).pdf")
            )
        }
        XCTAssertEqual(
            DragMovePolicy.decideEach(intent: .copy, files: files, sizeOf: { _ in 4096 }),
            Array(repeating: .leaveAlone(.notAMove), count: 4),
            "a plain drag of a multi-row selection removes the user's files"
        )
    }

    /// The decisions have to be paired back with the providers they were made
    /// for. A `zip` is what makes that true by construction; a lookup by index
    /// into a filtered list is how it would silently stop being.
    func test_each_decision_is_applied_to_the_file_it_was_made_for() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/ShelfDragSource.swift"))
        XCTAssertTrue(text.contains("DragMovePolicy.decideEach("), "read the wrong file")
        XCTAssertTrue(
            text.contains("for (provider, decision) in zip(pending, decisions)"),
            "the drag source no longer pairs each decision with the provider it was made for, so one file's answer can be applied to another file's source"
        )
    }

    // MARK: - Measuring what landed

    func test_a_files_size_is_its_bytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragMoveSize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try Data(repeating: 7, count: 321).write(to: file)
        XCTAssertEqual(DragMovePolicy.contentSize(of: file), 321)
        XCTAssertNil(
            DragMovePolicy.contentSize(of: dir.appendingPathComponent("nothing.txt")),
            "a file that is not there is measured as a size rather than as absent, so a missing copy would compare equal to an empty source"
        )
    }

    /// A folder can sit on the shelf and be dragged off it. `.fileSizeKey` is
    /// meaningless for one, so without this a ⌘-move of a folder could never
    /// verify — or, worse, could verify against nothing.
    func test_a_folders_size_is_what_is_inside_it() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragMoveFolder-\(UUID().uuidString)", isDirectory: true)
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 250).write(to: nested.appendingPathComponent("b.bin"))

        XCTAssertEqual(
            DragMovePolicy.contentSize(of: dir), 350,
            "a folder is not measured by what it contains, so a ⌘-move of one is verified against a number that means nothing"
        )
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// A gate nothing calls is not a gate. The drag source must ask
    /// `DragMovePolicy.decideEach` rather than deciding for itself, or what
    /// these tests pin is not what runs.
    func test_the_end_of_a_drag_asks_the_policy() throws {
        let text = try source("Sources/Magpie/ShelfDragSource.swift")
        XCTAssertTrue(
            text.contains("DragMovePolicy.decideEach("),
            "nothing asks the ADR 0011 gate, so either ⌘ does nothing or the source is removed without the conditions being checked"
        )
        XCTAssertTrue(
            text.contains("decision == .trashSource"),
            "the drag source acts on something other than the policy's answer"
        )
    }

    /// The promise can be fulfilled after the session has ended — measured, a
    /// real Finder drop wrote it roughly 400ms later. If the only look at the
    /// evidence happens when the mouse comes up, the move never fires.
    func test_a_promise_that_lands_late_is_still_acted_on() throws {
        let text = try source("Sources/Magpie/ShelfDragSource.swift")
        XCTAssertTrue(
            text.contains("provider.onFulfilled = { [weak self] in self?.settleMove() }"),
            "a promise fulfilled after the drag ends never re-opens the decision, so a ⌘-move onto Finder silently does nothing"
        )
    }
}

/// Where the drag-mode indicator is allowed to be.
///
/// It was a two-line block centred on the panel, and the collapsed strip faded
/// its rows to nothing to make room for it — so holding ⌘ emptied the shelf and
/// put a large coral box where the files had been. Rendered and looked at
/// (`strip-dragging-*`), the box took about half the panel and none of the three
/// rows were visible. The owner's words for the whole app are "minimal and
/// subtle", and the shelf's job is showing a set.
///
/// Nothing here can look at a pixel. What it can do is pin the two structural
/// facts a screenshot would have shown: the indicator is drawn in the chrome
/// line, and the rows are not hidden for the length of a drag.
final class DragModeBarPlacementTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    // MARK: - It does not cover the files

    /// THE defect. A drag must not make the shelf's own contents invisible.
    func test_the_rows_stay_visible_while_a_drag_is_in_flight() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/CollapsedShelfView.swift"))
        XCTAssertTrue(text.contains("ShelfStripRow("), "read the wrong file")
        XCTAssertFalse(
            text.contains("opacity(isDragging ? 0 : 1)"),
            "the strip fades its rows away for the length of a drag — the one moment the user is checking what they have hold of is the one moment the shelf shows nothing"
        )
    }

    /// And the indicator is not overlaid on the collapsed panel's content at
    /// all. A `.center`-aligned overlay is what put it on top of the rows.
    func test_the_collapsed_strip_does_not_overlay_the_indicator_on_its_content() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/ShelfContainerView.swift"))
        XCTAssertTrue(text.contains("DragModeBar("), "read the wrong file")
        XCTAssertFalse(
            text.contains("alignment: isExpanded ? .bottom : .center"),
            "the drag indicator is overlaid on the middle of the collapsed panel again, which is exactly where the rows are"
        )
        XCTAssertTrue(
            text.contains("if isExpanded, !isDocked {"),
            "the container overlays the drag indicator in every state; the collapsed strip carries it in its own header instead"
        )
    }

    /// The positive half: the collapsed strip really does render it, in the
    /// chrome line. Without this the fix above could be "delete the indicator".
    func test_the_collapsed_strip_shows_the_mode_in_its_chrome_line() throws {
        let text = magpieCodeOnly(try source("Sources/Magpie/CollapsedShelfView.swift"))
        XCTAssertTrue(
            text.contains("DragModeBar(intent: dragIntent, visible: true)"),
            "the collapsed strip no longer shows the drag mode at all — ⌘ became invisible again"
        )
        XCTAssertTrue(
            text.contains("frame(height: ShelfLayout.stripHeaderHeight)"),
            "the mode bar is not held to the header's height, so it changes the strip's layout mid-drag"
        )
    }

    // MARK: - It fits, in every language

    /// The bar is one line, "<mode> · <hint>", and that line has to fit the
    /// strip in every table. At 180pt it overflowed in five languages, Polish
    /// by 59pt, which is how a hint ends up covering the files it is about.
    func test_every_language_fits_the_strip_on_one_line() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        // The strip, less the panel margin on both sides and the bar's own
        // horizontal padding. `minimumScaleFactor(0.9)` is deliberately not
        // counted: this asserts the line fits at full size.
        let available = ShelfLayout.stripWidth
            - ShelfLayout.margin * 2
            - Design.Space.sm * 2
        let font = NSFont.systemFont(ofSize: 10)
        let boldFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

        for language in ["Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans"] {
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: resources
                    .appendingPathComponent("\(language).lproj")
                    .appendingPathComponent("Localizable.strings")) as? [String: String]
            )
            for (mode, key) in [
                ("drag.mode.copying", "drag.mode.hold-command"),
                ("drag.mode.moving", "drag.mode.release-command"),
            ] {
                // The bar draws "<mode> · <hint>", the mode word semibold and
                // the rest regular, so each half is measured at its own weight.
                let modeWord = try XCTUnwrap(table[mode])
                let rest = " · " + (try XCTUnwrap(table[key]))
                let value = modeWord + rest
                let width = ceil(
                    (modeWord as NSString).size(withAttributes: [.font: boldFont]).width
                        + (rest as NSString).size(withAttributes: [.font: font]).width
                )
                XCTAssertLessThanOrEqual(
                    width, available,
                    "\(language)'s \"\(value)\" is \(width)pt wide against \(available)pt of strip — it will shrink or truncate on the shelf"
                )
            }
        }
    }
}
