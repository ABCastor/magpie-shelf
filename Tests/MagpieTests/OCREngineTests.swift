import XCTest
@testable import Magpie

final class OCREngineTests: XCTestCase {
    private enum SentinelError: Error, Equatable {
        case expected
    }

    func test_firstResult_ignores_later_completion() async throws {
        let lines = try await OCREngine.firstResult { finish in
            finish(.success([]))
            finish(.failure(SentinelError.expected))
        }
        XCTAssertEqual(lines, [])

        do {
            _ = try await OCREngine.firstResult { finish in
                finish(.failure(SentinelError.expected))
                finish(.success([]))
            }
            XCTFail("Expected the first failure")
        } catch {
            XCTAssertEqual(error as? SentinelError, .expected)
        }
    }
}
