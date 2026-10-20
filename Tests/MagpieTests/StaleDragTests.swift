import Foundation
import XCTest
@testable import Magpie

/// Dragging a card whose backing file is unreachable used to be a silent
/// no-op: the drag source filtered the URLs, found nothing left, and returned.
/// The user drags, nothing happens, no explanation — indistinguishable from a
/// broken app. These tests pin the classification that decides when to speak
/// and which of two truths to tell: "this file is gone" vs "this file's
/// volume is not reachable right now".
final class StaleDragTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/tmp/a.txt")
    private let b = URL(fileURLWithPath: "/tmp/b.txt")

    func test_all_reachable_urls_drag_with_no_notice() {
        let result = StaleDrag.partition(urls: [a, b]) { _ in .reachable(isDirectory: false) }
        XCTAssertEqual(result.live, [a, b])
        XCTAssertNil(result.notice, "a working drag must not toast an error that didn't happen")
    }

    func test_partially_stale_drag_proceeds_with_the_live_subset_silently() {
        let result = StaleDrag.partition(urls: [a, b]) {
            $0 == a ? .reachable(isDirectory: false) : .confirmedMissing
        }
        XCTAssertEqual(result.live, [a])
        XCTAssertNil(result.notice, "the live file still moves; a toast over it would read as failure")
    }

    func test_all_missing_reports_missing_with_the_full_count() {
        let result = StaleDrag.partition(urls: [a, b]) { _ in .confirmedMissing }
        XCTAssertTrue(result.live.isEmpty)
        XCTAssertEqual(result.notice, .missing(count: 2))
    }

    func test_any_unavailable_among_all_stale_reports_unavailable() {
        // "Gone" is the stronger claim; an unmounted volume may come back, so
        // a mixed set must not be reported as deleted.
        let result = StaleDrag.partition(urls: [a, b]) {
            $0 == a ? .confirmedMissing : .unavailable
        }
        XCTAssertEqual(result.notice, .unavailable(count: 2))
    }

    func test_empty_input_is_silent() {
        let result = StaleDrag.partition(urls: []) { _ in .confirmedMissing }
        XCTAssertTrue(result.live.isEmpty)
        XCTAssertNil(result.notice, "no drag was attempted, so there is nothing to explain")
    }

    func test_message_key_tracks_case_and_count() {
        XCTAssertEqual(DragNotice.missing(count: 1).messageKey, "toast.drag-missing.one")
        XCTAssertEqual(DragNotice.missing(count: 3).messageKey, "toast.drag-missing.many")
        XCTAssertEqual(DragNotice.unavailable(count: 1).messageKey, "toast.drag-unavailable.one")
        XCTAssertEqual(DragNotice.unavailable(count: 3).messageKey, "toast.drag-unavailable.many")
    }

    // MARK: - Localization

    private static let languages = [
        "Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans",
    ]
    private static let keys = [
        "toast.drag-missing.one",
        "toast.drag-missing.many",
        "toast.drag-unavailable.one",
        "toast.drag-unavailable.many",
    ]

    private var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie/Resources")
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = resources
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language).lproj/Localizable.strings did not parse"
        )
    }

    func test_every_language_defines_the_stale_drag_strings() throws {
        for language in Self.languages {
            let strings = try table(language)
            for key in Self.keys {
                let value = strings[key]
                XCTAssertNotNil(value, "\(language) is missing \(key)")
                XCTAssertNotEqual(value, key, "\(language) left \(key) untranslated")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(key)")
            }
        }
    }

    /// A translation that drops the count leaves a plural toast unable to say
    /// how many files it is talking about.
    func test_every_language_keeps_the_count_in_the_plural_strings() throws {
        for language in Self.languages {
            for key in ["toast.drag-missing.many", "toast.drag-unavailable.many"] {
                let value = try XCTUnwrap(table(language)[key])
                XCTAssertTrue(
                    value.contains("%lld"),
                    "\(language) lost the count placeholder in \(key)"
                )
            }
        }
    }
}
