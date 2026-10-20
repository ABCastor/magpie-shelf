import AppKit
import UniformTypeIdentifiers

@MainActor
func presentTrashError(_ detail: String) {
    let alert = NSAlert()
    alert.messageText = L("Couldn't Move to Trash")
    alert.informativeText = detail
    alert.runModal()
}
/// Target object for NSMenuItem actions. Must be retained for the menu's lifetime,
/// so we keep a strong reference on the ShelfMenu container.
@MainActor
final class ShelfItemActions: NSObject {
    let item: ShelfItem
    let selectedItems: [ShelfItem]   // includes `item` when present in selection;
                                     // [item] for non-selection right-clicks
    let shelfID: UUID
    weak var manager: ShelfManager?
    weak var conversionService: ConversionService?
    weak var ocrService: OCRService?
    weak var routeService: RouteService?

    init(
        item: ShelfItem,
        selectedItems: [ShelfItem],
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?,
        ocrService: OCRService?,
        routeService: RouteService? = nil
    ) {
        self.item = item
        self.selectedItems = selectedItems
        self.shelfID = shelfID
        self.manager = manager
        self.conversionService = conversionService
        self.ocrService = ocrService
        self.routeService = routeService
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard
            let appURL = sender.representedObject as? URL,
            !subjectFileURLs.isEmpty
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(subjectFileURLs, withApplicationAt: appURL, configuration: config)
    }

    @objc func open() {
        guard !subjectFileURLs.isEmpty else { return }
        subjectFileURLs.forEach { NSWorkspace.shared.open($0) }
    }

    @objc func showInFinder() {
        guard !subjectFileURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(subjectFileURLs)
    }

    @objc func quickLook() {
        let urls = subjectFileURLs
        guard !urls.isEmpty else { return }
        let start = Self.quickLookStartIndex(for: item.fileURL, in: urls)
        QuickLookController.shared.show(urls: urls, startingAt: start)
    }

    /// The All Actions row's own action: the same request ⌘K sends. The row
    /// needs a real action for AppKit to keep the key equivalent it teaches,
    /// so the action is the shortcut's — clicking the row opens the palette,
    /// which is the row's submenu flattened and searchable.
    @objc func openPalette() {
        manager?.paletteRequested.send(shelfID)
    }

    static func quickLookStartIndex(for selectedURL: URL?, in urls: [URL]) -> Int {
        let availableURLs = urls.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return (selectedURL.flatMap { availableURLs.firstIndex(of: $0) }) ?? 0
    }

    @objc func copyToPasteboard() {
        _ = ShelfClipboardPayload.write(items: selectedItems, to: .general)
    }

    @objc func share() {
        ShareCoordinator.shared.share(items: selectedItems)
    }

    @objc func sendToClaude() {
        guard let manager else { return }
        HandoffCoordinator.shared.send(
            items: selectedItems,
            managedFilesDirectory: manager.managedFilesDirectory
        )
    }

    @objc func moveToTrash() {
        guard let manager else { return }
        ShelfTrash.move(items: selectedItems, in: shelfID, manager: manager)
    }

    @objc func rename() {
        guard selectedItems.count == 1 else { return }
        guard let url = item.fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let manager else { return }
        let current = url.lastPathComponent
        guard let newName = Self.promptRename(current: current),
              newName != current else { return }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try manager.renameItem(id: item.id, to: newURL, in: shelfID)
        } catch {
            Self.showRenameError(error)
        }
    }

    @MainActor
    private static func promptRename(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Rename")
        alert.informativeText = L("alert.rename.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.stringValue = current
        // Pre-select the basename (stem) so typing replaces only the name and
        // keeps the extension — matches Finder's rename behavior.
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: current.count)
        alert.accessoryView = field
        // Window must exist for makeFirstResponder; defer the focus request to
        // the next runloop tick.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let stem = (current as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: stem.count)
            }
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private static func showRenameError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't rename")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    @objc func duplicateFile() {
        guard selectedItems.count == 1 else { return }
        guard let url = item.fileURL else { return }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent + " copy"
        var candidate = url.deletingLastPathComponent().appendingPathComponent(stem)
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        var final = candidate
        var i = 2
        while FileManager.default.fileExists(atPath: final.path) {
            let name = stem + " \(i)"
            var u = url.deletingLastPathComponent().appendingPathComponent(name)
            if !ext.isEmpty { u.appendPathExtension(ext) }
            final = u
            i += 1
        }
        try? FileManager.default.copyItem(at: url, to: final)
    }

    @objc func removeFromShelf() {
        guard let manager else { return }
        ShelfKeyboardRemove.removeFromShelf(items: selectedItems, in: shelfID, manager: manager)
    }

    // MARK: - Image actions

    @objc func resizeImage() {
        guard selectedItems.count == 1 else { return }
        guard let url = item.fileURL else { return }
        guard let max = ImageActionPrompts.resizeMaxDimension() else { return }
        runImageAction { ImageActions.resize(url: url, maxDimension: max) }
    }

    @objc func convertTo(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ConversionTarget else { return }
        guard let service = conversionService else { return }
        for it in selectedItems {
            guard let url = it.fileURL else { continue }
            // Skip items already converting — re-enqueue would just queue
            // a redundant task at the back of the line.
            guard service.progress[it.id] == nil else { continue }
            service.enqueue(
                sourceItemID: it.id,
                shelfID: shelfID,
                source: url,
                target: target
            )
        }
    }

    @objc func makeSearchable(_ sender: NSMenuItem) {
        guard let service = ocrService else { return }
        for it in selectedItems {
            guard let url = it.fileURL else { continue }
            // Skip items already running an OCR task — re-enqueue would just
            // queue a redundant task at the back of the line.
            guard service.progress[it.id] == nil else { continue }
            service.enqueueMakeSearchable(
                sourceItemID: it.id,
                shelfID: shelfID,
                source: url
            )
        }
    }

    @objc func extractText(_ sender: NSMenuItem) {
        guard let service = ocrService else { return }
        for it in selectedItems {
            guard let url = it.fileURL else { continue }
            guard service.progress[it.id] == nil else { continue }
            let isPDF = url.pathExtension.lowercased() == "pdf"
                || (try? url.resourceValues(forKeys: [.contentTypeKey]))?
                    .contentType?.conforms(to: .pdf) == true
            service.enqueueExtractText(
                sourceItemID: it.id,
                shelfID: shelfID,
                source: url,
                isPDF: isPDF
            )
        }
    }

    /// Merge — the one PDF operation Finder's built-in Quick Action cannot do,
    /// because the inputs live in different folders. That is also why the result
    /// does not go beside the first input the way Create PDF does: with a
    /// cross-folder selection, "beside the first input" is an arbitrary folder.
    ///
    /// Order is the order on screen, top-left card first, and the save panel
    /// shows that order before a byte is written. There is no drag-reorder
    /// anywhere in this app, so a merge that came out backwards can only be
    /// fixed by clearing the shelf and dropping the files again in sequence.
    @objc func mergePDFs() {
        guard let manager else { return }
        // Not read off `selectedItems`: it arrives in shelf-storage order from
        // the context menu and in display order from the ⌘K palette, and only
        // one of those matches the cards the user is looking at.
        let ordered = ShelfDisplayOrder.displayed(
            manager.items(of: shelfID),
            selecting: Set(selectedItems.map(\.id))
        )
        let inputs = ordered.compactMap(\.fileURL)
        guard inputs.count >= 2 else { return }
        guard let chosen = Self.promptMergeDestination(inputs: inputs) else { return }
        // The panel's own replace prompt would overwrite a file Magpie does not
        // manage. ADR 0001: every new file lands at a unique URL, so the chosen
        // name is where the search starts, never a target to write over.
        let destination = ImageActions.uniqueURL(at: chosen)
        let shelfRef = shelfID
        let managerRef = manager
        Task.detached {
            do {
                try PDFMerge.merge(inputs: inputs, into: destination)
                await MainActor.run { _ = managerRef.addFile(url: destination, to: shelfRef) }
            } catch {
                await Self.showMergeFailure(error)
            }
        }
    }

    /// One surface, not two: where it goes, what it is called, and whether the
    /// order is right, all in the single moment the user is already stopped.
    @MainActor
    private static func promptMergeDestination(inputs: [URL]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Merged.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.accessoryView = mergeOrderView(inputs: inputs)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Read-only text, no controls: the name field keeps first responder, so the
    /// whole dialog stays type-the-name-and-press-Return.
    @MainActor
    private static func mergeOrderView(inputs: [URL]) -> NSView {
        let numbered = inputs.enumerated()
            .map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
            .joined(separator: "\n")
        let label = NSTextField(
            wrappingLabelWithString: L("merge.order.label") + "\n" + numbered
        )
        label.translatesAutoresizingMaskIntoConstraints = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 340
        let textHeight = label.fittingSize.height
        label.frame = NSRect(x: 0, y: 0, width: 340, height: textHeight)

        // A long selection would otherwise push the panel past the screen edge,
        // and an order the user cannot read is not a confirmation.
        let visible = min(textHeight, 160)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 12, width: 340, height: visible))
        scroll.hasVerticalScroller = textHeight > visible
        scroll.drawsBackground = false
        scroll.documentView = label
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: visible + 24))
        container.addSubview(scroll)
        return container
    }

    /// Names the file. A merge missing pages is the failure the user does not
    /// notice, so the one thing this alert must never be is generic.
    @MainActor
    private static func showMergeFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Action Failed")
        if case PDFMerge.Failure.unreadable(let name) = error {
            alert.informativeText = String(format: L("alert.merge.unreadable"), name)
        } else {
            alert.informativeText = L("alert.action-failed.body")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    /// Routes: the files the user selected, handed to a command the user
    /// wrote.
    /// Copy-only: the selection is read and stays exactly where it is.
    @objc func runRoute(_ sender: NSMenuItem) {
        guard let routeID = sender.representedObject as? String,
              let service = routeService else { return }
        RouteLauncher.run(
            routeID: routeID,
            items: selectedItems,
            shelfID: shelfID,
            store: RouteStore.shared,
            service: service
        )
    }

    @objc func compressImage() {
        guard selectedItems.count == 1 else { return }
        guard let url = item.fileURL else { return }
        guard let quality = ImageActionPrompts.compressionQuality() else { return }
        runImageAction { ImageActions.compress(url: url, quality: quality) }
    }

    @objc func removeMetadata() {
        guard selectedItems.count == 1 else { return }
        guard let url = item.fileURL else { return }
        runImageAction { ImageActions.removeMetadata(url: url) }
    }

    @objc func createPDF() {
        guard selectedItems.count == 1 else { return }
        guard let url = item.fileURL else { return }
        runImageAction { ImageActions.createPDF(from: [url]) }
    }

    private func runImageAction(_ work: @escaping () -> URL?) {
        let shelfRef = shelfID
        let managerRef = manager
        Task.detached {
            let result = work()
            await MainActor.run {
                if let result {
                    managerRef?.addFile(url: result, to: shelfRef)
                } else {
                    Self.showFailureAlert()
                }
            }
        }
    }

    var subjectFileURLs: [URL] {
        selectedItems.compactMap(\.fileURL)
    }

    @MainActor
    private static func showFailureAlert() {
        let alert = NSAlert()
        alert.messageText = L("Action Failed")
        alert.informativeText = L("alert.action-failed.body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

final class ShelfMenu: NSMenu {
    var actions: ShelfItemActions?
}

enum ShelfContextMenu {
    /// `claudeInstalled` is injectable so the handoff-row gating is testable
    /// on a machine that does have Claude; every real caller passes nil and
    /// gets LaunchServices' answer. An optional rather than a defaulted Bool
    /// because a default argument is evaluated outside the main actor, where
    /// `ClaudeLink.isAvailable` cannot be read.
    @MainActor
    static func make(
        for item: ShelfItem,
        selectedItems: [ShelfItem],
        shelfID: UUID,
        manager: ShelfManager?,
        conversionService: ConversionService?,
        ocrService: OCRService?,
        routeService: RouteService? = nil,
        claudeInstalled: Bool? = nil
    ) -> NSMenu {
        let claudeInstalled = claudeInstalled ?? ClaudeLink.isAvailable
        let menu = ShelfMenu()
        // This menu sets isEnabled on roughly ten rows below; AppKit's default
        // would ignore every one of them and re-enable any row whose target
        // merely responds to the selector. See the note in makeAllActionsMenu.
        menu.autoenablesItems = false
        let actions = ShelfItemActions(
            item: item,
            selectedItems: selectedItems,
            shelfID: shelfID,
            manager: manager,
            conversionService: conversionService,
            ocrService: ocrService,
            routeService: routeService
        )
        menu.actions = actions
        let hasFile = !actions.subjectFileURLs.isEmpty

        // Open With
        let openWithItem = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
        openWithItem.submenu = OpenWithMenuBuilder.make(
            for: actions.subjectFileURLs.first,
            target: actions,
            action: #selector(ShelfItemActions.openWith(_:))
        )
        openWithItem.isEnabled = hasFile
        menu.addItem(openWithItem)

        // Show in Finder
        let show = NSMenuItem(
            title: L("Show in Finder"),
            action: #selector(ShelfItemActions.showInFinder),
            keyEquivalent: ""
        )
        show.target = actions
        show.isEnabled = hasFile
        menu.addItem(show)

        // Quick Look
        let ql = NSMenuItem(
            title: L("Quick Look"),
            action: #selector(ShelfItemActions.quickLook),
            keyEquivalent: " "
        )
        ql.keyEquivalentModifierMask = []
        ql.target = actions
        ql.isEnabled = hasFile
        menu.addItem(ql)

        // Copy
        let copy = NSMenuItem(
            title: L("Copy"),
            action: #selector(ShelfItemActions.copyToPasteboard),
            keyEquivalent: "c"
        )
        copy.target = actions
        menu.addItem(copy)

        // Share
        let share = NSMenuItem(
            title: L("Share…"),
            action: #selector(ShelfItemActions.share),
            keyEquivalent: ""
        )
        share.target = actions
        menu.addItem(share)

        menu.addItem(.separator())

        // Rename — only for items with a real file path. Text snippets and
        // missing files don't get a rename row.
        let canRename = actions.selectedItems.count == 1
            && (item.fileURL != nil) && (item.type != .text)
        let rename = NSMenuItem(
            title: L("Rename…"),
            action: #selector(ShelfItemActions.rename),
            keyEquivalent: ""
        )
        rename.target = actions
        rename.isEnabled = canRename
        menu.addItem(rename)

        menu.addItem(.separator())

        // Move to Trash
        let trash = NSMenuItem(
            title: ShelfActionTitle.moveToTrash(count: actions.selectedItems.count),
            action: #selector(ShelfItemActions.moveToTrash),
            keyEquivalent: ""
        )
        trash.target = actions
        menu.addItem(trash)

        menu.addItem(.separator())

        // All Actions submenu. Carries ⌘K the same way the shelf menu's row
        // does: the palette flattens this menu, so the row that holds the
        // actions is the row that teaches the shortcut to them. The action is
        // required — AppKit strips the key equivalent off an action-less
        // submenu parent — and it is the honest one: what ⌘K does.
        let allActions = NSMenuItem(
            title: L("All Actions"),
            action: #selector(ShelfItemActions.openPalette),
            keyEquivalent: "k"
        )
        allActions.keyEquivalentModifierMask = .command
        allActions.target = actions
        allActions.submenu = makeAllActionsMenu(
            actions: actions,
            hasFile: hasFile,
            isImage: actions.selectedItems.count == 1 && item.type == .image,
            claudeInstalled: claudeInstalled
        )
        menu.addItem(allActions)

        return menu
    }

    @MainActor
    private static func makeAllActionsMenu(
        actions: ShelfItemActions,
        hasFile: Bool,
        isImage: Bool,
        claudeInstalled: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        // This menu decides its own enablement. AppKit's `autoenablesItems`
        // defaults to true, which *ignores* every `isEnabled` set below and
        // re-enables any row whose target merely responds to the selector — so
        // "Show in Finder" on a text snippet looked perfectly clickable and did
        // nothing. Every menu built here manages its own state, so every one of
        // them turns this off. The status menu deliberately does not: its
        // "Check for Updates…" row is wired straight to Sparkle so that AppKit
        // calls Sparkle's own `validateMenuItem` and greys it mid-check.
        menu.autoenablesItems = false

        if let submenu = ConversionMenu.makeSubmenu(
            items: actions.selectedItems,
            target: actions,
            action: #selector(ShelfItemActions.convertTo(_:))
        ) {
            let title = actions.selectedItems.count > 1
                ? String(format: L("Convert %lld Items to"), actions.selectedItems.count)
                : L("Convert to")
            let entry = NSMenuItem(
                title: title,
                action: nil,
                keyEquivalent: ""
            )
            entry.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: entry.title
            )
            entry.submenu = submenu
            menu.addItem(entry)
        }

        let appendedOCR = OCRMenu.appendItems(
            to: menu,
            items: actions.selectedItems,
            target: actions,
            makeSearchableSelector: #selector(ShelfItemActions.makeSearchable(_:)),
            extractTextSelector: #selector(ShelfItemActions.extractText(_:))
        )
        if appendedOCR > 0 {
            // No separator — sits in the same logical group as Convert to ▶.
        }

        // Same logical group again: a PDF-only row, gated the same way the OCR
        // rows are. Reachable from ⌘K for free — the palette flattens this menu.
        if PDFMerge.shouldOffer(for: actions.selectedItems) {
            addItem(
                to: menu,
                title: String(format: L("Merge %lld PDFs…"), actions.selectedItems.count),
                selector: #selector(ShelfItemActions.mergePDFs),
                symbol: "arrow.triangle.merge",
                target: actions
            )
        }

        if actions.routeService != nil, let submenu = RouteMenu.makeSubmenu(
            routes: RouteStore.shared.routes,
            items: actions.selectedItems,
            target: actions,
            action: #selector(ShelfItemActions.runRoute(_:))
        ) {
            let entry = NSMenuItem(title: L("routes.menu"), action: nil, keyEquivalent: "")
            entry.image = NSImage(
                systemSymbolName: "arrow.triangle.branch", accessibilityDescription: entry.title
            )
            entry.submenu = submenu
            menu.addItem(entry)
        }

        if isImage {
            menu.addItem(sectionHeader(L("Image Actions")))

            addItem(to: menu, title: L("Resize…"),
                    selector: #selector(ShelfItemActions.resizeImage),
                    symbol: "arrow.down.right.and.arrow.up.left",
                    target: actions)
            addItem(to: menu, title: L("Compress…"),
                    selector: #selector(ShelfItemActions.compressImage),
                    symbol: "arrow.down.to.line.compact",
                    target: actions)
            addItem(to: menu, title: L("Remove Metadata"),
                    selector: #selector(ShelfItemActions.removeMetadata),
                    symbol: "tag.slash",
                    target: actions)
            addItem(to: menu, title: L("Create PDF"),
                    selector: #selector(ShelfItemActions.createPDF),
                    symbol: "doc.badge.plus",
                    target: actions)

            menu.addItem(.separator())
            menu.addItem(sectionHeader(L("General Actions")))
        }

        let open = NSMenuItem(
            title: L("Open"),
            action: #selector(ShelfItemActions.open),
            keyEquivalent: ""
        )
        open.target = actions
        open.isEnabled = hasFile
        menu.addItem(open)

        let duplicate = NSMenuItem(
            title: L("Duplicate"),
            action: #selector(ShelfItemActions.duplicateFile),
            keyEquivalent: ""
        )
        duplicate.target = actions
        duplicate.isEnabled = hasFile && actions.selectedItems.count == 1
        menu.addItem(duplicate)

        // Scoped to the same menu subject as every other row. Gated on Claude
        // actually being installed, not merely on the selection:
        // without Claude this row is a dead end that stages a copy of the
        // user's files before discovering there is nowhere to send them.
        let handoffRow = HandoffMenu.row(
            claudeInstalled: claudeInstalled,
            hasSendableFiles: actions.selectedItems.contains { $0.fileURL != nil }
        )
        if handoffRow != .absent {
            let handoff = NSMenuItem(
                title: L("handoff.ingest"),
                action: #selector(ShelfItemActions.sendToClaude),
                keyEquivalent: ""
            )
            handoff.target = actions
            handoff.image = NSImage(
                systemSymbolName: "tray.and.arrow.up", accessibilityDescription: handoff.title
            )
            handoff.isEnabled = handoffRow == .enabled
            menu.addItem(handoff)
        }

        menu.addItem(.separator())

        let remove = NSMenuItem(
            title: ShelfActionTitle.removeItemsFromShelf(count: actions.selectedItems.count),
            action: #selector(ShelfItemActions.removeFromShelf),
            keyEquivalent: ""
        )
        remove.target = actions
        menu.addItem(remove)

        return menu
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    @MainActor
    private static func addItem(
        to menu: NSMenu,
        title: String,
        selector: Selector,
        symbol: String,
        target: AnyObject
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        // The glyph depicts the action the row's title names; describing it as
        // anything else would just be a second, drifting name for the same row.
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.isTemplate = true
            item.image = image
        }
        menu.addItem(item)
    }

}
