//
//  GitHubTokenBootstrap.swift
//  WorkHomepage
//
//  Tries to read the GitHub token from the `gh` CLI on first launch.
//  Absolute paths only — GUI processes don't inherit interactive shell PATH.
//

import Foundation

enum GitHubTokenBootstrap {
    /// Probes known absolute install paths for `gh`. No PATH lookup, no shell wrapper.
    private static let candidatePaths: [String] = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh"
    ]

    /// Returns a non-empty trimmed token from `gh auth token` if available, else nil.
    static func bootstrap() async -> String? {
        for path in candidatePaths {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if let token = await runGhAuthToken(at: path), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func runGhAuthToken(at path: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
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
