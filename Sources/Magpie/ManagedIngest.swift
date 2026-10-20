import CryptoKit
import Foundation

/// Whether two files hold exactly the same bytes.
///
/// Every cheap check here can only ever answer **"different"**. Equality is
/// concluded in exactly one place — the complete byte-for-byte comparison at
/// the bottom — and never inferred from a size, a sample, a hash or a
/// timestamp. That asymmetry is the whole design, because the two mistakes are
/// not the same size:
///
/// - Calling two identical files different costs one redundant copy. Invisible.
/// - Calling two *different* files identical means the file the user dropped is
///   never taken in, and the resulting card points at the other file's contents.
///   That is silent data loss, and no amount of speed pays for it.
///
/// So the samples are rejecters, not acceptors. What they buy is the case that
/// actually costs: a file that differs is refused after a couple of stats or
/// 128 KB, instead of after reading both files end to end.
enum FileContentComparison {
    /// Read from each end before falling back to the full comparison. The tail
    /// is the half that earns its keep: an appended-to or re-encoded file very
    /// often shares its opening bytes and differs only at the end, and the
    /// streaming comparison below would have to walk the whole file to find
    /// that out.
    static let sampleBytes = 64 * 1024

    /// How much of each file the full comparison holds in memory at once.
    static let chunkBytes = 1 << 20

    /// The cheap layer, on its own so that what it is *for* can be tested.
    ///
    /// `false` is a final answer: these files differ. `true` means only "not
    /// refuted" and is never, anywhere, treated as equality. Two same-sized
    /// files that differ somewhere in their middle come back `true` from here
    /// and `false` from `areIdentical`, which is the whole point.
    static func couldBeIdentical(_ a: URL, _ b: URL) throws -> Bool {
        guard let sizeA = fileSize(of: a), let sizeB = fileSize(of: b) else { return false }
        guard sizeA == sizeB else { return false }
        let sample = Int64(sampleBytes)
        guard sizeA > sample * 2 else { return true }

        let handleA = try FileHandle(forReadingFrom: a)
        defer { try? handleA.close() }
        let handleB = try FileHandle(forReadingFrom: b)
        defer { try? handleB.close() }
        if try read(handleA, at: 0, count: Int(sample))
            != read(handleB, at: 0, count: Int(sample)) { return false }
        let tail = UInt64(sizeA - sample)
        return try read(handleA, at: tail, count: Int(sample))
            == read(handleB, at: tail, count: Int(sample))
    }

    /// The only acceptor in the app. Throws `CancellationError` if `isCancelled`
    /// goes true mid-comparison, which on a multi-gigabyte pair is the
    /// difference between a cancel button that works and one that lies.
    static func areIdentical(
        _ a: URL,
        _ b: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> Bool {
        guard try couldBeIdentical(a, b) else { return false }
        guard let size = fileSize(of: a), size > 0 else { return true }

        let handleA = try FileHandle(forReadingFrom: a)
        defer { try? handleA.close() }
        let handleB = try FileHandle(forReadingFrom: b)
        defer { try? handleB.close() }

        var remaining = size
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(Int64(chunkBytes), remaining))
            let chunkA = try readExactly(handleA, count: want)
            let chunkB = try readExactly(handleB, count: want)
            // A short read means a file changed size underneath us. Answering
            // "different" sends the caller down the copy path, which is the
            // safe direction to be wrong in.
            guard chunkA.count == want, chunkA == chunkB else { return false }
            remaining -= Int64(want)
        }
        return true
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try readExactly(handle, count: count)
    }

    /// `FileHandle.read(upToCount:)` is allowed to hand back less than it was
    /// asked for. Two handles returning different amounts would compare unequal
    /// on identical bytes, so both sides are filled to the same length first.
    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty
            else { break }
            data.append(next)
        }
        return data
    }
}

/// Deciding where an ingested file lives, and putting it there.
///
/// Lifted out of `ShelfStore` so it can run off the main thread: it is a pure
/// function of the URLs handed to it and touches no shared mutable state, which
/// is the only reason a drop is safe to hand to a detached task at all.
///
/// ADR 0001 governs every line: the only thing written is a file inside the
/// app's own `ManagedFiles` directory, and the user's file is read and nothing
/// else. Directories are referenced, never snapshotted.
enum ManagedIngest {
    /// The two app-owned directories, snapshotted so a background task never
    /// reads them back off a main-actor object.
    struct Locations: Sendable {
        let storeDirectory: URL
        let managedFilesDirectory: URL
    }

    /// A fresh staging name. Every copy lands here first and is moved into
    /// place only once it is whole, so a cancelled or failed ingest can never
    /// leave a half-written file under the name the shelf would point at.
    static func stagingURL(in managedFilesDirectory: URL) -> URL {
        managedFilesDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
    }

    /// Bytes of copying-or-comparing this source would cost, or 0 when it is
    /// referenced where it already sits. Cheap — two path checks and a stat —
    /// and used only to decide whether a drop is heavy enough to be worth
    /// showing a progress bar for.
    static func managedWorkEstimate(for sourceURL: URL, locations: Locations) -> Int64 {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard needsManagedCopy(source, locations: locations) else { return 0 }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    /// The URL the shelf item should point at: the source itself, or the
    /// managed copy that now mirrors it.
    static func prepare(
        _ sourceURL: URL,
        locations: Locations,
        stagingURL: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> URL {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard needsManagedCopy(source, locations: locations) else { return source }
        if isCancelled() { throw CancellationError() }

        let fm = FileManager.default
        try fm.createDirectory(at: locations.managedFilesDirectory, withIntermediateDirectories: true)
        let rootValues = try locations.managedFilesDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // The staging path is the only thing this function ever deletes, and it
        // arrives as an argument. ADR 0001 says no code path may remove a file
        // Magpie does not manage, so the argument is checked rather than
        // trusted: a caller cannot make this reach outside ManagedFiles.
        guard ShelfStore.contains(stagingURL, in: locations.managedFilesDirectory) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let digest = SHA256.hash(data: Data(source.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined().prefix(16)
        let ext = source.pathExtension
        let stem = String(source.deletingPathExtension().lastPathComponent.prefix(180))
        let destinationName = "\(stem)-\(digest)" + (ext.isEmpty ? "" : ".\(ext)")
        let destination = locations.managedFilesDirectory
            .appendingPathComponent(destinationName, isDirectory: false)

        let destinationExists = fm.fileExists(atPath: destination.path)
        if destinationExists,
           try FileContentComparison.areIdentical(source, destination, isCancelled: isCancelled) {
            return destination
        }

        try? fm.removeItem(at: stagingURL)
        do {
            // `FileManager.copyItem` clones on APFS, so a same-volume copy of a
            // multi-gigabyte file costs nothing measurable. A hand-rolled
            // chunked copy would give byte-level progress and cost a real
            // read-and-write instead; it is not a trade worth making, which is
            // why cancellation here is checked around the copy rather than
            // inside it.
            try fm.copyItem(at: source, to: stagingURL)
            if isCancelled() { throw CancellationError() }
            try place(staged: stagingURL, at: destination, exists: destinationExists, fileManager: fm)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }
        return destination
    }

    /// Directories are referenced, never snapshotted — `copyItem` recurses, so a
    /// directory under a purgeable root would clone its whole tree into
    /// ManagedFiles, and `evictManagedCacheIfNeeded` only ever counts and
    /// removes regular files, so that clone would sit outside the 500 MB budget
    /// and never be reclaimed.
    private static func needsManagedCopy(_ source: URL, locations: Locations) -> Bool {
        guard !ShelfStore.contains(source, in: locations.storeDirectory) else { return false }
        let fm = FileManager.default
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true
        guard !isDirectory else { return false }
        let purgeableRoots = [fm.temporaryDirectory]
            + fm.urls(for: .cachesDirectory, in: .userDomainMask)
        return purgeableRoots.contains { ShelfStore.contains(source, in: $0) }
    }

    /// One managed copy per source path: a source whose contents changed
    /// replaces the copy that mirrored it rather than accumulating a second one.
    private static func place(
        staged: URL,
        at destination: URL,
        exists: Bool,
        fileManager fm: FileManager
    ) throws {
        if exists {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
            return
        }
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            // Someone got there between the existence check and now. Same
            // answer as the branch above rather than dropping the file.
            guard fm.fileExists(atPath: destination.path) else { throw error }
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        }
    }
}

/// Whether a drop is heavy enough to be worth saying anything about.
///
/// Without this the overlay flashes on for a frame every time three files come
/// off the desktop, which reads as a glitch rather than as feedback. Both
/// inputs are known before the work starts, so the bar is up while the wait is
/// happening and not after it.
enum IngestProgressPolicy {
    /// Above this many files, per-file metadata reads alone add up to a wait.
    static let visibleBatchSize = 8

    /// Above this, one file's copy-or-compare is on its own worth a bar.
    static let visibleByteThreshold: Int64 = 32 * 1_024 * 1_024

    static func isVisible(batchSize: Int, heaviestManagedBytes: Int64) -> Bool {
        batchSize > visibleBatchSize || heaviestManagedBytes > visibleByteThreshold
    }
}
