//
//  LegacyDataMigrationTests.swift
//  ForewordTests
//
//  The app used to be called WorkHomepage. On first launch under the new
//  name, `LegacyDataMigration` moves the SwiftData store, the worktree cache
//  and the Keychain items across so an upgrade keeps reviews, findings and
//  credentials. Every test runs against a temp dir and per-test Keychain
//  services; real `git` is used for the worktree-repair cases.
//

import XCTest
@testable import Foreword

@MainActor
final class LegacyDataMigrationTests: XCTestCase {

    private var tempDir: URL!
    private var locations: LegacyDataMigration.Locations!
    private var gitURL: URL!
    private var legacyService: String = ""
    private var newService: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LegacyDataMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let appSupport = tempDir.appendingPathComponent("Application Support", isDirectory: true)
        locations = LegacyDataMigration.Locations(
            legacyAppSupport: appSupport.appendingPathComponent("WorkHomepage", isDirectory: true),
            appSupport: appSupport.appendingPathComponent("Foreword", isDirectory: true),
            legacyCacheRoot: tempDir.appendingPathComponent(".work-homepage", isDirectory: true),
            cacheRoot: tempDir.appendingPathComponent(".foreword", isDirectory: true)
        )

        gitURL = URL(fileURLWithPath: "/usr/bin/git")
        legacyService = "test.legacy." + UUID().uuidString
        newService = "test.new." + UUID().uuidString
    }

    override func tearDownWithError() throws {
        for account in LegacyDataMigration.keychainAccounts {
            KeychainStore.delete(key: account, service: legacyService)
            KeychainStore.delete(key: account, service: newService)
        }
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Application Support (SwiftData store)

    func testMovesLegacyStoreWhenNewLocationIsMissing() throws {
        try write("legacy-store", to: locations.legacyAppSupport.appendingPathComponent("default.store"))

        let report = migrate()

        assertThat(report.appSupport).isEqualTo(.moved)
        assertThat(try read(locations.appSupport.appendingPathComponent("default.store"))).isEqualTo("legacy-store")
        assertThat(exists(locations.legacyAppSupport)).isFalse()
    }

    func testMovesLegacyStoreIntoEmptyNewDirectory() throws {
        try write("legacy-store", to: locations.legacyAppSupport.appendingPathComponent("default.store"))
        try FileManager.default.createDirectory(at: locations.appSupport, withIntermediateDirectories: true)

        let report = migrate()

        assertThat(report.appSupport).isEqualTo(.moved)
        assertThat(try read(locations.appSupport.appendingPathComponent("default.store"))).isEqualTo("legacy-store")
    }

    func testNeverOverwritesExistingStore() throws {
        try write("legacy-store", to: locations.legacyAppSupport.appendingPathComponent("default.store"))
        try write("new-store", to: locations.appSupport.appendingPathComponent("default.store"))

        let report = migrate()

        assertThat(report.appSupport).isEqualTo(.skippedNewLocationInUse)
        assertThat(try read(locations.appSupport.appendingPathComponent("default.store"))).isEqualTo("new-store")
        assertThat(exists(locations.legacyAppSupport)).isTrue()
    }

    func testNothingToDoWithoutLegacyData() throws {
        let report = migrate()

        assertThat(report.appSupport).isEqualTo(.nothingToMigrate)
        assertThat(report.cache).isEqualTo(.nothingToMigrate)
        assertThat(report.keychainAccountsCopied).isEmpty()
        assertThat(exists(locations.appSupport)).isFalse()
        assertThat(exists(locations.cacheRoot)).isFalse()
    }

    // MARK: - Worktree cache

    func testMovesCacheAndRepairsBareCloneWorktree() async throws {
        try skipUnlessGitAvailable()
        let upstream = try makeUpstreamBare()
        _ = try await WorktreeManager.cloneBareFromURL(
            sourceURL: upstream.path, repo: "acme/widgets",
            baseDir: locations.legacyCacheRoot, gitURL: gitURL
        )
        _ = try await WorktreeManager.prepare(
            repo: "acme/widgets", branch: "feature/x", sha: "deadbeef", prNumber: 42,
            baseDir: locations.legacyCacheRoot, gitURL: gitURL
        )

        let report = migrate()

        assertThat(report.cache).isEqualTo(.moved)
        assertThat(exists(locations.legacyCacheRoot)).isFalse()
        let worktree = WorktreeManager.worktreeURL(baseDir: locations.cacheRoot, repo: "acme/widgets", prNumber: 42)
        let bare = WorktreeManager.bareCloneURL(baseDir: locations.cacheRoot, repo: "acme/widgets")
        assertThat(git(["-C", worktree.path, "status", "--porcelain"]).exitCode).isEqualTo(0)
        assertThat(git(["-C", bare.path, "worktree", "list", "--porcelain"]).stdout)
            .contains(canonical(worktree.path))

        // A follow-up review on the moved cache refreshes in place.
        let again = try await WorktreeManager.prepare(
            repo: "acme/widgets", branch: "feature/x", sha: "deadbeef", prNumber: 42,
            baseDir: locations.cacheRoot, gitURL: gitURL
        )
        assertThat(again.path).isEqualTo(worktree.path)
    }

    func testMovesCacheAndRepairsLocalCloneWorktree() async throws {
        try skipUnlessGitAvailable()
        let upstream = try makeUpstreamBare()
        let localClone = tempDir.appendingPathComponent("src/widgets", isDirectory: true)
        assertThat(git(["clone", "-q", upstream.path, localClone.path]).exitCode).isEqualTo(0)
        _ = try await WorktreeManager.prepare(
            repo: "acme/widgets", branch: "feature/x", sha: "deadbeef", prNumber: 7,
            baseDir: locations.legacyCacheRoot, gitURL: gitURL, localRepoURL: localClone
        )

        let report = migrate()

        assertThat(report.cache).isEqualTo(.moved)
        let worktree = WorktreeManager.worktreeURL(baseDir: locations.cacheRoot, repo: "acme/widgets", prNumber: 7)
        assertThat(git(["-C", worktree.path, "status", "--porcelain"]).exitCode).isEqualTo(0)
        assertThat(git(["-C", localClone.path, "worktree", "list", "--porcelain"]).stdout)
            .contains(canonical(worktree.path))
    }

    func testSkipsCacheMoveWhileLegacyCacheIsInUse() throws {
        try write("x", to: locations.legacyCacheRoot.appendingPathComponent("repos/marker"))

        let report = migrate(isInUse: { _ in true })

        assertThat(report.cache).isEqualTo(.skippedLegacyInUse)
        assertThat(exists(locations.legacyCacheRoot)).isTrue()
        assertThat(exists(locations.cacheRoot)).isFalse()
    }

    func testNeverOverwritesExistingCache() throws {
        try write("legacy", to: locations.legacyCacheRoot.appendingPathComponent("repos/marker"))
        try write("new", to: locations.cacheRoot.appendingPathComponent("repos/marker"))

        let report = migrate()

        assertThat(report.cache).isEqualTo(.skippedNewLocationInUse)
        assertThat(try read(locations.cacheRoot.appendingPathComponent("repos/marker"))).isEqualTo("new")
        assertThat(exists(locations.legacyCacheRoot)).isTrue()
    }

    // MARK: - Keychain

    func testCopiesKeychainItemsWithoutOverwriting() throws {
        KeychainStore.set(key: "github.token", value: "legacy-gh", service: legacyService)
        KeychainStore.set(key: "jira.email", value: "legacy@example.com", service: legacyService)
        KeychainStore.set(key: "jira.email", value: "new@example.com", service: newService)

        let report = migrate()

        assertThat(report.keychainAccountsCopied).containsExactly(["github.token"])
        assertThat(KeychainStore.get(key: "github.token", service: newService)).isEqualTo("legacy-gh")
        assertThat(KeychainStore.get(key: "jira.email", service: newService)).isEqualTo("new@example.com")
        assertThat(KeychainStore.get(key: "jira.token", service: newService)).isNil()
        // Legacy items are copied, not moved.
        assertThat(KeychainStore.get(key: "github.token", service: legacyService)).isEqualTo("legacy-gh")
    }

    // MARK: - Helpers

    private func migrate(isInUse: @escaping (URL) -> Bool = { _ in false }) -> LegacyDataMigration.Report {
        LegacyDataMigration.run(
            locations: locations,
            legacyKeychainService: legacyService,
            keychainService: newService,
            gitURL: gitURL,
            isInUse: isInUse
        )
    }

    private func skipUnlessGitAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw XCTSkip("/usr/bin/git not available; skipping worktree repair tests.")
        }
    }

    /// Bare upstream with a `feature/x` branch, outside both cache roots.
    private func makeUpstreamBare() throws -> URL {
        let work = tempDir.appendingPathComponent("upstream", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
            ["config", "commit.gpgsign", "false"],
        ] {
            assertThat(git(["-C", work.path] + args).exitCode).isEqualTo(0)
        }
        try write("initial\n", to: work.appendingPathComponent("README.md"))
        assertThat(git(["-C", work.path, "add", "."]).exitCode).isEqualTo(0)
        assertThat(git(["-C", work.path, "commit", "-q", "-m", "initial"]).exitCode).isEqualTo(0)
        assertThat(git(["-C", work.path, "checkout", "-q", "-b", "feature/x"]).exitCode).isEqualTo(0)
        try write("feature\n", to: work.appendingPathComponent("README.md"))
        assertThat(git(["-C", work.path, "commit", "-q", "-am", "feature"]).exitCode).isEqualTo(0)

        let bare = tempDir.appendingPathComponent("upstream.git", isDirectory: true)
        assertThat(git(["clone", "-q", "--bare", work.path, bare.path]).exitCode).isEqualTo(0)
        return bare
    }

    private func git(_ args: [String]) -> WorktreeManager.ProcessResult {
        WorktreeManager.runProcessSync(executable: gitURL, arguments: args)
    }

    /// Git records realpaths, so `/var/folders/...` comes back as
    /// `/private/var/folders/...`.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            .replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
