import XCTest
@testable import Magpie

final class UniqueDestinationTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniqueDestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_returns_input_when_no_collision() {
        let candidate = tempDir.appendingPathComponent("foo.jpg")
        XCTAssertEqual(
            UniqueDestination.url(preferred: candidate),
            candidate
        )
    }

    func test_appends_1_when_first_taken() throws {
        let taken = tempDir.appendingPathComponent("foo.jpg")
        try Data().write(to: taken)
        XCTAssertEqual(
            UniqueDestination.url(preferred: taken),
            tempDir.appendingPathComponent("foo (1).jpg")
        )
    }

    func test_increments_until_free() throws {
        for suffix in ["foo.jpg", "foo (1).jpg", "foo (2).jpg"] {
            try Data().write(to: tempDir.appendingPathComponent(suffix))
        }
        let preferred = tempDir.appendingPathComponent("foo.jpg")
        XCTAssertEqual(
            UniqueDestination.url(preferred: preferred),
            tempDir.appendingPathComponent("foo (3).jpg")
        )
    }

    func test_handles_files_with_no_extension() throws {
        let taken = tempDir.appendingPathComponent("README")
        try Data().write(to: taken)
        XCTAssertEqual(
            UniqueDestination.url(preferred: taken),
            tempDir.appendingPathComponent("README (1)")
        )
    }

    func test_property_n_same_stem_results_are_distinct_and_never_preexisting() throws {
        for preexistingCount in [0, 1, 2, 7, 20] {
            let dir = tempDir.appendingPathComponent("case-\(preexistingCount)")
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            let preferred = dir.appendingPathComponent("same-stem.dat")
            for index in 0..<preexistingCount {
                let url = index == 0
                    ? preferred
                    : dir.appendingPathComponent("same-stem (\(index)).dat")
                try Data().write(to: url)
            }
            let preexisting = Set(try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).map(\.standardizedFileURL))
            var results: [URL] = []

            for _ in 0..<32 {
                let result = UniqueDestination.url(preferred: preferred).standardizedFileURL
                XCTAssertFalse(preexisting.contains(result))
                results.append(result)
                try Data().write(to: result)
            }

            XCTAssertEqual(Set(results).count, results.count)
        }
    }
}
