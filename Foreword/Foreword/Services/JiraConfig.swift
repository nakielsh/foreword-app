//
//  JiraConfig.swift
//  Foreword
//
//  Pure helper for Jira credential persistence.
//  Base URL → UserDefaults (non-secret).
//  Email + token → Keychain via KeychainStore (secrets).
//

import Foundation

enum JiraConfig {

    // MARK: - Default keys (production)

    static let baseURLDefaultsKey = "jira.baseURL"
    static let emailKeychainKey = "jira.email"
    static let tokenKeychainKey = "jira.token"

    // MARK: - Public API

    static func setBaseURL(_ url: String) {
        setBaseURL(url, key: baseURLDefaultsKey, defaults: .standard)
    }

    static func getBaseURL() -> String? {
        getBaseURL(key: baseURLDefaultsKey, defaults: .standard)
    }

    static func setEmail(_ email: String) {
        setEmail(email, key: emailKeychainKey)
    }

    static func getEmail() -> String? {
        getEmail(key: emailKeychainKey)
    }

    static func setToken(_ token: String) {
        setToken(token, key: tokenKeychainKey)
    }

    static func getToken() -> String? {
        getToken(key: tokenKeychainKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: baseURLDefaultsKey)
        KeychainStore.delete(key: emailKeychainKey)
        KeychainStore.delete(key: tokenKeychainKey)
    }

    // MARK: - Testable internal API
    //
    // Same logic, but tests pass unique keys per test so they don't trample
    // a developer's real Jira config in the shared keychain / defaults.

    /// Returns true when `url` is a syntactically valid https Jira base URL.
    /// We reject http (Basic-auth credentials would travel in plaintext),
    /// arbitrary schemes (file://, javascript:), and inputs that fail to
    /// parse as a URL. Empty input is allowed by callers as the "clear"
    /// signal, so we don't validate that here.
    static func validateBaseURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let parsed = URL(string: trimmed) else { return false }
        guard let scheme = parsed.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = parsed.host, !host.isEmpty else { return false }
        return true
    }

    static func setBaseURL(_ url: String, key: String, defaults: UserDefaults) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        // Silently refuse to persist a non-https URL; Settings UI surfaces the
        // validation result via `validateBaseURL` so the user gets a visible
        // error instead of "saved but doesn't work".
        guard validateBaseURL(trimmed) else { return }
        defaults.set(trimmed, forKey: key)
    }

    static func getBaseURL(key: String, defaults: UserDefaults) -> String? {
        let value = defaults.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }

    static func setEmail(_ email: String, key: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(key: key)
        } else {
            KeychainStore.set(key: key, value: trimmed)
        }
    }

    static func getEmail(key: String) -> String? {
        KeychainStore.get(key: key)
    }

    static func setToken(_ token: String, key: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(key: key)
        } else {
            KeychainStore.set(key: key, value: trimmed)
        }
    }

    static func getToken(key: String) -> String? {
        KeychainStore.get(key: key)
    }
}
