import AppKit
import UniformTypeIdentifiers

/// Builds the "Convert to ▶" submenu given a shelf-item selection. The
/// submenu is `nil` when the selection has no valid conversion target.
@MainActor
enum ConversionMenu {
    /// Selector handler signature: target action object owns a method that
    /// reads `representedObject as? ConversionTarget` and dispatches into
    /// the service.
    static func makeSubmenu(
        items: [ShelfItem],
        target: AnyObject,
        action: Selector
    ) -> NSMenu? {
        let urls = items.compactMap(\.fileURL)
        guard !urls.isEmpty, urls.count == items.count else { return nil }

        let utis = urls.compactMap(uti(for:))
        guard utis.count == urls.count else { return nil }

        // Image case: at least one image UTI in the selection. Take the
        // intersection of supported targets across selection.
        let imageTargets: [ConversionTarget]
        if utis.allSatisfy({ !ConversionTarget.supportedImageTargets(for: $0).isEmpty }) {
            imageTargets = ConversionTarget.commonImageTargets(forSourceUTIs: utis)
        } else {
            imageTargets = []
        }

        // Video case: every selected file is a readable video container.
        let isAllVideo = utis.allSatisfy(ConversionTarget.isVideoSourceUTI)
        let allReadable = isAllVideo && urls.allSatisfy { url in
            AVAssetReadabilityCache.isReadable(url)
        }

        var options: [ConversionTarget] = imageTargets
        if isAllVideo, allReadable { options.append(.mp4) }

        guard !options.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for option in options {
            let item = NSMenuItem(
                title: option.displayName,
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = option
            menu.addItem(item)
        }
        return menu
    }

    private static func uti(for url: URL) -> UTType? {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let t = values.contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }
}

// AVURLAsset.isReadable is expensive (opens the file). Reuse the result while
// the file is unchanged, then re-evaluate after its modification date changes.
import AVFoundation

@MainActor
enum AVAssetReadabilityCache {
    private struct Entry {
        let modificationDate: Date?
        let isReadable: Bool
    }

    private static var cache: [String: Entry] = [:]

    static func isReadable(
        _ url: URL,
        evaluate: (URL) -> Bool = { AVURLAsset(url: $0).isReadable }
    ) -> Bool {
        let key = url.path
        let modificationDate = (try? FileManager.default.attributesOfItem(
            atPath: key
        ))?[.modificationDate] as? Date
        if let cached = cache[key], cached.modificationDate == modificationDate {
            return cached.isReadable
        }
        let result = evaluate(url)
        cache[key] = Entry(modificationDate: modificationDate, isReadable: result)
        return result
    }
}
