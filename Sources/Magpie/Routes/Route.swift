import Foundation
import UniformTypeIdentifiers

/// A route takes the files on a shelf and runs a command the owner wrote.
///
/// SAFETY INVARIANT — **a route is copy-only.** Magpie passes input *paths*
/// and nothing else: it never moves, renames, overwrites or removes an input,
/// and there is no "delete when done" flag for a command to receive. That one
/// rule replaces the permission taxonomy, preview step and undo ledger a
/// rejected design proposed (ADR 0004), and it is what keeps ADR 0001
/// literally true — the only code in this app that destroys a user file is
/// still the user's own Move to Trash.
///
/// A route also only ever starts from a menu item the user clicked. Nothing
/// automated may reach one: see `RouteLauncher`, which is the single entry
/// point, and ADR 0003, which refuses a URL verb for this forever.
struct Route: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// SF Symbol name for the menu row. Nil renders without an image.
    let symbol: String?
    /// Nil (or empty) means "offer this route for any file".
    let match: RouteMatch?
    /// Absolute path to an executable. There is no PATH lookup and no shell.
    let command: String
    let arguments: [String]
    /// Absolute path. Nil means the user's home folder.
    let workingDirectory: String?
    /// Keychain names whose values are exported to the child process as
    /// environment variables of the same name.
    let secrets: [String]
    let timeout: TimeInterval
    /// True when the route asked for an output folder, either with the
    /// `{output}` token or `"collectOutput": true`.
    let collectsOutput: Bool
    let isEnabled: Bool
}

/// Which files a route offers itself for. Extensions and UTIs are OR-ed: a
/// file matches if its extension is listed *or* its type conforms to one of
/// the listed UTIs.
struct RouteMatch: Equatable, Sendable {
    /// Lowercased, without a leading dot.
    let extensions: [String]
    let utis: [String]

    var isEmpty: Bool { extensions.isEmpty && utis.isEmpty }
}

/// What the match predicate needs to know about one file. Kept separate from
/// `ShelfItem` (and from the filesystem) so the predicate stays pure.
struct RouteInput: Equatable {
    /// Path extension without the dot, as written on disk.
    let pathExtension: String
    /// UTType identifier, when one could be determined.
    let typeIdentifier: String?
}

// MARK: - Match predicate (pure)

extension RouteMatch {
    /// A route is offered only when EVERY input matches — the same all-or-none
    /// rule `OCRMenu` uses, so a multi-select never runs a command against a
    /// file it was not written for. An empty selection matches nothing.
    static func applies(_ match: RouteMatch?, to inputs: [RouteInput]) -> Bool {
        guard !inputs.isEmpty else { return false }
        guard let match, !match.isEmpty else { return true }
        return inputs.allSatisfy { match.matches($0) }
    }

    func matches(_ input: RouteInput) -> Bool {
        if extensions.contains(where: {
            $0.caseInsensitiveCompare(input.pathExtension) == .orderedSame
        }) { return true }
        guard let identifier = input.typeIdentifier,
              let type = UTType(identifier) else { return false }
        return utis.contains { listed in
            guard let listedType = UTType(listed) else { return false }
            return type.conforms(to: listedType)
        }
    }
}

// MARK: - Parse errors

/// Every failure a `routes.json` can produce, in the owner's language and
/// naming the route at fault. A raw decoder dump is never shown.
enum RouteParseError: Error, Equatable {
    case unreadable
    case invalidJSON
    case badShape
    case unsupportedVersion(found: Int, expected: Int)
    case badField(route: String, field: String)
    case relativeCommand(route: String, command: String)
    case duplicateID(String)
    case embeddedFilesToken(route: String)

    var displayMessage: String {
        switch self {
        case .unreadable:
            return L("routes.error.unreadable")
        case .invalidJSON:
            return L("routes.error.invalid-json")
        case .badShape:
            return L("routes.error.shape")
        case .unsupportedVersion(let found, let expected):
            return String(format: L("routes.error.version"), found, expected)
        case .badField(let route, let field):
            return String(format: L("routes.error.bad-field"), route, field)
        case .relativeCommand(let route, let command):
            return String(format: L("routes.error.relative-command"), route, command)
        case .duplicateID(let id):
            return String(format: L("routes.error.duplicate-id"), id)
        case .embeddedFilesToken(let route):
            return String(format: L("routes.error.files-token"), route)
        }
    }
}

// MARK: - The file format

/// Reads `routes.json`. Data only: nothing here runs, launches or resolves a
/// command — a route file is inert until a menu click hands it to
/// `RouteService`.
///
/// Hand-rolled on `JSONSerialization` rather than `Codable` on purpose: the
/// owner edits this file by hand, so every failure has to name the route and
/// the field in a sentence the owner can act on, which a `DecodingError`
/// cannot do. Unknown keys (`_readme`, `note`, anything the owner leaves for
/// themselves) are ignored.
enum RouteFile {
    static let currentVersion = 1
    static let defaultTimeout: TimeInterval = 120
    static let minimumTimeout: TimeInterval = 1
    static let maximumTimeout: TimeInterval = 3600

    static func parse(_ data: Data) -> Result<[Route], RouteParseError> {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return .failure(.invalidJSON) }
        guard let root = object as? [String: Any] else { return .failure(.badShape) }

        if let version = root["version"] {
            guard let number = version as? Int else { return .failure(.badShape) }
            guard number == currentVersion else {
                return .failure(.unsupportedVersion(found: number, expected: currentVersion))
            }
        }
        guard let rawRoutes = root["routes"] as? [Any] else { return .failure(.badShape) }

        var routes: [Route] = []
        var seen: Set<String> = []
        for (index, raw) in rawRoutes.enumerated() {
            guard let dictionary = raw as? [String: Any] else { return .failure(.badShape) }
            switch route(from: dictionary, position: index + 1) {
            case .failure(let error):
                return .failure(error)
            case .success(let route):
                guard seen.insert(route.id).inserted else {
                    return .failure(.duplicateID(route.id))
                }
                routes.append(route)
            }
        }
        return .success(routes)
    }

    // MARK: - One route

    private static func route(
        from dictionary: [String: Any],
        position: Int
    ) -> Result<Route, RouteParseError> {
        // Falls back to the position so an entry with no usable id can still
        // be pointed at ("the route “#2”").
        let label = (dictionary["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (dictionary["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "#\(position)"

        guard let id = nonEmptyString(dictionary["id"]) else {
            return .failure(.badField(route: label, field: "id"))
        }
        guard let name = nonEmptyString(dictionary["name"]) else {
            return .failure(.badField(route: label, field: "name"))
        }
        guard let command = nonEmptyString(dictionary["command"]) else {
            return .failure(.badField(route: label, field: "command"))
        }
        guard command.hasPrefix("/") else {
            return .failure(.relativeCommand(route: label, command: command))
        }

        let arguments: [String]
        switch stringList(dictionary["arguments"], route: label, field: "arguments") {
        case .failure(let error): return .failure(error)
        case .success(let list): arguments = list
        }
        // `{files}` becomes several arguments, so it can only be a whole one.
        // Anywhere else there is no honest answer, and guessing one would be
        // the kind of silent wrong result this app refuses elsewhere.
        if arguments.contains(where: {
            $0.contains(RouteInvocation.filesToken) && $0 != RouteInvocation.filesToken
        }) {
            return .failure(.embeddedFilesToken(route: label))
        }

        let secrets: [String]
        switch stringList(dictionary["secrets"], route: label, field: "secrets") {
        case .failure(let error): return .failure(error)
        case .success(let list): secrets = list
        }

        var workingDirectory: String?
        if let raw = dictionary["workingDirectory"] {
            guard let path = raw as? String, path.hasPrefix("/") else {
                return .failure(.badField(route: label, field: "workingDirectory"))
            }
            workingDirectory = path
        }

        var match: RouteMatch?
        if let raw = dictionary["match"] {
            guard let object = raw as? [String: Any] else {
                return .failure(.badField(route: label, field: "match"))
            }
            let extensions: [String]
            switch stringList(object["extensions"], route: label, field: "match") {
            case .failure(let error): return .failure(error)
            case .success(let list):
                extensions = list.map {
                    var value = $0.lowercased()
                    while value.hasPrefix(".") { value.removeFirst() }
                    return value
                }.filter { !$0.isEmpty }
            }
            let utis: [String]
            switch stringList(object["utis"], route: label, field: "match") {
            case .failure(let error): return .failure(error)
            case .success(let list): utis = list.filter { !$0.isEmpty }
            }
            match = RouteMatch(extensions: extensions, utis: utis)
        }

        var timeout = defaultTimeout
        if let raw = dictionary["timeoutSeconds"] {
            guard let seconds = raw as? NSNumber else {
                return .failure(.badField(route: label, field: "timeoutSeconds"))
            }
            timeout = min(max(seconds.doubleValue, minimumTimeout), maximumTimeout)
        }

        var isEnabled = true
        if let raw = dictionary["enabled"] {
            guard let flag = raw as? Bool else {
                return .failure(.badField(route: label, field: "enabled"))
            }
            isEnabled = flag
        }

        var collectOutput = false
        if let raw = dictionary["collectOutput"] {
            guard let flag = raw as? Bool else {
                return .failure(.badField(route: label, field: "collectOutput"))
            }
            collectOutput = flag
        }

        return .success(Route(
            id: id,
            name: name,
            symbol: nonEmptyString(dictionary["symbol"]),
            match: match,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            secrets: secrets,
            timeout: timeout,
            collectsOutput: collectOutput
                || arguments.contains { $0.contains(RouteInvocation.outputToken) },
            isEnabled: isEnabled
        ))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func stringList(
        _ value: Any?,
        route: String,
        field: String
    ) -> Result<[String], RouteParseError> {
        guard let value else { return .success([]) }
        guard let list = value as? [Any] else {
            return .failure(.badField(route: route, field: field))
        }
        var result: [String] = []
        for entry in list {
            guard let string = entry as? String else {
                return .failure(.badField(route: route, field: field))
            }
            result.append(string)
        }
        return .success(result)
    }
}
