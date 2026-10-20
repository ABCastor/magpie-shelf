import Foundation
import XCTest
@testable import Magpie

/// The inbound `magpie://add` link is reachable from any web page the user
/// visits, so its validator is tested the way an attacker would use it.
final class MagpieURLTests: XCTestCase {
    private var tempDir: URL!
    private var file: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        // Resolved up front: the validator returns symlink-resolved URLs, and
        // /var/folders is itself a symlink into /private.
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("MagpieURLTests-\(UUID().uuidString)")
        folder = tempDir.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = try write("report.pdf")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir).appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        return url
    }

    /// The same encoding the `scripts/magpie` wrapper produces: unreserved
    /// plus `/` stay literal, everything else is percent-encoded.
    private func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func addURL(_ query: String) throws -> URL {
        try XCTUnwrap(URL(string: "magpie://add?\(query)"))
    }

    private func pathQuery(_ paths: [String]) -> String {
        paths.map { "path=\(encode($0))" }.joined(separator: "&")
    }

    private func parsePaths(_ query: String) throws -> [URL] {
        switch MagpieURL.parse(try addURL(query)) {
        case .success(let request):
            return request.paths
        case .failure(let rejection):
            XCTFail("expected success, got \(rejection.logDescription)")
            return []
        }
    }

    private func rejection(_ query: String) throws -> MagpieURL.Rejection {
        switch MagpieURL.parse(try addURL(query)) {
        case .success(let request):
            XCTFail("expected a rejection, got \(request.paths)")
            return .noPaths
        case .failure(let rejection):
            return rejection
        }
    }

    // MARK: - Volume roots

    func test_a_volume_root_is_refused() throws {
        // `magpie://add?path=/` parsed cleanly before this guard: "/" exists,
        // is a directory, and contains no "." or ".." component. Accepting it
        // handed a drive-by link a recursive walk of the whole volume, which
        // the store then replayed on every launch because the item persists.
        XCTAssertEqual(try rejection(pathQuery(["/"])), .unusablePath("/"))
    }

    func test_a_mounted_volume_is_refused_but_an_ordinary_large_directory_is_not() throws {
        // /System/Volumes/Data is the data volume, i.e. a mount point, and is
        // refused for the same reason as "/". /Users is merely a big folder and
        // stays a legitimate thing to put on a shelf — the guard is about
        // volume roots, not about size.
        XCTAssertEqual(
            try rejection(pathQuery(["/System/Volumes/Data"])),
            .unusablePath("/System/Volumes/Data")
        )
        XCTAssertEqual(try parsePaths(pathQuery(["/Users"])), [URL(fileURLWithPath: "/Users")])
    }

    // MARK: - Accepted

    func test_an_absolute_path_to_an_existing_file_is_accepted() throws {
        XCTAssertEqual(try parsePaths(pathQuery([file.path])), [file])
    }

    func test_path_repeats_and_order_is_preserved() throws {
        let second = try write("chart.png")
        let paths = try parsePaths(pathQuery([file.path, folder.path, second.path]))
        XCTAssertEqual(paths, [file, folder, second])
    }

    func test_unknown_query_parameters_are_ignored() throws {
        let query = "source=claude&\(pathQuery([file.path]))&run=rm%20-rf%20~"
        XCTAssertEqual(try parsePaths(query), [file])
    }

    func test_a_shelf_uuid_is_carried_through_and_is_optional() throws {
        let id = UUID()
        let query = "\(pathQuery([file.path]))&shelf=\(id.uuidString)"
        guard case .success(let targeted) = MagpieURL.parse(try addURL(query)) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(targeted.shelfID, id)

        guard case .success(let untargeted) = MagpieURL.parse(
            try addURL(pathQuery([file.path]))
        ) else { return XCTFail("expected success") }
        XCTAssertNil(untargeted.shelfID)
    }

    func test_a_file_url_value_is_the_same_thing_spelled_differently() throws {
        let value = URL(fileURLWithPath: file.path).absoluteString
        XCTAssertEqual(try parsePaths("path=\(encode(value))"), [file])
    }

    // MARK: - Percent-encoding

    func test_spaces_ampersands_hashes_and_percents_survive_a_round_trip() throws {
        let awkward = try write("My Report (draft) & final #2 100%.pdf")
        let query = pathQuery([awkward.path])
        // The delimiters have to be encoded or the query splits in the wrong
        // places; the space has to be encoded or `open` refuses the URL.
        XCTAssertTrue(query.contains("%20"))
        XCTAssertTrue(query.contains("%26"))
        XCTAssertTrue(query.contains("%23"))
        XCTAssertTrue(query.contains("%25"))
        XCTAssertEqual(try parsePaths(query), [awkward])
    }

    /// A query value is not form-encoded, so `+` is a literal plus on both
    /// sides. A filename holding one has to survive either spelling.
    func test_a_plus_in_a_filename_is_never_read_as_a_space() throws {
        let plus = try write("a+b.txt")
        XCTAssertEqual(try parsePaths("path=\(encode(plus.path))"), [plus])
        XCTAssertEqual(try parsePaths("path=\(plus.path)"), [plus])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: plus.path.replacingOccurrences(of: "+", with: " ")
        ))
    }

    func test_a_non_ascii_filename_survives() throws {
        let accented = try write("café.txt")
        XCTAssertEqual(try parsePaths(pathQuery([accented.path])), [accented])
    }

    // MARK: - Rejected

    func test_a_url_with_no_path_parameter_is_refused() throws {
        XCTAssertEqual(try rejection("shelf=\(UUID().uuidString)"), .noPaths)
        guard case .failure(let empty) = MagpieURL.parse(
            try XCTUnwrap(URL(string: "magpie://add"))
        ) else { return XCTFail("expected a rejection") }
        XCTAssertEqual(empty, .noPaths)
    }

    func test_an_empty_path_is_refused() throws {
        XCTAssertEqual(try rejection("path="), .unusablePath(""))
    }

    func test_a_relative_path_is_refused_rather_than_resolved() throws {
        // Magpie's working directory is not the caller's, so a relative path
        // would silently mean something else — usually a file under "/".
        XCTAssertEqual(try rejection("path=report.pdf"), .unusablePath("report.pdf"))
        XCTAssertEqual(try rejection("path=./report.pdf"), .unusablePath("./report.pdf"))
        XCTAssertEqual(try rejection("path=~/report.pdf"), .unusablePath("~/report.pdf"))
    }

    func test_a_dot_dot_path_is_refused_even_when_it_resolves_to_a_real_file() throws {
        let traversal = folder.path + "/../report.pdf"
        XCTAssertTrue(FileManager.default.fileExists(atPath: traversal))
        XCTAssertEqual(try rejection("path=\(encode(traversal))"), .unusablePath(traversal))

        let dot = tempDir.path + "/./report.pdf"
        XCTAssertEqual(try rejection("path=\(encode(dot))"), .unusablePath(dot))
    }

    func test_a_non_file_scheme_is_refused_outright() throws {
        for value in [
            "http://example.com/payload.pdf",
            "https://example.com/payload.pdf",
            "smb://server/share/payload.pdf",
            "javascript:alert(1)",
            "magpie://add?path=/etc/hosts",
        ] {
            XCTAssertEqual(try rejection("path=\(encode(value))"), .unusablePath(value))
        }
    }

    func test_a_path_that_does_not_exist_is_refused() throws {
        let missing = tempDir.appendingPathComponent("gone.pdf").path
        XCTAssertEqual(try rejection("path=\(encode(missing))"), .unusablePath(missing))
    }

    /// A shelf holds files and folders. Reading a fifo or a device to build a
    /// thumbnail is a read that need never end.
    func test_something_that_is_neither_a_file_nor_a_folder_is_refused() throws {
        XCTAssertEqual(try rejection("path=/dev/null"), .unusablePath("/dev/null"))
    }

    func test_a_malformed_shelf_id_refuses_the_whole_url() throws {
        let query = "\(pathQuery([file.path]))&shelf=not-a-uuid"
        XCTAssertEqual(try rejection(query), .unusableShelfID("not-a-uuid"))
        XCTAssertEqual(try rejection("\(pathQuery([file.path]))&shelf="), .unusableShelfID(""))
    }

    func test_one_bad_path_refuses_the_whole_url() throws {
        let query = pathQuery([file.path, "/nope/missing.pdf", folder.path])
        XCTAssertEqual(try rejection(query), .unusablePath("/nope/missing.pdf"))
    }

    // MARK: - The count bound

    func test_the_path_count_is_bounded() throws {
        let atLimit = Array(repeating: file.path, count: MagpieURL.maxPaths)
        XCTAssertEqual(try parsePaths(pathQuery(atLimit)).count, MagpieURL.maxPaths)

        let overLimit = atLimit + [file.path]
        XCTAssertEqual(
            try rejection(pathQuery(overLimit)),
            .tooManyPaths(MagpieURL.maxPaths + 1)
        )
    }

    func test_the_bound_is_counted_before_any_path_is_touched() throws {
        // Ten thousand paths must cost ten thousand nothings, not ten thousand
        // filesystem round-trips.
        let flood = Array(repeating: "/nope/missing.pdf", count: 10_000)
        XCTAssertEqual(try rejection(pathQuery(flood)), .tooManyPaths(10_000))
    }

    // MARK: - Only `add` exists

    func test_only_the_add_host_of_the_magpie_scheme_is_answered() throws {
        // Every future verb is refused today, so none can acquire meaning by
        // accident. A URL scheme may never run anything — see MagpieURL.
        for string in [
            "magpie://run?path=/tmp",
            "magpie://route?path=/tmp",
            "magpie://add/run?path=/tmp",
            "magpie://?path=/tmp",
            "http://add?path=/tmp",
            "file:///tmp",
        ] {
            let url = try XCTUnwrap(URL(string: string))
            guard case .failure(let rejection) = MagpieURL.parse(url) else {
                return XCTFail("\(string) must not be answered")
            }
            XCTAssertEqual(rejection, .notAnAddURL(url.absoluteString))
        }
    }

    func test_the_scheme_and_host_are_case_insensitive() throws {
        let url = try XCTUnwrap(URL(string: "MAGPIE://ADD?\(pathQuery([file.path]))"))
        guard case .success(let request) = MagpieURL.parse(url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(request.paths, [file])
    }

    // MARK: - Symlinks

    func test_a_symlink_is_accepted_and_reported_as_its_target() throws {
        let link = tempDir.appendingPathComponent("shortcut.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        // What addFile would store anyway: prepareForIngest resolves before it
        // decides whether the source is a purgeable-temp path.
        XCTAssertEqual(try parsePaths(pathQuery([link.path])), [file])
    }

    func test_a_symlink_to_nowhere_is_refused() throws {
        let link = tempDir.appendingPathComponent("dangling.pdf")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: tempDir.appendingPathComponent("gone.pdf")
        )
        XCTAssertEqual(try rejection("path=\(encode(link.path))"), .unusablePath(link.path))
    }
}
