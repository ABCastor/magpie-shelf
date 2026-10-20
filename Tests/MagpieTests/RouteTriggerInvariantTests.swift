import Foundation
import XCTest
@testable import Magpie

/// Routes execute code the owner wrote, which is acceptable only because
/// the owner starts them, from a menu, by hand. These tests read the sources
/// and fail the moment a second way to start one appears, including the one ADR
/// 0003 forbids permanently, a `magpie://` URL.
///
/// A unit test cannot assert "nothing automated calls this"; what it can
/// assert is that the call graph has exactly one door, and name every file
/// allowed to knock on it.
final class RouteTriggerInvariantTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie")
    }

    private func swiftFiles() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(atPath: sources.path)
        )
        var files: [(String, String)] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let url = sources.appendingPathComponent(relative)
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    private func files(containing needle: String) throws -> Set<String> {
        Set(try swiftFiles().filter { $0.text.contains(needle) }.map(\.name))
    }

    func test_only_the_two_menu_surfaces_can_start_a_route() throws {
        XCTAssertEqual(
            try files(containing: "RouteLauncher.run("),
            ["ShelfContextMenu.swift", "ShelfActionMenu.swift"],
            "a new caller of RouteLauncher.run appeared — is it a click the user made?"
        )
    }

    func test_the_launcher_is_the_only_thing_that_enqueues_a_run() throws {
        // Named `enqueueRun` rather than `enqueue` precisely so this check can
        // be exact: the declaration, and the launcher. Nothing else.
        XCTAssertEqual(
            try files(containing: "enqueueRun("),
            ["RouteMenu.swift", "RouteService.swift"],
            "route enqueueing must stay behind RouteLauncher"
        )
    }

    func test_the_inbound_url_layer_knows_nothing_about_routes() throws {
        let magpieURL = try String(
            contentsOf: sources.appendingPathComponent("MagpieURL.swift"), encoding: .utf8
        )
        XCTAssertFalse(
            magpieURL.contains("Route"),
            "MagpieURL must not reference any route type — ADR 0003 decision 2"
        )

        let app = try String(
            contentsOf: sources.appendingPathComponent("App.swift"), encoding: .utf8
        )
        for marker in [
            "func application(_ application: NSApplication, open urls: [URL]) {",
            "private func addFiles(from url: URL) {",
        ] {
            let body = try XCTUnwrap(
                Self.body(after: marker, in: app),
                "could not find \(marker) — the invariant test needs updating"
            )
            XCTAssertFalse(
                body.lowercased().contains("route"),
                "the inbound URL handler must only add files and show the panel"
            )
        }
    }

    func test_only_the_app_delegate_owns_a_route_service() throws {
        XCTAssertEqual(
            try files(containing: "RouteService("),
            ["App.swift"],
            "a second RouteService would be a second, unwired way to run commands"
        )
    }

    /// A stored secret can be read back by exactly one thing: the runner's
    /// default secret provider. Nothing in the UI, the menus or the URL layer
    /// can reach a value.
    func test_secret_values_are_readable_from_one_place_only() throws {
        XCTAssertEqual(try files(containing: "SecretStore.value("), ["RouteService.swift"])
        XCTAssertEqual(try files(containing: "kSecReturnData"), ["SecretStore.swift"])
    }

    /// Route output goes through `ShelfManager.addFile`, the app's only ingest
    /// path, so it gets the same copy-in, dedupe and thumbnail as a dragged
    /// file — and no route ever writes into the shelf model directly.
    func test_route_results_reach_the_shelf_through_the_normal_ingest_path() throws {
        let app = try String(
            contentsOf: sources.appendingPathComponent("App.swift"), encoding: .utf8
        )
        XCTAssertTrue(app.contains("for url in success.producedFiles {"))
        XCTAssertTrue(app.contains("self.manager.addFile(url: url, to: shelfID)"))
    }

    /// Nothing on the route path may move, rename, replace or delete anything:
    /// ADR 0001's invariant, asserted against the sources that could break it.
    func test_no_route_source_file_mutates_a_user_file() throws {
        let forbidden = ["moveItem(", "removeItem(", "replaceItemAt(", "linkItem(", "trashItem("]
        for file in try swiftFiles() where file.name.hasPrefix("Route") {
            for call in forbidden {
                XCTAssertFalse(
                    file.text.contains(call),
                    "\(file.name) calls \(call) — routes are copy-only"
                )
            }
        }
    }

    /// The body of the first function whose signature matches `marker`,
    /// by brace balance.
    private static func body(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        var depth = 1
        var body = ""
        for character in text[range.upperBound...] {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(character)
        }
        return nil
    }
}
