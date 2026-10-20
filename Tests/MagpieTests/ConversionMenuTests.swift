import Foundation
import XCTest
@testable import Magpie

final class ConversionMenuTests: XCTestCase {
    @MainActor
    func test_readability_cache_rechecks_after_source_modification() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversionMenuTests-\(UUID().uuidString).mov")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: url.path
        )
        var evaluations = 0
        let evaluate: (URL) -> Bool = { _ in
            evaluations += 1
            return evaluations == 2
        }

        XCTAssertFalse(AVAssetReadabilityCache.isReadable(url, evaluate: evaluate))
        XCTAssertFalse(AVAssetReadabilityCache.isReadable(url, evaluate: evaluate))
        XCTAssertEqual(evaluations, 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: url.path
        )

        XCTAssertTrue(AVAssetReadabilityCache.isReadable(url, evaluate: evaluate))
        XCTAssertEqual(evaluations, 2)
    }
}
