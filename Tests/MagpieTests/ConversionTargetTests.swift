import XCTest
import UniformTypeIdentifiers
@testable import Magpie

final class ConversionTargetTests: XCTestCase {
    func test_heic_offers_jpeg_and_png() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.heic),
            [.jpeg, .png]
        )
    }

    func test_png_offers_jpeg_and_heic() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.png),
            [.jpeg, .heic]
        )
    }

    func test_jpeg_offers_png_and_heic() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.jpeg),
            [.png, .heic]
        )
    }

    func test_tiff_offers_jpeg_png_and_heic() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.tiff),
            [.jpeg, .png, .heic]
        )
    }

    func test_webp_offers_jpeg_png_and_heic() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.webP),
            [.jpeg, .png, .heic]
        )
    }

    /// A HEIC source is never offered HEIC: re-encoding a lossy format into
    /// itself only costs quality. Asserted as an exact array, not membership —
    /// a `Set`-shaped assertion would pass whatever else crept into the row.
    func test_heic_is_never_offered_for_a_heic_source() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.heic),
            [.jpeg, .png]
        )
        XCTAssertFalse(
            ConversionTarget.supportedImageTargets(for: UTType.heic).contains(.heic)
        )
    }

    func test_unknown_uti_offers_nothing() {
        XCTAssertEqual(
            ConversionTarget.supportedImageTargets(for: UTType.plainText),
            []
        )
    }

    func test_video_uti_offers_mp4_via_video_helper() {
        XCTAssertTrue(ConversionTarget.isVideoSourceUTI(UTType.quickTimeMovie))
        XCTAssertTrue(ConversionTarget.isVideoSourceUTI(UTType.mpeg4Movie))
        XCTAssertFalse(ConversionTarget.isVideoSourceUTI(UTType.png))
    }

    func test_intersection_of_targets_across_selection() {
        // 3 HEICs + 1 PNG → only JPEG is in everyone's target list.
        let utis: [UTType] = [.heic, .heic, .heic, .png]
        XCTAssertEqual(
            ConversionTarget.commonImageTargets(forSourceUTIs: utis),
            [.jpeg]
        )
    }

    /// PNG offers JPEG+HEIC; JPEG offers PNG+HEIC. HEIC is the one thing both
    /// can become, so a mixed PNG/JPEG selection now has exactly one target.
    func test_intersection_of_png_and_jpeg_is_heic_alone() {
        XCTAssertEqual(
            ConversionTarget.commonImageTargets(forSourceUTIs: [.png, .jpeg]),
            [.heic]
        )
    }

    /// The empty case still has to exist, or nothing pins the menu's decision
    /// to show no "Convert to ▶" at all.
    func test_intersection_empty_when_a_source_converts_to_nothing() {
        XCTAssertEqual(
            ConversionTarget.commonImageTargets(forSourceUTIs: [.png, .plainText]),
            []
        )
    }

    func test_displayName() {
        XCTAssertEqual(ConversionTarget.jpeg.displayName, "JPEG")
        XCTAssertEqual(ConversionTarget.png.displayName, "PNG")
        XCTAssertEqual(ConversionTarget.heic.displayName, "HEIC")
        XCTAssertEqual(ConversionTarget.mp4.displayName, "MP4")
    }

    func test_fileExtension() {
        XCTAssertEqual(ConversionTarget.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ConversionTarget.png.fileExtension, "png")
        XCTAssertEqual(ConversionTarget.heic.fileExtension, "heic")
        XCTAssertEqual(ConversionTarget.mp4.fileExtension, "mp4")
    }

    /// Menu order comes from `allCases`, so the case list is UI, not just a
    /// type. Pinned whole: a case appended in the wrong place silently reorders
    /// every "Convert to ▶" submenu.
    func test_case_order_is_the_menu_order() {
        XCTAssertEqual(ConversionTarget.allCases, [.jpeg, .png, .heic, .mp4])
    }

    func test_heic_destination_uti_is_public_heic() {
        XCTAssertEqual(
            ConversionTarget.heic.imageDestinationUTI as String,
            UTType.heic.identifier
        )
    }
}
