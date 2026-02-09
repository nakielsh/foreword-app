//
//  JiraConfig.swift
//  WorkHomepage
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

    static func setBaseURL(_ url: String, key: String, defaults: UserDefaults) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
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
