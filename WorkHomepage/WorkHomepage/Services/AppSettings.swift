//
//  AppSettings.swift
//  WorkHomepage
//
//  Non-secret app settings backed by UserDefaults.
//  Concurrency cap (review queue width), project key prefixes (slice 10),
//  and appearance / color-scheme selection (slice 19).
//

import Foundation
import SwiftUI

// MARK: - Appearance

/// Light / dark / system appearance choice. Persisted to UserDefaults under
/// `settings.appearance`. Default `.system` (follow macOS system setting).
enum Appearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .system: return "System"
        }
    }

    /// Maps to the `preferredColorScheme` modifier's type. `.system` returns
    /// `nil` which tells SwiftUI to follow the OS setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}

// MARK: - AppSettings

enum AppSettings {

    // MARK: - Keys

    static let concurrencyCapKey = "settings.concurrencyCap"
    static let projectKeyPrefixesKey = "settings.projectKeyPrefixes"
    static let appearanceKey = "settings.appearance"

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

    // MARK: - Appearance

    /// Current appearance preference, defaulting to `.system`.
    static var appearance: Appearance {
        get { appearance(defaults: .standard) }
        set { setAppearance(newValue, defaults: .standard) }
    }

    static func appearance(defaults: UserDefaults) -> Appearance {
        guard let raw = defaults.string(forKey: appearanceKey),
              let value = Appearance(rawValue: raw) else {
            return .system
        }
        return value
    }

    static func setAppearance(_ value: Appearance, defaults: UserDefaults) {
        defaults.set(value.rawValue, forKey: appearanceKey)
    }
}
