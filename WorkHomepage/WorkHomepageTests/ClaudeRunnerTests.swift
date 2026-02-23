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
//    - Real-world claude payload (renamed fields + positives + critical
//      severity + missing verdict) decodes leniently.
//    - Markdown code-fence wrapping is stripped before decoding.
//    - Prose preamble around the JSON is stripped.
//    - Truly garbage payloads still emit `.finalResult(decoded: nil)` so the
//      modal can surface the raw output.
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
        XCTAssertEqual(decoded?.summary, "Looks good")
        XCTAssertEqual(decoded?.verdict, "approve")
        XCTAssertEqual(decoded?.findings.isEmpty, true)
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
        XCTAssertEqual(decoded?.verdict, "comment")
    }

    // MARK: - Real-world payload from user smoke test

    /// Reproduces the failure mode from the user's smoke-test report: claude
    /// emitted `overallAssessment` instead of `verdict`, `description`/`suggestedFix`
    /// instead of `message`/`suggestion`, severity `critical`, plus a
    /// `positives` array. The strict slice 07 decoder rejected this; the
    /// lenient slice/07-fix decoder must accept it.
    func testRealWorldClaudePayloadDecodesLeniently() async throws {
        let payloadJSON = """
        {
          "summary": "PR mostly OK with one security issue.",
          "overallAssessment": "needsWork",
          "findings": [
            {
              "file": "src/api/Login.swift",
              "line": 10,
              "severity": "critical",
              "category": "security",
              "title": "Plaintext password",
              "description": "Stored in plaintext.",
              "suggestedFix": "Hash with bcrypt."
            }
          ],
          "positives": ["Tests cover the happy path"]
        }
        """
        let escaped = payloadJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        let resultLine = "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"\(escaped)\"}"
        let exe = try makeFakeClaude(emitting: [resultLine])

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
        XCTAssertNotNil(decoded, "real-world payload must structure-decode")
        XCTAssertEqual(decoded?.verdict, "needsWork", "verdict must come from overallAssessment")
        XCTAssertEqual(decoded?.findings.count, 1)
        XCTAssertEqual(decoded?.findings.first?.message, "Stored in plaintext.")
        XCTAssertEqual(decoded?.findings.first?.suggestion, "Hash with bcrypt.")
        XCTAssertEqual(decoded?.findings.first?.category, "security")
        XCTAssertEqual(decoded?.findings.first?.normalizedSeverity, "blocker")
        XCTAssertEqual(decoded?.positives, ["Tests cover the happy path"])
    }

    // MARK: - Markdown code-fence wrapping

    func testCodeFencedPayloadIsStripped() async throws {
        // Wrap a valid JSON payload in ```json\n...\n``` and ship it through
        // claude's `result` field as a string. The decoder must strip the
        // fence before parsing.
        let inner = #"{"summary":"fenced","verdict":"approve","findings":[]}"#
        let fenced = "```json\n\(inner)\n```"
        let escaped = fenced
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let resultLine = "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"\(escaped)\"}"
        let exe = try makeFakeClaude(emitting: [resultLine])

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
        XCTAssertEqual(decoded?.summary, "fenced")
    }

    // MARK: - Prose preamble around the JSON

    func testProsePreambleStrippedViaBalancedExtraction() async throws {
        let inner = #"{"summary":"prose","verdict":"approve","findings":[]}"#
        let withProse = "Here is my review:\n\(inner)\nHope it helps!"
        let escaped = withProse
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let resultLine = "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"\(escaped)\"}"
        let exe = try makeFakeClaude(emitting: [resultLine])

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
        XCTAssertEqual(decoded?.summary, "prose")
    }

    // MARK: - Decode failure path

    /// When the result payload is genuinely garbage (not JSON, not even a
    /// recoverable balanced object), the runner must still emit
    /// `.finalResult(decoded: nil)` with the raw payload preserved, NOT
    /// `.error`. The orchestrator then marks the row completed and the modal
    /// surfaces the raw output to the user.
    func testGarbagePayloadEmitsFinalResultWithNilDecoded() async throws {
        let resultLine = #"{"type":"result","subtype":"success","result":"this is not json at all"}"#
        let exe = try makeFakeClaude(emitting: [resultLine])

        var collected: [ClaudeEvent] = []
        let stream = try ClaudeRunner.run(
            prompt: "x", schema: "{}", cwd: cwd,
            allowedTools: "Read", timeout: .seconds(10), executableURL: exe
        )
        for try await event in stream {
            collected.append(event)
        }

        // Should NOT contain an .error event for the decode failure.
        for event in collected {
            if case .error(let m) = event {
                XCTFail("expected no error for decode failure; got: \(m)")
            }
        }
        // Should contain a finalResult with decoded == nil and the raw payload.
        let final = collected.last
        guard case .finalResult(let raw, let decoded) = final else {
            XCTFail("expected finalResult; got \(String(describing: final))")
            return
        }
        XCTAssertNil(decoded)
        XCTAssertTrue(raw.contains("this is not json"), "raw payload must be preserved; got: \(raw)")
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

    // MARK: - Unit tests for the candidate-strings extractor

    /// `candidateJSONStrings(from:)` is the wrapper-stripping front end of
    /// `decodeResultPayload`. Pure-Swift tests below pin its behaviour
    /// without the shell-script fakery.

    func testCandidateExtraction_passesThroughRawJSON() {
        let input = #"{"a":1}"#
        let candidates = ClaudeRunner.candidateJSONStrings(from: input)
        XCTAssertTrue(candidates.contains(input))
    }

    func testCandidateExtraction_stripsCodeFence() {
        let inner = #"{"a":1}"#
        let fenced = "```json\n\(inner)\n```"
        let candidates = ClaudeRunner.candidateJSONStrings(from: fenced)
        XCTAssertTrue(candidates.contains(inner), "expected fence-stripped candidate; got: \(candidates)")
    }

    func testCandidateExtraction_extractsBalancedObjectFromProse() {
        let inner = #"{"a":1,"b":{"nested":true}}"#
        let mixed = "Sure! Here's the JSON:\n\(inner)\nLet me know."
        let candidates = ClaudeRunner.candidateJSONStrings(from: mixed)
        XCTAssertTrue(candidates.contains(inner), "expected balanced extraction; got: \(candidates)")
    }

    func testBalancedExtraction_ignoresBracesInsideStringLiterals() {
        // The string literal contains `{"nope"` — must not trip the brace
        // counter.
        let input = #"prefix {"k":"weird {value}","n":1} suffix"#
        let extracted = ClaudeRunner.extractBalancedObject(from: input)
        XCTAssertEqual(extracted, #"{"k":"weird {value}","n":1}"#)
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
