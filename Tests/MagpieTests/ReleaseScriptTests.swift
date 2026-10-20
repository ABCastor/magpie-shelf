import Foundation
import XCTest

/// The release scripts live outside the Swift target, so nothing else pins
/// them. Two invariants, each bought by a real defect:
///
/// - The version once had two homes: `build-dmg.sh` and `install-local.sh`
///   each carried their own `VERSION="…"` literal, and both sat at the exact
///   version the published appcast already claimed — a fresh install would
///   never have been offered an update. The version now lives only in
///   `scripts/release-lib.sh`.
/// - Sparkle.framework ships inside the bundle under Sparkle's MIT licence,
///   whose notice condition applies to binary redistribution. For a while the
///   bundle carried no licence text at all. Both scripts must run the shared
///   copy step, which refuses to build when the source licence is missing.
final class ReleaseScriptTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/MagpieTests/<this>.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func script(_ name: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/\(name)"),
            encoding: .utf8
        )
    }

    /// A machine carrying a Developer ID identity is a machine meant to cut
    /// public releases. If notarization cannot run there, the build must stop.
    /// `notarytool history` fails for two different reasons — missing
    /// credentials and no network — so treating that failure as "fall back to
    /// ad-hoc" would hand back an unnotarized DMG that is byte-indistinguishable
    /// from a notarized one at a glance, and it would be published as if it
    /// were signed. Strangers would find out; the release machine would not.
    ///
    /// A machine with no identity is a different case and must still fall back
    /// quietly, or nobody could build a local DMG.
    func test_notarization_failure_on_a_release_machine_stops_the_build() throws {
        let script = try self.script("build-dmg.sh")

        guard let checkStart = script.range(of: "xcrun notarytool history") else {
            return XCTFail(
                "build-dmg.sh no longer probes notarytool before signing, so nothing "
                + "decides between the release path and the ad-hoc fallback."
            )
        }
        // The decision block runs from the probe to the DMG-independent work
        // that follows it; SPARKLE_FX is the first line after the fallback.
        guard let blockEnd = script.range(of: "SPARKLE_FX=", range: checkStart.upperBound..<script.endIndex) else {
            return XCTFail("could not locate the end of the notarization decision block in build-dmg.sh")
        }
        let decision = String(script[checkStart.upperBound..<blockEnd.lowerBound])

        XCTAssertTrue(
            decision.contains("exit 1"),
            "A failing notarytool probe on a machine that HAS a Developer ID identity must "
            + "abort the build. This block downgrades to an ad-hoc DMG instead, which would "
            + "ship unsigned while looking release-ready."
        )

        // The one legitimate downgrade is a deliberate, named opt-out.
        for line in decision.split(separator: "\n") where line.contains("NOTARIZE=0") {
            XCTAssertTrue(
                decision.contains("MAGPIE_ALLOW_ADHOC"),
                "build-dmg.sh clears NOTARIZE on a failed probe without requiring the explicit "
                + "MAGPIE_ALLOW_ADHOC opt-out, so a network blip silently produces an ad-hoc release."
            )
        }

        // The no-identity case must remain a quiet fallback, not an error.
        XCTAssertTrue(
            script.contains("no 'Developer ID Application' identity in the keychain"),
            "The no-identity path must still fall back to ad-hoc with an explanatory note, "
            + "otherwise a contributor cannot build a local DMG at all."
        )
    }

    /// A local install must sign with the Developer ID identity when the
    /// machine has one, and only fall back to ad-hoc when it does not.
    ///
    /// This looks like a distribution concern and is not: a local install is
    /// never notarized. It is about macOS privacy prompts. TCC remembers a
    /// grant against the app's signing identity, and an ad-hoc signature is
    /// derived from the binary, so every rebuild is a brand new app to TCC and
    /// "Magpie would like to access files in your Downloads folder" comes back
    /// after every install, forever. The owner hit exactly that. A Developer ID
    /// signature is stable across rebuilds, so the grant is asked once.
    func test_a_local_install_prefers_the_developer_id_identity() throws {
        let script = try self.script("install-local.sh")

        XCTAssertTrue(
            script.contains("Developer ID Application"),
            "install-local.sh no longer looks for a Developer ID identity, so every install "
            + "signs ad-hoc and macOS re-asks for file access after every rebuild."
        )

        guard let signSection = script.range(of: "SIGN_IDENTITY=") else {
            return XCTFail("install-local.sh no longer resolves a signing identity at all")
        }
        let rest = String(script[signSection.lowerBound...])
        XCTAssertTrue(
            rest.contains("--sign \"${SIGN_IDENTITY}\"") || rest.contains("--sign \"$SIGN_IDENTITY\""),
            "the resolved Developer ID identity is never passed to codesign — the lookup is "
            + "decorative and every build is still ad-hoc signed."
        )

        // The fallback must survive, or a contributor with no certificate cannot
        // install a local build at all.
        XCTAssertTrue(
            rest.contains("--sign -"),
            "the ad-hoc fallback is gone, so anyone without a Developer ID certificate can no "
            + "longer build and install Magpie locally."
        )
    }

    func test_version_has_exactly_one_home() throws {
        let lib = try script("release-lib.sh")
        XCTAssertNotNil(
            lib.range(of: #"(?m)^VERSION="[0-9]+\.[0-9]+\.[0-9]+"$"#, options: .regularExpression),
            "scripts/release-lib.sh must define VERSION=\"x.y.z\" — it is the version's one home"
        )
        for name in ["build-dmg.sh", "install-local.sh"] {
            let body = try script(name)
            XCTAssertTrue(
                body.contains("source scripts/release-lib.sh"),
                "\(name) must source scripts/release-lib.sh for VERSION and the shared helpers"
            )
            XCTAssertNil(
                body.range(of: #"(?m)^\s*VERSION="#, options: .regularExpression),
                "\(name) assigns its own VERSION — two homes for the version is how the scripts once drifted onto an already-published appcast version"
            )
        }
    }

    /// The feed may be empty, and it may advertise the current version. What
    /// it may not do is advertise a different one.
    ///
    /// It shipped claiming 1.5.0 while `release-lib.sh` said 1.6.0 and no such
    /// release existed, so a fresh install was never offered an update and
    /// anyone who was would have been sent to a download that 404s. The file's
    /// own history is the same failure from the other side: the build scripts
    /// once carried their own `VERSION` literals sitting at the version the
    /// published feed already claimed.
    func test_the_appcast_never_advertises_a_version_the_source_is_not_at() throws {
        let feed = try String(
            contentsOf: repoRoot.appendingPathComponent("appcast.xml"), encoding: .utf8
        )
        let advertised = feed.ranges(of: try Regex("<sparkle:version>([^<]+)</sparkle:version>"))
            .map { String(feed[$0]) }
            .map { $0.replacingOccurrences(of: "<sparkle:version>", with: "")
                     .replacingOccurrences(of: "</sparkle:version>", with: "") }
        guard !advertised.isEmpty else { return }   // an empty feed is valid

        let lib = try script("release-lib.sh")
        let versionLine = try XCTUnwrap(
            lib.split(separator: "\n").first { $0.hasPrefix("VERSION=") },
            "release-lib.sh no longer declares VERSION"
        )
        let current = versionLine
            .replacingOccurrences(of: "VERSION=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))

        for version in advertised {
            XCTAssertEqual(
                version, current,
                "appcast.xml advertises \(version) but the source is at \(current) — one of them is pointing at a release that does not exist"
            )
        }
    }

    func test_sparkle_licence_ships_in_the_bundle() throws {
        let lib = try script("release-lib.sh")
        XCTAssertTrue(
            lib.contains(".build/artifacts/sparkle/Sparkle/LICENSE"),
            "release-lib.sh no longer copies Sparkle's LICENSE from the SPM artifact — the bundle would redistribute Sparkle without its MIT notice"
        )
        XCTAssertNotNil(
            lib.range(
                of: #"(?s)copy_sparkle_license\(\).*?license_src.*?exit 1"#,
                options: .regularExpression
            ),
            "copy_sparkle_license must fail loudly (exit 1) when the source licence is missing, never silently skip"
        )
        for name in ["build-dmg.sh", "install-local.sh"] {
            // An actual call at the start of a line — a commented-out call
            // must not satisfy this.
            XCTAssertNotNil(
                try script(name).range(
                    of: #"(?m)^\s*copy_sparkle_license ""#, options: .regularExpression
                ),
                "\(name) never calls copy_sparkle_license — its bundles would ship Sparkle.framework with no licence text"
            )
        }
    }
}
