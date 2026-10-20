import Foundation
import XCTest
@testable import Magpie

/// The `scripts/magpie` wrapper, the Info.plist registration and the one
/// user-visible string, all of which live outside the Swift target and would
/// otherwise fail only on a user's machine.
///
/// The wrapper is run for real against a fake `open` on PATH, so the URL under
/// test is the URL a caller would actually fire — and it is then fed back
/// through `MagpieURL.parse`, which is the contract that matters.
final class MagpieCLITests: XCTestCase {
    private var tempDir: URL!
    private var workingDir: URL!
    private var fakeBin: URL!

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/MagpieTests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("MagpieCLITests-\(UUID().uuidString)", isDirectory: true)
        // A space in the working directory: the wrapper quotes every expansion
        // or absolutizing splits the path in half.
        workingDir = tempDir.appendingPathComponent("my drop box", isDirectory: true)
        fakeBin = tempDir.appendingPathComponent("bin", isDirectory: true)
        for dir in [workingDir!, fakeBin!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fakeOpen = fakeBin.appendingPathComponent("open")
        try "#!/bin/sh\nprintf '%s' \"$1\"\n".write(to: fakeOpen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String) throws -> URL {
        let url = workingDir.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        return url
    }

    private struct Run {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Runs `scripts/magpie` from `workingDir` with the fake `open` first on
    /// PATH, so nothing is launched and the URL is captured instead.
    private func magpie(_ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repoRoot.appendingPathComponent("scripts/magpie").path] + arguments
        process.currentDirectoryURL = workingDir
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fakeBin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    // MARK: - The wrapper

    func test_a_relative_path_is_absolutized_before_the_url_is_built() throws {
        // The single most likely bug in the feature: Magpie's working directory
        // is not the shell's, so "./out.pdf" sent raw resolves against "/".
        let file = try write("out.pdf")
        let run = try magpie(["add", "./out.pdf"])

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stdout.hasPrefix("magpie://add?path=/"), run.stdout)
        XCTAssertFalse(run.stdout.contains("/./"), run.stdout)
        XCTAssertFalse(run.stdout.contains(" "), run.stdout)
        // A path that had not been absolutized would name nothing and be
        // refused here; the payload check proves it names the file we wrote.
        let url = try XCTUnwrap(URL(string: run.stdout))
        guard case .success(let request) = MagpieURL.parse(url) else {
            return XCTFail("the app refused \(run.stdout)")
        }
        XCTAssertEqual(request.paths, [file.resolvingSymlinksInPath()])
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(request.paths.first)), Data("payload".utf8)
        )
    }

    func test_the_url_it_produces_is_a_url_the_app_accepts() throws {
        let awkward = try write("My Report (draft) & final.pdf")
        let percent = try write("100% + café #1.txt")
        let run = try magpie(["add", "./My Report (draft) & final.pdf", "100% + café #1.txt"])

        XCTAssertEqual(run.status, 0, run.stderr)
        let url = try XCTUnwrap(URL(string: run.stdout), "produced an unparseable URL")
        guard case .success(let request) = MagpieURL.parse(url) else {
            return XCTFail("the app refused its own wrapper's URL: \(run.stdout)")
        }
        XCTAssertEqual(request.paths, [awkward, percent])
        XCTAssertNil(request.shelfID)
    }

    func test_a_folder_and_a_parent_reference_come_out_canonical() throws {
        let sub = workingDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let run = try magpie(["add", "./sub", ".."])

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertFalse(run.stdout.contains(".."), run.stdout)
        let url = try XCTUnwrap(URL(string: run.stdout))
        guard case .success(let request) = MagpieURL.parse(url) else {
            return XCTFail("the app refused \(run.stdout)")
        }
        XCTAssertEqual(request.paths, [sub, tempDir])
    }

    func test_a_missing_file_fails_before_anything_is_opened() throws {
        let run = try magpie(["add", "nope.pdf"])
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(run.stdout, "")
        XCTAssertTrue(run.stderr.contains("no such file"), run.stderr)
    }

    func test_more_paths_than_the_app_accepts_fail_in_the_wrapper() throws {
        try write("one.pdf")
        let run = try magpie(["add"] + Array(repeating: "one.pdf", count: MagpieURL.maxPaths + 1))
        XCTAssertEqual(run.status, 1)
        XCTAssertEqual(run.stdout, "")
        XCTAssertTrue(run.stderr.contains("\(MagpieURL.maxPaths)"), run.stderr)
    }

    func test_no_subcommand_and_no_unknown_subcommand_do_anything() throws {
        for arguments in [[], ["list"], ["add"], ["route", "/tmp"]] {
            let run = try magpie(arguments)
            XCTAssertEqual(run.status, 2, "\(arguments)")
            XCTAssertEqual(run.stdout, "", "\(arguments)")
            XCTAssertTrue(run.stderr.contains("usage:"), "\(arguments)")
        }
    }

    // MARK: - Registration

    /// The handler is dead code unless the generated Info.plist claims the
    /// scheme. The plist is a heredoc in scripts/release-lib.sh, written by
    /// `write_info_plist`, which both packaging scripts must actually call.
    func test_the_packaging_script_registers_the_scheme_and_nothing_else() throws {
        let lib = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/release-lib.sh"), encoding: .utf8
        )
        XCTAssertTrue(lib.contains("<key>CFBundleURLTypes</key>"))
        XCTAssertTrue(lib.contains("<string>\(MagpieURL.scheme)</string>"))
        // Declaring document types would put Magpie in the Open With menu of
        // every file on the system — deliberately not done.
        XCTAssertFalse(lib.contains("<key>CFBundleDocumentTypes</key>"))
        for name in ["build-dmg.sh", "install-local.sh"] {
            let script = try String(
                contentsOf: repoRoot.appendingPathComponent("scripts/\(name)"), encoding: .utf8
            )
            // An actual call at the start of a line — a commented-out call
            // must not satisfy this.
            XCTAssertNotNil(
                script.range(of: #"(?m)^\s*write_info_plist ""#, options: .regularExpression),
                "\(name) never writes the Info.plist, so its bundle would register no URL scheme"
            )
        }
    }

    func test_every_language_defines_the_refused_link_toast() throws {
        let resources = repoRoot.appendingPathComponent("Sources/Magpie/Resources")
        for language in ["Base", "en", "de", "es", "fr", "it", "ja", "pl", "zh-Hans"] {
            let url = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let table = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language).lproj/Localizable.strings did not parse"
            )
            let value = table["toast.link-refused"]
            XCTAssertNotNil(value, "\(language) is missing toast.link-refused")
            XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty toast.link-refused")
        }
    }
}
