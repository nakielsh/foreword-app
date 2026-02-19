//
//  ClaudeRunnerTests.swift
//  WorkHomepageTests
//
//  Slice 07 — integration tests for `ClaudeRunner` against fake `claude` shell
//  scripts. We write each fake to a temp dir, mark it executable, and pass its
//  URL via `ClaudeRunner.run(executableURL:)`. No real `claude` invoked, no
//  network.
//
//  Coverage:
//    - Streamed text deltas arrive in order.
//    - Tool use events surface.
//    - Final structured payload decodes against `ReviewSchema`.
//    - Non-zero exit yields `.error(stderr)`.
//    - Timeout kills the process and yields `.error("timeout")`.
//

import XCTest
@testable import WorkHomepage

final class ClaudeRunnerTests: XCTestCase {

    private var tempDir: URL!
    private var cwd: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cwd = tempDir
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Happy path: deltas + tool use + final result

    func testHappyPathStreamsDeltasAndDecodesResult() async throws {
        let lines = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}}"#,
            // Final result, payload is a JSON-encoded *string* (the common shape).
            #"{"type":"result","subtype":"success","result":"{\"summary\":\"Looks good\",\"verdict\":\"approve\",\"findings\":[]}"}"#
        ]
        let exe = try makeFakeClaude(emitting: lines)

        var collected: [ClaudeEvent] = []
        let stream = try ClaudeRunner.run(
            prompt: "ignored",
            schema: "{}",
            cwd: cwd,
            allowedTools: "Read",
            timeout: .seconds(10),
            executableURL: exe
        )
        for try await event in stream {
            collected.append(event)
        }

        // Tool use first.
        XCTAssertEqual(collected.first, .toolUse(name: "Read"))
        // Two text deltas in order.
        let deltas = collected.compactMap { event -> String? in
            if case .textDelta(let s) = event { return s }
            return nil
        }
        XCTAssertEqual(deltas, ["Hello ", "world"])
        // Final result decodes.
        let final = collected.last
        guard case .finalResult(_, let decoded) = final else {
            XCTFail("expected final result event, got \(String(describing: final))")
            return
        }
        XCTAssertEqual(decoded.summary, "Looks good")
        XCTAssertEqual(decoded.verdict, "approve")
        XCTAssertTrue(decoded.findings.isEmpty)
    }

    // MARK: - Final result with object-shaped `result`

    func testFinalResultObjectShape() async throws {
        let lines = [
            #"{"type":"result","subtype":"success","result":{"summary":"ok","verdict":"comment","findings":[]}}"#
        ]
        let exe = try makeFakeClaude(emitting: lines)

        var final: ClaudeEvent?
        let stream = try ClaudeRunner.run(
            prompt: "x", schema: "{}", cwd: cwd,
            allowedTools: "Read", timeout: .seconds(10), executableURL: exe
        )
        for try await event in stream {
            if case .finalResult = event { final = event }
        }
        guard case .finalResult(_, let decoded) = final else {
            XCTFail("expected final result; got \(String(describing: final))")
            return
        }
        XCTAssertEqual(decoded.verdict, "comment")
    }

    // MARK: - Non-zero exit yields .error(stderr)

    func testNonZeroExitYieldsErrorWithStderr() async throws {
        let exe = try makeShellScript(body: """
        #!/bin/sh
        echo "boom" 1>&2
        exit 7
        """)

        var errors: [String] = []
        let stream = try ClaudeRunner.run(
            prompt: "x", schema: "{}", cwd: cwd,
            allowedTools: "Read", timeout: .seconds(10), executableURL: exe
        )
        for try await event in stream {
            if case .error(let m) = event { errors.append(m) }
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("boom"), "expected stderr 'boom' in error message; got: \(errors[0])")
    }

    // MARK: - Timeout

    func testTimeoutKillsProcessAndYieldsTimeoutError() async throws {
        // A claude that hangs for a while. Timeout is 1s; we expect SIGTERM
        // (via the process group) and a `timeout` error event.
        // `exec sleep` so the script process *is* the sleep — otherwise the
        // shell's sleep child outlives a SIGTERM aimed at the shell PID, and
        // its still-open stdout fd keeps our reader blocked even though the
        // shell is gone. Real `claude` is single-process, so this matches.
        let exe = try makeShellScript(body: """
        #!/bin/sh
        exec sleep 5
        """)

        var errors: [String] = []
        let start = Date()
        let stream = try ClaudeRunner.run(
            prompt: "x", schema: "{}", cwd: cwd,
            allowedTools: "Read", timeout: .seconds(1), executableURL: exe
        )
        for try await event in stream {
            if case .error(let m) = event { errors.append(m) }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "timeout should have fired well before the 5s sleep")
        XCTAssertTrue(errors.contains("timeout"), "expected 'timeout' error; got \(errors)")
    }

    // MARK: - Helpers

    /// Write a fake claude binary that emits each line as-is on stdout, then
    /// exits 0. Newlines between lines are added.
    private func makeFakeClaude(emitting lines: [String]) throws -> URL {
        var script = "#!/bin/sh\n"
        for line in lines {
            // Single-quote, escaping any single quotes by closing/opening.
            let escaped = line.replacingOccurrences(of: "'", with: "'\\''")
            script += "printf '%s\\n' '\(escaped)'\n"
        }
        script += "exit 0\n"
        return try makeShellScript(body: script)
    }

    private func makeShellScript(body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
