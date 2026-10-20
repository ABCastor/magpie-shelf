import Foundation
import XCTest
@testable import Magpie

/// Any web page can fire `magpie://` in a loop. The bucket is what turns a
/// flood into one refusal instead of hundreds of panels, so its arithmetic is
/// pinned here rather than left to the AppKit call site.
final class InboundLinkRateLimitTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func test_a_burst_up_to_capacity_is_allowed_and_the_rest_refused() {
        var bucket = TokenBucket(capacity: 3, refillPerSecond: 1, now: t0)

        let verdicts = (0..<5).map { _ in bucket.take(now: t0) }

        XCTAssertEqual(verdicts, [true, true, true, false, false])
    }

    func test_refills_at_the_stated_rate() {
        var bucket = TokenBucket(capacity: 2, refillPerSecond: 1, now: t0)
        XCTAssertTrue(bucket.take(now: t0))
        XCTAssertTrue(bucket.take(now: t0))
        XCTAssertFalse(bucket.take(now: t0))

        XCTAssertFalse(bucket.take(now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(bucket.take(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(bucket.take(now: t0.addingTimeInterval(1)))
    }

    func test_a_long_quiet_spell_refills_to_capacity_and_no_further() {
        var bucket = TokenBucket(capacity: 3, refillPerSecond: 1, now: t0)
        XCTAssertTrue(bucket.take(now: t0))
        let later = t0.addingTimeInterval(3_600)

        let verdicts = (0..<4).map { _ in bucket.take(now: later) }

        XCTAssertEqual(verdicts, [true, true, true, false])
    }

    /// A clock that runs backwards (NTP correction, a manual date change) must
    /// not hand out free tokens.
    func test_time_moving_backwards_does_not_refill() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1, now: t0)
        XCTAssertTrue(bucket.take(now: t0))

        XCTAssertFalse(bucket.take(now: t0.addingTimeInterval(-3_600)))
    }

    func test_every_language_defines_the_inbound_link_toasts() throws {
        let languages = ["Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans"]
        let keys = ["toast.link-refused", "toast.link-rate-limited"]
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")

        for language in languages {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            for key in keys {
                let value = table[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
        }
    }
}
