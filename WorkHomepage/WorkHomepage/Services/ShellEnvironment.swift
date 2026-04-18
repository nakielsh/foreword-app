//
//  ShellEnvironment.swift
//  WorkHomepage
//
//  Captures the user's interactive shell environment so child processes we
//  spawn from this GUI app can see env vars defined in `~/.zshrc` (or
//  `~/.bashrc`, etc.). macOS launches GUI apps via launchd with a minimal
//  env, so vars exported in the user's login shell never reach us — and by
//  extension never reach the child processes we spawn (IntelliJ, gradle
//  daemon, claude CLI). Without this bridge, projects that need
//  `REPO_USER`, `JAVA_HOME`, `ANTHROPIC_API_KEY` etc. fail with cryptic
//  "missing credentials" errors when launched from the app but work fine
//  when launched from a terminal.
//
//  Strategy: run the user's `$SHELL` (default `/bin/zsh`) in interactive +
//  login mode and dump `env`. Parse stdout, cache the result for the rest
//  of the app's lifetime. We pay this startup cost (typically 100–300 ms,
//  longer with heavyweight oh-my-zsh setups) at most once per launch.
//
//  We deliberately swallow stderr — non-interactive `-i` runs of zshrc
//  often emit benign warnings about prompt expansion, missing tty, etc.
//  Those don't affect the env dump on stdout.
//

import Foundation

enum ShellEnvironment {

    private static let lock = NSLock()
    private static var cached: [String: String]?

    /// Returns the captured env on first call, then the cached copy on
    /// every subsequent call. Synchronous and bounded — the underlying
    /// `Process` waits for the shell to exit before parsing.
    static func userInteractiveEnv() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let captured = capture()
        cached = captured
        return captured
    }

    /// Test seam: forget the cached env so the next call re-runs capture.
    /// Not used in production — but unit tests that exercise multiple
    /// fixtures need to reset state between cases.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    /// Test seam: inject a pre-built env map. Useful for tests of code
    /// that consumes `userInteractiveEnv()` without touching the real
    /// shell.
    static func injectForTesting(_ env: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        cached = env
    }

    // MARK: - Capture

    private static func capture() -> [String: String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // `-i -l` so the shell runs both interactive (sources `.zshrc` /
        // `.bashrc`) and login (sources `.zprofile` / `.profile`) init.
        // Most users put exports in `.zshrc`, so `-i` is the load-bearing
        // flag; `-l` is belt-and-suspenders.
        process.arguments = ["-ilc", "env"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        // Inherit our own (minimal) env so the shell at least has HOME and
        // USER. The child shell will overlay its own settings on top.
        process.environment = ProcessInfo.processInfo.environment
        do {
            try process.run()
        } catch {
            return [:]
        }
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return [:] }
        return parse(raw)
    }

    // MARK: - Parse

    /// Parses `KEY=VALUE` lines. Multi-line values (rare but possible —
    /// e.g. PROMPT command containing newlines) merge into the previous
    /// key's value, since `env` doesn't quote them.
    static func parse(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var lastKey: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let eq = line.firstIndex(of: "="), looksLikeKey(String(line[..<eq])) {
                let key = String(line[..<eq])
                let value = String(line[line.index(after: eq)...])
                result[key] = value
                lastKey = key
            } else if let key = lastKey {
                // Continuation of the previous value (newline-bearing).
                result[key, default: ""] += "\n" + line
            }
        }
        return result
    }

    /// Env-var keys are letters/digits/underscore and don't start with a
    /// digit. Filters out lines like `total 256` or stray prompt output
    /// that the shell may have written before `env` ran.
    private static func looksLikeKey(_ candidate: String) -> Bool {
        guard let first = candidate.unicodeScalars.first else { return false }
        if !(CharacterSet.letters.contains(first) || first == "_") { return false }
        for scalar in candidate.unicodeScalars {
            if !(CharacterSet.alphanumerics.contains(scalar) || scalar == "_") {
                return false
            }
        }
        return true
    }
}
