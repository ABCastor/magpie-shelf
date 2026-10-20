import Foundation
import XCTest
@testable import Magpie

final class HandoffBundleTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var managed: URL!
    private var source: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandoffBundleTests-\(UUID().uuidString)")
        root = tempDir.appendingPathComponent("Handoff", isDirectory: true)
        managed = tempDir.appendingPathComponent("ManagedFiles", isDirectory: true)
        source = tempDir.appendingPathComponent("Sources", isDirectory: true)
        for dir in [root!, managed!, source!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, in dir: URL, bytes: Int = 16) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private func stage(_ items: [ShelfItem], now: Date = Date()) throws -> HandoffDrop {
        try HandoffBundle.stage(
            items: items,
            in: root,
            managedFilesDirectory: managed,
            now: now
        )
    }

    // MARK: - Where the root lives

    /// `Handoff/` sits beside `ManagedFiles/` under the app's own Application
    /// Support directory — a sibling of the managed cache, never a folder
    /// inside it and never one of the user's own.
    func test_the_handoff_root_is_a_sibling_of_the_managed_files_directory() {
        let managed = URL(
            fileURLWithPath: "/tmp/AppSupport/Magpie/ManagedFiles", isDirectory: true
        )
        XCTAssertEqual(
            HandoffBundle.root(besideManagedFiles: managed),
            URL(fileURLWithPath: "/tmp/AppSupport/Magpie/Handoff", isDirectory: true)
        )
    }

    // MARK: - Staging

    func test_drop_folder_name_is_a_timestamp_plus_six_hex() throws {
        let name = HandoffBundle.folderName()
        XCTAssertNotNil(HandoffBundle.date(fromFolderName: name))
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 8)
        XCTAssertEqual(parts[1].count, 6)
        XCTAssertEqual(parts[2].count, 6)
    }

    func test_two_drops_in_the_same_second_do_not_collide() throws {
        let now = Date()
        let first = try stage([], now: now)
        let second = try stage([], now: now)
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.folder.path))
    }

    func test_staging_copies_and_leaves_the_original_in_place() throws {
        let file = try writeFile("invoice.pdf", in: source)
        let originalInode = try inode(file)

        let drop = try stage([ShelfItem(type: .file, fileURL: file)])

        XCTAssertEqual(drop.copied, 1)
        XCTAssertEqual(drop.referenced, 0)
        XCTAssertEqual(drop.skipped, 0)

        // The original is untouched — ADR 0001: nothing but a user-initiated
        // Move to Trash may ever touch a user file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 0x41, count: 16))

        let copy = drop.folder.appendingPathComponent("invoice.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: file))
        // A distinct inode proves this was copyItem and not linkItem: unlinking
        // a hardlink's last name would destroy the user's file outright.
        XCTAssertNotEqual(try inode(copy), originalInode)
    }

    func test_same_named_items_get_distinct_names_in_the_drop() throws {
        let a = try writeFile("report.txt", in: source, bytes: 8)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let b = try writeFile("report.txt", in: nested, bytes: 32)

        let drop = try stage([
            ShelfItem(type: .file, fileURL: a),
            ShelfItem(type: .file, fileURL: b),
        ])

        XCTAssertEqual(drop.copied, 2)
        XCTAssertEqual(Set(drop.entries.map(\.name)).count, 2)
        XCTAssertTrue(drop.entries.contains { $0.name == "report.txt" })
        XCTAssertTrue(drop.entries.contains { $0.name == "report (1).txt" })
    }

    func test_text_without_a_backing_file_becomes_a_note() throws {
        let drop = try stage([
            ShelfItem(type: .text, textContent: "first snippet"),
            ShelfItem(type: .text, textContent: "second snippet"),
        ])

        XCTAssertEqual(drop.copied, 2)
        XCTAssertEqual(drop.entries.map(\.name), ["note-1.md", "note-2.md"])
        XCTAssertEqual(
            try String(contentsOf: drop.folder.appendingPathComponent("note-1.md"), encoding: .utf8),
            "first snippet"
        )
    }

    func test_items_whose_file_vanished_are_counted_as_skipped() throws {
        let present = try writeFile("here.txt", in: source)
        let gone = source.appendingPathComponent("gone.txt")

        let drop = try stage([
            ShelfItem(type: .file, fileURL: present),
            ShelfItem(type: .file, fileURL: gone),
            ShelfItem(type: .file, fileURL: nil),
        ])

        XCTAssertEqual(drop.copied, 1)
        XCTAssertEqual(drop.skipped, 2)
    }

    /// The drop folder plus one last path component is the only destination
    /// staging ever builds, and a last path component cannot hold a separator.
    /// Refusing "." and ".." closes the only remaining way out of the drop.
    func test_a_relative_traversal_name_is_refused_rather_than_staged() throws {
        let drop = try stage([
            ShelfItem(type: .file, fileURL: source.appendingPathComponent("..")),
            ShelfItem(type: .file, fileURL: source.appendingPathComponent(".")),
        ])
        XCTAssertEqual(drop.entries.count, 0)
        XCTAssertEqual(drop.skipped, 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: drop.folder.path), []
        )
    }

    func test_a_managed_cache_copy_is_never_reported_as_the_original() throws {
        let cached = try writeFile("screenshot-ab12cd34.png", in: managed)
        let real = try writeFile("photo.png", in: source)

        let drop = try stage([
            ShelfItem(type: .image, fileURL: cached),
            ShelfItem(type: .image, fileURL: real),
        ])

        guard drop.entries.count == 2 else { return XCTFail("expected two entries") }
        guard case .magpieCache = drop.entries[0].origin else {
            return XCTFail("a ManagedFiles path is Magpie's own copy, not provenance")
        }
        guard case .path(let path) = drop.entries[1].origin else {
            return XCTFail("a user file keeps its real path")
        }
        XCTAssertEqual(path, real.path)

        // The cache path must not leak into the manifest at all: the eviction
        // can delete it later, so anything that linked it would rot.
        let manifest = HandoffPrompt.manifest(drop)
        XCTAssertFalse(manifest.contains(cached.path))
        XCTAssertTrue(manifest.contains("(unknown — Magpie cache copy)"))
        XCTAssertTrue(manifest.contains(real.path))
    }

    // MARK: - Cross-volume size rule

    func test_only_a_large_cross_volume_item_is_referenced_in_place() {
        let limit = HandoffBundle.crossVolumeCopyLimit
        XCTAssertTrue(HandoffBundle.shouldReferenceInPlace(
            byteSize: limit + 1, crossesVolume: true
        ))
        XCTAssertFalse(HandoffBundle.shouldReferenceInPlace(
            byteSize: limit, crossesVolume: true
        ))
        XCTAssertFalse(HandoffBundle.shouldReferenceInPlace(
            byteSize: limit + 1, crossesVolume: false
        ))
        // An unknown size (a folder whose recursive total hasn't been computed
        // yet) counts as unknown and is copied.
        XCTAssertFalse(HandoffBundle.shouldReferenceInPlace(
            byteSize: nil, crossesVolume: true
        ))
    }

    func test_same_volume_items_are_always_copied() throws {
        let file = try writeFile("big.mov", in: source, bytes: 1024)
        let drop = try stage([ShelfItem(type: .file, fileURL: file)])
        XCTAssertEqual(drop.copied, 1)
        XCTAssertEqual(drop.referenced, 0)
    }

    // MARK: - Sweep

    private func makeDrop(ageDays: Double, in dir: URL) throws -> URL {
        let created = Date().addingTimeInterval(-ageDays * 24 * 60 * 60)
        let folder = dir.appendingPathComponent(
            HandoffBundle.folderName(now: created), isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: folder.appendingPathComponent("file.txt"))
        return folder
    }

    func test_sweep_removes_expired_drops_and_keeps_fresh_ones() throws {
        let old = try makeDrop(ageDays: 8, in: root)
        let fresh = try makeDrop(ageDays: 1, in: root)

        let removed = HandoffBundle.sweep(root: root)

        XCTAssertEqual(removed.map(\.lastPathComponent), [old.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func test_sweep_ignores_anything_it_did_not_name() throws {
        let foreign = root.appendingPathComponent("my important notes", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        // Right shape, wrong alphabet in the random suffix.
        let nearMiss = root.appendingPathComponent("20200101-000000-ZZZZZZ", isDirectory: true)
        try FileManager.default.createDirectory(at: nearMiss, withIntermediateDirectories: true)

        XCTAssertTrue(HandoffBundle.sweep(root: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
    }

    func test_sweep_does_not_follow_a_symlink_out_of_the_root() throws {
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let hostage = try writeFile("payslip.pdf", in: outside)

        // A directory symlink inside Handoff/, named exactly like an expired
        // drop. Following it would delete a directory the app does not own.
        let link = root.appendingPathComponent(
            HandoffBundle.folderName(now: Date().addingTimeInterval(-30 * 24 * 60 * 60))
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertTrue(HandoffBundle.sweep(root: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostage.path))
    }

    func test_sweep_deleting_a_drop_unlinks_symlinks_rather_than_their_targets() throws {
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let hostage = try writeFile("bank-statement.pdf", in: outside)

        let old = try makeDrop(ageDays: 9, in: root)
        try FileManager.default.createSymbolicLink(
            at: old.appendingPathComponent("link-out"),
            withDestinationURL: outside
        )

        XCTAssertEqual(HandoffBundle.sweep(root: root).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostage.path))
    }

    func test_sweep_no_ops_when_the_root_itself_is_a_symlink() throws {
        let real = tempDir.appendingPathComponent("RealHandoff", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let old = try makeDrop(ageDays: 40, in: real)

        let linkedRoot = tempDir.appendingPathComponent("LinkedHandoff")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: real)

        XCTAssertTrue(HandoffBundle.sweep(root: linkedRoot).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func test_sweep_leaves_a_drop_created_by_this_invocation() throws {
        let drop = try stage([])
        _ = try makeDrop(ageDays: 30, in: root)

        let removed = HandoffBundle.sweep(root: root)

        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drop.folder.path))
    }
}
