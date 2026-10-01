//
//  Session.swift
//  Foreword
//
//  Slice 04: Codable shape for an active Claude Code session.
//  Mirrors what `refresh-sessions.py` writes to `claude-sessions.js`.
//

import Foundation

struct Session: Codable, Identifiable, Hashable {
    let pid: Int
    let sessionId: String
    let cwd: String
    /// Unix epoch milliseconds.
    let startedAt: Int
    /// "cli" or e.g. "vscode". Anything other than "cli" is rendered as "VS Code".
    let entrypoint: String
    let name: String
    let lastPrompt: String?

    var id: String { sessionId.isEmpty ? "\(pid)-\(startedAt)" : sessionId }
}
