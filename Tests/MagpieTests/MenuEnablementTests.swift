import AppKit
import XCTest
@testable import Magpie

/// Every menu this app builds decides its own enablement. AppKit's
/// `autoenablesItems` defaults to **true**, which ignores every `isEnabled` the
/// builders set and re-enables any row whose target merely responds to the
/// selector — so "Show in Finder" on a text snippet read and clicked as
/// enabled, and did nothing. That affected roughly ten rows across the two menu
/// surfaces, for every user, not only for assistive technology.
///
/// Asserting this by building a menu does not work: a submenu is only attached
/// when its contents are eligible, so a fresh store with no routes never
/// reaches `RouteMenu` and the assertion passes vacuously — I checked, by
/// deleting the fix and watching the test still go green. So this scans the
/// source instead, the same shape as `RouteTriggerInvariantTests`: every
/// `NSMenu` a builder constructs must turn autoenabling off on the next line.
final class MenuEnablementTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Magpie")
    }

    /// `App.swift` is the deliberate exception and is excluded by name. Its
    /// status menu keeps autoenabling because "Check for Updates…" is wired
    /// straight to Sparkle's controller, so AppKit calls Sparkle's own
    /// `validateMenuItem` and greys the row while a check is in flight.
    /// Turning it off there would freeze that row permanently enabled.
    private let exempt = ["App.swift"]

    /// Every type in the app that IS a menu: `NSMenu` plus everything declared
    /// as a subclass of it. Derived rather than listed, because the first
    /// version of this test hardcoded two names and silently missed
    /// `ShelfMenu` — which builds the item right-click menu, the most-used menu
    /// in the app, and which was therefore skipping the rule this test exists
    /// to enforce.
    private func menuTypeNames(in files: [(name: String, text: String)]) -> Set<String> {
        var names: Set<String> = ["NSMenu"]
        for file in files {
            for line in file.text.components(separatedBy: "\n") {
                guard let range = line.range(of: ": NSMenu"), line.contains("class ") else { continue }
                let head = line[line.startIndex..<range.lowerBound]
                if let declared = head.components(separatedBy: " ").last, !declared.isEmpty {
                    names.insert(declared)
                }
            }
        }
        return names
    }

    func test_every_constructed_menu_manages_its_own_enablement() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var files: [(name: String, text: String)] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let url = sources.appendingPathComponent(relative)
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        let menuTypes = menuTypeNames(in: files)
        XCTAssertTrue(
            menuTypes.contains("ShelfMenu"),
            "the subclass scan stopped finding ShelfMenu — the blind spot is back"
        )

        var offenders: [String] = []
        var checked = 0

        for file in files {
            let name = file.name
            guard !exempt.contains(name) else { continue }
            let lines = file.text.components(separatedBy: "\n")

            for (index, line) in lines.enumerated() {
                // A menu construction: `let x = <any menu type>()`.
                guard menuTypes.contains(where: { line.contains("= \($0)()") }) else {
                    continue
                }
                checked += 1
                let variable = line
                    .components(separatedBy: "=")[0]
                    .replacingOccurrences(of: "let ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // Look ahead far enough that an explanatory comment between the
                // two lines is fine — the primary site carries a long one.
                let window = lines[index..<min(index + 16, lines.count)].joined(separator: "\n")
                if !window.contains("\(variable).autoenablesItems = false") {
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }

        XCTAssertGreaterThan(checked, 5, "found suspiciously few menus — did the scan break?")
        XCTAssertEqual(
            offenders, [],
            "these menus let AppKit override the isEnabled their builder sets, so disabled rows look clickable and do nothing"
        )
    }
}
