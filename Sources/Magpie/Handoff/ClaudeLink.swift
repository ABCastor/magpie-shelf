import AppKit

/// The `claude://` deep link, isolated so a change to the grammar costs one
/// file. Nothing else in Magpie knows the scheme exists.
enum ClaudeLink {
    static func url(prompt: String, folder: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        // No `file=`. The `code/new` branch of Claude.app's handler reads
        // `getAll("file")` and uses it in exactly one place — a telemetry
        // field — never forwarding it. (The `cowork/new` branch does forward
        // it, which is likely how the public docs came to list it for both.)
        // A build that sent `file=` would look correct and attach nothing.
        components.queryItems = [
            URLQueryItem(name: "q", value: prompt),
            URLQueryItem(name: "folder", value: folder.path),
        ]
        // The receiver parses with `URLSearchParams`, which decodes `+` as a
        // space, so a literal plus in a filename would arrive mangled.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    @MainActor
    static func open(prompt: String, folder: URL) -> Bool {
        guard let url = url(prompt: prompt, folder: folder) else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor
    static var isAvailable: Bool {
        guard let probe = URL(string: "claude://code/new") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }
}
