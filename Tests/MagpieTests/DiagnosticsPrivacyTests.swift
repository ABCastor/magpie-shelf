import Foundation
import XCTest
@testable import Magpie

/// The diagnostics blob exists to be pasted into a public issue by someone who
/// will not read it first. So the guard is not "does it contain a known-bad
/// string" — a fixture-based grep passes forever the moment someone adds a
/// field the fixture never contained. The guard is the **closed key list**: a
/// report must carry exactly the keys `Diagnostics.keys` names, in that order,
/// so a new field goes red until a human updates the list and asks what they
/// just put in there.
///
/// The substring checks below sit on top of that, driven by a real store loaded
/// from disk holding exactly the things that must never escape.
final class DiagnosticsPrivacyTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    /// The things a shelf actually holds, all of which identify a person.
    private let shelfName = "Rosa Whitfield's tax return"
    private let secretFilePath = "/Users/someone/Documents/P45.pdf"
    private let snippet = "sort code 04-00-04, account 12345678"
    private let secretName = "GEMINI_API_KEY"
    private let routeCommand = "/Users/someone/bin/x.sh"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("shelf.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_report_carries_exactly_the_declared_keys_in_order() {
        XCTAssertEqual(Self.sampleRows().map(\.key), Diagnostics.keys)
    }

    func test_declared_keys_are_unique() {
        XCTAssertEqual(Set(Diagnostics.keys).count, Diagnostics.keys.count)
    }

    @MainActor
    func test_report_built_from_a_real_store_holds_none_of_what_the_store_held() throws {
        let loaded = try loadStoreHoldingPrivateThings()
        let routes = RouteStore(fileURL: tempDir.appendingPathComponent("routes.json"))
        let rows = Diagnostics.rows(
            appVersion: "1.4.0",
            build: "1.4.0",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Diagnostics.currentArchitecture,
            language: "en",
            shelfCount: loaded.shelves.count,
            itemCount: loaded.shelves.reduce(0) { $0 + $1.items.count },
            storeOutcome: loaded.outcome,
            managedCacheBytes: 123_456_789,
            routeCount: routes.routes.count,
            routeFileHasError: routes.parseError != nil,
            secretCount: 1,
            triggers: Diagnostics.Trigger.allCases,
            agent: .claudeCode,
            autoPaste: true,
            menuBarVisible: true,
            updateChecks: .automatic
        )
        let report = Diagnostics.text(rows)

        // The fixtures really did hold these, or this test proves nothing. The
        // bytes on disk are the check, not the loaded model: an item pointing
        // at a file that is not on this machine is dropped at load time, which
        // would quietly turn the leak test into a test of an empty store.
        let onDisk = try String(contentsOf: storeURL, encoding: .utf8)
        for planted in [shelfName, secretFilePath, snippet] {
            XCTAssertTrue(
                onDisk.contains(Self.jsonEscaped(planted)),
                "the fixture never held \(planted)"
            )
        }
        XCTAssertEqual(loaded.shelves.first?.name, shelfName)
        XCTAssertEqual(routes.routes.first?.command, routeCommand)

        for forbidden in [shelfName, secretFilePath, snippet, secretName, routeCommand] {
            XCTAssertFalse(
                report.contains(forbidden),
                "the report leaked \(forbidden)"
            )
        }
        XCTAssertFalse(report.contains("/Users/"), "the report leaked a home directory path")
        XCTAssertFalse(
            report.contains(NSHomeDirectory()),
            "the report leaked this machine's home directory"
        )
        XCTAssertFalse(report.contains(tempDir.path), "the report leaked the store's location")
    }

    /// A quarantine outcome carries a URL so the launch alert can reveal the
    /// file. That URL must not ride into the report with it.
    func test_quarantine_outcome_contributes_only_its_name_not_its_path() {
        let preserved = tempDir.appendingPathComponent("shelf.corrupt-1700000000000.json")
        let rows = Self.sampleRows(storeOutcome: .quarantined(preservedAt: preserved))
        let report = Diagnostics.text(rows)

        XCTAssertEqual(rows.first { $0.key == "store" }?.value, "quarantined")
        XCTAssertFalse(report.contains(preserved.path))
        XCTAssertFalse(report.contains("/Users/"))
    }

    /// The cache row is a bare byte count and nothing else. A size can ride
    /// into a public issue; a file name from inside ManagedFiles cannot be
    /// allowed to.
    func test_cache_row_is_a_bare_byte_count() {
        XCTAssertEqual(
            Self.sampleRows().first { $0.key == "cache" }?.value, "42",
            "the cache row stopped being the plain byte count it was handed"
        )
    }

    func test_report_ends_with_the_log_command_and_a_warning() {
        let report = Diagnostics.text(Self.sampleRows())

        XCTAssertTrue(
            report.contains(Diagnostics.logCommand),
            "nobody has ever been told the logs are already on disk"
        )
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(lines.last ?? ""), L("diagnostics.review-warning"))
    }

    /// Under `swift run` and in this very test bundle there is no Info.plist at
    /// all, so the version has to read as an answer rather than a blank.
    func test_version_is_nil_safe() {
        XCTAssertEqual(Diagnostics.versionDisplay(appVersion: nil, build: nil), "unknown")
        XCTAssertEqual(Diagnostics.versionDisplay(appVersion: "", build: "3"), "unknown")
        XCTAssertEqual(Diagnostics.versionDisplay(appVersion: "1.4.0", build: nil), "1.4.0")
        XCTAssertEqual(Diagnostics.versionDisplay(appVersion: "1.4.0", build: "1.4.0"), "1.4.0")
        XCTAssertEqual(Diagnostics.versionDisplay(appVersion: "1.4.0", build: "42"), "1.4.0 (42)")
    }

    // MARK: - Fixtures

    /// `JSONEncoder` writes every `/` as `\/`, so a plain substring search for
    /// a path in `shelf.json` looks for something that is never in the file —
    /// and the "the fixture really held it" check would pass by never firing.
    private static func jsonEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "\\/")
    }

    private func loadStoreHoldingPrivateThings() throws -> ShelfStoreContents {
        let store = ShelfStore(storeURL: storeURL)
        let file = ShelfItem(
            type: .file,
            fileURL: URL(fileURLWithPath: secretFilePath),
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let text = ShelfItem(
            type: .text,
            fileURL: ShelfItem.writeTextToTemp(snippet),
            textContent: snippet,
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        store.save(
            shelves: [Shelf(items: [file, text], name: shelfName)],
            currentShelfID: nil
        )
        // Whatever else a route file holds, its command is a path on this Mac.
        let routeFile = """
        { "routes": [ { "id": "x", "name": "X", "command": "\(routeCommand)" } ] }
        """
        try Data(routeFile.utf8).write(to: tempDir.appendingPathComponent("routes.json"))
        return store.load()
    }

    private static func sampleRows(
        storeOutcome: ShelfStore.LoadOutcome = .healthy
    ) -> [Diagnostics.Row] {
        Diagnostics.rows(
            appVersion: "1.4.0",
            build: "1.4.0",
            systemVersion: "Version 15.5 (Build 24F74)",
            architecture: Diagnostics.currentArchitecture,
            language: "en",
            shelfCount: 2,
            itemCount: 7,
            storeOutcome: storeOutcome,
            managedCacheBytes: 42,
            routeCount: 1,
            routeFileHasError: false,
            secretCount: 1,
            triggers: [.shake, .hotkey],
            agent: .claudeCode,
            autoPaste: false,
            menuBarVisible: true,
            updateChecks: .automatic
        )
    }
}
