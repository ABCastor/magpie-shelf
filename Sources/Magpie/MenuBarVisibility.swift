import AppKit

/// Whether Magpie keeps a menu-bar item.
///
/// The owner's reason for wanting this is worth recording, because it is also
/// the reason the feature is dangerous: an app that parks itself in the menu
/// bar and cannot be got rid of is a bad guest. Magpie should be able to run
/// with no permanent presence at all — summoned by hotkey, by shake, by screen
/// edge or by `magpie://`, and otherwise invisible.
///
/// **The trap.** Magpie is `LSUIElement`: no dock icon, no window unless a
/// shelf is summoned. `App.swift` says it plainly — the status menu is the only
/// route to Settings, Check for Updates and Quit. Hide the item naively and the
/// user is stranded: no way to reach Settings to turn it back on, and no way to
/// quit short of Activity Monitor. That is a worse version of the complaint the
/// feature exists to answer.
///
/// So hiding is only allowed to ship alongside two escape hatches, and
/// `MenuBarVisibilityTests` fails the build if either disappears:
///
/// 1. **Reopen.** Launching Magpie again — from Applications, Spotlight, or
///    `open -a Magpie` — opens Settings. AppKit routes that through
///    `applicationShouldHandleReopen(_:hasVisibleWindows:)`, which fires even
///    for an accessory app with no windows. This is the way back in.
/// 2. **Quit from Settings.** With no status menu there is no other Quit, and
///    an app you cannot quit is exactly what the owner objects to.
enum MenuBarVisibility {

    static let defaultsKey = "shelf.menuBarIcon"

    /// Shown unless the user has said otherwise. Registered as a default so an
    /// unset key does not read as `false` and hide the icon on first launch —
    /// which would strand a new user before they had ever seen the app.
    static let showsByDefault = true

    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? showsByDefault
    }

    /// Whether a status item should exist right now.
    ///
    /// Pure, so the decision is testable without a status bar. It takes the
    /// preference rather than reading it, because the caller has to be able to
    /// ask "what would happen if" in a test.
    static func shouldShowStatusItem(preferenceIsVisible: Bool) -> Bool {
        preferenceIsVisible
    }

    /// Whether reopening the app should surface Settings.
    ///
    /// True **always**, not only when the icon is hidden. If it were
    /// conditional, a user who hid the icon and then had the preference reset
    /// or the store quarantined would have no way back at all — and a
    /// conditional escape hatch is one that is missing exactly when it is
    /// needed. Reopening a running accessory app has no other sensible
    /// meaning, so there is nothing to trade away.
    static func reopenShouldOpenSettings() -> Bool { true }
}
