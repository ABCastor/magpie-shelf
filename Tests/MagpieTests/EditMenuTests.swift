import AppKit
import XCTest
@testable import Magpie

/// Cocoa ships no built-in ⌘V. Cut/Copy/Paste/Select All are *menu* key
/// equivalents that AppKit dispatches down the responder chain to whatever
/// field editor holds first responder, so an app with no Edit menu has text
/// fields that silently refuse to paste.
///
/// This app has two such fields, and both are reached without a mouse: the ⌘K
/// action palette's query field, which takes focus on appear, and the Settings
/// search field on ⌘F. A keyboard-first app whose only two text inputs cannot
/// take a paste is the kind of gap that reads as "this app is broken" rather
/// than "this feature is missing".
///
/// These tests drive the real dispatch path — `NSMenu.performKeyEquivalent` —
/// rather than asserting that menu items exist, because item-shaped assertions
/// pass just as happily when the items are wired to nothing.
@MainActor
final class EditMenuTests: XCTestCase {

    /// A window holding a focused text field, standing in for the palette.
    private func windowWithFocusedField() throws -> (NSWindow, NSTextField) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertTrue(
            window.firstResponder is NSText,
            "the fixture never got a field editor, so it cannot say anything about text editing"
        )
        return (window, field)
    }

    private func commandKey(_ character: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ))
    }

    func test_paste_into_a_focused_text_field_is_dispatched_by_the_main_menu() throws {
        let (window, _) = try windowWithFocusedField()
        let menu = MainMenu.build(delegate: AppDelegate())

        let handled = menu.performKeyEquivalent(with: try commandKey("v", in: window))

        XCTAssertTrue(
            handled,
            "⌘V reached no menu item, so the field editor never receives paste: — the ⌘K "
            + "palette and the Settings search field cannot be pasted into at all."
        )
    }

    func test_cut_copy_and_select_all_are_dispatched_too() throws {
        let (window, _) = try windowWithFocusedField()
        let menu = MainMenu.build(delegate: AppDelegate())

        for key in ["x", "c", "a"] {
            XCTAssertTrue(
                menu.performKeyEquivalent(with: try commandKey(key, in: window)),
                "⌘\(key.uppercased()) reached no menu item, so a focused text field cannot use it."
            )
        }
    }

    /// The proof that the Edit menu is what does the work: with only the app
    /// menu installed — the state this app shipped in — the very same event
    /// finds nothing. If this ever starts passing, the app grew a second
    /// dispatch path and the comment above is out of date.
    func test_without_an_edit_menu_the_same_paste_finds_nothing() throws {
        let (window, _) = try windowWithFocusedField()

        let appMenuOnly = NSMenu()
        let full = MainMenu.build(delegate: AppDelegate())
        if let first = full.items.first {
            full.removeItem(first)
            appMenuOnly.addItem(first)
        }

        XCTAssertFalse(
            appMenuOnly.performKeyEquivalent(with: try commandKey("v", in: window)),
            "the app menu alone answered ⌘V, so this test no longer isolates the Edit menu's role."
        )
    }

    /// The Edit menu's ⌘Z/⌘C/⌘A must not become the shelf's. The local key
    /// monitor in `App.swift` consumes those first whenever a shelf panel is
    /// key and the first responder is not text; this pins the condition that
    /// makes that safe, so a future edit to the monitor's guard fails here.
    func test_the_shelf_monitor_still_yields_only_to_a_field_editor() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/App.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("if panel.firstResponder is NSText { return event }"),
            "App.swift's key monitor no longer steps aside for a field editor. Either text "
            + "fields stopped receiving ⌘V, or the shelf stopped receiving it — one of the two."
        )
    }
}
