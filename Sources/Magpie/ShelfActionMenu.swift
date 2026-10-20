import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The `⋯` button in the strip's chrome line.
///
/// **This one is the shelf's menu and stays the shelf's menu**, even while the
/// header reads `1 of 5`. It is not a row: the user aimed at a control that sits
/// beside the close, dock and expand glyphs, all of which act on the shelf, and
/// nothing about pressing it names a file. A right-click on a *row* is the
/// gesture that means "these files", and that one now answers to the pick
/// (ADR 0014).
///
/// What keeps the difference honest is that the rows say which they are: with
/// five files on the shelf this menu offers **Move 5 Files to Trash** whatever
/// the header says, so the two menus can differ without either one lying.
struct ShelfActionMenu: View {
    @ObservedObject var manager: ShelfManager
    @EnvironmentObject private var routeService: RouteService
    let shelfID: UUID

    var body: some View {
        ShelfChromeButton(
            systemName: "ellipsis",
            label: L("a11y.shelf-actions"),
            action: presentMenu
        )
    }

    private func presentMenu() {
        let menu = ShelfActionMenuBuilder.make(
            manager: manager,
            shelfID: shelfID,
            // Written out rather than left to the default: the whole shelf is a
            // decision here, not an omission.
            selection: ShelfSelection.wholeShelf,
            routeService: routeService
        )
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

enum ZipArchiveWriter {
    /// The argv handed to `/usr/bin/zip`, run from the staging directory.
    /// `-x "*.DS_Store"` matters because `-r` recurses into every staged
    /// folder: without it, each folder a user zips and sends to a stranger
    /// carries Finder's metadata droppings at every level. Info-ZIP wildcards
    /// span path separators, so one pattern covers `.DS_Store` at any depth.
    nonisolated static func arguments(
        archivePath: String,
        basenames: [String]
    ) -> [String] {
        ["-r", archivePath] + basenames + ["-x", "*.DS_Store"]
    }

    static func write(
        to destination: URL,
        fileManager: FileManager = .default,
        createArchiveAt: (URL) -> String?
    ) -> String? {
        let temporaryArchive = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp.zip")
        defer { try? fileManager.removeItem(at: temporaryArchive) }

        if let failure = createArchiveAt(temporaryArchive) { return failure }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryArchive)
            } else {
                try fileManager.moveItem(at: temporaryArchive, to: destination)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The words on a row that acts on a set, so a menu is never vaguer than the
/// header above it.
///
/// The strip is quiet at rest and says what is in play in words (`5 Files`,
/// `1 of 5`, ADR 0012). A menu row reading a bare "Move to Trash" over five of
/// the user's files says nothing at all about the five, which is exactly how a
/// menu that ignored the pick went unnoticed. So the count travels into the
/// title from the same set the action receives.
///
/// Singular plain, plural counted — the shape the app already uses for `Copy` /
/// `Copy %lld Files` two rows above, and for every `undo.*-count` title. A
/// second shape for the same idea would be one more thing to keep in step.
enum ShelfActionTitle {
    static func moveToTrash(count: Int) -> String {
        count <= 1 ? L("Move to Trash") : String(format: L("menu.trash-count"), count)
    }

    /// Taking rows off the shelf. Emptying it is still called **Clear Shelf**:
    /// that is what it does, it is what the row has always said, and the undo
    /// entry behind it says the same. Anything short of the whole shelf names
    /// how much it takes instead.
    static func removeFromShelf(count: Int, of total: Int) -> String {
        if count >= total { return L("Clear Shelf") }
        return removeItemsFromShelf(count: count)
    }

    /// The same row in the **item** menu, which never collapses to "Clear
    /// Shelf". You reached this row by right-clicking a file, so it has to
    /// name the files: on a one-item shelf the shelf-menu wording is literally
    /// accurate and still reads as the wrong answer to what you just clicked.
    static func removeItemsFromShelf(count: Int) -> String {
        count <= 1
            ? L("Remove from Shelf")
            : String(format: L("menu.remove-count-from-shelf"), count)
    }

    static func copy(count: Int) -> String {
        count <= 1 ? L("Copy") : String(format: L("Copy %lld Files"), count)
    }
}

// MARK: - Actions target

/// Internal rather than file-private so a test can read the set a built menu's
/// rows would actually receive, without entering AppKit's modal tracking loop —
/// a real context menu blocks it for the better part of a minute. The same move
/// `ExpandedShelfView` made for the same reason (ADR 0013).
@MainActor
final class ShelfActionTargets: NSObject {
    let manager: ShelfManager
    let shelfID: UUID
    /// What the user picked out on the strip. **Empty is not "nothing": it is
    /// the whole shelf** (ADR 0012) — so the `⋯` button and every caller that
    /// means the shelf passes `ShelfSelection.wholeShelf` and gets exactly the
    /// behaviour this menu has always had.
    let selection: Set<UUID>
    weak var routeService: RouteService?
    private let writeCopy: ([ShelfItem]) -> Bool

    init(
        manager: ShelfManager,
        shelfID: UUID,
        selection: Set<UUID> = ShelfSelection.wholeShelf,
        routeService: RouteService? = nil,
        copyWriter: @escaping ([ShelfItem]) -> Bool = { items in
            ShelfClipboardPayload.write(items: items, to: .general)
        }
    ) {
        self.manager = manager
        self.shelfID = shelfID
        self.selection = selection
        self.routeService = routeService
        self.writeCopy = copyWriter
    }

    /// **The subject of every row in this menu, and the only place that decides
    /// it.** Read through `ShelfSelection.carried`, which is `effective` — the
    /// same answer the header states in words and a drag carries out. It used
    /// to be `manager.items(of: shelfID)`, which is how a shelf showing `1 of 5`
    /// recycled five files.
    var items: [ShelfItem] {
        ShelfSelection.carried(manager.items(of: shelfID), explicit: selection)
    }

    /// How many rows the shelf holds, for the one question that is genuinely
    /// about the shelf rather than about the pick: whether "clear" is emptying
    /// it. A second door beside `items` and deliberately the last one — no
    /// action below may reach past these two, which is what
    /// `StripMenuClaimTests` checks by reading this file.
    var shelfItemCount: Int { manager.items(of: shelfID).count }

    private var urls: [URL] {
        items.compactMap { $0.fileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard
            let appURL = sender.representedObject as? URL,
            let fileURL = items.first?.fileURL
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
    }

    @objc func showInFinder() {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func quickLook() {
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(startingAt: urls.count - 1)
    }

    /// The All Actions row's own action: the same request ⌘K sends. The row
    /// needs a real action for AppKit to keep the key equivalent it teaches,
    /// so the action is the shortcut's — clicking the row opens the palette,
    /// which is the row's submenu flattened and searchable.
    @objc func openPalette() {
        manager.paletteRequested.send(shelfID)
    }

    @objc func airDrop() {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    @objc func messages() {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .composeMessage) else { return }
        service.perform(withItems: urls)
    }

    @objc func addFromClipboard() {
        _ = manager.addFromClipboard(to: shelfID)
    }

    @objc func sendToClaude() {
        HandoffCoordinator.shared.send(
            items: items,
            managedFilesDirectory: manager.managedFilesDirectory
        )
    }

    /// Routes — the whole shelf, handed to a command the owner wrote.
    /// Copy-only: the files are read and nothing on the shelf changes.
    @objc func runRoute(_ sender: NSMenuItem) {
        guard let routeID = sender.representedObject as? String,
              let service = routeService else { return }
        RouteLauncher.run(
            routeID: routeID,
            items: items,
            shelfID: shelfID,
            store: RouteStore.shared,
            service: service
        )
    }

    /// One copy row, not two. A separate "Copy for chat" beside this one would
    /// buy a decision — *which copy do I want?* — on every single use, forever;
    /// the payload is folded in instead. File targets still receive the files
    /// exactly as before; a text target now receives a readable block of
    /// absolute paths rather than nothing.
    @objc func copyAll() {
        _ = writeCopy(items)
    }

    /// **Clear Shelf**, or **Remove N Files from Shelf** — one row, and which
    /// one it is depends on nothing but the set below it.
    ///
    /// Rows only: nothing here goes near the filesystem (ADR 0001). Emptying
    /// the shelf keeps going through `clear`, so its single "Undo Clear Shelf"
    /// entry is untouched; a narrowed shelf takes exactly the picked rows off
    /// with one undo entry of its own, the same door ⌫ uses.
    @objc func clear() {
        let carried = items
        guard carried.count < shelfItemCount else {
            manager.clear(shelfID: shelfID)
            return
        }
        ShelfKeyboardRemove.removeFromShelf(items: carried, in: shelfID, manager: manager)
    }

    @objc func undo() {
        manager.performUndo()
    }

    // MARK: - Identity

    @objc func renameShelf() {
        let current = manager.shelf(id: shelfID)?.name ?? ""
        guard let new = Self.promptShelfName(current: current) else { return }
        manager.renameShelf(id: shelfID, to: new)
    }

    @objc func togglePinned() {
        let current = manager.shelf(id: shelfID)?.pinned ?? false
        manager.setShelfPinned(id: shelfID, !current)
    }

    @objc func setAccentColor(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        manager.setShelfAccent(id: shelfID, .color(hex))
    }

    @objc func pickAccentEmoji() {
        // Toggling the character palette is the cheapest way to let the user
        // pick an emoji without rolling a custom picker. The user copies the
        // glyph; we read it back from the pasteboard via promptShelfName-style
        // alert for now.
        guard let emoji = Self.promptEmoji() else { return }
        manager.setShelfAccent(id: shelfID, .emoji(emoji))
    }

    @objc func clearAccent() {
        manager.setShelfAccent(id: shelfID, nil)
    }

    // MARK: - Global actions

    @objc func getInfo() {
        let urls = self.urls
        guard !urls.isEmpty else { return }
        // Cap to avoid spamming windows for huge shelves.
        for url in urls.prefix(8) {
            let escaped = url.path.replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(escaped)" as alias)
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    @objc func batchRename() {
        let renamable = items.compactMap { item -> (UUID, URL)? in
            guard let url = item.fileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (item.id, url)
        }
        guard !renamable.isEmpty else { return }
        guard let pattern = Self.promptBatchRename() else { return }

        var failures: [(name: String, reason: String)] = []
        var renamedCount = 0

        // Files we're about to rename away — don't treat them as collisions.
        let sourcePaths = Set(renamable.map { $0.1.standardizedFileURL.path })
        var plannedPaths: Set<String> = []

        for (i, pair) in renamable.enumerated() {
            let number = i + 1
            let url = pair.1
            let ext = url.pathExtension
            let dir = url.deletingLastPathComponent()

            // Only insert a number when the pattern asks for it.
            let baseName = pattern.contains("#")
                ? pattern.replacingOccurrences(of: "#", with: "\(number)")
                : pattern

            var target = dir.appendingPathComponent(baseName)
            if !ext.isEmpty { target.appendPathExtension(ext) }

            // Disambiguate only when the intended name really collides.
            var n = 2
            while target.standardizedFileURL.path != url.standardizedFileURL.path {
                let key = target.standardizedFileURL.path
                let existsOnDisk = FileManager.default.fileExists(atPath: target.path)
                    && !sourcePaths.contains(key)
                if !plannedPaths.contains(key) && !existsOnDisk { break }
                var cand = dir.appendingPathComponent("\(baseName) \(n)")
                if !ext.isEmpty { cand.appendPathExtension(ext) }
                target = cand
                n += 1
            }

            plannedPaths.insert(target.standardizedFileURL.path)
            guard target.standardizedFileURL.path != url.standardizedFileURL.path else {
                continue
            }

            do {
                try manager.renameItem(id: pair.0, to: target, in: shelfID)
                renamedCount += 1
            } catch {
                failures.append((
                    name: url.lastPathComponent,
                    reason: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                ))
            }
        }

        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = renamedCount > 0
                ? String(format: L("alert.batch-renamed.title"), renamedCount, failures.count)
                : L("Batch Rename Failed")
            alert.informativeText = failures
                .map { "• \($0.name) — \($0.reason)" }
                .joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }

    @objc func createZipArchive() {
        let urls = self.urls
        guard !urls.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Archive.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // Stage the sources by hard-link (falls back to copy) into a temp dir,
        // then run `zip -r` from that dir using basenames. This sidesteps
        // `zip -j` path-junk warnings and avoids any TCC surprises from
        // spawning zip with absolute paths into protected folders.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shelf-zip-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            Self.showZipError(String(format: L("alert.zip.staging-failed"), error.localizedDescription))
            return
        }

        var basenames: [String] = []
        var seen: Set<String> = []
        for src in urls {
            let name = Self.uniqueName(for: src.lastPathComponent, in: &seen)
            let link = staging.appendingPathComponent(name)
            do {
                try FileManager.default.linkItem(at: src, to: link)
            } catch {
                // Fall back to copy for cross-volume or permission cases.
                do {
                    try FileManager.default.copyItem(at: src, to: link)
                } catch {
                    Self.showZipError(String(format: L("alert.zip.stage-failed"), src.lastPathComponent, error.localizedDescription))
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
            }
            basenames.append(name)
        }

        Task.detached {
            let failure = ZipArchiveWriter.write(to: dest) { archiveURL in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = staging
                process.arguments = ZipArchiveWriter.arguments(
                    archivePath: archiveURL.path, basenames: basenames
                )

                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = Pipe()

                do {
                    try process.run()
                } catch {
                    return String(
                        format: L("alert.zip.launch-failed"),
                        error.localizedDescription
                    )
                }
                process.waitUntilExit()

                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = process.terminationStatus
                if status != 0 {
                    return errText.isEmpty
                        ? String(format: L("alert.zip.exit-status"), Int(status))
                        : errText
                }
                return nil
            }
            try? FileManager.default.removeItem(at: staging)
            if let failure { await Self.showZipError(failure) }
        }
    }

    @MainActor
    private static func showZipError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = L("Archive Failed")
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func uniqueName(for name: String, in seen: inout Set<String>) -> String {
        var candidate = name
        if !seen.contains(candidate) {
            seen.insert(candidate)
            return candidate
        }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !seen.contains(candidate) {
                seen.insert(candidate)
                return candidate
            }
            i += 1
        }
    }

    @objc func copyPath() {
        let urls = self.urls
        guard !urls.isEmpty else { return }
        let joined = urls.map { $0.path }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([joined as NSString])
    }

    /// The sharp end. Whatever this trashes is what the row above it named and
    /// what the header claimed — `items` is the pick, and `NSWorkspace.recycle`
    /// is still the only way a user file is touched at all (ADR 0001).
    @objc func moveAllToTrash() {
        ShelfTrash.move(items: items, in: shelfID, manager: manager)
    }

    static func promptShelfName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Rename Shelf")
        alert.informativeText = L("alert.shelf-rename.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func promptEmoji() -> String? {
        let alert = NSAlert()
        alert.messageText = L("Set Accent Emoji")
        alert.informativeText = L("alert.emoji.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("Set"))
        alert.addButton(withTitle: L("Cancel"))
        // Open the system character palette so the user can pick one.
        NSApp.orderFrontCharacterPalette(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    static func promptBatchRename(defaultPattern: String = "File #") -> String? {
        let alert = NSAlert()
        alert.messageText = L("Batch Rename")
        alert.informativeText = L("alert.batch-rename.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultPattern
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Internal, and it holds its targets in the open, so a test can ask a built
/// menu what its rows would act on. Every row in it is wired to this one object,
/// so that answer is the whole answer.
final class ShelfActionNSMenu: NSMenu {
    var targets: ShelfActionTargets?
}

// MARK: - Menu builder

@MainActor
enum ShelfActionMenuBuilder {
    /// `claudeInstalled` is injectable so the gating below is testable on a
    /// machine that does have Claude; every real caller passes nil and gets
    /// LaunchServices' answer — the same source of truth the Settings agent
    /// picker uses (`HarnessResolver.installed`). An optional rather than a
    /// defaulted Bool because a default argument is evaluated outside the
    /// main actor, where `ClaudeLink.isAvailable` cannot be read.
    ///
    /// `selection` is what the user picked out on the strip, and **empty means
    /// the whole shelf** — the one representation ADR 0012 settled, so a caller
    /// that means the shelf passes `ShelfSelection.wholeShelf` (or nothing) and
    /// gets byte-for-byte the menu this has always built. A caller that hands
    /// over a pick gets a menu every row of which acts on exactly that pick, and
    /// says so where it matters.
    static func make(
        manager: ShelfManager,
        shelfID: UUID,
        selection: Set<UUID> = ShelfSelection.wholeShelf,
        routeService: RouteService? = nil,
        claudeInstalled: Bool? = nil
    ) -> NSMenu {
        let claudeInstalled = claudeInstalled ?? ClaudeLink.isAvailable
        let menu = ShelfActionNSMenu()
        menu.autoenablesItems = false
        let targets = ShelfActionTargets(
            manager: manager,
            shelfID: shelfID,
            selection: selection,
            routeService: routeService
        )
        menu.targets = targets

        // Read off the targets, never recomputed here: the rows must be built
        // from the same set they will act on, or the menu can describe one thing
        // and do another — which is the whole of the defect this closes.
        let items = targets.items
        let shelfTotal = targets.shelfItemCount
        let urls = items.compactMap { $0.fileURL }
        let hasFiles = !urls.isEmpty

        // Open With — only for a single file
        if items.count == 1, let url = items[0].fileURL {
            let openWith = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
            openWith.image = symbol("square.stack", describing: openWith.title)
            openWith.submenu = OpenWithMenuBuilder.make(
                for: url,
                target: targets,
                action: #selector(ShelfActionTargets.openWith(_:))
            )
            menu.addItem(openWith)
        }

        menu.addItem(makeItem(
            title: L("Show in Finder"),
            symbol: "folder",
            action: #selector(ShelfActionTargets.showInFinder),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Quick Look"),
            symbol: "eye",
            action: #selector(ShelfActionTargets.quickLook),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Get Info"),
            symbol: "info.circle",
            action: #selector(ShelfActionTargets.getInfo),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        // The clipboard group: what leaves on the pasteboard, and what arrives
        // from it. Kept together because the user's question here is one
        // question — "how do I get this into the other window" — and the three
        // answers used to sit in two different menus.
        menu.addItem(makeItem(
            title: ShelfActionTitle.copy(count: items.count),
            symbol: "doc.on.doc",
            action: #selector(ShelfActionTargets.copyAll),
            target: targets,
            enabled: !items.isEmpty
        ))

        menu.addItem(makeItem(
            title: L("Copy Path"),
            symbol: "text.alignleft",
            action: #selector(ShelfActionTargets.copyPath),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Add From Clipboard"),
            symbol: "doc.on.clipboard",
            action: #selector(ShelfActionTargets.addFromClipboard),
            target: targets,
            enabled: true
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: L("AirDrop"),
            symbol: "wave.3.right",
            action: #selector(ShelfActionTargets.airDrop),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Messages"),
            symbol: "message",
            action: #selector(ShelfActionTargets.messages),
            target: targets,
            enabled: hasFiles
        ))

        // Gated on Claude actually being installed, not merely on having
        // files: without Claude this row is a dead end that stages a copy of
        // the user's files before discovering there is nowhere to send them.
        let handoffRow = HandoffMenu.row(
            claudeInstalled: claudeInstalled, hasSendableFiles: hasFiles
        )
        if handoffRow != .absent {
            menu.addItem(makeItem(
                title: L("handoff.ingest"),
                symbol: "tray.and.arrow.up",
                action: #selector(ShelfActionTargets.sendToClaude),
                target: targets,
                enabled: handoffRow == .enabled
            ))
        }

        if routeService != nil, let submenu = RouteMenu.makeSubmenu(
            routes: RouteStore.shared.routes,
            items: items,
            target: targets,
            action: #selector(ShelfActionTargets.runRoute(_:))
        ) {
            let routes = NSMenuItem(title: L("routes.menu"), action: nil, keyEquivalent: "")
            routes.image = symbol("arrow.triangle.branch", describing: routes.title)
            routes.submenu = submenu
            menu.addItem(routes)
        }

        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: L("Batch Rename…"),
            symbol: "character.cursor.ibeam",
            action: #selector(ShelfActionTargets.batchRename),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(makeItem(
            title: L("Create ZIP Archive…"),
            symbol: "doc.zipper",
            action: #selector(ShelfActionTargets.createZipArchive),
            target: targets,
            enabled: hasFiles
        ))

        menu.addItem(.separator())

        // ⌘K, on a row that opens the palette and carries no submenu.
        //
        // It used to head a submenu called "All Actions", which is what a menu
        // calls a drawer it has stopped organising: Get Info, Batch Rename,
        // Create ZIP and Copy Path had nothing in common except not having
        // been placed, and Move to Trash — the one row in this app that moves
        // a user's file — sat at the bottom of it, two levels down, where an
        // action that consequential must never be. Those rows now sit with the
        // actions they belong to. What is left is the honest thing this row
        // always did on a click: open the palette, which is this menu
        // flattened and searchable, and therefore genuinely all actions.
        let allActions = NSMenuItem(
            title: L("All Actions"),
            action: #selector(ShelfActionTargets.openPalette),
            keyEquivalent: "k"
        )
        allActions.keyEquivalentModifierMask = .command
        allActions.target = targets
        allActions.image = symbol("ellipsis.circle", describing: allActions.title)
        menu.addItem(allActions)

        let identity = NSMenuItem(title: L("Shelf"), action: nil, keyEquivalent: "")
        identity.image = symbol("tag", describing: identity.title)
        identity.submenu = makeIdentityMenu(manager: manager, shelfID: shelfID, targets: targets)
        menu.addItem(identity)

        // Undo (Cmd-Z) — title reflects what's about to be reversed so the
        // user knows whether they're undoing a Clear or a Move-to-Trash. The
        // row stays in the menu when there's nothing to undo (disabled), so
        // discoverability isn't tied to recent activity.
        let undoTitle = manager.undoSnapshot?.menuTitle ?? L("Undo")
        let undo = NSMenuItem(
            title: undoTitle,
            action: #selector(ShelfActionTargets.undo),
            keyEquivalent: "z"
        )
        undo.keyEquivalentModifierMask = .command
        undo.target = targets
        undo.image = symbol("arrow.uturn.backward", describing: undo.title)
        undo.isEnabled = manager.canUndo
        menu.addItem(undo)

        menu.addItem(makeItem(
            title: ShelfActionTitle.removeFromShelf(count: items.count, of: shelfTotal),
            symbol: "xmark.bin",
            action: #selector(ShelfActionTargets.clear),
            target: targets,
            enabled: !items.isEmpty
        ))

        // The two ways to be rid of something, adjacent and in order of
        // consequence: the shelf forgets it, or the file goes to the Bin.
        // Adjacent because the user is answering one question and the
        // difference between the answers is the whole point; last because it
        // is the only row here that touches a file; and carrying ⌘⌫ because
        // that is what the keystroke does and a menu is where a keystroke is
        // taught. The count comes off the targets, which is the set
        // `moveAllToTrash` recycles (ADR 0014).
        let trash = NSMenuItem(
            title: ShelfActionTitle.moveToTrash(count: items.count),
            action: #selector(ShelfActionTargets.moveAllToTrash),
            keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!)
        )
        trash.keyEquivalentModifierMask = .command
        trash.target = targets
        trash.image = symbol("trash", describing: trash.title)
        trash.isEnabled = hasFiles
        menu.addItem(trash)

        return menu
    }

    private static func makeIdentityMenu(
        manager: ShelfManager,
        shelfID: UUID,
        targets: ShelfActionTargets
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let shelf = manager.shelf(id: shelfID)
        let isPinned = shelf?.pinned ?? false
        let currentAccent = shelf?.accent

        let renameTitle = (shelf?.name?.isEmpty == false) ? L("Rename Shelf…") : L("Name Shelf…")
        menu.addItem(makeItem(
            title: renameTitle,
            symbol: "character.cursor.ibeam",
            action: #selector(ShelfActionTargets.renameShelf),
            target: targets,
            enabled: true
        ))

        let pin = makeItem(
            title: isPinned ? L("Unpin Shelf") : L("Pin Shelf"),
            symbol: isPinned ? "pin.slash" : "pin",
            action: #selector(ShelfActionTargets.togglePinned),
            target: targets,
            enabled: true
        )
        if isPinned { pin.state = .on }
        menu.addItem(pin)

        menu.addItem(.separator())

        let accentLabel = NSMenuItem(title: L("Accent"), action: nil, keyEquivalent: "")
        accentLabel.image = symbol("paintpalette", describing: accentLabel.title)
        accentLabel.submenu = makeAccentMenu(currentAccent: currentAccent, targets: targets)
        menu.addItem(accentLabel)

        return menu
    }

    private static func makeAccentMenu(
        currentAccent: ShelfAccent?,
        targets: ShelfActionTargets
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let none = NSMenuItem(
            title: L("None"),
            action: #selector(ShelfActionTargets.clearAccent),
            keyEquivalent: ""
        )
        none.target = targets
        if currentAccent == nil { none.state = .on }
        menu.addItem(none)

        menu.addItem(.separator())

        let palette: [(String, String)] = [
            (L("Red"),    "#FF453A"),
            (L("Orange"), "#FF9F0A"),
            (L("Yellow"), "#FFD60A"),
            (L("Green"),  "#30D158"),
            (L("Blue"),   "#0A84FF"),
            (L("Purple"), "#BF5AF2"),
        ]
        for (label, hex) in palette {
            let mi = NSMenuItem(
                title: label,
                action: #selector(ShelfActionTargets.setAccentColor(_:)),
                keyEquivalent: ""
            )
            mi.target = targets
            mi.representedObject = hex
            mi.image = colorSwatch(hex: hex)
            if case .color(let active) = currentAccent, active == hex { mi.state = .on }
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        let emoji = NSMenuItem(
            title: L("Pick Emoji…"),
            action: #selector(ShelfActionTargets.pickAccentEmoji),
            keyEquivalent: ""
        )
        emoji.target = targets
        if case .emoji = currentAccent { emoji.state = .on }
        menu.addItem(emoji)

        return menu
    }

    private static func colorSwatch(hex: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            (NSColor(hex: hex) ?? .systemGray).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        return image
    }

    private static func makeItem(
        title: String,
        symbol name: String,
        action: Selector,
        target: AnyObject,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = symbol(name, describing: title)
        item.isEnabled = enabled
        return item
    }

    /// `describing` is the row's own title: the glyph depicts the action the
    /// title names, and reading it off the item keeps the two from drifting.
    private static func symbol(_ name: String, describing: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: describing)
    }

}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
