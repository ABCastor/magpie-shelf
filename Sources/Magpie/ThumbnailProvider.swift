import AppKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ThumbnailProvider {
    private final class CachedThumbnail: NSObject {
        let image: NSImage
        let isIcon: Bool

        init(image: NSImage, isIcon: Bool) {
            self.image = image
            self.isIcon = isIcon
        }
    }

    private static let thumbnailCache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.countLimit = 256
        return cache
    }()

    /// What a generation attempt produced: the image, and whether it is a
    /// file-type icon rather than a real preview.
    typealias Result = (image: NSImage, isIcon: Bool)

    /// The QuickLook call behind `generateThumbnail`, injectable because its
    /// failure path (no representation at all) cannot be driven on demand
    /// through the real generator — QuickLook decides for itself which inputs
    /// it can still icon, and it icons even files that do not exist.
    typealias Generator = (
        QLThumbnailGenerator.Request,
        @escaping @Sendable (Result?) -> Void
    ) -> Void

    static let quickLookGenerator: Generator = { request, handler in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            handler(rep.map { ($0.nsImage, $0.type == .icon) })
        }
    }

    @MainActor
    static func generateThumbnail(
        for url: URL,
        generator: Generator = quickLookGenerator,
        completion: @escaping @MainActor (NSImage, Bool) -> Void
    ) {
        let key = cacheKey(for: url)
        if let cached = thumbnailCache.object(forKey: key as NSString) {
            completion(cached.image, cached.isIcon)
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: 256, height: 320)
        // Only image files get the full QL preview pipeline; everything else
        // gets the file-type icon. QL's "thumbnail" rep for text/markdown/json
        // is a rendered page on a white background, which clashes with the
        // dark shelf and reads as a stray paper backdrop.
        let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey])
            .contentType)?.conforms(to: .image) ?? false
        let reprTypes: QLThumbnailGenerator.Request.RepresentationTypes =
            isImage ? .all : .icon
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: reprTypes
        )
        generator(request) { result in
            guard let result else {
                // QuickLook failed outright (unreadable file, sandboxed
                // volume, a codec it doesn't know). Swallowing the callback
                // here left the card wearing its placeholder forever — this
                // completion is the only thing that ever replaces it. Fall
                // back to the file-type icon, and deliberately do NOT cache
                // it: the next request retries, so a transient failure heals.
                Task { @MainActor in
                    completion(NSWorkspace.shared.icon(forFile: url.path), true)
                }
                return
            }
            thumbnailCache.setObject(
                CachedThumbnail(image: result.image, isIcon: result.isIcon),
                forKey: key as NSString
            )
            Task { @MainActor in
                completion(result.image, result.isIcon)
            }
        }
    }

    private static func cacheKey(for url: URL) -> String {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate?.timeIntervalSince1970) ?? 0
        return "\(url.path)#\(mod)"
    }
}
