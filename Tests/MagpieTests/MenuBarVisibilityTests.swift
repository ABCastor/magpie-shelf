import AppKit
import XCTest
@testable import Magpie

/// Hiding the menu-bar item is safe **only** because two escape hatches exist.
/// Magpie is `LSUIElement`: no dock icon, and `App.swift` states outright that
/// the status menu is the only route to Settings, Check for Updates and Quit.
/// Remove the item without a way back and the user is stranded with a running
/// app they cannot configure and cannot quit — a worse version of the very
/// complaint this feature answers.
///
/// These tests exist so that stays true. The source scans are deliberately
/// ugly: a behavioural test cannot reach `applicationShouldHandleReopen`
/// without a running `NSApplication` and a real reopen event, so the next best
/// guarantee is that the code is present and wired.
@MainActor
final class MenuBarVisibilityTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - The preference

    /// An unset key must read as *shown*. If it read as hidden, a first launch
    /// would strand a user who had never seen the app.
    func testUnsetPreferenceShowsTheIcon() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MenuBarVisibility.defaultsKey)
        defer {
            if let original { defaults.set(original, forKey: MenuBarVisibility.defaultsKey) }
            else { defaults.removeObject(forKey: MenuBarVisibility.defaultsKey) }
        }

        defaults.removeObject(forKey: MenuBarVisibility.defaultsKey)
        XCTAssertTrue(MenuBarVisibility.isVisible, "an unset preference must show the icon")
        XCTAssertTrue(MenuBarVisibility.showsByDefault)
    }

    func testPreferenceDrivesTheStatusItem() {
        XCTAssertTrue(MenuBarVisibility.shouldShowStatusItem(preferenceIsVisible: true))
        XCTAssertFalse(MenuBarVisibility.shouldShowStatusItem(preferenceIsVisible: false))
    }

    /// The reopen hatch must be unconditional. A hatch that only opens when the
    /// icon is hidden is missing in the one case it is needed — a preference
    /// that was reset, or a store that was quarantined.
    func testReopenAlwaysOpensSettings() {
        XCTAssertTrue(
            MenuBarVisibility.reopenShouldOpenSettings(),
            "the way back into Settings must not be conditional on the preference it rescues"
        )
    }

    // MARK: - The escape hatches, in the shipped code

    /// Hatch 1: reopening the app opens Settings.
    func testAppDelegateImplementsReopenAndOpensSettings() throws {
        let app = try source("Sources/Magpie/App.swift")
        XCTAssertTrue(
            app.contains("func applicationShouldHandleReopen"),
            "without applicationShouldHandleReopen there is NO way back into Settings once the icon is hidden"
        )
        let reopenBody = app
            .components(separatedBy: "func applicationShouldHandleReopen")
            .dropFirst().first ?? ""
        XCTAssertTrue(
            reopenBody.prefix(400).contains("openSettingsAction"),
            "applicationShouldHandleReopen exists but does not open Settings, so it rescues nothing"
        )
    }

    /// Hatch 2: Settings can quit the app. With no status menu there is no
    /// other Quit anywhere in the product.
    func testSettingsCanQuitTheApp() throws {
        let settings = try source("Sources/Magpie/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("NSApp.terminate"),
            "Settings has no Quit; with the menu-bar item hidden the app cannot be quit at all"
        )
    }

    /// The toggle has to actually be reachable, or the preference is unusable
    /// by anyone who has already hidden the icon.
    func testSettingsExposesTheToggle() throws {
        let settings = try source("Sources/Magpie/SettingsView.swift")
        // Bound by symbol, not by the literal key — binding to a copy of the
        // string is exactly how the toggle and the app would silently drift
        // onto two different preferences.
        XCTAssertTrue(
            settings.contains("MenuBarVisibility.defaultsKey"),
            "the toggle must bind to MenuBarVisibility.defaultsKey, not a duplicated literal"
        )
        XCTAssertFalse(
            settings.contains("\"\(MenuBarVisibility.defaultsKey)\""),
            "the preference key is hardcoded in SettingsView; bind to the symbol instead"
        )
        XCTAssertTrue(settings.contains("Show Magpie in the menu bar"))
    }

    /// Changing the preference has to take effect on a running app. If it only
    /// applied at launch, turning the icon off would appear to do nothing and
    /// turning it back on would require a relaunch the user cannot trigger.
    func testVisibilityIsReappliedWhenDefaultsChange() throws {
        let app = try source("Sources/Magpie/App.swift")
        let handler = app
            .components(separatedBy: "func handleDefaultsChange")
            .dropFirst().first ?? ""
        XCTAssertTrue(
            handler.prefix(400).contains("applyMenuBarVisibility"),
            "the menu-bar preference is not reapplied live, so the toggle does nothing until relaunch"
        )
    }

    /// The item must be genuinely removed, not just hidden — `isVisible = false`
    /// can leave a gap, and the point of the feature is that nothing remains.
    func testHidingRemovesTheStatusItemRatherThanHidingIt() throws {
        let app = try source("Sources/Magpie/App.swift")
        XCTAssertTrue(
            app.contains("NSStatusBar.system.removeStatusItem"),
            "hiding must remove the status item, not set isVisible = false"
        )
    }

    /// Every localized table must carry the strings, or a non-English user
    /// hides the icon and gets a raw key where the instructions to get back in
    /// should be.
    func testEveryLocaleExplainsHowToGetBack() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
        let locales = try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        XCTAssertGreaterThanOrEqual(locales.count, 9, "expected the full set of string tables")

        for locale in locales {
            let table = try String(
                contentsOf: locale.appendingPathComponent("Localizable.strings"),
                encoding: .utf8
            )
            var values: [String: String] = [:]
            for key in [
                "Show Magpie in the menu bar",
                "Quit Magpie",
                "settings.menubar.description",
            ] {
                XCTAssertTrue(
                    table.contains("\"\(key)\""),
                    "\(locale.lastPathComponent) is missing \"\(key)\""
                )
                // Presence is not correctness. The first version of this test
                // asserted only that the keys existed, and passed while every
                // value in all nine tables was shifted one slot by a stray
                // shell argument — the toggle rendered with an EMPTY label and
                // the Quit button was captioned "Show Magpie in the menu bar".
                guard let line = table
                    .components(separatedBy: .newlines)
                    .first(where: { $0.hasPrefix("\"\(key)\"") }),
                    let value = line
                        .components(separatedBy: "= ").last?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
                else {
                    XCTFail("\(locale.lastPathComponent): could not parse \"\(key)\"")
                    continue
                }
                XCTAssertFalse(
                    value.isEmpty,
                    "\(locale.lastPathComponent): \"\(key)\" has an EMPTY value — the control will render unlabelled"
                )
                values[key] = value
            }

            // A shift shows up as one key carrying another key's name as its
            // value. No translation of a UI label is ever the literal text of
            // a different key.
            for (key, value) in values {
                for otherKey in values.keys where otherKey != key {
                    XCTAssertNotEqual(
                        value, otherKey,
                        "\(locale.lastPathComponent): \"\(key)\" has the value \"\(otherKey)\" — the table is shifted"
                    )
                }
            }

            XCTAssertFalse(
                values["settings.menubar.description"]?.contains("\n") ?? true,
                "\(locale.lastPathComponent): the recovery description must stay on one line"
            )
        }
    }
}
