import Foundation

enum WritableDestinationResolver {
    static func resolve(
        preferred: URL,
        fallbackSubdirectory: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let candidate = UniqueDestination.url(preferred: preferred, fileManager: fileManager)
        let probe = candidate
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? fileManager.removeItem(at: probe)
            return candidate
        } catch {
            let cache = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(fallbackSubdirectory, isDirectory: true)
            try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
            let fallback = cache.appendingPathComponent(preferred.lastPathComponent)
            return UniqueDestination.url(preferred: fallback, fileManager: fileManager)
        }
    }
}
