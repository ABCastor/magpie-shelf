import Foundation
import XCTest
@testable import Magpie

/// The owner edits `routes.json` by hand, so every failure has to name the
/// route and the field. These pin the grammar and the wording contract.
final class RouteFileTests: XCTestCase {
    private func parse(_ json: String) -> Result<[Route], RouteParseError> {
        RouteFile.parse(Data(json.utf8))
    }

    // MARK: - The file we ship

    func test_default_file_parses_and_ships_only_switched_off_examples() throws {
        let routes = try parse(RouteFile.defaultContents).get()
        XCTAssertEqual(routes.count, 2)
        XCTAssertTrue(routes.allSatisfy { !$0.isEnabled },
                      "shipped examples must stay out of the menus until edited")
        XCTAssertEqual(routes.map(\.id), ["example-copy-to-folder", "example-run-a-script"])
        XCTAssertTrue(routes.allSatisfy { $0.command.hasPrefix("/") })
        // The second example teaches the output folder and a secret.
        XCTAssertTrue(routes[1].collectsOutput)
        XCTAssertEqual(routes[1].secrets, ["GEMINI_API_KEY"])
        XCTAssertEqual(routes[1].timeout, 900)
    }

    // MARK: - Accepting

    func test_minimal_route_gets_the_documented_defaults() throws {
        let routes = try parse("""
        { "version": 1, "routes": [
            { "id": "a", "name": "A", "command": "/bin/echo" }
        ] }
        """).get()
        let route = try XCTUnwrap(routes.first)
        XCTAssertTrue(route.isEnabled)
        XCTAssertNil(route.match)
        XCTAssertNil(route.workingDirectory)
        XCTAssertEqual(route.arguments, [])
        XCTAssertEqual(route.secrets, [])
        XCTAssertEqual(route.timeout, RouteFile.defaultTimeout)
        XCTAssertFalse(route.collectsOutput)
    }

    func test_unknown_fields_are_ignored() throws {
        let routes = try parse("""
        {
          "version": 1,
          "_readme": ["anything at all", 3, {"nested": true}],
          "routes": [
            { "id": "a", "name": "A", "command": "/bin/echo",
              "note": "a comment to myself", "futureField": [1, 2] }
          ]
        }
        """).get()
        XCTAssertEqual(routes.count, 1)
    }

    func test_a_missing_version_is_accepted() throws {
        let routes = try parse("""
        { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo" } ] }
        """).get()
        XCTAssertEqual(routes.count, 1)
    }

    func test_output_token_implies_collect_output() throws {
        let routes = try parse("""
        { "routes": [
            { "id": "a", "name": "A", "command": "/bin/echo",
              "arguments": ["--out={output}"] }
        ] }
        """).get()
        XCTAssertTrue(routes[0].collectsOutput)
    }

    func test_timeout_is_clamped_to_the_documented_range() throws {
        let routes = try parse("""
        { "routes": [
            { "id": "a", "name": "A", "command": "/bin/echo", "timeoutSeconds": 0 },
            { "id": "b", "name": "B", "command": "/bin/echo", "timeoutSeconds": 99999 }
        ] }
        """).get()
        XCTAssertEqual(routes[0].timeout, RouteFile.minimumTimeout)
        XCTAssertEqual(routes[1].timeout, RouteFile.maximumTimeout)
    }

    func test_match_extensions_are_normalised() throws {
        let routes = try parse("""
        { "routes": [
            { "id": "a", "name": "A", "command": "/bin/echo",
              "match": { "extensions": [".PDF", "M4A"], "utis": ["public.image"] } }
        ] }
        """).get()
        XCTAssertEqual(routes[0].match?.extensions, ["pdf", "m4a"])
        XCTAssertEqual(routes[0].match?.utis, ["public.image"])
    }

    func test_disabled_routes_still_parse() throws {
        let routes = try parse("""
        { "routes": [
            { "id": "a", "name": "A", "command": "/bin/echo", "enabled": false }
        ] }
        """).get()
        XCTAssertEqual(routes.count, 1)
        XCTAssertFalse(routes[0].isEnabled)
    }

    // MARK: - Refusing

    func test_malformed_json_is_reported_as_invalid_json() {
        // A missing comma between two fields, and an unclosed bracket: the two
        // hand-edit mistakes the message names.
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a" "name": "A", "command": "/bin/echo" } ] }
            """).failure,
            .invalidJSON
        )
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo" }
            """).failure,
            .invalidJSON
        )
    }

    func test_a_trailing_comma_is_tolerated_because_foundation_tolerates_it() throws {
        // Verified against JSONSerialization on this OS: it accepts them. The
        // error text must not send the owner hunting for one.
        let routes = try parse("""
        { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo", }, ] }
        """).get()
        XCTAssertEqual(routes.count, 1)
    }

    func test_not_an_object_is_reported_as_shape() {
        XCTAssertEqual(parse("[]").failure, .badShape)
        XCTAssertEqual(parse("{ \"version\": 1 }").failure, .badShape)
        XCTAssertEqual(parse("{ \"routes\": \"nope\" }").failure, .badShape)
    }

    func test_a_newer_version_is_refused_by_number() {
        XCTAssertEqual(
            parse("{ \"version\": 2, \"routes\": [] }").failure,
            .unsupportedVersion(found: 2, expected: 1)
        )
    }

    func test_missing_fields_name_the_route_and_the_field() {
        XCTAssertEqual(
            parse("{ \"routes\": [ { \"name\": \"A\", \"command\": \"/bin/echo\" } ] }").failure,
            .badField(route: "A", field: "id")
        )
        XCTAssertEqual(
            parse("{ \"routes\": [ { \"id\": \"a\", \"command\": \"/bin/echo\" } ] }").failure,
            .badField(route: "a", field: "name")
        )
        XCTAssertEqual(
            parse("{ \"routes\": [ { \"id\": \"a\", \"name\": \"A\" } ] }").failure,
            .badField(route: "a", field: "command")
        )
        // With nothing usable to name it by, the position is the label.
        XCTAssertEqual(
            parse("{ \"routes\": [ {}, {} ] }").failure,
            .badField(route: "#1", field: "id")
        )
    }

    func test_wrong_types_are_reported_per_field() {
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo",
              "arguments": [1, 2] } ] }
            """).failure,
            .badField(route: "a", field: "arguments")
        )
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo",
              "enabled": "yes" } ] }
            """).failure,
            .badField(route: "a", field: "enabled")
        )
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo",
              "match": ["pdf"] } ] }
            """).failure,
            .badField(route: "a", field: "match")
        )
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo",
              "workingDirectory": "relative/dir" } ] }
            """).failure,
            .badField(route: "a", field: "workingDirectory")
        )
    }

    func test_a_relative_command_is_refused_because_there_is_no_path_lookup() {
        XCTAssertEqual(
            parse("{ \"routes\": [ { \"id\": \"a\", \"name\": \"A\", \"command\": \"sips\" } ] }").failure,
            .relativeCommand(route: "a", command: "sips")
        )
    }

    func test_duplicate_ids_are_refused() {
        XCTAssertEqual(
            parse("""
            { "routes": [
                { "id": "a", "name": "A", "command": "/bin/echo" },
                { "id": "a", "name": "B", "command": "/bin/echo" }
            ] }
            """).failure,
            .duplicateID("a")
        )
    }

    func test_files_token_inside_a_longer_argument_is_refused() {
        XCTAssertEqual(
            parse("""
            { "routes": [ { "id": "a", "name": "A", "command": "/bin/echo",
              "arguments": ["--input={files}"] } ] }
            """).failure,
            .embeddedFilesToken(route: "a")
        )
    }

    func test_every_parse_error_has_a_sentence_and_no_decoder_dump() {
        let errors: [RouteParseError] = [
            .unreadable, .invalidJSON, .badShape,
            .unsupportedVersion(found: 2, expected: 1),
            .badField(route: "a", field: "id"),
            .relativeCommand(route: "a", command: "sips"),
            .duplicateID("a"),
            .embeddedFilesToken(route: "a"),
        ]
        for error in errors {
            let message = error.displayMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("%"), "unsubstituted format in: \(message)")
            XCTAssertFalse(message.contains("Swift."), "decoder dump leaked: \(message)")
        }
    }
}

private extension Result where Failure == RouteParseError {
    var failure: RouteParseError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
