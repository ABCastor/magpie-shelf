import Foundation

/// The defaults registered before anything reads them, gathered in one place
/// so the value a control displays and the value the code executes cannot be
/// two literals that merely happened to agree.
///
/// Two kinds of key live here. The trigger flags default to on, so they cannot
/// rely on `bool(forKey:)` returning false for an unset key the way the older
/// prefs do. The expiry default is here for the opposite failure: Settings
/// displayed `@AppStorage`'s fallback ("After 10 days") while
/// `runShelfExpiryPrune` read the same key with `integer(forKey:)`, got 0 for
/// the unset key, and treated 0 as "Never". For a whole release the window
/// promised a cleanup the code never ran. Registering the shared
/// `ShelfExpiry.defaultValue` makes both readers see one value.
///
/// `shelf.agentSend.autoPaste` must never appear here: an unset key reading
/// false is the designed default, and registering it true would switch a
/// TCC-gated behaviour on for everyone (see `AgentSendInvariantTests`).
enum DefaultPreferences {
    static let values: [String: Any] = [
        "shelf.trigger.shake": true,
        "shelf.trigger.hotkey": true,
        "shelf.trigger.dragToEdge": true,
        "shelf.trigger.menuBarClick": true,
        "shelf.chatCopy.hotkey": true,
        ShelfExpiry.defaultsKey: ShelfExpiry.defaultValue.rawValue,
    ]

    /// Called once, at the top of `applicationDidFinishLaunching`, before any
    /// reader. The registration domain is volatile, so this must happen on
    /// every launch.
    static func register(into defaults: UserDefaults = .standard) {
        defaults.register(defaults: values)
    }
}
