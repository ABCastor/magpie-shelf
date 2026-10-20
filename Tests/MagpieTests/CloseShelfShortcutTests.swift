import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Magpie

/// ⌘W closes the shelf.
///
/// The interesting question about this key is not what it does but **what it
/// must not do**: ⌘W is the most universally bound shortcut on macOS, and an
/// accessory app that took it system-wide would close a document in whatever
/// the user was actually working in. That is the property pinned here.
///
/// Magpie has exactly three keyboard surfaces and they have different reach:
/// the Carbon registration in `HotkeyManager` is genuinely system-wide,
/// `NSApp.mainMenu` fires while this app is active, and the local `.keyDown`
/// monitor in `App.swift` fires only while this app is active **and** one of
/// its panels is key. ⌘W belongs to the last one and to no other. The owner's
/// requirement was "only when it's highlighted", and `isKeyWindow` is exactly
/// that.
///
/// The last mile — a real ⌘W at a real focused panel — is not reachable from a
/// test: the monitor is a private closure installed process-wide at launch with
/// no injection seam, which is the same reason `ShelfKeyboard` pushes its
/// decisions into a pure model. What can be checked is that the key is wired to
/// the one surface with the right scope, and to the same call the ✕ button
/// makes, so the two cannot drift apart.
@MainActor
final class CloseShelfShortcutTests: XCTestCase {

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// No global registration may claim **⌘ on its own with a letter**, which
    /// is the shape every app's own shortcuts take and the shape that taking
    /// ⌘W away from them would require. ⌃⌥⌘S is fine and is deliberately
    /// offered: it contains ⌘ but cannot collide with a plain ⌘-letter.
    ///
    /// Asserted over the real preset tables rather than the source text —
    /// these are the only combinations `HotkeyManager` can ever register.
    func test_no_global_hotkey_claims_a_plain_command_letter() {
        let otherModifiers = UInt32(controlKey | optionKey | shiftKey)
        func assertNotPlainCommand(_ modifiers: UInt32, _ name: String) {
            guard modifiers & UInt32(cmdKey) != 0 else { return }
            XCTAssertNotEqual(
                modifiers & otherModifiers, 0,
                "\(name) registers a plain ⌘ combination system-wide, which is how an accessory app steals ⌘W from every other app"
            )
        }
        for preset in HotkeyPreset.allCases {
            assertNotPlainCommand(preset.carbonModifiers, preset.rawValue)
        }
        for preset in ChatHotkeyPreset.allCases {
            assertNotPlainCommand(preset.carbonModifiers, preset.rawValue)
        }
    }

    /// The app-wide menu must not claim ⌘W either. A main-menu key equivalent
    /// fires whenever Magpie is active, including when no shelf is focused at
    /// all — which is broader than "only when it's highlighted" and would make
    /// the shortcut fire with nothing to close.
    func test_the_main_menu_does_not_claim_command_w() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("close-shelf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = NSApplication.shared
        let manager = ShelfManager(store: ShelfStore(
            storeURL: scratch.appendingPathComponent("shelf.json")
        ))
        let delegate = AppDelegate(manager: manager, flushOnTermination: {})
        let menu = MainMenu.build(delegate: delegate)
        var claimed: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalent == "w", item.keyEquivalentModifierMask == [.command] {
                    claimed.append(item.title)
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        XCTAssertEqual(
            claimed, [],
            "⌘W is on the main menu, so it fires whenever Magpie is active rather than only when a shelf is focused"
        )
    }

    /// Wired to the panel-scoped monitor, and to the same teardown the ✕ button
    /// runs. If the button's call is ever renamed and this one is not, the
    /// keyboard path silently becomes a different operation from the click.
    func test_command_w_is_handled_in_the_panel_scoped_monitor() throws {
        let app = try source("App.swift")

        let monitorIsLocal = app.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)")
        XCTAssertTrue(
            monitorIsLocal,
            "the shelf key monitor is no longer a local one — a global monitor sees other apps' keys and needs Accessibility"
        )
        XCTAssertTrue(
            app.contains("$0.value.isKeyWindow"),
            "the monitor stopped requiring a key panel, so ⌘W would fire with no shelf focused"
        )
        XCTAssertTrue(
            app.contains("case \"w\":"),
            "⌘W is no longer handled in the key monitor"
        )
        // The ✕ button and ⌘W must run the same teardown.
        XCTAssertTrue(
            app.contains("onClose: { self?.hidePanel(for: shelfID) }"),
            "the ✕ button no longer calls hidePanel — the click and the key have drifted apart"
        )
        XCTAssertTrue(
            app.contains("self.hidePanel(for: shelfID)"),
            "⌘W no longer calls hidePanel"
        )
    }

    /// ⌘W must not be swallowed while a text field owns the keys: the ⌘K
    /// palette's query field is inside the panel, and closing the whole shelf
    /// out from under someone who is typing is not what that keystroke means
    /// there. The monitor's field-editor guard sits above every ⌘ case, and
    /// this pins the order rather than the mere presence.
    func test_a_focused_text_field_still_gets_the_keys_first() throws {
        let app = try source("App.swift")
        let guardIndex = try XCTUnwrap(
            app.range(of: "if panel.firstResponder is NSText { return event }")?.lowerBound,
            "the field-editor guard is gone — ⌘V and ⌘W now eat the user's typing"
        )
        let closeIndex = try XCTUnwrap(app.range(of: "case \"w\":")?.lowerBound)
        XCTAssertLessThan(
            guardIndex, closeIndex,
            "⌘W is handled before the field-editor guard, so it fires while the palette's query field has focus"
        )
    }
}
