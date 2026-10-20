import Foundation

/// Grammar and validation for the inbound `magpie://add` link — the only way
/// anything that is not a hand holding a mouse can put a file on the shelf.
///
/// `magpie://add?path=<percent-encoded absolute path>`, `path` repeatable,
/// with an optional `shelf=<uuid>`. Unknown query parameters are ignored;
/// parameter names are case-sensitive.
///
/// SECURITY INVARIANT — read this before extending the file. Any web page the
/// user visits can fire `magpie://` from a link, an iframe or a redirect, so
/// this is an attacker-reachable entry point. A `magpie://` URL may only ever
/// cause two things: `ShelfManager.addFile` and showing the panel. It must
/// never run a route, a script, a shell command, a conversion, an OCR job or
/// any other action, now or later — the moment a URL can act, a registered
/// scheme is a drive-by execution surface. A future "run a route" feature gets
/// a menu item, not a URL verb. Any host other than `add` is refused here, so
/// no future verb can acquire meaning by accident.
enum MagpieURL {
    static let scheme = "magpie"
    static let addHost = "add"

    /// A shelf is a handful of tiles, and each add costs a UTType sniff, a
    /// thumbnail request and a store write. This is what keeps one link from
    /// enqueuing ten thousand items; a caller with more than a shelf's worth
    /// of files should pass the folder, which the shelf holds as one item.
    static let maxPaths = 32

    struct AddRequest: Equatable {
        /// Existing regular files or directories, absolute and symlink-resolved,
        /// in the order they appeared in the URL.
        let paths: [URL]
        /// Nil means "the shelf the user is already on".
        let shelfID: UUID?
    }

    /// A link applies completely or not at all: a partly-applied batch is
    /// indistinguishable from the batch the caller asked for, so one bad path
    /// refuses the whole URL rather than landing a subset.
    enum Rejection: Error, Equatable {
        case notAnAddURL(String)
        case noPaths
        case tooManyPaths(Int)
        case unusablePath(String)
        case unusableShelfID(String)

        var logDescription: String {
            switch self {
            case .notAnAddURL(let url): return "not a magpie://add URL: \(url)"
            case .noPaths: return "no path parameter"
            case .tooManyPaths(let count): return "\(count) paths, limit is \(maxPaths)"
            case .unusablePath(let value): return "unusable path: \(value)"
            case .unusableShelfID(let value): return "unusable shelf id: \(value)"
            }
        }
    }

    static func parse(_ url: URL) -> Result<AddRequest, Rejection> {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == addHost,
              url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failure(.notAnAddURL(url.absoluteString)) }

        let queryItems = components.queryItems ?? []
        let pathValues = queryItems.filter { $0.name == "path" }.map { $0.value ?? "" }
        guard !pathValues.isEmpty else { return .failure(.noPaths) }
        // Counted before any filesystem work, so a link with ten thousand
        // paths costs ten thousand nothings.
        guard pathValues.count <= maxPaths else {
            return .failure(.tooManyPaths(pathValues.count))
        }

        var shelfID: UUID?
        // First `shelf` wins. A second one is an ambiguity, not a target, and
        // ignoring the extras keeps the grammar "path repeats, shelf doesn't".
        if let item = queryItems.first(where: { $0.name == "shelf" }) {
            guard let raw = item.value, let parsed = UUID(uuidString: raw) else {
                return .failure(.unusableShelfID(item.value ?? ""))
            }
            shelfID = parsed
        }

        var paths: [URL] = []
        for value in pathValues {
            guard let url = fileURL(forPathValue: value) else {
                return .failure(.unusablePath(value))
            }
            paths.append(url)
        }
        return .success(AddRequest(paths: paths, shelfID: shelfID))
    }

    /// Absolute paths only, and only when something readable is actually there.
    /// Returns the symlink-resolved URL, which is what `addFile` would store
    /// anyway (`ShelfStore.prepareForIngest` resolves before it decides).
    static func fileURL(forPathValue value: String) -> URL? {
        let rawPath: String
        if value.hasPrefix("/") {
            rawPath = value
        } else if let parsed = URL(string: value), parsed.isFileURL, !parsed.path.isEmpty {
            // `file:///…` is the same thing spelled differently.
            rawPath = parsed.path
        } else {
            // Empty, relative, `~`-prefixed, or any non-file scheme. The app's
            // working directory is not the caller's, so a relative path would
            // resolve against `/` and quietly mean something else.
            return nil
        }

        // Read off the string, not off `URL`, so this does not depend on what
        // Foundation chooses to normalize. There is no confinement root here
        // for `..` to escape — the shelf can legitimately hold anything the
        // user can read — so this is not the security control (that is the
        // invariant above). It keeps every stored locator canonical instead of
        // relative to a directory this app never shared with its caller. `.`
        // and `..` are reserved names on macOS, so nothing legitimate is lost.
        guard !rawPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }

        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isVolumeKey]
        )
        // A device, socket or fifo is not something a shelf can hold — reading
        // one to build a thumbnail would block on a file that never ends.
        guard values?.isRegularFile == true || values?.isDirectory == true else { return nil }
        // A volume root is never a plausible shelf tile, and accepting one lets
        // a single drive-by link (`magpie://add?path=/`) queue a recursive walk
        // of an entire volume — which the store then replays at every launch,
        // silently, until the user notices the tile. Refused at the door.
        guard values?.isVolume != true else { return nil }
        return resolved
    }
}
