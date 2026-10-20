import Foundation
import XCTest
@testable import Magpie

@MainActor
final class RouteStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = tempDir.appendingPathComponent("routes.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
    }

    func test_first_run_writes_the_self_teaching_default() throws {
        let store = RouteStore(fileURL: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(store.parseError)
        // Both shipped examples are switched off, so a fresh install shows no
        // Routes submenu until the owner has edited one.
        XCTAssertTrue(store.routes.isEmpty)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"_readme\""), "the header has to travel with the file")
        XCTAssertTrue(contents.contains("{files}"))
        XCTAssertTrue(contents.contains("{output}"))
    }

    func test_an_existing_file_is_never_overwritten() throws {
        try write("""
        { "routes": [ { "id": "mine", "name": "Mine", "command": "/bin/echo" } ] }
        """)
        let store = RouteStore(fileURL: fileURL)
        XCTAssertEqual(store.routes.map(\.id), ["mine"])
        XCTAssertTrue(try String(contentsOf: fileURL, encoding: .utf8).contains("\"mine\""))
    }

    func test_disabled_routes_stay_out_of_the_menus() throws {
        try write("""
        { "routes": [
            { "id": "on", "name": "On", "command": "/bin/echo" },
            { "id": "off", "name": "Off", "command": "/bin/echo", "enabled": false }
        ] }
        """)
        XCTAssertEqual(RouteStore(fileURL: fileURL).routes.map(\.id), ["on"])
    }

    func test_a_broken_edit_reports_itself_and_keeps_the_last_good_routes() throws {
        try write("""
        { "routes": [ { "id": "mine", "name": "Mine", "command": "/bin/echo" } ] }
        """)
        let store = RouteStore(fileURL: fileURL)
        XCTAssertEqual(store.routes.count, 1)

        try write("{ \"routes\": [ { \"id\": \"mine\" ")
        store.reload()

        XCTAssertEqual(store.parseError, .invalidJSON)
        XCTAssertEqual(
            store.routes.map(\.id), ["mine"],
            "a half-typed edit must not empty the menus mid-keystroke"
        )
    }

    func test_a_fixed_file_clears_the_error_on_reload() throws {
        try write("{ nonsense")
        let store = RouteStore(fileURL: fileURL)
        XCTAssertNotNil(store.parseError)

        try write("""
        { "routes": [ { "id": "fixed", "name": "Fixed", "command": "/bin/echo" } ] }
        """)
        store.reload()

        XCTAssertNil(store.parseError)
        XCTAssertEqual(store.routes.map(\.id), ["fixed"])
    }

    func test_lookup_by_id_only_finds_loaded_routes() throws {
        try write("""
        { "routes": [ { "id": "mine", "name": "Mine", "command": "/bin/echo" } ] }
        """)
        let store = RouteStore(fileURL: fileURL)
        XCTAssertNotNil(store.route(id: "mine"))
        XCTAssertNil(store.route(id: "not-a-route"))
    }
}
