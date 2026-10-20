import Foundation
import XCTest
@testable import Magpie

/// One frozen end-to-end string. Every other test checks a property; this one
/// pins the whole grammar at once, so an accidental change to the scheme, the
/// path, the parameter set or the encoding shows up as a diff a human reads
/// rather than as a link that opens an empty session.
final class ClaudeLinkGoldenTests: XCTestCase {
    private static let dropFolder = URL(
        fileURLWithPath:
            "/Users/someone/Library/Application Support/Magpie/Handoff/20260727-224500-a1b2c3"
    )
    private static let names = [
        "Barclays Statement 2026-06.pdf",
        "Screenshot 2026-07-27 at 21.43.08.png",
        "invoice+scan LMN-4821.pdf",
    ]

    // Deliberately one unbroken line: it is a literal to be compared, not read.
    private static let expected = "claude://code/new?q=Use%20my%20shelf%20skill%20to%20file%20this%20Magpie%20drop:%20/Users/someone/Library/Application%20Support/Magpie/Handoff/20260727-224500-a1b2c3%0A3%20items:%20Barclays%20Statement%202026-06.pdf,%20Screenshot%202026-07-27%20at%2021.43.08.png,%20invoice%2Bscan%20LMN-4821.pdf.%0ARead%20SHELF.md%20in%20that%20folder%20first%20%E2%80%94%20it%20lists%20every%20item,%20where%20it%20came%20from,%20and%20the%20rules%20for%20handling%20copies.%0AIf%20I%20have%20no%20shelf%20skill,%20just%20read%20SHELF.md%20and%20follow%20it.&folder=/Users/someone"

    func test_three_item_shelf_produces_this_exact_url() throws {
        let prompt = HandoffPrompt.prompt(
            folder: Self.dropFolder, names: Self.names, totalItems: 3
        )
        let url = try XCTUnwrap(ClaudeLink.url(
            prompt: prompt, folder: URL(fileURLWithPath: "/Users/someone")
        ))
        XCTAssertEqual(url.absoluteString, Self.expected)
    }
}
