import Foundation

/// The text a user copies into a bug report.
///
/// Everything here is a scalar handed in by the caller. There is deliberately
/// no way to reach a `Shelf`, a `ShelfItem`, a `Route` or a secret from inside
/// this file — not a count of them, an *instance* of them — because the whole
/// value of the report is that it can be pasted into a public issue without
/// reading it first. `SecretStore` already refuses to hand out values; this
/// goes one step further and never asks it anything but how many there are.
///
/// `keys` is a closed list and `DiagnosticsPrivacyTests` asserts a report
/// carries exactly it, in order. That is the guard that survives: a field
/// someone adds in six months to help debug something turns the test red until
/// a human updates the list, which is the moment to ask what they just added.
enum Diagnostics {
    typealias Row = (key: String, value: String)

    static let keys = [
        "app",
        "macos",
        "arch",
        "language",
        "shelves",
        "items",
        "store",
        "cache",
        "routes",
        "routes-error",
        "secrets",
        "triggers",
        "agent",
        "auto-paste",
        "menu-bar",
        "updates",
    ]

    /// The summon triggers, as fixed identifiers. An enum rather than strings
    /// so no caller can pass something it read off the user's disk.
    enum Trigger: String, CaseIterable {
        case shake
        case hotkey
        case screenEdge = "screen-edge"
        case menuBarClick = "menu-bar-click"
    }

    enum UpdateChecks: String {
        case automatic
        case manual
        /// No Sparkle signing key in this build, so it cannot check at all.
        case unavailable
    }

    /// A compile-time constant, so an Intel Mac and an Apple Silicon one are
    /// distinguishable in a report without asking the machine anything.
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// What only the shelf model knows. Four scalars, gathered where the model
    /// lives so Settings never has to hold it.
    struct ShelfSnapshot: Equatable {
        var shelfCount: Int
        var itemCount: Int
        var storeOutcome: ShelfStore.LoadOutcome
        /// The bytes `ManagedFiles` holds right now. A count of bytes, never a
        /// name: the report must stay pasteable unread.
        var managedCacheBytes: Int64

        /// For previews and any caller with no model to hand. `.healthy` is the
        /// honest default: a caller with no store has no failure to report.
        static let empty = ShelfSnapshot(
            shelfCount: 0, itemCount: 0, storeOutcome: .healthy, managedCacheBytes: 0
        )
    }

    /// The version, for the Settings row and the report's first line.
    ///
    /// `Bundle.main.infoDictionary` is nil under `swift run` — the README says
    /// as much, which is why the `magpie://` scheme is unregistered there — so
    /// this has to read as an answer rather than as a blank row.
    static func versionDisplay(appVersion: String?, build: String?) -> String {
        guard let appVersion, !appVersion.isEmpty else { return "unknown" }
        guard let build, !build.isEmpty, build != appVersion else { return appVersion }
        return "\(appVersion) (\(build))"
    }

    /// Pure. Every value is either handed in or a constant, so what the report
    /// can contain is decided entirely by this signature.
    static func rows(
        appVersion: String?,
        build: String?,
        systemVersion: String,
        architecture: String,
        language: String,
        shelfCount: Int,
        itemCount: Int,
        storeOutcome: ShelfStore.LoadOutcome,
        managedCacheBytes: Int64,
        routeCount: Int,
        routeFileHasError: Bool,
        secretCount: Int,
        triggers: [Trigger],
        agent: AgentHarness,
        autoPaste: Bool,
        menuBarVisible: Bool,
        updateChecks: UpdateChecks
    ) -> [Row] {
        return [
            ("app", versionDisplay(appVersion: appVersion, build: build)),
            ("macos", systemVersion),
            ("arch", architecture),
            ("language", language),
            ("shelves", String(shelfCount)),
            ("items", String(itemCount)),
            ("store", storeOutcome.key),
            // Raw bytes, not a formatted size: ByteCountFormatter localizes,
            // and the report has to read the same in every language.
            ("cache", String(managedCacheBytes)),
            ("routes", String(routeCount)),
            ("routes-error", yesNo(routeFileHasError)),
            ("secrets", String(secretCount)),
            ("triggers", triggers.isEmpty
                ? "none"
                : triggers.map(\.rawValue).joined(separator: ", ")),
            ("agent", agent.rawValue),
            ("auto-paste", yesNo(autoPaste)),
            ("menu-bar", menuBarVisible ? "shown" : "hidden"),
            ("updates", updateChecks.rawValue),
        ]
    }

    /// The shell command that pulls Magpie's own log lines back out of the
    /// unified log. Every `NSLog` the app makes is already there and persisted;
    /// nobody had ever been told so. Filtering by process catches both the
    /// "Shelf:" and "Magpie:" prefixes the app writes.
    static let logCommand =
        #"log show --predicate 'process == "Magpie"' --last 1h"#

    /// What lands on the clipboard.
    static func text(_ rows: [Row]) -> String {
        let width = rows.map(\.key.count).max() ?? 0
        let body = rows.map { row in
            row.key.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  " + row.value
        }
        return (["Magpie diagnostics", ""] + body + [
            "",
            L("diagnostics.logs-hint"),
            logCommand,
            "",
            L("diagnostics.review-warning"),
        ]).joined(separator: "\n")
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
