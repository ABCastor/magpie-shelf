import AppKit
import Foundation
import XCTest
@testable import Magpie

@MainActor
final class RouteMenuTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func route(id: String, match: RouteMatch?) -> Route {
        Route(
            id: id, name: "Route \(id)", symbol: "terminal", match: match,
            command: "/bin/echo", arguments: [], workingDirectory: nil,
            secrets: [], timeout: 5, collectsOutput: false, isEnabled: true
        )
    }

    private func item(named name: String) throws -> ShelfItem {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return ShelfItem(type: .file, fileURL: url)
    }

    func test_no_applicable_route_means_no_submenu() throws {
        let submenu = RouteMenu.makeSubmenu(
            routes: [route(id: "a", match: RouteMatch(extensions: ["pdf"], utis: []))],
            items: [try item(named: "note.txt")],
            target: self,
            action: #selector(noop)
        )
        XCTAssertNil(submenu)
    }

    func test_no_routes_at_all_means_no_submenu() throws {
        XCTAssertNil(RouteMenu.makeSubmenu(
            routes: [], items: [try item(named: "note.txt")],
            target: self, action: #selector(noop)
        ))
    }

    func test_a_text_snippet_with_no_file_offers_nothing() {
        let snippet = ShelfItem(type: .text, textContent: "hello")
        XCTAssertNil(RouteMenu.makeSubmenu(
            routes: [route(id: "a", match: nil)], items: [snippet],
            target: self, action: #selector(noop)
        ))
    }

    func test_matching_routes_become_rows_carrying_their_id() throws {
        let submenu = try XCTUnwrap(RouteMenu.makeSubmenu(
            routes: [
                route(id: "any", match: nil),
                route(id: "text-only", match: RouteMatch(extensions: ["txt"], utis: [])),
                route(id: "pdf-only", match: RouteMatch(extensions: ["pdf"], utis: [])),
            ],
            items: [try item(named: "note.txt")],
            target: self,
            action: #selector(noop)
        ))
        XCTAssertEqual(submenu.items.count, 2)
        XCTAssertEqual(
            submenu.items.compactMap { $0.representedObject as? String },
            ["any", "text-only"]
        )
        XCTAssertEqual(submenu.items[0].title, "Route any")
        XCTAssertTrue(submenu.items.allSatisfy { $0.target === self })
    }

    func test_a_mixed_selection_only_offers_routes_that_cover_all_of_it() throws {
        let items = [try item(named: "note.txt"), try item(named: "scan.pdf")]
        let submenu = RouteMenu.makeSubmenu(
            routes: [route(id: "text-only", match: RouteMatch(extensions: ["txt"], utis: []))],
            items: items, target: self, action: #selector(noop)
        )
        XCTAssertNil(submenu)

        let anything = try XCTUnwrap(RouteMenu.makeSubmenu(
            routes: [route(id: "any", match: nil)],
            items: items, target: self, action: #selector(noop)
        ))
        XCTAssertEqual(anything.items.count, 1)
    }

    func test_input_reads_the_real_type_of_a_file_on_disk() throws {
        let input = RouteMenu.input(for: try item(named: "page.pdf"))
        XCTAssertEqual(input.pathExtension, "pdf")
        XCTAssertEqual(input.typeIdentifier, "com.adobe.pdf")
    }

    @objc private func noop() {}
}
