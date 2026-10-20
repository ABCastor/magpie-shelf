import Foundation

/// Whether this build can actually check for updates.
///
/// Sparkle verifies every update against an EdDSA public key baked into
/// `Info.plist` as `SUPublicEDKey`. With no key — or a placeholder, which is
/// what `scripts/install-local.sh` writes so a local build can exist at all
/// without the private half — `SPUStandardUpdaterController(startingUpdater:)`
/// fails to start and Sparkle puts up **"Unable to Check For Updates ... The
/// updater failed to start"** at every launch.
///
/// That alert is correct and useless: it fires on a build that was never going
/// to update, tells the user to contact the developer about a condition the
/// developer created deliberately, and does it every single time.
///
/// So the updater is not started at all unless a real key is present. This is
/// not only a local-build concern: anyone who clones the repo and builds it
/// gets the same placeholder, and an open-source project whose first-run
/// experience is an error dialog has a bug, not a configuration.
enum UpdateAvailability {

    /// Written by `scripts/install-local.sh` when no real key is configured.
    static let placeholderKey = "LOCAL_BUILD_PLACEHOLDER_NOT_A_REAL_KEY"

    /// An Ed25519 public key is 32 bytes, which is 44 characters of base64.
    /// Anything shorter cannot be one, whatever else it is.
    static let minimumPlausibleKeyLength = 40

    /// Pure so the decision is testable without a bundle: `nil` is "no key at
    /// all", which is what a source build with no configuration produces.
    static func isConfigured(publicKey: String?) -> Bool {
        guard let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              key != placeholderKey,
              key.count >= minimumPlausibleKeyLength
        else { return false }
        // A real key is base64. A human-readable sentinel someone invents later
        // will almost certainly contain a character that is not.
        let base64 = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return key.unicodeScalars.allSatisfy { base64.contains($0) }
    }

    /// The running app's answer.
    static var isConfigured: Bool {
        isConfigured(publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    /// What the Settings toggle may show. Pure, because the defect it guards
    /// was visual: on a build with no signing key the stored preference still
    /// reads true, so the toggle sat live-looking and ON for an updater that
    /// was never started. Off and disabled is the only display that matches
    /// what the build can actually do; on a configured build the stored
    /// preference is the truth and passes through untouched.
    static func displayedAutoCheck(
        configured: Bool, stored: Bool
    ) -> (isOn: Bool, isEnabled: Bool) {
        configured ? (stored, true) : (false, false)
    }
}
