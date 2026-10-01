//
//  SessionsReader.swift
//  Foreword
//
//  Slice 04: native replacement for `refresh-sessions.py`.
//
//  Reads `~/.claude/sessions/*.json`, drops sessions whose PID is no longer
//  alive, joins each with the most recent user prompt for that session in
//  `~/.claude/history.jsonl`, sorts newest-first, and returns the result.
//
//  On-demand only — there is no polling here. Call sites invoke this from
//  the global Refresh button on the Sessions tab.
//

import Foundation
import Darwin

enum SessionsReader {
    /// Default path: `~/.claude/sessions`.
    private static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Default path: `~/.claude/history.jsonl`.
    private static var defaultHistoryFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    /// Public surface used by the Sessions tab.
    static func currentSessions() -> [Session] {
        currentSessions(sessionsDir: defaultSessionsDir, historyFile: defaultHistoryFile)
    }

    /// Test-friendly variant. Mirrors `refresh-sessions.py`:
    ///   - Missing/unreadable directory or history file → silently empty/no-op.
    ///   - Dead PIDs (errno ESRCH) are filtered out; EPERM is treated as alive
    ///     (a process owned by another user, but the PID is still in use).
    ///   - Long prompts are truncated to 200 characters and suffixed with "..."
    ///     to match the existing Python behavior exactly.
    static func currentSessions(sessionsDir: URL, historyFile: URL) -> [Session] {
        let historyBySession = loadHistory(historyFile: historyFile)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var sessions: [Session] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let session = parseSessionFile(at: url, historyBySession: historyBySession) else {
                continue
            }
            sessions.append(session)
        }

        sessions.sort { $0.startedAt > $1.startedAt }
        return sessions
    }

    // MARK: - History

    private static func loadHistory(historyFile: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: historyFile),
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var bySession: [String: String] = [:]
        // Newest entry per session wins — match Python: it overwrites on each line, so
        // the last appearance in the file is the value retained.
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }

            let sid = obj["sessionId"] as? String ?? ""
            let display = obj["display"] as? String ?? ""
            if !sid.isEmpty && !display.isEmpty {
                bySession[sid] = display
            }
        }
        return bySession
    }

    // MARK: - Sessions

    private static func parseSessionFile(at url: URL, historyBySession: [String: String]) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let pid = raw["pid"] as? Int else { return nil }
        guard isPIDAlive(pid) else { return nil }

        let sessionId = raw["sessionId"] as? String ?? ""
        let cwd = raw["cwd"] as? String ?? ""
        let startedAt = (raw["startedAt"] as? Int) ?? 0
        let entrypoint = raw["entrypoint"] as? String ?? "cli"
        let name = raw["name"] as? String ?? ""

        let lastPromptRaw = historyBySession[sessionId] ?? ""
        let lastPrompt = truncatePrompt(lastPromptRaw)

        return Session(
            pid: pid,
            sessionId: sessionId,
            cwd: cwd,
            startedAt: startedAt,
            entrypoint: entrypoint,
            name: name,
            lastPrompt: lastPrompt.isEmpty ? nil : lastPrompt
        )
    }

    /// Truncate to 200 Unicode characters; append "..." when truncated.
    /// Matches Python's `s[:200] + "..."` in `refresh-sessions.py`.
    static func truncatePrompt(_ s: String) -> String {
        if s.count > 200 {
            let head = s.prefix(200)
            return head + "..."
        }
        return s
    }

    // MARK: - PID liveness

    /// `kill(pid, 0)` returns 0 when the process exists and the caller may signal it.
    /// On failure, errno is:
    ///   - ESRCH (no such process) → treat as dead
    ///   - EPERM (no permission)   → process exists but owned by another user → alive
    /// Anything else → conservatively treat as dead so we never show stale entries.
    static func isPIDAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let result = Darwin.kill(pid_t(pid), 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }
}
