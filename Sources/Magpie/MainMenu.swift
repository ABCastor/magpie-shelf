import AppKit

/// The app-wide home of the shortcuts the status menu advertises.
///
/// A key equivalent on a status-item menu fires only while that menu is popped
/// up and tracking, so the ⌥⇧N the menu shows beside New Shelf was dead the
/// rest of the time: a stranger presses it with a shelf focused, nothing
/// happens, and the app reads as broken. AppKit routes unhandled key
/// equivalents through `NSApp.mainMenu` whenever this app owns the key window,
/// and an `LSUIElement` accessory never draws a menu bar, so installing one
/// changes nothing visible — it is pure keyboard surface. It is also what makes
/// the advertised ⌘, and ⌘Q genuinely work.
///
/// The plain-⌘ single keys the shelf handles itself (⌘V ⌘A ⌘C ⌘Z ⌘K ⌘Y) live in
/// the local `.keyDown` monitor in `App.swift` and are consumed there before
/// menu dispatch, so nothing here can shadow them. `MainMenuTests` holds the
/// two surfaces together: every shortcut the status menu shows must exist here
/// with the same action, or it is an advertisement for a dead key.
@MainActor
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        // Unlike the status menu (whose Check for Updates row leans on
        // Sparkle's own validateMenuItem), every item here is unconditionally
        // available, so enablement is decided at build time.
        menu.autoenablesItems = false

        let appMenu = NSMenu()
        appMenu.autoenablesItems = false

        let newShelf = NSMenuItem(
            title: L("New Shelf"),
            action: #selector(AppDelegate.newShelfAction),
            keyEquivalent: "n"
        )
        newShelf.keyEquivalentModifierMask = [.option, .shift]
        newShelf.target = delegate
        appMenu.addItem(newShelf)

        let newFromClip = NSMenuItem(
            title: L("New Shelf From Clipboard"),
            action: #selector(AppDelegate.newShelfFromClipboardAction),
            keyEquivalent: "a"
        )
        newFromClip.keyEquivalentModifierMask = [.option, .shift]
        newFromClip.target = delegate
        appMenu.addItem(newFromClip)

        appMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: L("Settings…"),
            action: #selector(AppDelegate.openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = delegate
        appMenu.addItem(settings)

        appMenu.addItem(.separator())

        // Nil target, like the status menu's Quit: the action walks the
        // responder chain and lands on NSApp.
        let quit = NSMenuItem(
            title: L("Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quit)

        // Convention: the main menu's first item carries the app menu. The bar
        // itself is never drawn for an accessory app; only the key equivalents
        // inside it matter.
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editMenu()
        menu.addItem(editItem)
        return menu
    }

    /// Cocoa has no built-in ⌘V. Text editing shortcuts are *menu* key
    /// equivalents dispatched down the responder chain to the field editor, so
    /// an app without an Edit menu has text fields you cannot paste into — and
    /// this app has two, the ⌘K palette's query field and the Settings search
    /// field. Both take focus without a click, then refused the paste that
    /// naturally follows.
    ///
    /// These do not shadow the shelf's own ⌘V/⌘C/⌘A/⌘Z: the local `.keyDown`
    /// monitor in `App.swift` runs *before* menu dispatch and consumes them
    /// whenever a shelf panel is key, returning the event untouched only when
    /// the first responder is an `NSText` — which is exactly the case these
    /// items exist to serve.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu()
        // Autoenabling would let AppKit grey these against the responder chain,
        // which sounds right and buys nothing: an accessory app draws no menu
        // bar, so nobody ever sees the enabled state. Only dispatch matters,
        // and turning it off keeps this menu inside the rule the whole app
        // follows — the rule that exists because autoenabling once silently
        // re-enabled ten rows that did nothing when clicked.
        edit.autoenablesItems = false

        func item(_ title: String, _ action: Selector, _ key: String,
                  _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let menuItem = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mask
            return menuItem                    // nil target: walks the responder chain
        }

        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return edit
    }
}
