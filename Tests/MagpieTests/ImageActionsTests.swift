import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Magpie

/// `Remove Metadata` used to decode and re-encode whatever it was given. On a
/// PNG that is harmless (PNG is lossless). On a photo — the only kind of file
/// that carries the GPS coordinates this action exists to remove — it quietly
/// recompressed the picture every time it ran.
final class ImageActionsTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageActionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Deliberately noisy. A flat colour survives a re-encode looking identical,
    /// which would make the pixel-preservation assertion below pass while the
    /// bug it guards was back.
    private func makeNoisyCGImage(size: Int = 64) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "ImageActionsTests", code: -1) }
        var generator = SystemRandomNumberGenerator()
        for x in 0..<size {
            for y in 0..<size {
                ctx.setFillColor(
                    red: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                    green: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                    blue: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                    alpha: 1
                )
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "ImageActionsTests", code: -2)
        }
        return image
    }

    /// A JPEG carrying the metadata a real photo carries: GPS coordinates and an
    /// Exif capture date.
    private func makeJPEGWithLocation(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).jpg")
        let image = try makeNoisyCGImage()
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 52.2053,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1218,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:28 09:41:00",
                kCGImagePropertyExifUserComment: "taken at home",
            ] as [CFString: Any],
        ]
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makePNGWithMetadata(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).png")
        let image = try makeNoisyCGImage()
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "captured on this machine",
            ] as [CFString: Any],
        ]
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }

    /// Decoded pixels, so two files can be compared regardless of how they are
    /// encoded.
    private func pixels(of url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpaceCreateDeviceRGB()
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Data(bytes)
    }

    // MARK: - The data-loss fix

    /// THE regression. The whole point of the lossy branch: the picture must
    /// come out of "Remove Metadata" bit-for-bit unchanged. A re-encode fails
    /// this even at high quality, which is how the bug reads on screen — nothing
    /// visibly wrong, just a slightly worse photo every time.
    func test_removing_metadata_from_a_jpeg_does_not_touch_a_single_pixel() throws {
        let source = try makeJPEGWithLocation(named: "photo")
        let before = try pixels(of: source)

        let result = try XCTUnwrap(ImageActions.removeMetadata(url: source))

        XCTAssertEqual(
            try pixels(of: result), before,
            "the photo was re-encoded — Remove Metadata degraded the picture it was asked to keep"
        )
    }

    /// And it has to actually remove the metadata, or the pixel-preservation
    /// above is satisfied by doing nothing at all.
    func test_removing_metadata_from_a_jpeg_drops_gps_and_exif() throws {
        let source = try makeJPEGWithLocation(named: "photo")
        // The precondition this test rests on.
        let originalProperties = try properties(of: source)
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(originalProperties[kCGImagePropertyExifDictionary])

        let result = try XCTUnwrap(ImageActions.removeMetadata(url: source))
        let stripped = try properties(of: result)

        XCTAssertNil(
            stripped[kCGImagePropertyGPSDictionary],
            "the GPS coordinates survived — this action's entire job"
        )
        let exif = stripped[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal], "the capture date survived")
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment], "the user comment survived")
    }

    func test_the_original_is_left_untouched() throws {
        let source = try makeJPEGWithLocation(named: "photo")
        let originalBytes = try Data(contentsOf: source)

        let result = try XCTUnwrap(ImageActions.removeMetadata(url: source))

        XCTAssertNotEqual(result, source, "the output overwrote the input (ADR 0001)")
        XCTAssertEqual(
            try Data(contentsOf: source), originalBytes,
            "the source file changed — no code path may modify a user file in place"
        )
    }

    /// The lossless side of the branch has the same three guarantees.
    func test_png_output_stays_png_pixel_identical_and_metadata_free() throws {
        let source = try makePNGWithMetadata(named: "shot")
        let before = try pixels(of: source)
        XCTAssertNotNil(
            try properties(of: source)[kCGImagePropertyExifDictionary],
            "fixture carries no metadata, so the assertion below would prove nothing"
        )

        let result = try XCTUnwrap(ImageActions.removeMetadata(url: source))

        XCTAssertEqual(result.pathExtension, "png")
        XCTAssertEqual(try pixels(of: result), before)
        let type = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(type) as String?, UTType.png.identifier)
        let exif = try properties(of: result)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
    }

    /// The two branches are indistinguishable from their output on a PNG — both
    /// are lossless, so no assertion over the resulting file can tell them
    /// apart. What the branch buys is real but unmeasurable here: PNG keeps the
    /// re-encode because ImageIO writes a smaller file than `screencapture`
    /// does. Collapsing this into a single copy path is a silent regression no
    /// behavioural test in this file would catch, so it is pinned structurally.
    func test_the_lossy_lossless_branch_still_exists() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Magpie/ImageActions.swift"),
            encoding: .utf8
        )
        let body = source
            .components(separatedBy: "static func removeMetadata(url: URL) -> URL? {")
            .dropFirst().first?
            .components(separatedBy: "\n    }").first ?? ""
        XCTAssertFalse(body.isEmpty, "could not find removeMetadata")
        XCTAssertTrue(
            body.contains("if isLossyEncoding(type) {"),
            "removeMetadata no longer branches on the source encoding — a photo is being re-encoded again"
        )
        XCTAssertTrue(
            body.contains("copyStrippingMetadata(from: source"),
            "the lossy branch no longer copies the encoded image through"
        )
        XCTAssertTrue(
            body.contains("return write(image: image, to: dest, type: type, properties: nil)"),
            "the lossless branch lost its re-encode, and with it the PNG size win"
        )
    }

    /// Fails closed on the lossless branch: a file ImageIO cannot decode returns
    /// nil — which reaches the existing failure alert — and leaves no stub next
    /// to the original. (ImageIO types this file as nothing, so it lands here
    /// rather than in the copy path.)
    func test_undecodable_source_returns_nil_and_leaves_no_file_behind() throws {
        let bogus = tempDir.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: bogus)

        XCTAssertNil(ImageActions.removeMetadata(url: bogus))

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains("no metadata") }
        XCTAssertEqual(leftovers, [], "a half-written file was left beside the original")
    }
}
