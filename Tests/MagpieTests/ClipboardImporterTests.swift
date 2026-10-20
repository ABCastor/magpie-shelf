import AppKit
import XCTest
@testable import Magpie

@MainActor
final class ClipboardImporterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        pasteboard = NSPasteboard(name: .init("ClipboardImporterTests-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
    }

    func test_concealed_pasteboard_imports_nothing() {
        pasteboard.declareTypes([.string, ClipboardImporter.concealedType], owner: nil)
        pasteboard.setString("correct horse battery staple", forType: .string)
        pasteboard.setData(Data(), forType: ClipboardImporter.concealedType)

        let result = importClipboard()

        XCTAssertTrue(ClipboardImporter.isConcealed(pasteboard))
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.texts.isEmpty)
    }

    func test_ordinary_text_pasteboard_still_imports() {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("a perfectly ordinary snippet", forType: .string)

        let result = importClipboard()

        XCTAssertFalse(ClipboardImporter.isConcealed(pasteboard))
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.texts, ["a perfectly ordinary snippet"])
    }

    func test_ordinary_file_pasteboard_still_imports() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardImporterTests-\(UUID().uuidString).txt")
        try Data("file bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        let result = importClipboard()

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.files.map(\.lastPathComponent), [url.lastPathComponent])
    }

    private func importClipboard() -> (added: Int, files: [URL], texts: [String]) {
        var files: [URL] = []
        var texts: [String] = []
        let added = ClipboardImporter.addFromClipboard(
            from: pasteboard,
            addFile: { files.append($0) },
            addText: { texts.append($0) }
        )
        return (added, files, texts)
    }
}
