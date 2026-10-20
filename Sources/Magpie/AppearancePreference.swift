import AppKit

/// Whether the shelf follows the system's Light/Dark setting, or is pinned.
///
/// The default is `.system`, which is the decision recorded on 2026-07-28:
/// the panel floats over the user's real work, so a user in Light Mode should
/// not get a dark slab dropped over light content. The override exists because
/// "follow the system" is right for most people and wrong for some — a shelf
/// pinned dark over a light desktop is a legitimate preference, and pinning it
/// is cheaper than arguing with anyone about it.
///
/// Applying is a pure map to an `NSAppearance?` so it can be asserted without
/// an app running; `nil` means "inherit", which is what makes `.system` work.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The appearance to force, or `nil` to follow the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }

    static let defaultsKey = "shelf.appearance"

    static var current: AppearancePreference {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    /// Sets the process-wide appearance. Applies to every window the app owns —
    /// the shelf panels, Settings, and the status menu — so the app can never
    /// again disagree with itself about which appearance it is in.
    @MainActor
    static func apply(_ preference: AppearancePreference) {
        NSApp.appearance = preference.appearance
    }
}
