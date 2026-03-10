//
//  WorktreeManager.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Owns disk layout for review worktrees:
//
//    ~/.work-homepage/repos/<org>/<repo>.git           — bare clone, shared
//    ~/.work-homepage/worktrees/<org>/<repo>/<pr#>/    — per-PR worktree
//
//  First time per repo: bare clone (SSH if `~/.ssh/id_*` exists, HTTPS otherwise).
//  Subsequent times: fetch from origin in the bare clone, then either add a new
//  worktree or fast-forward the existing one to the requested SHA.
//
//  Note on the public `prepare` signature: the slice 07 spec sketches it as
//  `prepare(repo:branch:sha:)`, but the worktree path is keyed on the PR number
//  (`worktrees/<org>/<repo>/<pr#>/`), so PR number has to be an input. We take
//  it explicitly here. The orchestrator (which knows the PR number) calls this
//  directly.
//
//  Every git invocation goes through `Process` with an absolute path resolved
//  via `BinaryResolver`. No `/bin/zsh -lc` shell calls — those would inherit a
//  GUI app's empty PATH and fail silently in surprising ways. The base directory
//  and `git` binary path are both injectable so tests can exercise the full
//  flow against a temp HOME and `/usr/bin/git`.
//

import Foundation

// MARK: - Errors

/// Typed error surface for worktree operations. Carries captured stderr where
/// available so failures are debuggable in the modal without dropping into the
/// console.
enum WorktreeError: Error, Equatable {
    /// `git` (or another required binary) couldn't be located via the resolver.
    case binaryNotFound(String)
    /// `git clone --bare` failed (network down, repo doesn't exist, etc.).
    case cloneFailed(stderr: String)
    /// `git fetch` against the bare clone failed.
    case fetchFailed(stderr: String)
    /// `git worktree add` failed (e.g. ref doesn't exist, path collision the
    /// manager couldn't recover from).
    case worktreeAddFailed(stderr: String)
    /// Branch can't be resolved as `origin/<branch>` after fetch.
    case branchNotFound(String)
    /// `git reset --hard` failed when advancing an existing worktree.
    case resetFailed(stderr: String)
    /// FileManager I/O failed (e.g. couldn't create base dirs).
    case ioFailed(String)
    /// Slice 17: refused to wipe caches because a review is still running
    /// against the same repo. Carries the repo full name so the UI can render
    /// a meaningful message.
    case cannotEvictWhileReviewRunning(String)
}

// MARK: - WorktreeManager

struct WorktreeManager {

    // MARK: - Public API (production defaults)

    /// Ensures the bare clone exists, fetches the latest, and returns a worktree
    /// rooted at `~/.work-homepage/worktrees/<org>/<repo>/<prNumber>/` checked out
    /// at the head of `branch` (we resolve via `origin/<branch>` rather than the
    /// raw SHA so future re-prepares pick up new commits to the branch).
    /// `repo` is `<org>/<repo>` (e.g. `Ala-com/work-homepage`).
    static func prepare(repo: String, branch: String, sha: String, prNumber: Int) async throws -> URL {
        try await prepare(
            repo: repo,
            branch: branch,
            sha: sha,
            prNumber: prNumber,
            baseDir: defaultBaseDir(),
            gitURL: try resolveGit()
        )
    }

    /// Removes the worktree directory for the given PR but keeps the bare clone
    /// around for the next review of any PR in this repo. Slice 17 wires a UI
    /// for this; slice 07 only needs the API surface and tests.
    static func evict(repo: String, prNumber: Int) throws {
        try evict(
            repo: repo,
            prNumber: prNumber,
            baseDir: defaultBaseDir(),
            gitURL: try resolveGit()
        )
    }

    // MARK: - Testable internal API
    //
    // These accept the base directory and the `git` binary URL so tests can run
    // against a temp HOME with `/usr/bin/git` directly, no env juggling required.

    static func prepare(
        repo: String,
        branch: String,
        sha: String,
        prNumber: Int,
        baseDir: URL,
        gitURL: URL
    ) async throws -> URL {
        let bareDir = bareCloneURL(baseDir: baseDir, repo: repo)
        let worktreeDir = worktreeURL(baseDir: baseDir, repo: repo, prNumber: prNumber)

        try ensureParentDirs(for: bareDir)
        try ensureParentDirs(for: worktreeDir)

        // Step 1: ensure the bare clone exists.
        if !FileManager.default.fileExists(atPath: bareDir.path) {
            try await cloneBare(repo: repo, into: bareDir, gitURL: gitURL)
        } else {
            // Fetch latest refs so `origin/<branch>` resolves to the current head.
            try await fetchBare(bareDir: bareDir, gitURL: gitURL)
        }

        // Step 2: create or refresh the worktree.
        if FileManager.default.fileExists(atPath: worktreeDir.path) {
            // Pre-existing worktree (re-review of the same PR). The bare fetch
            // above already moved `origin/<branch>` to the latest head; reset
            // the worktree's HEAD to it so we always review the current state.
            try await resetHardInWorktree(worktreeDir: worktreeDir, branch: branch, gitURL: gitURL)
        } else {
            try await addWorktree(
                bareDir: bareDir,
                worktreeDir: worktreeDir,
                branch: branch,
                gitURL: gitURL
            )
        }

        return worktreeDir
    }

    static func evict(
        repo: String,
        prNumber: Int,
        baseDir: URL,
        gitURL: URL
    ) throws {
        let bareDir = bareCloneURL(baseDir: baseDir, repo: repo)
        let worktreeDir = worktreeURL(baseDir: baseDir, repo: repo, prNumber: prNumber)

        // `git worktree remove` is the clean way; if the worktree dir is gone
        // already we still want to scrub `.git/worktrees/<name>` from the bare
        // clone, which `git worktree prune` handles.
        if FileManager.default.fileExists(atPath: worktreeDir.path) {
            // --force in case the user has dirty files; the worktree is meant
            // to be ephemeral.
            _ = runProcessSync(
                executable: gitURL,
                arguments: ["-C", bareDir.path, "worktree", "remove", "--force", worktreeDir.path]
            )
        }
        if FileManager.default.fileExists(atPath: bareDir.path) {
            _ = runProcessSync(
                executable: gitURL,
                arguments: ["-C", bareDir.path, "worktree", "prune"]
            )
        }
        // Last resort: if `git worktree remove` left the dir behind (or never
        // ran because the bare clone was missing), nuke it from the filesystem.
        if FileManager.default.fileExists(atPath: worktreeDir.path) {
            try FileManager.default.removeItem(at: worktreeDir)
        }
    }

    // MARK: - URL layout helpers

    static func defaultBaseDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".work-homepage", isDirectory: true)
    }

    static func bareCloneURL(baseDir: URL, repo: String) -> URL {
        // `repo` is `<org>/<name>`. Layout: <baseDir>/repos/<org>/<name>.git
        baseDir
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repo + ".git", isDirectory: true)
    }

    static func worktreeURL(baseDir: URL, repo: String, prNumber: Int) -> URL {
        // <baseDir>/worktrees/<org>/<name>/<pr#>
        baseDir
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(String(prNumber), isDirectory: true)
    }

    /// Picks SSH if any `~/.ssh/id_*` private key exists, HTTPS otherwise.
    /// Re-evaluated each call — the probe is one directory listing and adding
    /// or removing keys between runs is rare enough not to warrant caching.
    static func cloneURL(for repo: String) -> String {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) {
            let hasKey = entries.contains { name in
                name.hasPrefix("id_") && !name.hasSuffix(".pub")
            }
            if hasKey {
                return "git@github.com:\(repo).git"
            }
        }
        return "https://github.com/\(repo).git"
    }

    // MARK: - Internals

    private static func resolveGit() throws -> URL {
        guard let url = BinaryResolver.resolve(.git) else {
            throw WorktreeError.binaryNotFound("git")
        }
        return url
    }

    private static func ensureParentDirs(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw WorktreeError.ioFailed("Could not create \(parent.path): \(error.localizedDescription)")
        }
    }

    private static func cloneBare(repo: String, into bareDir: URL, gitURL: URL) async throws {
        let url = cloneURL(for: repo)
        let result = await runProcess(
            executable: gitURL,
            arguments: ["clone", "--bare", url, bareDir.path]
        )
        if result.exitCode != 0 {
            // Clean up the partial clone so the next attempt starts fresh.
            try? FileManager.default.removeItem(at: bareDir)
            throw WorktreeError.cloneFailed(stderr: result.stderr)
        }
        try await configureBareRefspec(bareDir: bareDir, gitURL: gitURL)
    }

    /// Test-friendly variant: clone from an arbitrary URL (typically a local
    /// `git init --bare` fixture) into the same layout. Production code calls
    /// `cloneBare(repo:into:gitURL:)` which builds the URL via SSH/HTTPS rules.
    static func cloneBareFromURL(
        sourceURL: String,
        repo: String,
        baseDir: URL,
        gitURL: URL
    ) async throws -> URL {
        let bareDir = bareCloneURL(baseDir: baseDir, repo: repo)
        try ensureParentDirs(for: bareDir)
        let result = await runProcess(
            executable: gitURL,
            arguments: ["clone", "--bare", sourceURL, bareDir.path]
        )
        if result.exitCode != 0 {
            try? FileManager.default.removeItem(at: bareDir)
            throw WorktreeError.cloneFailed(stderr: result.stderr)
        }
        try await configureBareRefspec(bareDir: bareDir, gitURL: gitURL)
        return bareDir
    }

    /// `git clone --bare` does not set a fetch refspec by default, which means
    /// `git fetch origin` won't update `refs/remotes/origin/*` and
    /// `origin/<branch>` won't resolve. Configure the standard refspec
    /// post-clone so the rest of the pipeline can use `origin/<branch>` as the
    /// canonical "what the upstream currently says about this branch" ref.
    /// Idempotent: re-setting the same value is a no-op.
    private static func configureBareRefspec(bareDir: URL, gitURL: URL) async throws {
        let result = await runProcess(
            executable: gitURL,
            arguments: [
                "-C", bareDir.path,
                "config", "remote.origin.fetch",
                "+refs/heads/*:refs/remotes/origin/*"
            ]
        )
        if result.exitCode != 0 {
            throw WorktreeError.fetchFailed(stderr: "configure refspec failed: \(result.stderr)")
        }
        // Pull the refs into refs/remotes/origin/* immediately so the first
        // `worktree add origin/<branch>` succeeds without a separate fetch
        // pass at the call site.
        let fetch = await runProcess(
            executable: gitURL,
            arguments: ["-C", bareDir.path, "fetch", "origin", "--prune"]
        )
        if fetch.exitCode != 0 {
            throw WorktreeError.fetchFailed(stderr: fetch.stderr)
        }
    }

    private static func fetchBare(bareDir: URL, gitURL: URL) async throws {
        let result = await runProcess(
            executable: gitURL,
            arguments: ["-C", bareDir.path, "fetch", "origin", "--prune"]
        )
        if result.exitCode != 0 {
            throw WorktreeError.fetchFailed(stderr: result.stderr)
        }
    }

    private static func addWorktree(
        bareDir: URL,
        worktreeDir: URL,
        branch: String,
        gitURL: URL
    ) async throws {
        // `git worktree add --detach <path> origin/<branch>` checks out a
        // detached HEAD at the remote ref. That's what we want — slice 07 is
        // read-only review territory; we never push from a worktree.
        let result = await runProcess(
            executable: gitURL,
            arguments: [
                "-C", bareDir.path,
                "worktree", "add",
                "--detach",
                worktreeDir.path,
                "origin/" + branch
            ]
        )
        if result.exitCode != 0 {
            // The most common failure mode is "fatal: invalid reference" when
            // the branch doesn't exist on the remote. Distinguish that for the
            // UI.
            let lower = result.stderr.lowercased()
            if lower.contains("invalid reference") || lower.contains("not a valid ref") || lower.contains("unknown revision") {
                throw WorktreeError.branchNotFound(branch)
            }
            throw WorktreeError.worktreeAddFailed(stderr: result.stderr)
        }
    }

    private static func fetchBranchInWorktree(
        worktreeDir: URL,
        branch: String,
        gitURL: URL
    ) async throws {
        let result = await runProcess(
            executable: gitURL,
            arguments: ["-C", worktreeDir.path, "fetch", "origin", branch]
        )
        if result.exitCode != 0 {
            throw WorktreeError.fetchFailed(stderr: result.stderr)
        }
    }

    private static func resetHardInWorktree(
        worktreeDir: URL,
        branch: String,
        gitURL: URL
    ) async throws {
        let result = await runProcess(
            executable: gitURL,
            arguments: ["-C", worktreeDir.path, "reset", "--hard", "origin/" + branch]
        )
        if result.exitCode != 0 {
            throw WorktreeError.resetFailed(stderr: result.stderr)
        }
    }

    // MARK: - Process plumbing

    /// Output of a one-shot child process spawn.
    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Async wrapper around `Process` that captures stdout + stderr and waits
    /// for exit. Git operations are bounded, so we don't need streaming here —
    /// the modal can show step-level progress (cloning, fetching, adding
    /// worktree, ...) without surfacing every byte.
    @discardableResult
    static func runProcess(executable: URL, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            // Hop off the main actor: `Process.run` + `waitUntilExit` block,
            // which would freeze the UI if called inline.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runProcessSync(executable: executable, arguments: arguments)
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous variant. Used by `evict` (no async benefit) and as the
    /// implementation of `runProcess`. We drain pipes via
    /// `readDataToEndOfFile()` after exit because git outputs aren't huge and
    /// we don't need streaming.
    @discardableResult
    static func runProcessSync(executable: URL, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Minimal env. Git needs HOME for SSH/HTTPS credential helpers; PATH so
        // it can find `ssh` if it shells out for SSH cloning.
        var env: [String: String] = [:]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        if let term = ProcessInfo.processInfo.environment["TERM"] { env["TERM"] = term }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "Failed to launch \(executable.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }
}

// MARK: - Slice 17: Disk usage + per-repo evict
//
// `diskUsage()` and `usagePerRepo()` walk the on-disk caches under
// `~/.work-homepage/repos` and `~/.work-homepage/worktrees` and sum file sizes
// via `FileManager`'s directory enumerator. There's no `du` shellout — we want
// portable, sandbox-friendly I/O, and 200MB-class repos enumerate in well under
// a second on an SSD. The work is still I/O-bound, so the production callers
// (Settings) wrap these in `Task.detached` and explicitly drive recomputation
// via a "Refresh" button rather than re-running per-render.
//
// The path resolution is layered: the no-arg public entrypoints read the
// production `~/.work-homepage` HOME, and parameterized internal entrypoints
// take a `baseDir: URL` so tests can build a temp filesystem and exercise the
// real walker. This mirrors the `prepare(...:baseDir:gitURL:)` pattern from
// Slice 07.
//
// `evictAllForRepo` is the destructive operation — it nukes both the bare
// clone and the entire `worktrees/<org>/<repo>/` subtree. To avoid yanking the
// disk out from under a running review, the public entrypoint refuses if the
// `ReviewOrchestrator` singleton currently has a `running` review against the
// same repo. Tests inject a custom "is busy" closure to drive that branch
// without mutating the shared singleton (which lives on `@MainActor`).

extension WorktreeManager {

    // MARK: - RepoUsage

    /// Per-repo cache footprint. `bareBytes` is the bare clone, `worktreeBytes`
    /// is the sum across all live PR worktrees for that repo.
    struct RepoUsage: Equatable {
        let repo: String              // "<org>/<repo>"
        let bareBytes: Int64
        let worktreeBytes: Int64
        var totalBytes: Int64 { bareBytes + worktreeBytes }
    }

    // MARK: - Public API (production defaults)

    /// Total bytes used by all bare clones + worktrees under the production
    /// `~/.work-homepage` base directory. Synchronous and I/O-heavy — call from
    /// a detached task.
    static func diskUsage() -> Int64 {
        diskUsage(baseDir: defaultBaseDir())
    }

    /// Per-repo breakdown sorted by `totalBytes` descending. Synchronous and
    /// I/O-heavy — call from a detached task.
    static func usagePerRepo() -> [RepoUsage] {
        usagePerRepo(baseDir: defaultBaseDir())
    }

    /// Removes both the bare clone and all worktrees for the given repo.
    /// Throws `WorktreeError.cannotEvictWhileReviewRunning` if a review is in
    /// flight against this repo. Production reads `ReviewOrchestrator.shared`
    /// for the busy check; tests inject their own predicate.
    ///
    /// Note: this entrypoint must be called from the main actor because the
    /// busy check reads the `@MainActor`-isolated orchestrator singleton. Off
    /// the main thread, callers should snapshot the busy-state on the main
    /// actor and use the `isBusy:` overload.
    @MainActor
    static func evictAllForRepo(_ repo: String) throws {
        try evictAllForRepo(
            repo,
            baseDir: defaultBaseDir(),
            isBusy: { Self.defaultIsBusy(repo: $0) }
        )
    }

    // MARK: - Testable internal API

    /// `diskUsage` parameterized by base dir. Walks `<baseDir>/repos` and
    /// `<baseDir>/worktrees` and sums per-file allocated sizes. Missing dirs
    /// contribute 0.
    static func diskUsage(baseDir: URL) -> Int64 {
        let repos = baseDir.appendingPathComponent("repos", isDirectory: true)
        let worktrees = baseDir.appendingPathComponent("worktrees", isDirectory: true)
        return directorySize(at: repos) + directorySize(at: worktrees)
    }

    /// Per-repo breakdown parameterized by base dir. Walks two parallel
    /// directory trees:
    ///
    ///   - `<baseDir>/repos/<org>/<repo>.git` → `bareBytes`
    ///   - `<baseDir>/worktrees/<org>/<repo>/<pr#>/...` → `worktreeBytes`
    ///
    /// The set of repos is the union of repos seen in either tree. Sorted by
    /// `totalBytes` descending so the largest spenders surface first.
    static func usagePerRepo(baseDir: URL) -> [RepoUsage] {
        var bareByRepo: [String: Int64] = [:]
        var worktreeByRepo: [String: Int64] = [:]

        let reposRoot = baseDir.appendingPathComponent("repos", isDirectory: true)
        for org in immediateSubdirectories(of: reposRoot) {
            let orgURL = reposRoot.appendingPathComponent(org, isDirectory: true)
            for entry in immediateSubdirectories(of: orgURL) {
                guard entry.hasSuffix(".git") else { continue }
                let repoName = String(entry.dropLast(".git".count))
                let key = "\(org)/\(repoName)"
                let url = orgURL.appendingPathComponent(entry, isDirectory: true)
                bareByRepo[key, default: 0] += directorySize(at: url)
            }
        }

        let worktreesRoot = baseDir.appendingPathComponent("worktrees", isDirectory: true)
        for org in immediateSubdirectories(of: worktreesRoot) {
            let orgURL = worktreesRoot.appendingPathComponent(org, isDirectory: true)
            for repoName in immediateSubdirectories(of: orgURL) {
                let key = "\(org)/\(repoName)"
                let url = orgURL.appendingPathComponent(repoName, isDirectory: true)
                worktreeByRepo[key, default: 0] += directorySize(at: url)
            }
        }

        let allKeys = Set(bareByRepo.keys).union(worktreeByRepo.keys)
        let usages = allKeys.map { key in
            RepoUsage(
                repo: key,
                bareBytes: bareByRepo[key] ?? 0,
                worktreeBytes: worktreeByRepo[key] ?? 0
            )
        }
        return usages.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.repo < rhs.repo
        }
    }

    /// Test seam for `evictAllForRepo`. The `isBusy` closure receives the repo
    /// full name and returns `true` if eviction must be refused. Production
    /// passes a closure that reads `ReviewOrchestrator.shared.current`.
    static func evictAllForRepo(
        _ repo: String,
        baseDir: URL,
        isBusy: (String) -> Bool
    ) throws {
        if isBusy(repo) {
            throw WorktreeError.cannotEvictWhileReviewRunning(repo)
        }
        let bareDir = bareCloneURL(baseDir: baseDir, repo: repo)
        let worktreesDir = worktreesRootForRepo(baseDir: baseDir, repo: repo)
        let fm = FileManager.default
        if fm.fileExists(atPath: bareDir.path) {
            do {
                try fm.removeItem(at: bareDir)
            } catch {
                throw WorktreeError.ioFailed("Could not remove bare clone at \(bareDir.path): \(error.localizedDescription)")
            }
        }
        if fm.fileExists(atPath: worktreesDir.path) {
            do {
                try fm.removeItem(at: worktreesDir)
            } catch {
                throw WorktreeError.ioFailed("Could not remove worktrees at \(worktreesDir.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Layout helpers

    /// `<baseDir>/worktrees/<org>/<name>` — the per-repo worktree root that
    /// holds all `<pr#>` subdirectories. Used by `evictAllForRepo` to take
    /// down the entire subtree in one `removeItem` call.
    static func worktreesRootForRepo(baseDir: URL, repo: String) -> URL {
        baseDir
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }

    // MARK: - Internals

    /// Production "is this repo currently being reviewed?" predicate. The
    /// orchestrator singleton lives on `@MainActor`; the public
    /// `evictAllForRepo(_:)` is itself `@MainActor`-isolated, so this
    /// `assumeIsolated` is safe — Swift just can't see through the closure.
    private static func defaultIsBusy(repo: String) -> Bool {
        MainActor.assumeIsolated {
            let orch = ReviewOrchestrator.shared
            return orch.current?.state == "running" && orch.current?.repoFullName == repo
        }
    }

    /// Returns the total size in bytes of every regular file reachable from
    /// `url` via a recursive directory enumerator. Missing or unreadable paths
    /// contribute 0 — this is a best-effort measurement, not a correctness
    /// boundary.
    ///
    /// We prefer `URLResourceValues.totalFileAllocatedSize` (allocated blocks
    /// on disk, including any sparse-file slack) and fall back to
    /// `fileSize` when the allocated size isn't available — same shape as the
    /// AppKit Finder reports.
    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            // Skip non-regular files (directories, symlinks). Their own bytes
            // are negligible and the enumerator will descend into directories
            // separately.
            if values.isRegularFile != true { continue }
            if let allocated = values.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let allocated = values.fileAllocatedSize {
                total += Int64(allocated)
            } else if let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Lists immediate subdirectory names of `url`, ignoring dotfiles and any
    /// non-directory entries. Returns `[]` if the path doesn't exist or isn't
    /// readable. We list names rather than URLs so callers can pattern-match
    /// `.git` suffixes cheaply.
    private static func immediateSubdirectories(of url: URL) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { entryURL in
            let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return entryURL.lastPathComponent
        }
    }
}
