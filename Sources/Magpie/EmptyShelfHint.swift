import Foundation

/// What the empty collapsed shelf says.
///
/// The empty state is the one surface a stranger is guaranteed to look at, so
/// it is where the app names the summon triggers — but only the ones that are
/// actually switched on, with the shortcut the user actually configured. A
/// hint that mentions shaking after the user turned shake off is teaching a
/// gesture that does nothing.
///
/// A value type with no SwiftUI in it, so what the empty state claims can be
/// asserted directly — the same split as `SettingsSearch` and `OCRMenu`, and
/// the reason "Drop or shake here" could previously sit translated in nine
/// tables while no view ever showed it.
///
/// Deliberately quiet: at most two short lines. Edge summon is not named —
/// it fires mid-drag and announces itself by appearing, which is a better
/// teacher than a sentence here would be. Neither is the menu-bar icon; the
/// user just clicked it to get here.
struct EmptyShelfHint: Equatable {
    /// The prompt line. Always present: drag-in is the one trigger that can
    /// never be switched off.
    let title: String
    /// One quiet line naming the summon shortcut, or nil when the hotkey
    /// trigger is off. The shortcut glyphs come from the preset the user
    /// chose, never from a hardcoded default.
    let subtitle: String?

    /// Pure over the trigger preferences as stored: the two switches and the
    /// chosen preset, exactly the values Settings writes.
    static func from(
        shakeEnabled: Bool,
        hotkeyEnabled: Bool,
        hotkeyPreset: HotkeyPreset
    ) -> EmptyShelfHint {
        EmptyShelfHint(
            title: shakeEnabled ? L("Drop or shake here") : L("Drop files here"),
            subtitle: hotkeyEnabled
                ? String(format: L("empty.summon-hint"), hotkeyPreset.displayName)
                : nil
        )
    }
}
