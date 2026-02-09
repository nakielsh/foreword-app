//
//  AppSettings.swift
//  WorkHomepage
//
//  Non-secret app settings backed by UserDefaults.
//  Concurrency cap (review queue width) and project key prefixes (for the
//  TicketKeyExtractor in slice 10).
//

import Foundation

enum AppSettings {

    // MARK: - Keys

    static let concurrencyCapKey = "settings.concurrencyCap"
    static let projectKeyPrefixesKey = "settings.projectKeyPrefixes"

    // MARK: - Limits

    static let concurrencyCapDefault: Int = 3
    static let concurrencyCapMin: Int = 1
    static let concurrencyCapMax: Int = 10

    // MARK: - Concurrency cap

    static var concurrencyCap: Int {
        get { concurrencyCap(defaults: .standard) }
        set { setConcurrencyCap(newValue, defaults: .standard) }
    }

    static func concurrencyCap(defaults: UserDefaults) -> Int {
        // `integer(forKey:)` returns 0 for absent or non-numeric values; treat
        // 0 (and anything below min) as "use the default".
        let raw = defaults.object(forKey: concurrencyCapKey) as? Int ?? concurrencyCapDefault
        return clampCap(raw)
    }

    static func setConcurrencyCap(_ value: Int, defaults: UserDefaults) {
        defaults.set(clampCap(value), forKey: concurrencyCapKey)
    }

    static func clampCap(_ value: Int) -> Int {
        min(max(value, concurrencyCapMin), concurrencyCapMax)
    }

    // MARK: - Project key prefixes

    /// Stored as a `[String]` in UserDefaults. Default empty == "accept any [A-Z]+-\d+".
    static var projectKeyPrefixes: [String] {
        get { projectKeyPrefixes(defaults: .standard) }
        set { setProjectKeyPrefixes(newValue, defaults: .standard) }
    }

    static func projectKeyPrefixes(defaults: UserDefaults) -> [String] {
        (defaults.array(forKey: projectKeyPrefixesKey) as? [String]) ?? []
    }

    static func setProjectKeyPrefixes(_ value: [String], defaults: UserDefaults) {
        let cleaned = value
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        defaults.set(cleaned, forKey: projectKeyPrefixesKey)
    }
}
