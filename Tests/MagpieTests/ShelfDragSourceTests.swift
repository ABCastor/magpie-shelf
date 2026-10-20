import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Magpie

@MainActor
final class ShelfDragSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfDragSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Move vs copy on drag-out

    func test_card_stays_when_source_file_still_exists() throws {
        let source = tempDir.appendingPathComponent("still-here.txt")
        try Data("still here".utf8).write(to: source)

        XCTAssertFalse(DragOutcome.shouldRemoveCardAfterDrag(
            sourceURL: source,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ))
    }

    func test_card_is_removed_when_source_file_is_gone() throws {
        let source = tempDir.appendingPathComponent("moved-away.txt")
        try Data("moved away".utf8).write(to: source)
        try FileManager.default.moveItem(
            at: source, to: tempDir.appendingPathComponent("destination.txt")
        )

        XCTAssertTrue(DragOutcome.shouldRemoveCardAfterDrag(
            sourceURL: source,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ))
    }

    func test_card_stays_when_item_has_no_resolvable_location() {
        var checked = false
        XCTAssertFalse(DragOutcome.shouldRemoveCardAfterDrag(
            sourceURL: nil,
            fileExists: { _ in checked = true; return false }
        ))
        XCTAssertFalse(checked, "no location to check means no filesystem question to ask")
    }
}
