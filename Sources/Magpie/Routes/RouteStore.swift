import Foundation

/// Owns `routes.json`: writes the self-teaching default the first time, reads
/// it at launch and on demand, and keeps the parse failure around in plain
/// language for Settings to show.
///
/// Loading is data only. Nothing in the file is executed, resolved or even
/// stat-ed here — a route becomes a process only when `RouteLauncher` is
/// handed one by a menu item the user clicked.
@MainActor
final class RouteStore: ObservableObject {
    static let shared = RouteStore()

    let fileURL: URL
    /// Routes the menus may offer: parsed, and not switched off in the file.
    @Published private(set) var routes: [Route] = []
    @Published private(set) var parseError: RouteParseError?

    /// Mirrors `ShelfStore`'s location so `routes.json` lands beside
    /// `shelf.json` in the app's own Application Support directory — through
    /// the same resolution, because either of the two may be built first.
    init(fileURL: URL = StoreLocation.applicationSupportDirectory()
        .appendingPathComponent("routes.json")) {
        self.fileURL = fileURL
        reload()
    }

    func reload() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            // Written the moment the file is first needed, so the format
            // teaches itself: two switched-off examples plus the field list.
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data(RouteFile.defaultContents.utf8).write(to: fileURL, options: .atomic)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            routes = []
            parseError = .unreadable
            return
        }
        switch RouteFile.parse(data) {
        case .success(let parsed):
            routes = parsed.filter(\.isEnabled)
            parseError = nil
        case .failure(let error):
            // Keep whatever was loaded before: a half-typed edit should not
            // empty the menus while the user is still typing.
            parseError = error
        }
    }

    func route(id: String) -> Route? { routes.first { $0.id == id } }
}
