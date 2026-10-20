import Foundation
import XCTest

/// A Magpie build once crashed at launch on every Mac whose `.build` folder did not
/// hold the exact path it was compiled at. SwiftPM's `Bundle.module` accessor
/// traps when its resource bundle is missing, and the packaging scripts never
/// copy that bundle: they copy the `.lproj` folders into `Contents/Resources`.
/// So `Bundle.module` may be reached from exactly one place, the fallback in
/// `LanguagePreference.resourceBundle`, which a packaged app never takes.
final class ResourceBundleTests: XCTestCase {
    func test_only_the_resource_bundle_fallback_touches_Bundle_module() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("Bundle.module") || code.contains("bundle: .module") {
                    hits.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(
            hits.count, 1,
            "Bundle.module traps in a packaged app. Route lookups through "
            + "LanguagePreference.resourceBundle instead. Found: \(hits)"
        )
        XCTAssertTrue(hits.first?.hasPrefix("Localization.swift") ?? false, "\(hits)")
    }
}
