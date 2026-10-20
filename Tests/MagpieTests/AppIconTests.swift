import AppKit
import XCTest

/// The app icon is the approved drawing in both appearances, and the bundle
/// is told where to find it.
final class AppIconTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testBothMastersExistAndDiffer() throws {
        let light = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Icon/AppIcon-light.png")))
        let dark = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Icon/AppIcon-dark.png")))
        let l = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(light.tiffRepresentation)))
        let d = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(dark.tiffRepresentation)))
        XCTAssertEqual(l.pixelsWide, 1024)
        // The background, bottom right of the tile: peach in light, navy in dark.
        let lc = try XCTUnwrap(l.colorAt(x: 800, y: 860)?.usingColorSpace(.deviceRGB))
        let dc = try XCTUnwrap(d.colorAt(x: 800, y: 860)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(lc.redComponent, 0.8, "the light icon's ground is not the approved peach")
        XCTAssertLessThan(dc.redComponent, 0.3, "the dark icon's ground is not the approved deep navy")
        // The canvas margin is transparent: the tile sits on the macOS icon grid.
        XCTAssertLessThan(l.colorAt(x: 20, y: 512)?.alphaComponent ?? 1, 0.05, "the icon fills its canvas edge to edge")
    }

    func testTheBundleNamesTheAssetCatalogIcon() throws {
        let lib = try String(contentsOf: root.appendingPathComponent("scripts/release-lib.sh"), encoding: .utf8)
        XCTAssertTrue(lib.contains("<key>CFBundleIconName</key><string>AppIcon</string>"),
                      "without CFBundleIconName the system never reads the dark icon in Assets.car")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Magpie/Resources/Assets.car").path))
    }
}
