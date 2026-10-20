import AppKit
import XCTest
@testable import Magpie

final class ShelfItemTests: XCTestCase {
    func test_with_preserves_fields_and_supports_explicit_nil_overrides() {
        let originalURL = URL(fileURLWithPath: "/tmp/original")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement")
        let original = ShelfItem(
            id: UUID(),
            type: .file,
            fileURL: originalURL,
            bookmarkData: Data([1, 2, 3]),
            persistedPath: originalURL.path,
            textContent: "text",
            thumbnail: NSImage(size: NSSize(width: 1, height: 1)),
            thumbnailIsIcon: true,
            createdAt: Date(timeIntervalSince1970: 123),
            pixelSize: CGSize(width: 4, height: 3),
            pageCount: 2,
            isDirectory: true,
            cachedFolderBytes: 7
        )

        let replacementThumbnail = NSImage(size: NSSize(width: 2, height: 2))
        let updated = original.with(
            fileURL: replacementURL,
            bookmarkData: .some(nil),
            persistedPath: .some(nil),
            thumbnail: replacementThumbnail,
            thumbnailIsIcon: false,
            cachedFolderBytes: 9
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.type, original.type)
        XCTAssertEqual(updated.fileURL, replacementURL)
        XCTAssertNil(updated.bookmarkData)
        XCTAssertNil(updated.persistedPath)
        XCTAssertEqual(updated.textContent, original.textContent)
        XCTAssertTrue(updated.thumbnail === replacementThumbnail)
        XCTAssertFalse(updated.thumbnailIsIcon)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.pixelSize, original.pixelSize)
        XCTAssertEqual(updated.pageCount, original.pageCount)
        XCTAssertEqual(updated.isDirectory, original.isDirectory)
        XCTAssertEqual(updated.cachedFolderBytes, 9)
    }
}
