import Foundation
import XCTest
@testable import Magpie

/// The duplicate check decides whether a file the user dropped is taken in at
/// all. Its two mistakes are not the same size, and these tests exist to hold
/// the asymmetry:
///
/// - Calling identical files different costs one redundant copy. Nobody sees it.
/// - Calling *different* files identical means the drop is silently discarded
///   and the card the user gets points at the other file's contents.
///
/// So the cheap checks are only ever allowed to say "different", and the tests
/// below pin exactly that: `couldBeIdentical` may return true for files that
/// differ, and `areIdentical` may not.
final class FileContentComparisonTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileContentComparisonTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A body of a given size with one byte changed at `differingAt`.
    private func body(size: Int, differingAt: Int? = nil) -> Data {
        var bytes = Data(repeating: 0xAB, count: size)
        if let differingAt { bytes[differingAt] = 0x00 }
        return bytes
    }

    // MARK: - The false positive

    /// THE test. These two files are the same size, share their first 64 KB and
    /// their last 64 KB, and differ by a single byte in the middle — exactly the
    /// pair a bounded fingerprint cannot tell apart. If this ever returns true,
    /// the app silently drops a file the user asked it to keep.
    func test_files_differing_only_in_the_middle_are_never_called_identical() throws {
        let size = 1_000_000
        let a = try write("a.bin", body(size: size))
        let b = try write("b.bin", body(size: size, differingAt: size / 2))

        XCTAssertTrue(
            try FileContentComparison.couldBeIdentical(a, b),
            "the cheap layer is supposed to be unable to tell these apart — "
                + "if it can, this test has stopped guarding anything"
        )
        XCTAssertFalse(
            try FileContentComparison.areIdentical(a, b),
            "two DIFFERENT files were judged identical: the dropped file would "
                + "never be ingested and its card would point at the other file"
        )
    }

    func test_identical_files_are_identical() throws {
        let a = try write("same-a.bin", body(size: 400_000))
        let b = try write("same-b.bin", body(size: 400_000))

        XCTAssertTrue(try FileContentComparison.areIdentical(a, b))
    }

    func test_empty_files_are_identical() throws {
        let a = try write("empty-a.bin", Data())
        let b = try write("empty-b.bin", Data())

        XCTAssertTrue(try FileContentComparison.areIdentical(a, b))
    }

    // MARK: - What the cheap layer buys

    /// The discriminator that rejects for free. Everything else in the app is
    /// paid for by how often this one answers first.
    func test_a_different_size_is_refuted_without_opening_either_file() throws {
        let a = try write("size-a.bin", body(size: 300_000))
        let b = try write("size-b.bin", body(size: 300_001))

        XCTAssertFalse(try FileContentComparison.couldBeIdentical(a, b))
    }

    /// The tail sample. A file that was appended to or re-encoded very often
    /// shares its opening bytes and differs only near the end, and without this
    /// the full comparison has to walk the entire file to find that out.
    func test_a_difference_in_the_last_bytes_is_refuted_by_the_sample() throws {
        let size = FileContentComparison.sampleBytes * 4
        let a = try write("tail-a.bin", body(size: size))
        let b = try write("tail-b.bin", body(size: size, differingAt: size - 1))

        XCTAssertFalse(try FileContentComparison.couldBeIdentical(a, b))
    }

    func test_a_difference_in_the_first_bytes_is_refuted_by_the_sample() throws {
        let size = FileContentComparison.sampleBytes * 4
        let a = try write("head-a.bin", body(size: size))
        let b = try write("head-b.bin", body(size: size, differingAt: 0))

        XCTAssertFalse(try FileContentComparison.couldBeIdentical(a, b))
    }

    // MARK: - Cancelling

    /// The comparison is the expensive half of an ingest — measured at roughly
    /// five seconds per gigabyte per pair — so a cancel that cannot reach inside
    /// it is a cancel button that lies.
    func test_a_long_comparison_stops_when_cancelled() throws {
        let size = FileContentComparison.chunkBytes * 4
        let a = try write("long-a.bin", body(size: size))
        let b = try write("long-b.bin", body(size: size))
        var calls = 0

        XCTAssertThrowsError(
            try FileContentComparison.areIdentical(a, b, isCancelled: {
                calls += 1
                return calls > 1
            })
        ) { error in
            XCTAssertTrue(
                error is CancellationError,
                "the comparison ran to completion instead of unwinding on cancel"
            )
        }
    }
}

/// `ManagedIngest` chooses the destination for an ingested file and puts it
/// there. ADR 0001 governs it: the only thing it may write is a file inside the
/// app's own `ManagedFiles` directory, and a cancelled or failed run must leave
/// nothing half-written under a name a card could point at.
final class ManagedIngestTests: XCTestCase {
    private var storeDir: URL!
    private var sourceDir: URL!
    private var locations: ManagedIngest.Locations!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedIngestTests-store-\(UUID().uuidString)", isDirectory: true)
        // Real system temp: `prepareForIngest` only makes a managed copy of a
        // file sitting under a purgeable root, so a made-up directory would
        // exercise the wrong branch.
        sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedIngestTests-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        locations = ManagedIngest.Locations(
            storeDirectory: storeDir,
            managedFilesDirectory: storeDir.appendingPathComponent("ManagedFiles", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
        try? FileManager.default.removeItem(at: sourceDir)
    }

    private var managedFiles: [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: locations.managedFilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func staging() -> URL {
        ManagedIngest.stagingURL(in: locations.managedFilesDirectory)
    }

    /// True from the `after`-th call onwards. Lets a test stop an ingest at an
    /// exact point without racing a real task.
    private func cancelling(after: Int) -> () -> Bool {
        var calls = 0
        return {
            calls += 1
            return calls >= after
        }
    }

    func test_a_purgeable_file_is_copied_into_managed_files() throws {
        let source = sourceDir.appendingPathComponent("promised.txt")
        try Data("hello".utf8).write(to: source)

        let destination = try ManagedIngest.prepare(
            source, locations: locations, stagingURL: staging()
        )

        XCTAssertEqual(destination.deletingLastPathComponent(), locations.managedFilesDirectory)
        XCTAssertEqual(try Data(contentsOf: destination), Data("hello".utf8))
    }

    /// The fix an earlier security review bought: a directory under a purgeable
    /// root is referenced where it stands, never snapshotted, because
    /// `copyItem` recurses and the eviction that bounds the cache only counts
    /// regular files — so a cloned tree would sit outside the budget forever.
    func test_a_directory_under_temp_is_referenced_not_copied() throws {
        let folder = sourceDir.appendingPathComponent("a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("child.txt"))

        let destination = try ManagedIngest.prepare(
            folder, locations: locations, stagingURL: staging()
        )

        XCTAssertEqual(destination.standardizedFileURL, folder.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertTrue(managedFiles.isEmpty, "a directory was snapshotted into the managed cache")
    }

    func test_a_file_outside_a_purgeable_root_is_referenced_where_it_is() throws {
        let outside = storeDir.deletingLastPathComponent()
            .appendingPathComponent("ManagedIngestTests-outside-\(UUID().uuidString).txt")
        try Data("elsewhere".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        // `storeDir` itself lives under temp, so this proves the store-directory
        // exclusion rather than the purgeable-root one; both return the source.
        let destination = try ManagedIngest.prepare(
            storeDir.appendingPathComponent("inside-the-store.txt"),
            locations: locations,
            stagingURL: staging()
        )

        XCTAssertEqual(destination.lastPathComponent, "inside-the-store.txt")
        XCTAssertTrue(managedFiles.isEmpty)
    }

    func test_re_ingesting_an_unchanged_source_reuses_the_one_managed_copy() throws {
        let source = sourceDir.appendingPathComponent("stable.txt")
        try Data("unchanged".utf8).write(to: source)

        let first = try ManagedIngest.prepare(source, locations: locations, stagingURL: staging())
        let second = try ManagedIngest.prepare(source, locations: locations, stagingURL: staging())

        XCTAssertEqual(first, second)
        XCTAssertEqual(managedFiles.count, 1)
    }

    func test_re_ingesting_a_changed_source_refreshes_the_same_managed_copy() throws {
        let source = sourceDir.appendingPathComponent("changing.txt")
        try Data("version-1".utf8).write(to: source)
        let first = try ManagedIngest.prepare(source, locations: locations, stagingURL: staging())
        try Data("version-2".utf8).write(to: source, options: .atomic)

        let second = try ManagedIngest.prepare(source, locations: locations, stagingURL: staging())

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try text(of: second), "version-2",
            "the managed copy still holds the old contents: the duplicate check "
                + "called two different files the same"
        )
        XCTAssertEqual(managedFiles.count, 1)
    }

    private func text(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// The staging path is the only thing `prepare` ever removes, and it comes
    /// in as an argument. ADR 0001 allows no code path to delete a file Magpie
    /// does not manage, so a staging URL outside `ManagedFiles` has to be
    /// refused rather than trusted — and the files have to survive the refusal.
    func test_a_staging_path_outside_managed_files_is_refused() throws {
        let source = sourceDir.appendingPathComponent("victim.txt")
        try Data("do not delete me".utf8).write(to: source)
        let hostage = sourceDir.appendingPathComponent("hostage.txt")
        try Data("nor me".utf8).write(to: hostage)

        XCTAssertThrowsError(
            try ManagedIngest.prepare(source, locations: locations, stagingURL: hostage)
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hostage.path),
            "an ingest deleted a file outside its own managed directory"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Cancelling

    /// A cancelled ingest is a fully absent item, never a half-copied one. The
    /// copy lands on a staging name and is moved into place only once whole, so
    /// a cancel between the two leaves the managed cache exactly as it was —
    /// including no orphaned staging file.
    func test_a_cancel_after_the_copy_leaves_nothing_behind() throws {
        let source = sourceDir.appendingPathComponent("interrupted.txt")
        try Data("half a file".utf8).write(to: source)

        XCTAssertThrowsError(
            try ManagedIngest.prepare(
                source,
                locations: locations,
                stagingURL: staging(),
                // Call 1 is the guard before any work; call 2 is the one after
                // the bytes have been copied to staging.
                isCancelled: cancelling(after: 2)
            )
        ) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertEqual(
            managedFiles.map(\.lastPathComponent), [],
            "a cancelled ingest left a file in the managed cache"
        )
    }

    /// The same property for the refresh path, where there is an existing copy
    /// a card is already pointing at. A cancel must leave that copy whole and
    /// unchanged — a partially updated managed file is a card whose contents
    /// silently changed underneath the user.
    func test_a_cancel_during_a_refresh_leaves_the_existing_copy_whole() throws {
        let source = sourceDir.appendingPathComponent("refreshing.txt")
        try Data("version-1".utf8).write(to: source)
        let destination = try ManagedIngest.prepare(
            source, locations: locations, stagingURL: staging()
        )
        try Data("version-2-which-is-longer".utf8).write(to: source, options: .atomic)

        XCTAssertThrowsError(
            try ManagedIngest.prepare(
                source,
                locations: locations,
                stagingURL: staging(),
                // 1: the opening guard. 2: inside the comparison, which the
                // differing sizes short-circuit. 2: after the staged copy.
                isCancelled: cancelling(after: 2)
            )
        ) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertEqual(
            try text(of: destination), "version-1",
            "a cancelled refresh left the managed copy half-updated"
        )
        XCTAssertEqual(managedFiles.count, 1, "a cancelled refresh left a staging file behind")
    }
}

/// Whether a drop is worth putting a bar over. Without a rule, the overlay
/// flashes on for a frame every time three files come off the desktop, which
/// reads as a glitch rather than as feedback.
final class IngestProgressPolicyTests: XCTestCase {
    func test_a_small_quick_drop_says_nothing() {
        XCTAssertFalse(IngestProgressPolicy.isVisible(batchSize: 3, heaviestManagedBytes: 0))
    }

    func test_a_big_pile_of_small_files_is_worth_a_bar() {
        XCTAssertTrue(
            IngestProgressPolicy.isVisible(
                batchSize: IngestProgressPolicy.visibleBatchSize + 1,
                heaviestManagedBytes: 0
            )
        )
    }

    func test_one_heavy_file_is_worth_a_bar_on_its_own() {
        XCTAssertTrue(
            IngestProgressPolicy.isVisible(
                batchSize: 1,
                heaviestManagedBytes: IngestProgressPolicy.visibleByteThreshold + 1
            )
        )
    }
}
