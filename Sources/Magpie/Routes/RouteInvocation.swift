import Foundation

/// Turns a route plus its inputs into the exact argument vector and
/// environment the child process receives. Pure, so the contract is pinned by
/// tests rather than by reading a `Process` call site.
///
/// THE ARGUMENT CONTRACT
/// - `{files}` must be an argument all by itself. It is replaced by one
///   argument per input path, in shelf order.
/// - `{output}` is replaced, wherever it appears inside an argument, by the
///   path of an empty folder Magpie made for this run.
/// - Everything else is passed through untouched.
///
/// Paths are handed over as `execve` argv entries through `Process.arguments`.
/// There is no shell anywhere on this path — no `sh -c`, no interpolated
/// command string — so a path containing spaces, double quotes, `$`, `;` or a
/// newline arrives at the command as one argument, byte for byte, and needs
/// no escaping by the user or by us. That is the whole reason the contract is
/// shaped this way.
enum RouteInvocation {
    static let filesToken = "{files}"
    static let outputToken = "{output}"

    static func arguments(
        template: [String],
        files: [URL],
        outputDirectory: URL?
    ) -> [String] {
        var result: [String] = []
        for argument in template {
            if argument == filesToken {
                result.append(contentsOf: files.map(\.path))
                continue
            }
            guard let outputDirectory, argument.contains(outputToken) else {
                result.append(argument)
                continue
            }
            result.append(argument.replacingOccurrences(
                of: outputToken, with: outputDirectory.path
            ))
        }
        return result
    }

    /// The child's environment: the app's own, plus the route's secrets under
    /// their own names, plus two `MAGPIE_` variables a script can read instead
    /// of taking arguments. Secret values live here and nowhere else — they
    /// are never written to a log, a toast, an alert or captured output.
    static func environment(
        base: [String: String],
        secrets: [String: String],
        outputDirectory: URL?,
        routeID: String
    ) -> [String: String] {
        var environment = base
        for (name, value) in secrets { environment[name] = value }
        environment["MAGPIE_ROUTE_ID"] = routeID
        if let outputDirectory {
            environment["MAGPIE_OUTPUT_DIR"] = outputDirectory.path
        }
        return environment
    }

    /// The last `limit` characters of a command's stderr, whitespace-trimmed —
    /// what the failure alert shows. A command that printed nothing gets an
    /// empty string and the alert says so in words.
    static func tail(of text: String, limit: Int = 4_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    /// Belt and braces: even if a command echoes its own key, the text that
    /// reaches the user cannot carry it. Called on every captured string
    /// before it leaves the background worker.
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "•••")
        }
        return result
    }
}
