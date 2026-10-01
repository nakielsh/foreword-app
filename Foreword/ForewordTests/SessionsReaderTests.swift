//
//  SessionsReaderTests.swift
//  ForewordTests
//
//  Drives SessionsReader against a temp directory so we never touch
//  the real `~/.claude` while tests run.
//

import XCTest
@testable import Foreword

final class SessionsReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SessionsReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func sessionsDir() -> URL {
        let url = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func historyFile() -> URL {
        tempDir.appendingPathComponent("history.jsonl")
    }

    private func writeSession(
        _ filename: String,
        pid: Int,
        sessionId: String,
        cwd: String = "/Users/test/proj",
        startedAt: Int = 1_700_000_000_000,
        entrypoint: String = "cli",
        name: String = ""
    ) throws {
        let payload: [String: Any] = [
            "pid": pid,
            "sessionId": sessionId,
            "cwd": cwd,
            "startedAt": startedAt,
            "entrypoint": entrypoint,
            "name": name
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let url = sessionsDir().appendingPathComponent(filename)
        try data.write(to: url)
    }

    private func writeHistory(_ entries: [(sessionId: String, display: String)]) throws {
        let lines = try entries.map { entry -> String in
            let obj: [String: Any] = ["sessionId": entry.sessionId, "display": entry.display]
            let data = try JSONSerialization.data(withJSONObject: obj)
            return String(data: data, encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(to: historyFile(), atomically: true, encoding: .utf8)
    }

    /// Returns a PID guaranteed to be dead: spawn `/bin/true`, wait for it, return its PID.
    /// (PID values may be reused, but on macOS the kernel doesn't recycle a PID until
    /// it's wrapped — for the test window after this returns, the PID should be free.)
    private func makeDeadPID() throws -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try proc.run()
        proc.waitUntilExit()
        return Int(proc.processIdentifier)
    }

    // MARK: - Tests

    func testEmptyDirectoryReturnsEmpty() {
        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )
        XCTAssertEqual(result, [])
    }

    func testMissingDirectoryReturnsEmpty() {
        // Point at a non-existent path — must not throw.
        let nonExistent = tempDir.appendingPathComponent("does/not/exist")
        let result = SessionsReader.currentSessions(
            sessionsDir: nonExistent,
            historyFile: historyFile()
        )
        XCTAssertEqual(result, [])
    }

    func testValidSessionParsedCorrectly() throws {
        let alivePID = Int(getpid())
        try writeSession("a.json",
                         pid: alivePID,
                         sessionId: "sess-1",
                         cwd: "/Users/me/code",
                         startedAt: 1_700_000_000_000,
                         entrypoint: "cli",
                         name: "main")
        try writeHistory([(sessionId: "sess-1", display: "hello world")])

        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )

        XCTAssertEqual(result.count, 1)
        let s = result[0]
        XCTAssertEqual(s.pid, alivePID)
        XCTAssertEqual(s.sessionId, "sess-1")
        XCTAssertEqual(s.cwd, "/Users/me/code")
        XCTAssertEqual(s.startedAt, 1_700_000_000_000)
        XCTAssertEqual(s.entrypoint, "cli")
        XCTAssertEqual(s.name, "main")
        XCTAssertEqual(s.lastPrompt, "hello world")
    }

    func testDeadPIDFiltered() throws {
        let alivePID = Int(getpid())
        let deadPID = try makeDeadPID()

        try writeSession("alive.json",
                         pid: alivePID,
                         sessionId: "alive",
                         startedAt: 1_700_000_000_000)
        try writeSession("dead.json",
                         pid: deadPID,
                         sessionId: "dead",
                         startedAt: 1_700_000_000_001)

        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionId, "alive")
    }

    func testMultipleSessionsSortedNewestFirst() throws {
        let alivePID = Int(getpid())
        try writeSession("old.json",
                         pid: alivePID,
                         sessionId: "old",
                         startedAt: 1_000)
        try writeSession("new.json",
                         pid: alivePID,
                         sessionId: "new",
                         startedAt: 9_000)
        try writeSession("mid.json",
                         pid: alivePID,
                         sessionId: "mid",
                         startedAt: 5_000)

        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )

        XCTAssertEqual(result.map(\.sessionId), ["new", "mid", "old"])
    }

    func testMissingHistoryFileDoesNotCrash() throws {
        let alivePID = Int(getpid())
        try writeSession("a.json",
                         pid: alivePID,
                         sessionId: "sess-x",
                         startedAt: 1_700_000_000_000)

        // Note: no history file written.
        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].lastPrompt)
    }

    func testLastPromptTruncatedAt200Chars() throws {
        let alivePID = Int(getpid())
        let longPrompt = String(repeating: "a", count: 250)
        try writeSession("a.json",
                         pid: alivePID,
                         sessionId: "sess-long",
                         startedAt: 1_700_000_000_000)
        try writeHistory([(sessionId: "sess-long", display: longPrompt)])

        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )

        XCTAssertEqual(result.count, 1)
        let prompt = try XCTUnwrap(result[0].lastPrompt)
        // Mirrors Python: first 200 chars + literal "..." suffix.
        XCTAssertEqual(prompt.count, 203)
        XCTAssertTrue(prompt.hasSuffix("..."))
        XCTAssertEqual(String(prompt.prefix(200)), String(repeating: "a", count: 200))
    }

    func testShortPromptNotTruncated() throws {
        let alivePID = Int(getpid())
        try writeSession("a.json",
                         pid: alivePID,
                         sessionId: "sess-short",
                         startedAt: 1_700_000_000_000)
        try writeHistory([(sessionId: "sess-short", display: "tiny")])

        let result = SessionsReader.currentSessions(
            sessionsDir: sessionsDir(),
            historyFile: historyFile()
        )

        XCTAssertEqual(result.first?.lastPrompt, "tiny")
    }
}
