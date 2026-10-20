import Foundation
import XCTest
@testable import Magpie

final class ShelfActionMenuTests: XCTestCase {
    func test_failed_zip_preserves_existing_destination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfActionMenuTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("Archive.zip")
        let original = Data("original archive".utf8)
        try original.write(to: destination)

        let failure = ZipArchiveWriter.write(to: destination) { archiveURL in
            try? Data("partial archive".utf8).write(to: archiveURL)
            return "forced zip failure"
        }

        XCTAssertNotNil(failure)
        XCTAssertEqual(try Data(contentsOf: destination), original)

        let replacement = Data("completed archive".utf8)
        let success = ZipArchiveWriter.write(to: destination) { archiveURL in
            try? replacement.write(to: archiveURL)
            return nil
        }

        XCTAssertNil(success)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
    }

    /// Runs the real `/usr/bin/zip` with the exact argv the menu action builds,
    /// over a staged folder salted with `.DS_Store` at two depths. `zip -r`
    /// recurses, so without the exclusion every archive a user sends carries
    /// Finder metadata junk into folders a stranger will open.
    func test_zip_archive_excludes_ds_store_at_every_depth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfActionMenuTests-zip-\(UUID().uuidString)")
        let staging = directory.appendingPathComponent("staging")
        let folder = staging.appendingPathComponent("Pics")
        let nested = folder.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("photo".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        try Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try Data("junk".utf8).write(to: nested.appendingPathComponent(".DS_Store"))

        let archive = directory.appendingPathComponent("Archive.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ZipArchiveWriter.arguments(
            archivePath: archive.path, basenames: ["Pics"]
        )
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "zip must succeed for the assertion to mean anything")

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", archive.path]
        let out = Pipe()
        list.standardOutput = out
        try list.run()
        list.waitUntilExit()
        let entries = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""

        XCTAssertTrue(entries.contains("Pics/photo.jpg"), "the real content must still be archived")
        XCTAssertTrue(entries.contains("Pics/Nested/deep.txt"), "recursion must still reach nested files")
        XCTAssertFalse(
            entries.contains(".DS_Store"),
            "the archive carries Finder metadata junk: \(entries)"
        )
    }
}
