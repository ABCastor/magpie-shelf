import Combine
import Foundation

private final class RouteCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Queues route runs and executes them one at a time. Same shape as
/// `ConversionService` and `OCRService`, which is what makes the tile progress
/// overlay, the per-item cancel button and the toast wiring work unchanged.
///
/// The heavy work (a subprocess, its output, its timeout) happens on
/// `workQueue`; this class only ever holds the queue and publishes state.
@MainActor
final class RouteService: ObservableObject {
    /// Keyed by every input item of a running route, so all its tiles dim and
    /// any of them can cancel the run. A subprocess has no fraction to report,
    /// so the value stays at 0 and the overlay reads as "busy, cancellable".
    @Published private(set) var progress: [UUID: Double] = [:]

    let completed = PassthroughSubject<(RouteSuccess, UUID /* shelfID */), Never>()
    let failed = PassthroughSubject<RouteFailure, Never>()

    private struct QueuedTask {
        let route: Route
        let itemIDs: [UUID]
        let shelfID: UUID
        let files: [URL]
    }

    private var queue: [QueuedTask] = []
    private var inFlight: QueuedTask?
    private var inFlightCancellation: RouteCancellationToken?
    private let workQueue = DispatchQueue(label: "magpie.routes.work", qos: .userInitiated)
    private let executor: RouteExecutor
    private let secretProvider: @Sendable (String) -> String?
    private let outputRoot: URL

    /// `outputRoot` defaults to the temp directory on purpose: a file ingested
    /// from there is copied into `ManagedFiles/` by `ShelfStore.prepareForIngest`
    /// and then falls under the bounded cache ADR 0001 already governs. Route
    /// output therefore needs no new deletion path of its own.
    init(
        executor: @escaping RouteExecutor = RouteRunner.execute,
        secretProvider: @escaping @Sendable (String) -> String? = { SecretStore.value(for: $0) },
        outputRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.executor = executor
        self.secretProvider = secretProvider
        self.outputRoot = outputRoot
    }

    // MARK: - Public API

    func enqueueRun(route: Route, itemIDs: [UUID], shelfID: UUID, files: [URL]) {
        guard !files.isEmpty else { return }
        queue.append(QueuedTask(
            route: route, itemIDs: itemIDs, shelfID: shelfID, files: files
        ))
        for id in itemIDs { progress[id] = 0 }
        runNextIfIdle()
    }

    /// Cancels the run `itemID` belongs to — queued or in flight. A route acts
    /// on a set of files, so cancelling from one tile cancels the whole run.
    func cancel(itemID: UUID) {
        for task in queue where task.itemIDs.contains(itemID) {
            for id in task.itemIDs { progress.removeValue(forKey: id) }
        }
        queue.removeAll { $0.itemIDs.contains(itemID) }
        if let inFlight, inFlight.itemIDs.contains(itemID) {
            inFlightCancellation?.cancel()
            for id in inFlight.itemIDs { progress.removeValue(forKey: id) }
        }
    }

    func cancelAll() {
        queue.removeAll()
        inFlightCancellation?.cancel()
        progress.removeAll()
    }

    // MARK: - Internals

    private func runNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let task = queue.removeFirst()
        inFlight = task

        var secrets: [String: String] = [:]
        for name in task.route.secrets {
            guard let value = secretProvider(name), !value.isEmpty else {
                finish(task: task, result: .failure(
                    .missingSecret(route: task.route.name, secret: name)
                ))
                return
            }
            secrets[name] = value
        }

        let token = RouteCancellationToken()
        inFlightCancellation = token
        let outputDirectory = task.route.collectsOutput
            ? outputRoot.appendingPathComponent("MagpieRoute-\(UUID().uuidString)", isDirectory: true)
            : nil
        let route = task.route
        let files = task.files
        let executor = self.executor

        workQueue.async { [weak self] in
            let result = RouteRunner.perform(
                route: route,
                files: files,
                outputDirectory: outputDirectory,
                secrets: secrets,
                executor: executor,
                isCancelled: { token.isCancelled }
            )
            Task { @MainActor [weak self] in
                self?.finish(task: task, result: result)
            }
        }
    }

    private func finish(task: QueuedTask, result: Result<RouteSuccess, RouteFailure>) {
        let wasCancelled = inFlightCancellation?.isCancelled == true
        for id in task.itemIDs { progress.removeValue(forKey: id) }
        inFlight = nil
        inFlightCancellation = nil

        if wasCancelled {
            failed.send(.cancelled)
        } else {
            switch result {
            case .success(let success):
                completed.send((success, task.shelfID))
            case .failure(let failure):
                // The route name and the exit code, never the command's output:
                // a log line is the one place a stray secret would outlive the
                // process that held it.
                if case .cancelled = failure {} else {
                    NSLog("Magpie: route “\(task.route.name)” failed")
                }
                failed.send(failure)
            }
        }
        runNextIfIdle()
    }
}
