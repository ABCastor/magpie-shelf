import AppKit

/// Stages a shelf into a drop folder, hands the folder to Claude, and waits
/// for the receiving agent to acknowledge it. Thin on purpose: the copy plan
/// lives in `HandoffBundle`, the text in `HandoffPrompt`, the deep-link
/// grammar in `ClaudeLink`.
@MainActor
final class HandoffCoordinator {
    static let shared = HandoffCoordinator()

    /// Wired by `AppDelegate`. Failures have to be visible: a deep link that
    /// silently does nothing is indistinguishable from a broken app.
    var onToast: ((String) -> Void)?

    private let receiptTimeout: TimeInterval = 90
    private let pollInterval: TimeInterval = 1
    private var receiptTask: Task<Void, Never>?

    func send(items: [ShelfItem], managedFilesDirectory: URL) {
        let root = HandoffBundle.root(besideManagedFiles: managedFilesDirectory)
        let drop: HandoffDrop
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            drop = try HandoffBundle.stage(
                items: items,
                in: root,
                managedFilesDirectory: managedFilesDirectory
            )
            try HandoffPrompt.manifest(drop).write(
                to: drop.folder.appendingPathComponent(HandoffBundle.manifestName),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog("Magpie: handoff staging failed — \(error)")
            onToast?(L("handoff.staging-failed"))
            return
        }

        defer { HandoffBundle.sweep(root: root) }

        guard !drop.entries.isEmpty else {
            onToast?(L("handoff.nothing-to-send"))
            return
        }

        let prompt = HandoffPrompt.prompt(
            folder: drop.folder,
            names: drop.entries.map(\.name),
            totalItems: drop.entries.count
        )
        // One folder, and it is $HOME: it contains both the drop and wherever
        // the files are going, so one grant covers both. A session rooted
        // anywhere narrower starts without the context it needs.
        let opened = ClaudeLink.isAvailable && ClaudeLink.open(
            prompt: prompt,
            folder: FileManager.default.homeDirectoryForCurrentUser
        )
        if opened {
            watchForReceipt(in: drop.folder)
        } else {
            reportFailure(folder: drop.folder, message: L("handoff.no-claude"))
        }
    }

    private func watchForReceipt(in folder: URL) {
        receiptTask?.cancel()
        let receipt = folder.appendingPathComponent(HandoffBundle.receiptName)
        let deadline = Date().addingTimeInterval(receiptTimeout)
        let interval = pollInterval
        receiptTask = Task { [weak self] in
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: receipt.path) { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
            }
            self?.reportFailure(folder: folder, message: L("handoff.no-receipt"))
        }
    }

    /// The drop path goes on the clipboard so a failed handoff is still usable:
    /// paste it into any chat and the folder is reachable.
    private func reportFailure(folder: URL, message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([folder.path as NSString])
        onToast?(message)
    }
}
