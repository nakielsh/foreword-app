//
//  AppSettings.swift
//  Foreword
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
    /// Shares the same UserDefaults key as `ReviewPromptStore` — no duplication.
    static let reviewPromptTemplateKey = ReviewPromptStore.defaultsKey
    static let summaryConcurrencyCapKey = "settings.summaryConcurrencyCap"
    static let reviewTimeoutMinutesKey = "settings.reviewTimeoutMinutes"

    // MARK: - Limits

    static let concurrencyCapDefault: Int = 3
    static let concurrencyCapMin: Int = 1
    static let concurrencyCapMax: Int = 10

    static let summaryConcurrencyCapDefault: Int = 5
    static let summaryConcurrencyCapMin: Int = 1
    static let summaryConcurrencyCapMax: Int = 10

    /// Per-review wall-clock timeout in minutes. `claude` sometimes takes more
    /// than 10 minutes on large diffs (the previous hard-coded ceiling), so the
    /// value is user-configurable. Default 30 minutes; range [5, 120].
    static let reviewTimeoutMinutesDefault: Int = 30
    static let reviewTimeoutMinutesMin: Int = 5
    static let reviewTimeoutMinutesMax: Int = 120

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

    // MARK: - Summary concurrency cap

    /// Maximum number of `PreReviewSummaryRunner` invocations that can run
    /// concurrently. Separate from `concurrencyCap` (the Review pool).
    /// Default 5, range [1, 10].
    static var summaryConcurrencyCap: Int {
        get { summaryConcurrencyCap(defaults: .standard) }
        set { setSummaryConcurrencyCap(newValue, defaults: .standard) }
    }

    static func summaryConcurrencyCap(defaults: UserDefaults) -> Int {
        let raw = defaults.object(forKey: summaryConcurrencyCapKey) as? Int ?? summaryConcurrencyCapDefault
        return clampSummaryCap(raw)
    }

    static func setSummaryConcurrencyCap(_ value: Int, defaults: UserDefaults) {
        defaults.set(clampSummaryCap(value), forKey: summaryConcurrencyCapKey)
    }

    static func clampSummaryCap(_ value: Int) -> Int {
        min(max(value, summaryConcurrencyCapMin), summaryConcurrencyCapMax)
    }

    // MARK: - Review timeout

    /// Per-review wall-clock timeout in minutes. Persisted in UserDefaults;
    /// clamped to `[reviewTimeoutMinutesMin, reviewTimeoutMinutesMax]` on read
    /// so a hand-edited / corrupt value can't push the runner outside the
    /// supported range.
    static var reviewTimeoutMinutes: Int {
        get { reviewTimeoutMinutes(defaults: .standard) }
        set { setReviewTimeoutMinutes(newValue, defaults: .standard) }
    }

    static func reviewTimeoutMinutes(defaults: UserDefaults) -> Int {
        let raw = defaults.object(forKey: reviewTimeoutMinutesKey) as? Int ?? reviewTimeoutMinutesDefault
        return clampReviewTimeout(raw)
    }

    static func setReviewTimeoutMinutes(_ value: Int, defaults: UserDefaults) {
        defaults.set(clampReviewTimeout(value), forKey: reviewTimeoutMinutesKey)
    }

    static func clampReviewTimeout(_ value: Int) -> Int {
        min(max(value, reviewTimeoutMinutesMin), reviewTimeoutMinutesMax)
    }

    /// Convenience for callers that want the timeout as seconds (e.g.
    /// `Duration.seconds(...)` for `ClaudeRunner.run`).
    static var reviewTimeoutSeconds: Int { reviewTimeoutMinutes * 60 }

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

    // MARK: - Review Prompt Template

    /// User-editable PR-body template. Delegates to `ReviewPromptStore` so
    /// there is exactly one storage key shared between the two access points.
    static var reviewPromptTemplate: String {
        get { reviewPromptTemplate(defaults: .standard) }
        set { setReviewPromptTemplate(newValue, defaults: .standard) }
    }

    static func reviewPromptTemplate(defaults: UserDefaults) -> String {
        ReviewPromptStore(defaults: defaults).current()
    }

    static func setReviewPromptTemplate(_ value: String, defaults: UserDefaults) {
        ReviewPromptStore(defaults: defaults).setCurrent(value)
    }
}
