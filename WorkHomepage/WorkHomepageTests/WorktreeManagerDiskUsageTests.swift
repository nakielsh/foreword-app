//
//  WorktreeManagerDiskUsageTests.swift
//  WorkHomepageTests
//
//  Slice 17 — disk-usage walker + per-repo evict.
//
//  These tests build the same on-disk layout that `WorktreeManager.prepare`
//  produces (without going through `prepare`, to keep them dependency-free
//  and fast):
//
//      <tmp>/repos/<org>/<repo>.git/...
//      <tmp>/worktrees/<org>/<repo>/<pr#>/...
//
//  We seed each leaf with regular files of known total size and assert that
//  the public reporters return matching numbers, that the per-repo breakdown
//  is sorted by total bytes descending, and that `evictAllForRepo` only
//  takes down the targeted repo (and refuses while a "review" is in flight).
//
//  No git is involved: the walker only cares about file sizes, not git
//  structure. Calling `prepare` here would just slow the suite down.
//

import XCTest
@testable import WorkHomepage

final class WorktreeManagerDiskUsageTests: XCTestCase {

    private var tempDir: URL!
    private var baseDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorktreeManagerDiskUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        baseDir = tempDir.appendingPathComponent(".work-homepage", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - diskUsage()

    func testDiskUsageZeroOnEmptyTree() {
        // Base dir exists but has no `repos/` or `worktrees/` children.
        let total = WorktreeManager.diskUsage(baseDir: baseDir)
        assertThat(total).isEqualTo(0)
    }

    func testDiskUsageZeroWhenBaseDirMissing() {
        let nonExistent = baseDir.appendingPathComponent("nope", isDirectory: true)
        let total = WorktreeManager.diskUsage(baseDir: nonExistent)
        assertThat(total).isEqualTo(0)
    }

    func testDiskUsageSumsBareAndWorktreeBytes() throws {
        // 1 KiB in a bare clone, 2 KiB across two worktree leaves, 4 KiB in
        // an unrelated org. Total = 7 KiB.
        try seedBareFile(org: "Acme", repo: "widgets", relPath: "objects/pack/pack-1.idx", bytes: 1024)
        try seedWorktreeFile(org: "Acme", repo: "widgets", pr: 1, relPath: "README.md", bytes: 1024)
        try seedWorktreeFile(org: "Acme", repo: "widgets", pr: 2, relPath: "src/main.swift", bytes: 1024)
        try seedBareFile(org: "Other", repo: "tools", relPath: "objects/pack/pack-2.idx", bytes: 4096)

        let total = WorktreeManager.diskUsage(baseDir: baseDir)
        // APFS may report `totalFileAllocatedSize` rounded up to block size;
        // assert at-least-equal rather than exact.
        assertThat(total >= 7 * 1024).isTrue()
    }

    // MARK: - usagePerRepo()

    func testUsagePerRepoEmptyOnEmptyTree() {
        let result = WorktreeManager.usagePerRepo(baseDir: baseDir)
        assertThat(result).isEmpty()
    }

    func testUsagePerRepoBreaksDownByRepoAndSortsDescending() throws {
        // Acme/widgets: 1 KiB bare + 5 KiB worktrees = 6 KiB
        try seedBareFile(org: "Acme", repo: "widgets", relPath: "objects/info.idx", bytes: 1024)
        try seedWorktreeFile(org: "Acme", repo: "widgets", pr: 10, relPath: "a.txt", bytes: 3072)
        try seedWorktreeFile(org: "Acme", repo: "widgets", pr: 11, relPath: "b.txt", bytes: 2048)

        // Acme/cogs: 10 KiB bare + 0 worktrees = 10 KiB
        try seedBareFile(org: "Acme", repo: "cogs", relPath: "objects/info.idx", bytes: 10 * 1024)

        // Other/tools: 0 bare + 2 KiB worktrees = 2 KiB
        try seedWorktreeFile(org: "Other", repo: "tools", pr: 1, relPath: "x.txt", bytes: 2048)

        let result = WorktreeManager.usagePerRepo(baseDir: baseDir)

        assertThat(result.count).isEqualTo(3)

        // Sorted by total bytes descending: cogs (10K) > widgets (6K) > tools (2K)
        assertThat(result[0].repo).isEqualTo("Acme/cogs")
        assertThat(result[1].repo).isEqualTo("Acme/widgets")
        assertThat(result[2].repo).isEqualTo("Other/tools")

        // Per-row breakdown is sane.
        assertThat(result[1].bareBytes >= 1024).isTrue()
        assertThat(result[1].worktreeBytes >= 5 * 1024).isTrue()
        assertThat(result[1].totalBytes).isEqualTo(result[1].bareBytes + result[1].worktreeBytes)

        assertThat(result[0].bareBytes >= 10 * 1024).isTrue()
        assertThat(result[0].worktreeBytes).isEqualTo(0)

        assertThat(result[2].bareBytes).isEqualTo(0)
        assertThat(result[2].worktreeBytes >= 2048).isTrue()
    }

    func testUsagePerRepoIncludesRepoWithOnlyWorktrees() throws {
        try seedWorktreeFile(org: "Acme", repo: "orphan", pr: 1, relPath: "x", bytes: 512)
        let result = WorktreeManager.usagePerRepo(baseDir: baseDir)
        assertThat(result.count).isEqualTo(1)
        assertThat(result[0].repo).isEqualTo("Acme/orphan")
        assertThat(result[0].bareBytes).isEqualTo(0)
        assertThat(result[0].worktreeBytes >= 512).isTrue()
    }

    func testUsagePerRepoIncludesRepoWithOnlyBare() throws {
        try seedBareFile(org: "Acme", repo: "fresh", relPath: "objects/info.idx", bytes: 512)
        let result = WorktreeManager.usagePerRepo(baseDir: baseDir)
        assertThat(result.count).isEqualTo(1)
        assertThat(result[0].repo).isEqualTo("Acme/fresh")
        assertThat(result[0].bareBytes >= 512).isTrue()
        assertThat(result[0].worktreeBytes).isEqualTo(0)
    }

    // MARK: - evictAllForRepo()

    func testEvictAllForRepoRemovesBareAndWorktrees() throws {
        try seedBareFile(org: "Acme", repo: "widgets", relPath: "objects/info.idx", bytes: 256)
        try seedWorktreeFile(org: "Acme", repo: "widgets", pr: 1, relPath: "a.txt", bytes: 128)
        try seedWorktreeFile(org: "Acme", repo: "widgets", pr: 2, relPath: "b.txt", bytes: 128)
        // Unrelated repo that must NOT be touched.
        try seedBareFile(org: "Other", repo: "tools", relPath: "objects/info.idx", bytes: 128)
        try seedWorktreeFile(org: "Other", repo: "tools", pr: 9, relPath: "c.txt", bytes: 128)

        let widgetsBare = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "Acme/widgets")
        let widgetsWorktreeRoot = WorktreeManager.worktreesRootForRepo(baseDir: baseDir, repo: "Acme/widgets")
        let toolsBare = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "Other/tools")
        let toolsWorktreeRoot = WorktreeManager.worktreesRootForRepo(baseDir: baseDir, repo: "Other/tools")

        // Sanity: everything exists pre-eviction.
        assertThat(FileManager.default.fileExists(atPath: widgetsBare.path)).isTrue()
        assertThat(FileManager.default.fileExists(atPath: widgetsWorktreeRoot.path)).isTrue()
        assertThat(FileManager.default.fileExists(atPath: toolsBare.path)).isTrue()
        assertThat(FileManager.default.fileExists(atPath: toolsWorktreeRoot.path)).isTrue()

        try WorktreeManager.evictAllForRepo("Acme/widgets", baseDir: baseDir, isBusy: { _ in false })

        // Targeted repo: gone.
        assertThat(FileManager.default.fileExists(atPath: widgetsBare.path)).isFalse()
        assertThat(FileManager.default.fileExists(atPath: widgetsWorktreeRoot.path)).isFalse()

        // Unrelated repo: untouched.
        assertThat(FileManager.default.fileExists(atPath: toolsBare.path)).isTrue()
        assertThat(FileManager.default.fileExists(atPath: toolsWorktreeRoot.path)).isTrue()
    }

    func testEvictAllForRepoIsIdempotentOnMissingDirs() throws {
        // Nothing on disk for this repo. Should not throw.
        try WorktreeManager.evictAllForRepo("Acme/never-existed", baseDir: baseDir, isBusy: { _ in false })
    }

    func testEvictAllForRepoOnlyBareNoWorktrees() throws {
        try seedBareFile(org: "Acme", repo: "bare-only", relPath: "objects/info.idx", bytes: 64)
        let bare = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "Acme/bare-only")
        assertThat(FileManager.default.fileExists(atPath: bare.path)).isTrue()
        try WorktreeManager.evictAllForRepo("Acme/bare-only", baseDir: baseDir, isBusy: { _ in false })
        assertThat(FileManager.default.fileExists(atPath: bare.path)).isFalse()
    }

    func testEvictAllForRepoThrowsWhenReviewIsRunningOnSameRepo() throws {
        try seedBareFile(org: "Acme", repo: "busy", relPath: "objects/info.idx", bytes: 64)
        let bare = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "Acme/busy")
        assertThat(FileManager.default.fileExists(atPath: bare.path)).isTrue()

        // Inject "is busy" closure that flags the targeted repo.
        var thrown: WorktreeError?
        do {
            try WorktreeManager.evictAllForRepo(
                "Acme/busy",
                baseDir: baseDir,
                isBusy: { repo in repo == "Acme/busy" }
            )
            XCTFail("expected throw")
        } catch let error as WorktreeError {
            thrown = error
        }

        assertThat(thrown).isNotNil()
        if case .cannotEvictWhileReviewRunning(let r) = thrown! {
            assertThat(r).isEqualTo("Acme/busy")
        } else {
            XCTFail("expected cannotEvictWhileReviewRunning, got \(String(describing: thrown))")
        }

        // And the cache was NOT touched.
        assertThat(FileManager.default.fileExists(atPath: bare.path)).isTrue()
    }

    func testEvictAllForRepoSucceedsWhenReviewIsRunningOnDifferentRepo() throws {
        try seedBareFile(org: "Acme", repo: "target", relPath: "objects/info.idx", bytes: 64)
        let bare = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "Acme/target")
        assertThat(FileManager.default.fileExists(atPath: bare.path)).isTrue()

        // Closure says "busy", but only for a different repo.
        try WorktreeManager.evictAllForRepo(
            "Acme/target",
            baseDir: baseDir,
            isBusy: { repo in repo == "Other/some-other" }
        )

        assertThat(FileManager.default.fileExists(atPath: bare.path)).isFalse()
    }

    // MARK: - Fixture helpers

    /// Writes a regular file of `bytes` zero bytes at
    /// `<baseDir>/repos/<org>/<repo>.git/<relPath>`. Creates intermediate
    /// directories so callers can specify nested paths like
    /// `objects/pack/pack-foo.idx`.
    private func seedBareFile(org: String, repo: String, relPath: String, bytes: Int) throws {
        let bareDir = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "\(org)/\(repo)")
        let target = bareDir.appendingPathComponent(relPath)
        try ensureParent(of: target)
        try writeZeros(at: target, bytes: bytes)
    }

    /// Writes a regular file at
    /// `<baseDir>/worktrees/<org>/<repo>/<pr>/<relPath>`.
    private func seedWorktreeFile(org: String, repo: String, pr: Int, relPath: String, bytes: Int) throws {
        let worktreeDir = WorktreeManager.worktreeURL(baseDir: baseDir, repo: "\(org)/\(repo)", prNumber: pr)
        let target = worktreeDir.appendingPathComponent(relPath)
        try ensureParent(of: target)
        try writeZeros(at: target, bytes: bytes)
    }

    private func ensureParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    /// Allocates a file of exactly `bytes` zero bytes. We write a `Data` blob
    /// rather than truncating to size so the file occupies real allocated
    /// blocks and `totalFileAllocatedSize` returns a meaningful number on APFS.
    private func writeZeros(at url: URL, bytes: Int) throws {
        let data = Data(count: bytes)
        try data.write(to: url)
    }
}

// MARK: - assertJ-style fluent assertions
//
// Tiny, self-contained shim so the slice 17 tests follow the user's global
// "always assertJ instead of jupiter" rule without dragging a third-party
// dependency into the project. Covers exactly the assertions used here:
// `isTrue`, `isFalse`, `isEqualTo`, `isNotNil`, `isEmpty`. Failures route
// through `XCTFail` so Xcode highlights the right line.

private struct FluentAssertion<T> {
    let value: T
    let file: StaticString
    let line: UInt
}

private func assertThat<T>(_ value: T, file: StaticString = #filePath, line: UInt = #line) -> FluentAssertion<T> {
    FluentAssertion(value: value, file: file, line: line)
}

extension FluentAssertion where T == Bool {
    func isTrue() {
        if !value { XCTFail("expected true, got false", file: file, line: line) }
    }
    func isFalse() {
        if value { XCTFail("expected false, got true", file: file, line: line) }
    }
}

extension FluentAssertion where T: Equatable {
    func isEqualTo(_ expected: T) {
        if value != expected {
            XCTFail("expected \(expected), got \(value)", file: file, line: line)
        }
    }
}

extension FluentAssertion {
    func isNotNil() {
        // Mirror checks via Optional reflection: T may be Optional<U>.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional && mirror.children.isEmpty {
            XCTFail("expected non-nil, got nil", file: file, line: line)
        }
    }
}

extension FluentAssertion where T: Collection {
    func isEmpty() {
        if !value.isEmpty {
            XCTFail("expected empty collection, got \(value.count) elements", file: file, line: line)
        }
    }
}
