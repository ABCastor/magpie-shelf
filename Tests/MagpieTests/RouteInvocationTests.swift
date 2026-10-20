import Foundation
import XCTest
@testable import Magpie

/// The argument contract. A route's command receives argv entries, never a
/// shell string, so these tests are what stands between a filename with a
/// space in it and a silently wrong run.
final class RouteInvocationTests: XCTestCase {
    private let awkward = URL(fileURLWithPath: #"/tmp/a folder/we ird "quoted" $name;rm -rf.txt"#)
    private let plain = URL(fileURLWithPath: "/tmp/plain.txt")

    func test_files_token_becomes_one_argument_per_file() {
        let arguments = RouteInvocation.arguments(
            template: ["-R", "{files}", "/dest"],
            files: [plain, awkward],
            outputDirectory: nil
        )
        XCTAssertEqual(arguments, ["-R", plain.path, awkward.path, "/dest"])
    }

    /// The load-bearing one: a path with a space AND a double quote survives
    /// as exactly one argument, unquoted and unescaped, because nothing ever
    /// re-parses it.
    func test_a_path_with_a_space_and_a_quote_stays_one_argument() {
        let arguments = RouteInvocation.arguments(
            template: ["{files}"], files: [awkward], outputDirectory: nil
        )
        XCTAssertEqual(arguments.count, 1)
        XCTAssertEqual(arguments[0], awkward.path)
        XCTAssertTrue(arguments[0].contains(" "))
        XCTAssertTrue(arguments[0].contains("\""))
        XCTAssertFalse(arguments[0].contains("\\"), "nothing escapes the path")
    }

    func test_no_files_token_means_the_command_gets_no_paths() {
        let arguments = RouteInvocation.arguments(
            template: ["--from-env"], files: [plain], outputDirectory: nil
        )
        XCTAssertEqual(arguments, ["--from-env"])
    }

    func test_output_token_substitutes_inside_an_argument() {
        let output = URL(fileURLWithPath: "/tmp/out dir")
        let arguments = RouteInvocation.arguments(
            template: ["--out={output}", "{output}"], files: [], outputDirectory: output
        )
        XCTAssertEqual(arguments, ["--out=/tmp/out dir", "/tmp/out dir"])
    }

    func test_output_token_is_left_alone_when_there_is_no_output_folder() {
        let arguments = RouteInvocation.arguments(
            template: ["{output}"], files: [], outputDirectory: nil
        )
        XCTAssertEqual(arguments, ["{output}"])
    }

    func test_files_keep_their_order() {
        let files = (1...5).map { URL(fileURLWithPath: "/tmp/\($0).txt") }
        let arguments = RouteInvocation.arguments(
            template: ["{files}"], files: files, outputDirectory: nil
        )
        XCTAssertEqual(arguments, files.map(\.path))
    }

    // MARK: - Environment

    func test_environment_carries_secrets_and_the_output_folder() {
        let environment = RouteInvocation.environment(
            base: ["PATH": "/usr/bin"],
            secrets: ["GEMINI_API_KEY": "sk-live-123"],
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            routeID: "transcribe"
        )
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["GEMINI_API_KEY"], "sk-live-123")
        XCTAssertEqual(environment["MAGPIE_OUTPUT_DIR"], "/tmp/out")
        XCTAssertEqual(environment["MAGPIE_ROUTE_ID"], "transcribe")
    }

    func test_no_output_variable_when_the_route_did_not_ask_for_one() {
        let environment = RouteInvocation.environment(
            base: [:], secrets: [:], outputDirectory: nil, routeID: "a"
        )
        XCTAssertNil(environment["MAGPIE_OUTPUT_DIR"])
    }

    // MARK: - What reaches the user

    func test_the_tail_keeps_the_end_and_marks_the_cut() {
        let long = String(repeating: "x", count: 500) + "THE LAST LINE"
        let tail = RouteInvocation.tail(of: long, limit: 20)
        XCTAssertTrue(tail.hasSuffix("THE LAST LINE"))
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertEqual(tail.count, 21)
    }

    func test_short_output_is_trimmed_not_truncated() {
        XCTAssertEqual(RouteInvocation.tail(of: "\n  boom  \n"), "boom")
    }

    func test_a_secret_echoed_by_the_command_is_redacted() {
        let leaked = "curl failed with key sk-live-1234567890 and no retry"
        let safe = RouteInvocation.redact(leaked, secrets: ["sk-live-1234567890"])
        XCTAssertFalse(safe.contains("sk-live-1234567890"))
        XCTAssertTrue(safe.contains("•••"))
    }

    func test_redaction_ignores_values_too_short_to_be_a_secret() {
        // A one-character "secret" would blank out most of any message.
        XCTAssertEqual(RouteInvocation.redact("a b c", secrets: ["a"]), "a b c")
    }
}
