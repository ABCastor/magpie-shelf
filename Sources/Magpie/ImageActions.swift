import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageActions {
    @discardableResult
    static func resize(url: URL, maxDimension: CGFloat) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
        let dest = uniqueURL(basedOn: url, suffix: " (resized)")
        return write(image: image, to: dest, type: type, properties: nil)
    }

    @discardableResult
    static func compress(url: URL, quality: Double) -> URL? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent + " (compressed)"
        let candidate = url.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("jpg")
        let dest = uniqueURL(at: candidate)
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        return write(image: image, to: dest,
                     type: UTType.jpeg.identifier as CFString,
                     properties: props)
    }

    /// Strip Exif/GPS/IPTC without touching the picture.
    ///
    /// The two branches are not tidiness. On a lossy source — a photo, which is
    /// exactly what carries GPS — the single re-encode path this used to be
    /// decoded and recompressed the image, so asking to remove metadata quietly
    /// degraded the picture. `CGImageDestinationCopyImageSource` copies the
    /// encoded data through untouched and replaces only the metadata.
    ///
    /// PNG keeps the re-encode deliberately: PNG is lossless, so the pixels come
    /// out identical either way, and ImageIO's encoder writes a smaller file than
    /// `screencapture` does (~8% on a screenshot, macOS 26.5.2). Collapsing the
    /// two branches into one copy path would hand that back.
    @discardableResult
    static func removeMetadata(url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
        let dest = uniqueURL(basedOn: url, suffix: " (no metadata)")

        if isLossyEncoding(type) {
            return copyStrippingMetadata(from: source, to: dest, type: type)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Passing nil properties writes the pixels without carrying EXIF/GPS/IPTC.
        return write(image: image, to: dest, type: type, properties: nil)
    }

    /// True when decoding and re-encoding the source would lose picture data.
    private static func isLossyEncoding(_ type: CFString) -> Bool {
        guard let uti = UTType(type as String) else { return false }
        return uti.conforms(to: .jpeg) || uti.conforms(to: .heic) || uti.conforms(to: .heif)
    }

    /// Replaces all metadata with nothing while copying the encoded image
    /// verbatim. Container support varies, so it can genuinely fail: it fails
    /// CLOSED — nil reaches the existing failure alert and no half-written file
    /// is left sitting beside the user's original (ADR 0001).
    ///
    /// The cleanup on a failed copy is untested defence: on macOS 26.5.2 this
    /// call succeeds even for a truncated JPEG, so no fixture reaches it.
    private static func copyStrippingMetadata(
        from source: CGImageSource,
        to url: URL,
        type: CFString
    ) -> URL? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
        ]
        guard CGImageDestinationCopyImageSource(
            destination, source, options as CFDictionary, nil
        ) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    @discardableResult
    static func createPDF(from urls: [URL]) -> URL? {
        let pdf = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                continue
            }
            pdf.insert(page, at: pdf.pageCount)
        }
        guard pdf.pageCount > 0, let first = urls.first else { return nil }
        let stem = first.deletingPathExtension().lastPathComponent
        let candidate = first.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("pdf")
        let dest = uniqueURL(at: candidate)
        guard pdf.write(to: dest) else { return nil }
        return dest
    }

    // MARK: - Helpers

    private static func write(
        image: CGImage,
        to url: URL,
        type: CFString,
        properties: [CFString: Any]?
    ) -> URL? {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    static func uniqueURL(basedOn url: URL, suffix: String) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent + suffix
        var candidate = url.deletingLastPathComponent().appendingPathComponent(stem)
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        return uniqueURL(at: candidate)
    }

    static func uniqueURL(at url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            var candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem) \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }
}

// MARK: - Prompts

@MainActor
enum ImageActionPrompts {
    static func resizeMaxDimension(defaultValue: Int = 1024) -> CGFloat? {
        let alert = NSAlert()
        alert.messageText = L("Resize Image")
        alert.informativeText = L("alert.resize.body")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(defaultValue)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Resize"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let value = Double(field.stringValue), value > 0 else { return nil }
        return CGFloat(value)
    }

    static func compressionQuality(defaultValue: Double = 0.75) -> Double? {
        let alert = NSAlert()
        alert.messageText = L("Compress Image")
        alert.informativeText = L("alert.compress.body")
        let slider = NSSlider(
            value: defaultValue,
            minValue: 0.1,
            maxValue: 1.0,
            target: nil,
            action: nil
        )
        slider.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = slider
        alert.addButton(withTitle: L("Compress"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return slider.doubleValue
    }
}
