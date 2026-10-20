import Foundation

/// Everything one run of a route needs, flattened so the worker can be faked
/// in tests without a real process.
struct RouteExecution: Sendable, Equatable {
    let command: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
    let timeout: TimeInterval
}

struct RouteOutcome: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

struct RouteSuccess: Sendable {
    let routeName: String
    /// New files the command left in its output folder, already on disk.
    let producedFiles: [URL]
}

/// Failure as the user will see it. Every case names the route, and none of
/// them can carry a secret: `detail` is the command's stderr tail after
/// redaction, and the other cases carry no captured output at all.
enum RouteFailure: Error, Equatable, Sendable {
    case launchFailed(route: String, command: String)
    case missingSecret(route: String, secret: String)
    case timedOut(route: String, seconds: Int)
    case exited(route: String, code: Int32, detail: String)
    case cancelled

    var displayMessage: String {
        switch self {
        case .launchFailed(let route, let command):
            return String(format: L("routes.failed.launch"), route, command)
        case .missingSecret(let route, let secret):
            return String(format: L("routes.failed.secret"), route, secret)
        case .timedOut(let route, let seconds):
            return String(format: L("routes.failed.timeout"), route, seconds)
        case .exited(let route, let code, _):
            return String(format: L("routes.failed.exit"), route, Int(code))
        case .cancelled:
            return ""
        }
    }

    /// The stderr tail, shown in a scrollable field under the message. Empty
    /// means the alert says the command explained nothing.
    var detail: String {
        if case .exited(_, _, let detail) = self { return detail }
        return ""
    }
}

/// Thrown by the executor when the command could not be started at all
/// (missing file, not executable, bad interpreter line).
struct RouteLaunchFailure: Error, Sendable {
    let reason: String
}

typealias RouteExecutor = @Sendable (RouteExecution, @escaping @Sendable () -> Bool) throws -> RouteOutcome

/// Runs a route's command. Never on the main thread: `RouteService` dispatches
/// `perform` onto its work queue and hops back to the main actor with the
/// result.
enum RouteRunner {
    /// One run of a route, start to finish. Creates the output folder, expands
    /// the arguments, runs the command, and collects whatever new files were
    /// left behind.
    ///
    /// The inputs are read and nothing else: no input is moved, renamed,
    /// rewritten or removed here or anywhere downstream.
    static func perform(
        route: Route,
        files: [URL],
        outputDirectory: URL?,
        secrets: [String: String],
        executor: RouteExecutor,
        isCancelled: @escaping @Sendable () -> Bool,
        fileManager: FileManager = .default
    ) -> Result<RouteSuccess, RouteFailure> {
        if let outputDirectory {
            do {
                try fileManager.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
            } catch {
                return .failure(.launchFailed(route: route.name, command: route.command))
            }
        }

        let execution = RouteExecution(
            command: route.command,
            arguments: RouteInvocation.arguments(
                template: route.arguments, files: files, outputDirectory: outputDirectory
            ),
            workingDirectory: route.workingDirectory
                ?? fileManager.homeDirectoryForCurrentUser.path,
            environment: RouteInvocation.environment(
                base: ProcessInfo.processInfo.environment,
                secrets: secrets,
                outputDirectory: outputDirectory,
                routeID: route.id
            ),
            timeout: route.timeout
        )

        let outcome: RouteOutcome
        do {
            outcome = try executor(execution, isCancelled)
        } catch {
            return .failure(.launchFailed(route: route.name, command: route.command))
        }

        if isCancelled() { return .failure(.cancelled) }
        if outcome.timedOut {
            return .failure(.timedOut(route: route.name, seconds: Int(route.timeout)))
        }
        guard outcome.exitCode == 0 else {
            // The only place captured output reaches a human, so it is
            // redacted here rather than at the presentation layer.
            let detail = RouteInvocation.tail(of: RouteInvocation.redact(
                outcome.standardError, secrets: Array(secrets.values)
            ))
            return .failure(.exited(route: route.name, code: outcome.exitCode, detail: detail))
        }

        return .success(RouteSuccess(
            routeName: route.name,
            producedFiles: outputDirectory.map {
                producedFiles(in: $0, fileManager: fileManager)
            } ?? []
        ))
    }

    /// Direct children of the run's own output folder, name-sorted. The folder
    /// was created empty seconds ago, so everything in it is this run's work —
    /// no mtime guessing, and no chance of picking up a file the user owns.
    static let maximumProducedFiles = 32

    static func producedFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        let sorted = names.sorted().prefix(maximumProducedFiles)
        if names.count > maximumProducedFiles {
            NSLog("Magpie: a route produced \(names.count) files; adding the first \(maximumProducedFiles)")
        }
        return sorted.map { directory.appendingPathComponent($0) }
    }

    // MARK: - The real process

    /// `Process` with an argument array — never `sh -c` on an interpolated
    /// string, so no path can be re-parsed, split or expanded on its way in.
    static let execute: RouteExecutor = { execution, isCancelled in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execution.command)
        process.arguments = execution.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: execution.workingDirectory)
        process.environment = execution.environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw RouteLaunchFailure(reason: error.localizedDescription)
        }

        // Drain both pipes on their own threads. A command that fills the
        // 64 KB pipe buffer blocks forever if nobody is reading.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isError) in [
            (outPipe.fileHandleForReading, false),
            (errPipe.fileHandleForReading, true),
        ] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    collector.append(chunk, isError: isError)
                }
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(execution.timeout)
        var timedOut = false
        while process.isRunning {
            if isCancelled() {
                stop(process)
                break
            }
            if Date() >= deadline {
                timedOut = true
                stop(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()

        return RouteOutcome(
            exitCode: process.terminationStatus,
            standardOutput: collector.text(isError: false),
            standardError: collector.text(isError: true),
            timedOut: timedOut
        )
    }

    /// SIGTERM first so the command can clean up, SIGKILL if it will not go.
    private static func stop(_ process: Process) {
        process.terminate()
        let hardDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < hardDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// Bounded, thread-safe accumulation of a child's two output streams. Bounded
/// because a runaway command must not be able to grow this app's memory.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let limit = 256 * 1024

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError {
            if err.count < limit { err.append(data) }
        } else {
            if out.count < limit { out.append(data) }
        }
    }

    func text(isError: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: isError ? err : out, as: UTF8.self)
    }
}
