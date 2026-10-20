import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synchronous ImageIO-backed converter. Designed to be called from a
/// background queue (the service handles dispatch).
enum ImageConverter {
    /// JPEG quality from the spec (0.9, sRGB).
    private static let jpegQuality: CGFloat = 0.9

    /// HEIC is lossy, exactly like JPEG — even at 1.0 it does not reproduce an
    /// arbitrary source bit-for-bit. Same number as JPEG so that choosing
    /// between the two formats is a choice of format, not a hidden change of
    /// quality tradeoff. Nothing in the UI calls this conversion lossless.
    private static let heicQuality: CGFloat = 0.9

    /// Convert `source` to `target`. Writes next to the source; falls back
    /// to `~/Library/Caches/Magpie/Converted` if the source dir refuses
    /// writes. Atomic: writes to a sibling `<name>.partXXXX.<ext>` and
    /// renames into place on success.
    @discardableResult
    static func convert(
        source: URL,
        target: ConversionTarget,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false }
    ) throws -> URL {
        guard target != .mp4 else {
            preconditionFailure("ImageConverter cannot produce mp4")
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw ConversionError.sourceMissing
        }
        if isCancelled() { throw CancellationError() }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw ConversionError.sourceUnreadable
        }

        let stem = source.deletingPathExtension().lastPathComponent
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(target.fileExtension)
        let finalDestination = try WritableDestinationResolver.resolve(
            preferred: preferred,
            fallbackSubdirectory: "Magpie/Converted",
            fileManager: fileManager
        )
        if isCancelled() { throw CancellationError() }

        // Atomic write: encode to a temp sibling, then rename.
        let tempURL = finalDestination
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(target.fileExtension)

        let properties = makeProperties(for: target)

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, target.imageDestinationUTI, 1, nil
        ) else {
            throw ConversionError.destinationUnwritable
        }
        CGImageDestinationAddImage(dest, cgImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            try? fileManager.removeItem(at: tempURL)
            throw ConversionError.encodingFailed(reason: "image encoder failed")
        }
        if isCancelled() {
            try? fileManager.removeItem(at: tempURL)
            throw CancellationError()
        }

        do {
            try fileManager.moveItem(at: tempURL, to: finalDestination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ConversionError.destinationUnwritable
        }
        return finalDestination
    }

    // MARK: - Internals

    private static func makeProperties(for target: ConversionTarget) -> CFDictionary? {
        switch target {
        case .jpeg:
            let dict: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: jpegQuality
            ]
            return dict as CFDictionary
        case .heic:
            let dict: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: heicQuality
            ]
            return dict as CFDictionary
        case .png, .mp4:
            return nil
        }
    }

}
