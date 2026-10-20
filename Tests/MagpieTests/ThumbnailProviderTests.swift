import AppKit
import XCTest
@testable import Magpie

/// A card is only ever released from its placeholder by the thumbnail
/// completion. The QuickLook failure path used to `return` without calling it,
/// which made a single failed thumbnail permanent: no retry, no icon, a card
/// that looks broken forever.
///
/// The failure is driven through the injectable generator, not through a file
/// QuickLook dislikes: the real generator icons anything — including files
/// that do not exist — so no fixture can force `nil` reliably.
final class ThumbnailProviderTests: XCTestCase {

    /// Each test gets its own never-before-seen URL so the shared cache from
    /// other tests (and other runs in the same process) cannot answer for it.
    private func freshURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailProviderTests-\(UUID().uuidString).png")
    }

    @MainActor
    func test_a_failed_generation_still_calls_completion_with_an_icon() {
        let delivered = expectation(
            description: "completion must fire even when QuickLook produces nothing"
        )
        ThumbnailProvider.generateThumbnail(
            for: freshURL(),
            generator: { _, handler in handler(nil) }
        ) { image, isIcon in
            XCTAssertTrue(
                isIcon,
                "a failed generation must be reported as an icon, not passed off as a preview"
            )
            XCTAssertGreaterThan(
                image.size.width, 0,
                "the fallback must be a drawable image, not an empty placeholder"
            )
            delivered.fulfill()
        }

        wait(for: [delivered], timeout: 5)
    }

    /// The fallback icon must not be cached: caching it would pin one
    /// transient QuickLook failure to the file for the rest of the session,
    /// and the preview would never appear even once the file became readable.
    @MainActor
    func test_a_failure_is_not_cached_so_the_next_request_retries() {
        let url = freshURL()

        let first = expectation(description: "failing request resolves")
        ThumbnailProvider.generateThumbnail(
            for: url,
            generator: { _, handler in handler(nil) }
        ) { _, _ in first.fulfill() }
        wait(for: [first], timeout: 5)

        // If the failure had been cached, this generator would never run and
        // the card would stay an icon forever; a cache miss must retry it.
        var generatorRanAgain = false
        let second = expectation(description: "second request resolves")
        ThumbnailProvider.generateThumbnail(
            for: url,
            generator: { _, handler in
                generatorRanAgain = true
                handler((image: NSImage(size: NSSize(width: 8, height: 8)), isIcon: false))
            }
        ) { _, isIcon in
            XCTAssertFalse(isIcon, "the retried generation's real preview must win")
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
        XCTAssertTrue(
            generatorRanAgain,
            "the earlier failure was cached, so the file can never recover its preview"
        )
    }

    /// A successful generation IS cached — that is the cache earning its keep,
    /// and the counterpart that proves the no-cache rule above is specific to
    /// failures rather than the cache being broken off entirely.
    @MainActor
    func test_a_success_is_cached_and_served_without_regenerating() {
        let url = freshURL()

        let first = expectation(description: "first request resolves")
        ThumbnailProvider.generateThumbnail(
            for: url,
            generator: { _, handler in
                handler((image: NSImage(size: NSSize(width: 8, height: 8)), isIcon: false))
            }
        ) { _, _ in first.fulfill() }
        wait(for: [first], timeout: 5)

        var generatorRanAgain = false
        let second = expectation(description: "second request resolves from cache")
        ThumbnailProvider.generateThumbnail(
            for: url,
            generator: { _, handler in
                generatorRanAgain = true
                handler(nil)
            }
        ) { _, isIcon in
            XCTAssertFalse(isIcon, "the cached preview must be served back")
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
        XCTAssertFalse(generatorRanAgain, "a cached success must not regenerate")
    }
}
