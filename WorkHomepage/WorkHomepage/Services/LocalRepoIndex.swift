//
//  LocalRepoIndex.swift
//  WorkHomepage
//
//  Maps `<org>/<repo>` GitHub identifiers onto on-disk git checkouts the user
//  already owns (default scan root: `~/src`). When a mapping exists,
//  `WorktreeManager` creates worktrees inside the existing clone rather than
//  inflating a fresh bare clone under `~/.work-homepage/`.
//
//  Persistence layout (UserDefaults):
//    - `localRepoIndex.roots`     [String]               // bookmark paths to scan
//    - `localRepoIndex.mapping`   [String: String]       // last-known scan results
//    - `localRepoIndex.overrides` [String: String]       // user-set per-repo paths
//
//  Lookup order: override → mapping → nil. Overrides are written by Settings
//  when the user picks a directory by hand; the mapping is filled by
//  `rescan(...)` which walks the roots and asks `git remote get-url origin`
//  for each candidate directory.
//

import Foundation

enum LocalRepoIndex {

    // MARK: - Keys

    static let rootsKey = "localRepoIndex.roots"
    static let mappingKey = "localRepoIndex.mapping"
    static let overridesKey = "localRepoIndex.overrides"

    // MARK: - Defaults

    /// Default search roots seeded into UserDefaults the first time the user
    /// hits the Settings UI (or `roots(defaults:)` is called with an empty
    /// store). Matches the user's actual workspace layout — `~/src/` is the
    /// shared convention across this codebase.
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("src", isDirectory: true)]
    }

    // MARK: - Roots

    static var roots: [URL] {
        get { roots(defaults: .standard) }
        set { setRoots(newValue, defaults: .standard) }
    }

    static func roots(defaults: UserDefaults) -> [URL] {
        guard let raw = defaults.array(forKey: rootsKey) as? [String], !raw.isEmpty else {
            return defaultRoots()
        }
        return raw.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func setRoots(_ value: [URL], defaults: UserDefaults) {
        let cleaned = value
            .map { $0.path }
            .filter { !$0.isEmpty }
        defaults.set(cleaned, forKey: rootsKey)
    }

    // MARK: - Mapping (cached scan results)

    static var mapping: [String: URL] {
        get { mapping(defaults: .standard) }
        set { setMapping(newValue, defaults: .standard) }
    }

    static func mapping(defaults: UserDefaults) -> [String: URL] {
        guard let raw = defaults.dictionary(forKey: mappingKey) as? [String: String] else {
            return [:]
        }
        return raw.mapValues { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func setMapping(_ value: [String: URL], defaults: UserDefaults) {
        let raw = value.mapValues { $0.path }
        defaults.set(raw, forKey: mappingKey)
    }

    // MARK: - Overrides (user-set)

    static var overrides: [String: URL] {
        get { overrides(defaults: .standard) }
        set { setOverrides(newValue, defaults: .standard) }
    }

    static func overrides(defaults: UserDefaults) -> [String: URL] {
        guard let raw = defaults.dictionary(forKey: overridesKey) as? [String: String] else {
            return [:]
        }
        return raw.mapValues { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func setOverrides(_ value: [String: URL], defaults: UserDefaults) {
        let raw = value.mapValues { $0.path }
        defaults.set(raw, forKey: overridesKey)
    }

    static func setOverride(repo: String, url: URL?, defaults: UserDefaults = .standard) {
        var current = overrides(defaults: defaults)
        if let url {
            current[repo] = url
        } else {
            current.removeValue(forKey: repo)
        }
        setOverrides(current, defaults: defaults)
    }

    // MARK: - Lookup

    /// Resolves the on-disk checkout path for `<org>/<repo>`. Lookup order:
    /// override → mapping → nil. Returns `nil` when the caller should fall
    /// back to the bare-clone flow under `~/.work-homepage/`.
    static func localPath(for repo: String, defaults: UserDefaults = .standard) -> URL? {
        if let override = overrides(defaults: defaults)[repo] {
            return override
        }
        return mapping(defaults: defaults)[repo]
    }

    /// Serialises rescans so two concurrent callers can't both walk the
    /// roots, both write back partial mappings, and clobber each other's
    /// just-discovered entries. Implemented as an `NSLock` (not an actor —
    /// the work is synchronous I/O and the rest of `LocalRepoIndex` is
    /// non-isolated; an actor would force every caller to `await`).
    private static let scanLock = NSLock()

    /// Lookup with a one-shot rescan fallback. If neither the override nor
    /// the persisted mapping has the repo, walks the configured roots, writes
    /// the result back, and returns the freshly-resolved path. Synchronous
    /// and I/O-heavy — call from a detached task. Used by `WorktreeManager`
    /// so the user doesn't have to open Settings → Rescan before the first
    /// review hits a local clone.
    static func localPathOrScan(for repo: String, defaults: UserDefaults = .standard) -> URL? {
        if let cached = localPath(for: repo, defaults: defaults) {
            return cached
        }
        let configuredRoots = roots(defaults: defaults)
        guard !configuredRoots.isEmpty, let gitURL = BinaryResolver.resolve(.git) else {
            return nil
        }
        // Serialise the read-modify-write so two parallel `start(...)` calls
        // against repos that aren't yet mapped don't race each other and lose
        // entries. The first to grab the lock writes the merged mapping; the
        // second sees the cached value and skips the scan entirely.
        scanLock.lock()
        defer { scanLock.unlock() }
        if let cached = localPath(for: repo, defaults: defaults) {
            return cached
        }
        let scanned = scan(roots: configuredRoots, gitURL: gitURL)
        // Merge into the existing mapping rather than replacing it. The
        // `scan` walker only sees what's on disk right now; rare-but-real
        // case: another rescan finished between our cache check and the
        // lock acquisition. Replacing wholesale would drop their entries.
        var merged = mapping(defaults: defaults)
        for (k, v) in scanned { merged[k] = v }
        setMapping(merged, defaults: defaults)
        if let override = overrides(defaults: defaults)[repo] {
            return override
        }
        return merged[repo]
    }

    // MARK: - Scanning

    /// Walks each root one level deep, plus one nested level (so layouts like
    /// `~/src/<org>/<repo>` work alongside flat `~/src/<repo>` ones), and
    /// shells out to `git -C <dir> remote get-url origin` for each candidate.
    /// Origins matching `github.com[:/]<owner>/<name>(.git)?` are recorded
    /// as `<owner>/<name>` → `<dir>`.
    ///
    /// Containment check: after parsing the GitHub repo from the remote URL,
    /// the resolved candidate dir must live under one of the configured
    /// roots. Without this, a malicious nested directory whose `origin`
    /// points at `github.com/<owner>/<repo>` could spoof the mapping for
    /// that repo (via symlinks pointing outside the user's `~/src/`,
    /// FileManager-followed) — leading the next review to clone-bypass into
    /// attacker-controlled territory.
    ///
    /// Synchronous and I/O-heavy. Call from a detached task.
    static func scan(roots: [URL], gitURL: URL) -> [String: URL] {
        // Resolve roots once for containment comparison. Symlinks in the
        // root paths themselves are honoured (e.g. `~/src` → `/Volumes/...`)
        // so legitimate user setups still match. Candidate paths are
        // resolved the same way before comparison.
        let resolvedRoots: [URL] = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }

        var result: [String: URL] = [:]
        for root in roots {
            for dir in candidateDirectories(under: root) {
                guard let remote = readOriginRemote(at: dir, gitURL: gitURL) else { continue }
                guard let repo = parseGitHubRepo(from: remote) else { continue }
                guard isContained(dir, in: resolvedRoots) else { continue }
                // First match wins: we don't want a stale clone deeper in the
                // tree to overwrite a primary one closer to the root. The
                // candidate enumeration already produces shallower entries
                // first.
                if result[repo] == nil {
                    result[repo] = dir
                }
            }
        }
        return result
    }

    /// True iff `candidate`, after symlink resolution, sits at or beneath
    /// one of `resolvedRoots`. Comparison is by path-component prefix to
    /// avoid `/srcfoo` matching `/src` on plain string contains checks.
    static func isContained(_ candidate: URL, in resolvedRoots: [URL]) -> Bool {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let candidateComponents = resolved.pathComponents
        for root in resolvedRoots {
            let rootComponents = root.pathComponents
            guard candidateComponents.count >= rootComponents.count else { continue }
            if Array(candidateComponents.prefix(rootComponents.count)) == rootComponents {
                return true
            }
        }
        return false
    }

    /// Convenience: scan the persisted roots, using the resolved `git` binary,
    /// and write the result back into the persisted mapping. Returns the new
    /// mapping for callers that want to render it without re-reading.
    @discardableResult
    static func rescan(defaults: UserDefaults = .standard) -> [String: URL] {
        guard let gitURL = BinaryResolver.resolve(.git) else { return mapping(defaults: defaults) }
        let result = scan(roots: roots(defaults: defaults), gitURL: gitURL)
        setMapping(result, defaults: defaults)
        return result
    }

    // MARK: - Internals

    /// Returns immediate subdirectories of `root`, plus one extra nested level
    /// so `<root>/<org>/<repo>` layouts surface alongside flat `<root>/<repo>`
    /// ones. Hidden dirs are skipped. Symlinks are followed via FileManager's
    /// default behaviour — git remote queries on non-repo directories are
    /// cheap and bounded (one process spawn per dir).
    private static func candidateDirectories(under root: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        var out: [URL] = []
        let firstLevel = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in firstLevel {
            guard isDirectory(entry) else { continue }
            out.append(entry)
            // Probe one nested level for org-style layouts. Skipped when the
            // first-level entry itself looks like a git checkout (has `.git`)
            // — we don't want to descend into a repo's own subdirectories.
            if hasGitDir(entry) { continue }
            let secondLevel = (try? fm.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for nested in secondLevel where isDirectory(nested) {
                out.append(nested)
            }
        }
        return out
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    private static func hasGitDir(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Runs `git -C <dir> remote get-url origin` and returns trimmed stdout on
    /// success. Returns `nil` when the directory isn't a git checkout or has
    /// no `origin` remote.
    private static func readOriginRemote(at dir: URL, gitURL: URL) -> String? {
        let result = WorktreeManager.runProcessSync(
            executable: gitURL,
            arguments: ["-C", dir.path, "remote", "get-url", "origin"]
        )
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses an `origin` URL into `<owner>/<repo>`. Accepts:
    ///   - `git@github.com:Owner/Repo.git`
    ///   - `git@github.com:Owner/Repo`
    ///   - `https://github.com/Owner/Repo.git`
    ///   - `https://github.com/Owner/Repo`
    ///   - `ssh://git@github.com/Owner/Repo.git`
    /// Returns `nil` for non-GitHub remotes; the local-repo flow only kicks in
    /// for repos we'd otherwise clone from `github.com`.
    static func parseGitHubRepo(from remote: String) -> String? {
        var s = remote
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        // Try to find `github.com` and take everything after the first
        // separator (`:` for SCP-style, `/` for URL-style).
        guard let range = s.range(of: "github.com") else { return nil }
        var tail = String(s[range.upperBound...])
        guard let first = tail.first else { return nil }
        if first == ":" || first == "/" {
            tail.removeFirst()
        } else {
            return nil
        }
        let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }
}
