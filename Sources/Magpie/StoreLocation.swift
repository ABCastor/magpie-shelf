import Foundation

/// Resolves the app's Application Support directory.
///
/// Everything the app persists — `shelf.json`, `ManagedFiles/`, `Handoff/`,
/// `routes.json` — lives in one directory, and `ShelfStore.storeURL`,
/// `ShelfStore.managedFilesDirectory`, `HandoffBundle.root` and
/// `RouteStore.fileURL` are all derived from it. `ShelfStore.init` and
/// `RouteStore.init` both resolve it through here from their default
/// arguments — two independent derivation sites, one resolution — so the
/// stores cannot disagree about where the app's data lives.
enum StoreLocation {
    static let directoryName = "Magpie"
    static let storeFileName = "shelf.json"

    /// The directory every persisted path derives from, created if needed.
    static func applicationSupportDirectory(fileManager fm: FileManager = .default) -> URL {
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
