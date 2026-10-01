//
//  KeychainStore.swift
//  Foreword
//
//  Thin wrapper around Security.framework. Single service identifier, generic password class.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "io.github.nakielsh.foreword"

    /// `useDataProtectionKeychain` opts items into the modern data-protection
    /// keychain (per-app, app-identity-scoped) rather than the legacy file
    /// keychain. Stronger isolation: a different developer-signed binary on
    /// the same login keychain can't read items from this one. Disabled by
    /// default because it requires the binary to carry a keychain-access-
    /// group entitlement (and `ENABLE_APP_SANDBOX = NO` here means we don't
    /// have one yet). When the sandbox decision lands and the entitlements
    /// file is added, flip this to `true`.
    ///
    /// All `SecItem*` calls go through `baseQuery(account:)` so this single
    /// switch consistently affects reads, writes, and deletes.
    private static let useDataProtectionKeychain = false

    private static func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    /// Store `value` under `key`. Replaces existing value if present. Returns true on success.
    @discardableResult
    static func set(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first so add never collides.
        SecItemDelete(baseQuery(account: key) as CFDictionary)

        var addQuery = baseQuery(account: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(key: String) -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
