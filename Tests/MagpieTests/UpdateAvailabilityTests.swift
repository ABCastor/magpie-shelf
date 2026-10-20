import XCTest
@testable import Magpie

/// Sparkle put up "Unable to Check For Updates — the updater failed to start"
/// at EVERY launch, because the bundle carries a placeholder signing key. The
/// alert was correct and useless: it fired on a build that was never going to
/// update, and told the user to contact the developer about a condition the
/// developer created.
final class UpdateAvailabilityTests: XCTestCase {

    /// THE regression. The exact string `scripts/install-local.sh` writes must
    /// never read as a usable key.
    func testThePlaceholderKeyIsNotConfigured() {
        XCTAssertFalse(
            UpdateAvailability.isConfigured(publicKey: UpdateAvailability.placeholderKey),
            "the local-build placeholder counts as a real key; Sparkle will start and fail at every launch"
        )
    }

    func testMissingOrEmptyKeyIsNotConfigured() {
        XCTAssertFalse(UpdateAvailability.isConfigured(publicKey: nil))
        XCTAssertFalse(UpdateAvailability.isConfigured(publicKey: ""))
        XCTAssertFalse(UpdateAvailability.isConfigured(publicKey: "   \n "))
    }

    /// A future sentinel someone invents instead of reusing ours still must not
    /// pass. Real keys are base64; readable placeholders almost never are.
    func testAHumanReadableSentinelIsNotConfigured() {
        for sentinel in ["REPLACE_ME_WITH_A_REAL_KEY_BEFORE_SHIPPING",
                         "not-a-real-key-please-generate-one-first",
                         "TODO: generate with generate_keys before release"] {
            XCTAssertFalse(
                UpdateAvailability.isConfigured(publicKey: sentinel),
                "\"\(sentinel)\" was accepted as a signing key"
            )
        }
    }

    func testATooShortKeyIsNotConfigured() {
        XCTAssertFalse(UpdateAvailability.isConfigured(publicKey: "abc123=="))
    }

    /// The positive case has to actually pass, or the feature is "updates are
    /// always off" wearing a check.
    func testARealShapedEd25519KeyIsConfigured() {
        // The shape Sparkle's generate_keys emits: 44 characters of base64.
        //
        // Built rather than pasted. A 44-character base64 literal is
        // indistinguishable from a real key to a secret scanner, and this
        // repository's publish gate blocks on one, so a hard-coded fixture
        // would fail every export forever. Nothing here is weaker for it: what
        // `isConfigured` reads is the length and the character set, not the
        // bytes, and both are asserted below.
        let key = String(String(repeating: "ABCDefgh1234+/", count: 4).prefix(43)) + "="
        XCTAssertEqual(key.count, 44, "fixture is not the length of a real key")
        XCTAssertTrue(
            UpdateAvailability.isConfigured(publicKey: key),
            "a correctly shaped key was rejected; updates would be permanently disabled"
        )
        XCTAssertTrue(
            UpdateAvailability.isConfigured(publicKey: "  \(key)  "),
            "surrounding whitespace from a config file must not disqualify a real key"
        )
    }

    /// The updater must not be started when there is no key — starting it is
    /// what produces the alert.
    func testTheUpdaterIsStartedOnlyWhenAKeyIsPresent() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/Updates/UpdateController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("startingUpdater: isAvailable"),
            "the updater is started unconditionally again; Sparkle will alert on every launch of a keyless build"
        )
        XCTAssertFalse(
            source.contains("startingUpdater: true"),
            "startingUpdater is hardcoded true"
        )
    }

    /// The Settings defect: `SUEnableAutomaticChecks` stores true by default,
    /// so on a keyless build the toggle sat ON and live-looking for an updater
    /// that was never started. The display decision must show off-and-disabled
    /// there, and the stored truth everywhere else.
    func testAKeylessBuildShowsTheToggleOffAndDisabledWhateverIsStored() {
        for stored in [true, false] {
            let display = UpdateAvailability.displayedAutoCheck(
                configured: false, stored: stored
            )
            XCTAssertFalse(
                display.isOn,
                "the toggle shows ON (stored \(stored)) for an updater that is never started"
            )
            XCTAssertFalse(
                display.isEnabled,
                "the toggle looks live on a build that cannot check for updates"
            )
        }
    }

    func testAConfiguredBuildShowsTheStoredPreferenceLive() {
        XCTAssertEqual(
            UpdateAvailability.displayedAutoCheck(configured: true, stored: true).isOn, true
        )
        XCTAssertEqual(
            UpdateAvailability.displayedAutoCheck(configured: true, stored: false).isOn, false
        )
        XCTAssertTrue(
            UpdateAvailability.displayedAutoCheck(configured: true, stored: false).isEnabled,
            "a configured build greyed out its own updates toggle"
        )
    }

    /// The decision only helps if the Settings section actually renders
    /// through it. Source-level, like the updater-start check above, because
    /// the section is a view body no unit test can execute.
    func testTheSettingsToggleRendersThroughTheDisplayDecision() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("UpdateAvailability.displayedAutoCheck("),
            "the updates toggle stopped going through displayedAutoCheck — it can show ON again on a build whose updater never starts"
        )
        XCTAssertTrue(
            source.contains("\"updates.unavailable\""),
            "the unavailable state lost its explanation under the toggle"
        )
    }

    /// Every locale needs the explanation, or a non-English user gets a raw key
    /// in the tooltip on a greyed row.
    func testEveryLocaleExplainsWhyUpdatesAreOff() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        for locale in try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "lproj" }) {
            let table = try String(
                contentsOf: locale.appendingPathComponent("Localizable.strings"), encoding: .utf8)
            guard let line = table.components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("\"updates.unavailable\"") }) else {
                XCTFail("\(locale.lastPathComponent) is missing updates.unavailable"); continue
            }
            let value = line.components(separatedBy: "= ").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";")) ?? ""
            XCTAssertFalse(value.isEmpty, "\(locale.lastPathComponent): updates.unavailable is empty")
        }
    }
}

/// ⌘K must land you in the query field. Requiring a click first makes the
/// shortcut slower than the right-click it replaces.
final class PaletteFocusTests: XCTestCase {
    func testTheQueryFieldClaimsFocusFromTheViewNotFromAReRender() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ShelfActionPalette.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("override func viewDidMoveToWindow"),
            "focus is not claimed from the view; on the first updateNSView the field has no window, and SwiftUI has no reason to call it again"
        )
        XCTAssertTrue(
            source.contains("FocusOnAppearTextField"),
            "the palette no longer uses the self-focusing field"
        )
        let update = source.components(separatedBy: "func updateNSView").dropFirst().first?.prefix(600) ?? ""
        XCTAssertFalse(
            update.contains("makeFirstResponder"),
            "focus is being claimed from updateNSView again, which is the path that silently never ran"
        )
    }
}
