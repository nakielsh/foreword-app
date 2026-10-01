//
//  LegacyDataMigration.swift
//  Foreword
//
//  One-shot upgrade path from the app's previous name, WorkHomepage. Runs
//  from `ForewordApp.init` before the SwiftData container is built and moves
//  three things across, never overwriting data already at the new location:
//
//    Application Support/WorkHomepage/   → Application Support/Foreword/
//    ~/.work-homepage/                   → ~/.foreword/ (+ `git worktree repair`)
//    Keychain service `com.work-homepage` → `KeychainStore.defaultService` (copied)
//
//  Every step is idempotent: once the legacy location is gone (or the new one
//  holds data) it reports `.nothingToMigrate` / `.skippedNewLocationInUse`
//  and does no further work, so calling it on every launch is cheap.
//

import Foundation
import os

enum LegacyDataMigration {

    struct Locations {
        let legacyAppSupport: URL
        let appSupport: URL
        let legacyCacheRoot: URL
        let cacheRoot: URL
    }

    enum Outcome: Equatable {
        case nothingToMigrate
        case moved
        /// The new location already holds data; the legacy copy is left alone.
        case skippedNewLocationInUse
        /// A process is working inside the legacy cache (e.g. a `claude`
        /// session in a worktree). Retried on the next launch.
        case skippedLegacyInUse
        case failed(String)
    }

    struct Report: Equatable {
        var appSupport: Outcome
        var cache: Outcome
        var keychainAccountsCopied: [String]
    }

    static let legacyKeychainService = "com.work-homepage"

    /// Every account the app stores through `KeychainStore`.
    static let keychainAccounts = ["github.token", JiraConfig.emailKeychainKey, JiraConfig.tokenKeychainKey]

    private static let log = Logger(subsystem: "Foreword", category: "legacyMigration")

    /// Production entry point. Resolves the real locations and `git`, then
    /// runs the migration and logs anything that moved or failed.
    static func runIfNeeded() {
        guard let appSupportRoot = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations = Locations(
            legacyAppSupport: appSupportRoot.appendingPathComponent("WorkHomepage", isDirectory: true),
            appSupport: appSupportRoot.appendingPathComponent("Foreword", isDirectory: true),
            legacyCacheRoot: home.appendingPathComponent(".work-homepage", isDirectory: true),
            cacheRoot: WorktreeManager.defaultBaseDir()
        )
        let report = run(
            locations: locations,
            legacyKeychainService: legacyKeychainService,
            keychainService: KeychainStore.defaultService,
            gitURL: BinaryResolver.resolve(.git),
            isInUse: { hasProcessWorkingInside($0) }
        )
        if report != Report(appSupport: .nothingToMigrate, cache: .nothingToMigrate, keychainAccountsCopied: []) {
            log.notice("legacy migration: \(String(describing: report), privacy: .public)")
        }
    }

    /// Testable core. `isInUse` is only consulted when the cache would
    /// otherwise be moved.
    static func run(
        locations: Locations,
        legacyKeychainService: String,
        keychainService: String,
        gitURL: URL?,
        isInUse: (URL) -> Bool,
        fileManager: FileManager = .default
    ) -> Report {
        let appSupport = move(
            from: locations.legacyAppSupport,
            to: locations.appSupport,
            isInUse: { _ in false },
            fileManager: fileManager
        )
        let cache = move(
            from: locations.legacyCacheRoot,
            to: locations.cacheRoot,
            isInUse: isInUse,
            fileManager: fileManager
        )
        if cache == .moved, let gitURL {
            repairWorktrees(movedFrom: locations.legacyCacheRoot, to: locations.cacheRoot, gitURL: gitURL, fileManager: fileManager)
        }
        let copied = copyKeychainItems(from: legacyKeychainService, to: keychainService)
        return Report(appSupport: appSupport, cache: cache, keychainAccountsCopied: copied)
    }

    // MARK: - Directories

    private static func move(
        from legacy: URL,
        to target: URL,
        isInUse: (URL) -> Bool,
        fileManager: FileManager
    ) -> Outcome {
        guard fileManager.fileExists(atPath: legacy.path) else { return .nothingToMigrate }
        if fileManager.fileExists(atPath: target.path) {
            // An empty directory (e.g. created by an earlier launch that
            // skipped the move) doesn't count as data worth protecting.
            guard let contents = try? fileManager.contentsOfDirectory(atPath: target.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else {
                return .skippedNewLocationInUse
            }
        }
        if isInUse(legacy) { return .skippedLegacyInUse }
        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: target)
            return .moved
        } catch {
            log.error("could not move \(legacy.path, privacy: .public) → \(target.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    // MARK: - Worktrees

    /// Git stores absolute paths in both directions of a linked worktree
    /// (`<worktree>/.git` → admin dir, admin dir `gitdir` → worktree), so a
    /// plain directory move leaves every worktree detached. For each worktree
    /// under `<newRoot>/worktrees/<org>/<repo>/<pr#>`, find the repository
    /// that owns it — the bare clone that moved with it, or the user's own
    /// clone that didn't — and run `git worktree repair` there.
    private static func repairWorktrees(movedFrom oldRoot: URL, to newRoot: URL, gitURL: URL, fileManager: FileManager) {
        let worktreesRoot = newRoot.appendingPathComponent("worktrees", isDirectory: true)
        for worktree in worktreeDirectories(under: worktreesRoot, fileManager: fileManager) {
            guard let adminPath = gitdirPointer(of: worktree) else { continue }
            let admin = URL(fileURLWithPath: rebase(adminPath, from: oldRoot, to: newRoot))
            // <common dir>/worktrees/<id> → <common dir>
            let commonDir = admin.deletingLastPathComponent().deletingLastPathComponent()
            let repoDir = commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : commonDir
            let result = WorktreeManager.runProcessSync(
                executable: gitURL,
                arguments: ["-C", repoDir.path, "worktree", "repair", worktree.path]
            )
            if result.exitCode != 0 {
                log.error("git worktree repair failed for \(worktree.path, privacy: .public): \(result.stderr, privacy: .public)")
            }
        }
    }

    private static func worktreeDirectories(under root: URL, fileManager: FileManager) -> [URL] {
        func subdirectories(_ url: URL) -> [URL] {
            let children = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return subdirectories(root)
            .flatMap(subdirectories)
            .flatMap(subdirectories)
            .filter { worktree in
                var isDirectory: ObjCBool = false
                let dotGit = worktree.appendingPathComponent(".git").path
                return fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
    }

    /// Reads `gitdir: <path>` from a linked worktree's `.git` file. Relative
    /// pointers (`worktree.useRelativePaths`) are resolved against the
    /// worktree.
    private static func gitdirPointer(of worktree: URL) -> String? {
        guard let contents = try? String(contentsOf: worktree.appendingPathComponent(".git"), encoding: .utf8),
              contents.hasPrefix("gitdir:") else { return nil }
        let path = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: path, relativeTo: worktree).standardizedFileURL.path
    }

    /// Re-roots `path` from `oldRoot` to `newRoot` when it lives under
    /// `oldRoot`; otherwise returns it unchanged.
    private static func rebase(_ path: String, from oldRoot: URL, to newRoot: URL) -> String {
        let canonicalPath = withoutPrivatePrefix(path)
        let canonicalRoot = withoutPrivatePrefix(oldRoot.path)
        guard canonicalPath.hasPrefix(canonicalRoot + "/") else { return path }
        return newRoot.path + canonicalPath.dropFirst(canonicalRoot.count)
    }

    /// Git records realpaths, so `/var/...` and `/tmp/...` come back as
    /// `/private/var/...`. Compare without the firmlink prefix.
    private static func withoutPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// True when any of the user's processes has its working directory
    /// inside `root` — e.g. a terminal or `claude` session in a worktree.
    static func hasProcessWorkingInside(_ root: URL) -> Bool {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: lsof.path) else { return false }
        let result = WorktreeManager.runProcessSync(
            executable: lsof,
            arguments: ["-a", "-d", "cwd", "-u", NSUserName(), "-F", "n"]
        )
        let rootPath = withoutPrivatePrefix(root.path)
        return result.stdout.split(separator: "\n").contains { line in
            guard line.hasPrefix("n") else { return false }
            let cwd = withoutPrivatePrefix(String(line.dropFirst()))
            return cwd == rootPath || cwd.hasPrefix(rootPath + "/")
        }
    }

    // MARK: - Keychain

    /// Copies each known account that is missing under `newService`. Legacy
    /// items stay in place so a rollback to the old build keeps working.
    private static func copyKeychainItems(from legacyService: String, to newService: String) -> [String] {
        keychainAccounts.filter { account in
            guard KeychainStore.get(key: account, service: newService) == nil,
                  let value = KeychainStore.get(key: account, service: legacyService) else { return false }
            return KeychainStore.set(key: account, value: value, service: newService)
        }
    }
}
