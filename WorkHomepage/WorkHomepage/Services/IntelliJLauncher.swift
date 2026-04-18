//
//  IntelliJLauncher.swift
//  WorkHomepage
//
//  Slice 09 — IntelliJ launcher.
//
//  Spawns IntelliJ IDEA's `idea` CLI with `--line <line> <worktree>/<file>` so
//  clicking a finding in the review modal jumps the user straight to the right
//  file:line, with the worktree (not the user's main repo checkout) as the
//  open project. The launcher resolves the absolute path to `idea` via
//  `BinaryResolver`, because GUI macOS apps don't inherit shell PATH.
//
//  Two entry points:
//
//  - `open(worktree:file:line:)` is the strict, throws-on-error variant. Used
//    by tests and by callers that want to handle the failure modes themselves.
//
//  - `openWithFallback(worktree:file:line:)` is the UI-friendly variant: when
//    `idea` is missing it falls back to `NSWorkspace.shared.open(...)` so the
//    user still gets the file open (just without the line jump), and reports
//    the outcome via a `FallbackResult` enum so the sheet can surface a toast.
//
//  Process spawning detaches — we just want to launch IntelliJ; we don't wait
//  for the IDE to exit.
//

import Foundation
import AppKit

enum IntelliJLauncher {

    enum LaunchError: Error, Equatable {
        /// `BinaryResolver.resolve(.idea)` returned nil. Caller should fall
        /// back to `NSWorkspace.shared.open(...)` (no line-jump) and surface a
        /// non-blocking toast.
        case ideaCLINotFound
        /// The file path we were asked to open does not exist inside the
        /// worktree. Usually means claude hallucinated a path or the worktree
        /// has drifted from the SHA the review was produced against.
        case fileNotFoundInWorktree(URL)
    }

    /// Surface returned by the UI-friendly entry point. The sheet maps each
    /// case to a different feedback affordance (silent / toast / alert).
    enum FallbackResult: Equatable {
        case openedInIntelliJ
        /// `idea` CLI missing → `NSWorkspace.shared.open` succeeded, no line
        /// jump. Caller should toast "idea CLI not found — opened without
        /// line jump".
        case openedWithoutLineJump
        case fileMissing(URL)
        case failed(String)
    }

    // MARK: - Public API (production defaults)

    /// Launches IntelliJ at the worktree, jumping to file:line. Throws if the
    /// `idea` CLI is missing (caller decides whether to fall back) or if the
    /// file doesn't exist inside the worktree.
    static func open(worktree: URL, file: String, line: Int) throws {
        try open(
            worktree: worktree,
            file: file,
            line: line,
            resolveIdea: { BinaryResolver.resolve(.idea) },
            spawn: defaultSpawn
        )
    }

    /// UI-friendly entry point. Tries `open(...)`; on `.ideaCLINotFound`,
    /// falls back to `NSWorkspace.shared.open(...)` so the file at least
    /// surfaces in IntelliJ (or whatever the user has bound to source files)
    /// without the line jump. Returns a `FallbackResult` so the sheet can
    /// surface the right feedback.
    static func openWithFallback(worktree: URL, file: String, line: Int) -> FallbackResult {
        openWithFallback(
            worktree: worktree,
            file: file,
            line: line,
            resolveIdea: { BinaryResolver.resolve(.idea) },
            spawn: defaultSpawn,
            workspaceOpen: { url in NSWorkspace.shared.open(url) }
        )
    }

    // MARK: - Testable internal API
    //
    // The resolver and the spawn are injected so tests can drive both branches
    // (cli-missing, cli-present-but-file-missing) without touching the real
    // BinaryResolver cache or actually launching IntelliJ.

    static func open(
        worktree: URL,
        file: String,
        line: Int,
        resolveIdea: () -> URL?,
        spawn: (URL, [String]) throws -> Void
    ) throws {
        guard let ideaURL = resolveIdea() else {
            throw LaunchError.ideaCLINotFound
        }
        let fileURL = worktree.appending(path: file)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            throw LaunchError.fileNotFoundInWorktree(fileURL)
        }
        // Pass the worktree directory as an explicit project argument
        // BEFORE the file. Without this, IntelliJ routes the file to the
        // active project window (e.g. the user's main checkout opened in
        // another window) rather than recognising the worktree's `.idea/`
        // as a separate project. With the project arg, IntelliJ opens (or
        // focuses) the worktree project and then navigates to file:line.
        try spawn(ideaURL, [worktree.path, "--line", "\(line)", fileURL.path])
    }

    static func openWithFallback(
        worktree: URL,
        file: String,
        line: Int,
        resolveIdea: () -> URL?,
        spawn: (URL, [String]) throws -> Void,
        workspaceOpen: (URL) -> Bool
    ) -> FallbackResult {
        do {
            try open(worktree: worktree, file: file, line: line, resolveIdea: resolveIdea, spawn: spawn)
            return .openedInIntelliJ
        } catch let error as LaunchError {
            switch error {
            case .ideaCLINotFound:
                let fileURL = worktree.appending(path: file)
                // The fallback predates the file existence check that lives
                // inside `open(...)`, so we re-check here to keep the UI
                // surface honest: a missing file in the worktree is a
                // missing file regardless of whether `idea` is installed.
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    return .fileMissing(fileURL)
                }
                if workspaceOpen(fileURL) {
                    return .openedWithoutLineJump
                }
                return .failed("NSWorkspace could not open \(fileURL.path)")
            case .fileNotFoundInWorktree(let url):
                return .fileMissing(url)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Default spawn

    /// Default spawn: launches `idea` in a detached `Process`. We don't wait
    /// for exit — IntelliJ stays running long after this call returns.
    private static func defaultSpawn(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Minimal env so `idea` can find supporting tools if it shells out.
        // Mirrors `WorktreeManager.runProcessSync`'s minimal env shape.
        var env: [String: String] = [:]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        process.environment = env
        try process.run()
        // Intentionally do NOT call `waitUntilExit` — we want to detach.
    }
}
