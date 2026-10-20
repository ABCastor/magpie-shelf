import Foundation
import XCTest
@testable import Magpie

/// A fresh install must execute what its Settings window displays.
///
/// The defect these tests pin: the expiry picker displayed `@AppStorage`'s
/// fallback ("After 10 days") while `runShelfExpiryPrune` read the same key
/// with `integer(forKey:)`, got 0 for the unset key, and its `guard days > 0`
/// read 0 as "Never". Staged managed copies accumulated forever behind a UI
/// promising a ten-day cleanup. The repair is one registered value shared by
/// both readers; these tests hold each piece of that arrangement in place.
final class DefaultPreferencesTests: XCTestCase {
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

    func test_expiry_default_is_registered_and_matches_what_settings_displays() {
        XCTAssertEqual(
            DefaultPreferences.values[ShelfExpiry.defaultsKey] as? Int,
            ShelfExpiry.defaultValue.rawValue,
            "the registered expiry default must be the value the Settings picker displays"
        )
    }

    func test_the_registered_expiry_default_actually_prunes() throws {
        let days = try XCTUnwrap(
            DefaultPreferences.values[ShelfExpiry.defaultsKey] as? Int,
            "shelf.expiryDays fell out of the registered defaults — integer(forKey:) reads 0 again and the pruner treats a fresh install as Never"
        )
        XCTAssertGreaterThan(
            days, 0,
            "runShelfExpiryPrune skips on 0; registering 0 re-creates the release where Settings said After 10 days and nothing was ever pruned"
        )
    }

    /// The five flags that were in the old inline `register(defaults:)` call.
    /// Moving them here must not lose one: an unset trigger key reads false,
    /// which would silently switch that trigger off for every fresh install.
    func test_the_trigger_defaults_stay_registered_on() {
        for key in [
            "shelf.trigger.shake",
            "shelf.trigger.hotkey",
            "shelf.trigger.dragToEdge",
            "shelf.trigger.menuBarClick",
            "shelf.chatCopy.hotkey",
        ] {
            XCTAssertEqual(
                DefaultPreferences.values[key] as? Bool, true,
                "\(key) is no longer registered on — a fresh install loses that trigger"
            )
        }
    }

    /// The auto-paste key is TCC-gated and off by design; registering it would
    /// switch it on for everyone (`AgentSendInvariantTests` holds the readers).
    func test_auto_paste_is_never_registered() {
        XCTAssertNil(DefaultPreferences.values["shelf.agentSend.autoPaste"])
    }

    /// The values above only matter if launch registers them and both readers
    /// go through the shared key. Source-level, like the other invariant tests
    /// in this repo, because none of these call sites is reachable from a test.
    func test_launch_registers_and_both_readers_share_the_key() throws {
        let app = try source("App.swift")
        XCTAssertTrue(
            app.contains("DefaultPreferences.register()"),
            "applicationDidFinishLaunching no longer registers the defaults — a fresh install reads 0 and never prunes"
        )
        XCTAssertTrue(
            app.contains("integer(forKey: ShelfExpiry.defaultsKey)"),
            "the pruner stopped reading the shared expiry key"
        )
        XCTAssertFalse(
            app.contains("\"shelf.expiryDays\""),
            "a literal expiry key in App.swift is a second source of truth waiting to disagree"
        )
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(
            settings.contains("@AppStorage(ShelfExpiry.defaultsKey)"),
            "the Settings picker stopped declaring itself through the shared key"
        )
        XCTAssertTrue(
            settings.contains("= ShelfExpiry.defaultValue.rawValue"),
            "the picker's fallback drifted from the shared default"
        )
    }
}
