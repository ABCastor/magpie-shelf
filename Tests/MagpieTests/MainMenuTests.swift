import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Magpie

/// The status menu advertises ⌥⇧N, ⌥⇧A, ⌘, and ⌘Q — but a key equivalent on a
/// status-item menu fires only while that menu is popped up and tracking. The
/// app-wide surface for those keys is `NSApp.mainMenu`, which an accessory app
/// never draws but AppKit still consults. This suite asks the question the
/// vacuous version would skip: is each advertised shortcut reachable from the
/// state the app is actually in — no menu open, a shelf panel focused?
@MainActor
final class MainMenuTests: XCTestCase {

    private var scratch: URL!

    override func setUp() async throws {
        // Menu action dispatch goes through NSApp.sendAction, which is a
        // silent no-op until the shared application exists. The real app
        // always has one; the SPM test runner does not until asked.
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("main-menu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeDelegate() -> (delegate: AppDelegate, manager: ShelfManager) {
        let store = ShelfStore(storeURL: scratch.appendingPathComponent("shelf.json"))
        let manager = ShelfManager(store: store)
        let delegate = AppDelegate(manager: manager, flushOnTermination: {})
        return (delegate, manager)
    }

    /// A synthetic key press. A hardware event carries keyboard-layout backing
    /// that `NSEvent.keyEvent(with:)` cannot fake, so NSMenu's matcher falls
    /// back to comparing `charactersIgnoringModifiers` against the item's
    /// literal key-equivalent string — pass the lowercase letter, and the
    /// Shift requirement is expressed through `modifiers` alone. (Verified
    /// empirically: "N" does not match, "n" does.)
    private func keyDown(
        _ charIgnoringModifiers: String,
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: charIgnoringModifiers,
            charactersIgnoringModifiers: charIgnoringModifiers,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            var all = [item]
            if let submenu = item.submenu { all += flatten(submenu) }
            return all
        }
    }

    // MARK: - The keystroke, end to end

    /// THE regression this batch exists for: ⌥⇧N pressed with no menu open must
    /// still create a shelf. Goes through `NSMenu.performKeyEquivalent`, which
    /// is exactly what `NSApp.sendEvent` consults for an unhandled key, so a
    /// menu item that is mis-keyed, mis-targeted, or disabled fails here.
    func test_option_shift_n_creates_a_shelf_with_no_menu_open() throws {
        let (delegate, manager) = makeDelegate()
        let menu = MainMenu.build(delegate: delegate)
        let before = manager.shelves.count

        let event = try keyDown("n", keyCode: kVK_ANSI_N, modifiers: [.option, .shift])
        XCTAssertTrue(
            menu.performKeyEquivalent(with: event),
            "⌥⇧N matched no main-menu item — the advertised shortcut is dead app-wide again"
        )
        XCTAssertEqual(
            manager.shelves.count, before + 1,
            "⌥⇧N matched a menu item but created no shelf — the item is wired to the wrong action"
        )
    }

    // MARK: - Advertisement parity

    /// Every shortcut the status menu shows beside a title must exist on the
    /// main menu with the same action. A key printed in the status menu that
    /// only works while that menu is open is an advertisement for a dead key.
    func test_every_status_menu_shortcut_exists_app_wide_with_the_same_action() throws {
        let (delegate, _) = makeDelegate()
        let statusMenu = NSMenu()
        delegate.rebuildStatusMenu(statusMenu)
        let mainItems = flatten(MainMenu.build(delegate: delegate))

        var advertised = 0
        for item in flatten(statusMenu) where !item.keyEquivalent.isEmpty {
            advertised += 1
            let counterpart = mainItems.first {
                $0.keyEquivalent == item.keyEquivalent
                    && $0.keyEquivalentModifierMask == item.keyEquivalentModifierMask
            }
            XCTAssertNotNil(
                counterpart,
                "the status menu advertises \(item.keyEquivalent) (mask \(item.keyEquivalentModifierMask.rawValue)) on “\(item.title)” but no main-menu item carries it, so it is dead whenever the menu is closed"
            )
            XCTAssertEqual(
                counterpart?.action, item.action,
                "“\(item.title)” and its main-menu counterpart share a key but fire different actions"
            )
        }
        XCTAssertEqual(advertised, 4, "the status menu advertises a different number of shortcuts than this test knows about — update the parity check")
    }

    /// The other three advertised keys, structurally: behaviourally exercising
    /// them would quit the test runner (⌘Q), open a real Settings window (⌘,)
    /// or read the machine's clipboard (⌥⇧A).
    func test_quit_settings_and_clipboard_items_are_wired() throws {
        let (delegate, _) = makeDelegate()
        let items = flatten(MainMenu.build(delegate: delegate))

        let quit = items.first { $0.action == #selector(NSApplication.terminate(_:)) }
        XCTAssertEqual(quit?.keyEquivalent, "q")
        XCTAssertEqual(quit?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(quit?.isEnabled, true)

        let settings = items.first { $0.action == #selector(AppDelegate.openSettingsAction) }
        XCTAssertEqual(settings?.keyEquivalent, ",")
        XCTAssertEqual(settings?.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(settings?.target === delegate, "Settings has no target, so ⌘, would fall off the responder chain")

        let clipboard = items.first { $0.action == #selector(AppDelegate.newShelfFromClipboardAction) }
        XCTAssertEqual(clipboard?.keyEquivalent, "a")
        XCTAssertEqual(clipboard?.keyEquivalentModifierMask, [.option, .shift])
        XCTAssertTrue(clipboard?.target === delegate, "New Shelf From Clipboard has no target")
    }

    // MARK: - Installed from the state the app is actually in

    /// A built-but-never-installed menu is the vacuous version of this whole
    /// suite. `applicationDidFinishLaunching` has launch-order side effects
    /// (status item, monitors, timers, a possible modal alert) that make it
    /// unsafe to run inside the harness, so this follows the
    /// `MenuBarVisibilityTests` shape and pins the wiring in source.
    func test_the_main_menu_is_installed_at_launch() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/App.swift"),
            encoding: .utf8
        )
        let launchBody = app
            .components(separatedBy: "func applicationDidFinishLaunching")
            .dropFirst().first ?? ""
        XCTAssertTrue(
            launchBody.contains("NSApp.mainMenu = MainMenu.build(delegate: self)"),
            "applicationDidFinishLaunching no longer installs the main menu, so every advertised shortcut is dead app-wide"
        )
    }
}
