import Foundation
import Security

/// The owner's own API keys, in the macOS Keychain and nowhere else — never in
/// `UserDefaults` beside the preferences, and never in `routes.json`.
///
/// Magpie is not sandboxed, so plain `SecItem*` calls against
/// `kSecClassGenericPassword` under one service name work with no entitlement.
/// A value goes in once and is only ever read again to hand it to a route's
/// child process: nothing in this app displays, logs or copies one.
enum SecretStore {
    static let service = "com.anneo22.magpie"

    /// Names only — the list Settings shows. There is no API here that returns
    /// every value, because nothing in the UI has a reason to hold them.
    static func names() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func value(for name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds, or replaces the value of an existing name. Returns false if the
    /// Keychain refused, which Settings reports rather than swallowing.
    @discardableResult
    static func set(_ value: String, for name: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ name: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
