//
//  BinaryResolver.swift
//  Foreword
//
//  Probes the typical install paths for `claude`, `gh`, `git`, and `idea`.
//  GUI macOS apps launched from Finder do not inherit shell PATH, so every
//  binary spawn needs an absolute path. Persists the last successful resolution
//  in UserDefaults; user overrides take priority over auto-detection.
//

import Foundation

enum Tool: String, CaseIterable {
    case claude
    case gh
    case git
    case idea
}

enum ResolverStatus: Equatable {
    case found(URL)
    case missing
}

struct BinaryResolver {

    // MARK: - Public API (production defaults)

    /// Returns the resolved absolute URL for `tool`, preferring (in order):
    /// 1) user override saved via `setOverride(...)`,
    /// 2) cached resolution from a prior `validate()` / `reDetect()` call,
    /// 3) live probe of the candidate paths.
    /// Returns nil if nothing exists.
    static func resolve(_ tool: Tool) -> URL? {
        resolve(tool, candidates: defaultCandidates(for: tool), defaults: .standard)
    }

    /// Re-probes every tool from scratch (ignores cache, honours overrides) and writes
    /// the freshly resolved paths back to the cache. Returns one status per tool.
    static func validate() -> [Tool: ResolverStatus] {
        validate(candidates: defaultCandidatesAllTools(), defaults: .standard)
    }

    /// Alias for `validate()` — explicit "ignore cache" entrypoint matching the spec.
    static func reDetect() -> [Tool: ResolverStatus] {
        validate()
    }

    /// Persist a manual override path for `tool`, or clear it when `url` is nil.
    static func setOverride(_ tool: Tool, url: URL?) {
        setOverride(tool, url: url, defaults: .standard)
    }

    // MARK: - Testable internal API
    //
    // These accept the candidate paths and a UserDefaults instance so tests can
    // drive resolution against a temp directory without touching real Homebrew /
    // Toolbox paths or the global UserDefaults suite.

    static func resolve(
        _ tool: Tool,
        candidates: [String],
        defaults: UserDefaults
    ) -> URL? {
        // 1. Override wins.
        if let override = readOverride(tool, defaults: defaults), exists(override.path) {
            return override
        }
        // 2. Cached resolution wins next, but only if the file still exists
        //    (binaries get uninstalled / moved between runs).
        if let cachedPath = defaults.string(forKey: cacheKey(tool)), exists(cachedPath) {
            return URL(fileURLWithPath: cachedPath)
        }
        // 3. Live probe.
        if let probed = firstExisting(in: candidates) {
            defaults.set(probed.path, forKey: cacheKey(tool))
            return probed
        }
        // No luck — drop a stale cache entry if any.
        defaults.removeObject(forKey: cacheKey(tool))
        return nil
    }

    static func validate(
        candidates: [Tool: [String]],
        defaults: UserDefaults
    ) -> [Tool: ResolverStatus] {
        var result: [Tool: ResolverStatus] = [:]
        for tool in Tool.allCases {
            // Override beats live probe.
            if let override = readOverride(tool, defaults: defaults), exists(override.path) {
                defaults.set(override.path, forKey: cacheKey(tool))
                result[tool] = .found(override)
                continue
            }
            let toolCandidates = candidates[tool] ?? []
            if let probed = firstExisting(in: toolCandidates) {
                defaults.set(probed.path, forKey: cacheKey(tool))
                result[tool] = .found(probed)
            } else {
                defaults.removeObject(forKey: cacheKey(tool))
                result[tool] = .missing
            }
        }
        return result
    }

    static func setOverride(_ tool: Tool, url: URL?, defaults: UserDefaults) {
        if let url {
            defaults.set(url.path, forKey: overrideKey(tool))
        } else {
            defaults.removeObject(forKey: overrideKey(tool))
        }
    }

    static func readOverride(_ tool: Tool, defaults: UserDefaults) -> URL? {
        guard let path = defaults.string(forKey: overrideKey(tool)), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Default candidate paths

    static func defaultCandidates(for tool: Tool) -> [String] {
        let home = NSHomeDirectory()
        switch tool {
        case .claude:
            return [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                home + "/.claude/local/claude"
            ]
        case .gh:
            return [
                "/opt/homebrew/bin/gh",
                "/usr/local/bin/gh"
            ]
        case .git:
            return [
                "/usr/bin/git",
                "/opt/homebrew/bin/git",
                "/usr/local/bin/git"
            ]
        case .idea:
            return [
                "/opt/homebrew/bin/idea",
                "/usr/local/bin/idea",
                home + "/Library/Application Support/JetBrains/Toolbox/scripts/idea",
                "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"
            ]
        }
    }

    static func defaultCandidatesAllTools() -> [Tool: [String]] {
        var map: [Tool: [String]] = [:]
        for tool in Tool.allCases {
            map[tool] = defaultCandidates(for: tool)
        }
        return map
    }

    // MARK: - Storage keys

    static func cacheKey(_ tool: Tool) -> String {
        "binary.\(tool.rawValue).resolved"
    }

    static func overrideKey(_ tool: Tool) -> String {
        "binary.\(tool.rawValue).override"
    }

    // MARK: - Helpers

    private static func firstExisting(in candidates: [String]) -> URL? {
        for path in candidates where exists(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func exists(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path) && fm.isExecutableFile(atPath: path)
    }
}
