import AppKit

/// Hosts the NSSharingServicePicker so its delegate outlives the menu invocation.
@MainActor
final class ShareCoordinator: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareCoordinator()

    private var activePicker: NSSharingServicePicker?

    func share(item: ShelfItem) {
        share(items: [item])
    }

    /// Share from a shelf's header button: the picker opens at the pointer,
    /// on the shelf that was clicked, whether or not it is the key window.
    func shareFromPointer(items: [ShelfItem]) {
        let mouse = NSEvent.mouseLocation
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(mouse) && $0 is NSPanel }),
              let view = window.contentView else {
            share(items: items)
            return
        }
        let local = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        share(items: items, anchor: NSRect(x: local.x, y: local.y, width: 1, height: 1), in: view)
    }

    func share(items: [ShelfItem], anchor: NSRect? = nil, in anchorView: NSView? = nil) {
        var shareItems: [Any] = []
        for item in items {
            if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
                shareItems.append(url)
            }
            if let text = item.textContent, !text.isEmpty {
                shareItems.append(text)
            }
        }
        guard !shareItems.isEmpty else { return }

        let picker = NSSharingServicePicker(items: shareItems)
        picker.delegate = self
        self.activePicker = picker

        if let anchor, let anchorView {
            picker.show(relativeTo: anchor, of: anchorView, preferredEdge: .minY)
            return
        }
        // Anchor to the shelf panel's content view (the currently key window).
        if let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }),
           let view = window.contentView {
            let anchor = NSRect(x: view.bounds.midX, y: 0, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    // MARK: - NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        Task { @MainActor in
            self.activePicker = nil
        }
    }
}
