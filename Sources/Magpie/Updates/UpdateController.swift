import AppKit
import Sparkle

/// Owns the Sparkle updater controller. One instance, created at launch and
/// retained for the app's lifetime by AppDelegate.
///
/// We use SPUStandardUpdaterController (vs SPUUpdater + SPUStandardUserDriver
/// directly) because it provides the standard prompt UI and binds correctly
/// to NSMenuItem validation out of the box.
@MainActor
final class UpdateController {
    /// Exposed so the menu item can target it directly with
    /// `#selector(SPUStandardUpdaterController.checkForUpdates(_:))`. That
    /// hookup gives us automatic NSMenuItem validation (Sparkle disables the
    /// item while a check or download is already running) without any glue.
    let updaterController: SPUStandardUpdaterController

    /// False when this build has no usable Sparkle signing key. See
    /// `UpdateAvailability`. The status-menu row reads this to grey itself
    /// out; the Settings toggle never sees this controller and reads
    /// `UpdateAvailability.isConfigured` directly — same underlying answer,
    /// so the app says it once, quietly, instead of Sparkle shouting it at
    /// every launch.
    let isAvailable: Bool

    init() {
        isAvailable = UpdateAvailability.isConfigured

        // startingUpdater is gated on the key. Starting it without one makes
        // Sparkle fail and put up "Unable to Check For Updates — the updater
        // failed to start" on EVERY launch, which is what a local build and
        // every fresh clone of this repo did. Not starting it is the honest
        // state: a build that cannot verify an update must not offer to fetch
        // one. Constructed either way so the menu target stays non-optional.
        //
        // userDriverDelegate: nil — the standard driver's defaults are fine
        // (modal "Update available" prompt; auto-installs on quit if the user
        // chose "Install on Quit").
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isAvailable,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Bridges Sparkle's `SUEnableAutomaticChecks` UserDefaults key, which is
    /// the key that SPUUpdater reads itself. Setting it through Sparkle's API
    /// (`updater.automaticallyChecksForUpdates`) would also work, but the raw
    /// key is what the persisted setting is. SettingsView does not call this:
    /// it persists through the same raw key via `@AppStorage`, with the same
    /// absent-key fallback of `true`. This static is where that contract (the
    /// key name plus Sparkle's documented default when it is absent) is
    /// written down and tested, so the two readers cannot drift apart.
    static var automaticallyChecksForUpdates: Bool {
        get {
            // Sparkle's documented default is `true` when the key is absent.
            if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks")
        }
    }
}
