//
//  GitHubTokenBootstrap.swift
//  Foreword
//
//  Tries to read the GitHub token from the `gh` CLI on first launch.
//  Absolute paths only — GUI processes don't inherit interactive shell PATH.
//  Path is resolved by `BinaryResolver.resolve(.gh)` so user overrides + cache
//  apply consistently across the app.
//

import Foundation

enum GitHubTokenBootstrap {
    /// Returns a non-empty trimmed token from `gh auth token` if available, else nil.
    static func bootstrap() async -> String? {
        guard let ghURL = BinaryResolver.resolve(.gh) else { return nil }
        guard let token = await runGhAuthToken(at: ghURL), !token.isEmpty else { return nil }
        return token
    }

    private static func runGhAuthToken(at url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = url
            process.arguments = ["auth", "token"]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            // Provide a minimal env. `gh` reads HOME for its config.
            var env: [String: String] = [:]
            if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
            if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }
}
