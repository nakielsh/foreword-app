//
//  PreReviewSummaryRunnerTests.swift
//  WorkHomepageTests
//
//  Slice 24 — Pre-Review Summary tracer.
//
//  Integration tests for `PreReviewSummaryRunner` using fake `claude` shell
//  scripts. Pattern-matched from `ClaudeRunnerTests.swift`. No real `claude`
//  is invoked; tests inject a fake binary via `claudePath:`.
//
//  Coverage:
//    - Streamed `.delta` events arrive in order before the final `.result`.
//    - `.result` decodes correctly from a standard stream-json payload.
//    - Non-zero exit yields `.error`.
//    - A hanging fake times out and yields `.error(message: "timeout")`.
//    - Result payload wrapped in a markdown code fence is accepted.
//    - Payload wrapped in prose preamble is accepted (balanced-object
//      extraction via `ClaudeRunner.candidateJSONStrings`).
//

import XCTest
@testable import WorkHomepage

final class PreReviewSummaryRunnerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PreReviewSummaryRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Happy path: deltas + final result

    func testStreamsDeltasThenResult() async throws {
        let lines = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}}"#,
            #"{"type":"result","subtype":"success","result":"{\"what\":\"Added retry logic\",\"why\":\"To handle transient failures\",\"risk\":\"May mask real errors\"}"}"#
        ]
        let exe = try makeFakeScript(emitting: lines)

        var events: [SummaryEvent] = []
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            events.append(event)
        }

        // Deltas arrive before the final result.
        let deltas = events.compactMap { event -> String? in
            if case .delta(_, let text) = event { return text }
            return nil
        }
        XCTAssertEqual(deltas, ["Hello ", "world"], "deltas must arrive in order")

        // Final result is the last event and decodes correctly.
        let last = events.last
        guard case .result(let what, let why, let risk) = last else {
            XCTFail("last event must be .result; got \(String(describing: last))")
            return
        }
        XCTAssertEqual(what, "Added retry logic")
        XCTAssertEqual(why, "To handle transient failures")
        XCTAssertEqual(risk, "May mask real errors")
    }

    // MARK: - Result as inline JSON object (not string-encoded)

    func testResultWithObjectShapeDecodes() async throws {
        let lines = [
            #"{"type":"result","subtype":"success","result":{"what":"Changed API","why":"Needed new field","risk":"Breaking change"}}"#
        ]
        let exe = try makeFakeScript(emitting: lines)

        var result: SummaryEvent?
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            if case .result = event { result = event }
        }
        guard case .result(let what, let why, let risk) = result else {
            XCTFail("expected .result; got \(String(describing: result))")
            return
        }
        XCTAssertEqual(what, "Changed API")
        XCTAssertEqual(why, "Needed new field")
        XCTAssertEqual(risk, "Breaking change")
    }

    // MARK: - Markdown code fence

    func testCodeFencedResultDecodes() async throws {
        let inner = #"{"what":"Fenced what","why":"Fenced why","risk":"Fenced risk"}"#
        let fenced = "```json\n\(inner)\n```"
        let escaped = fenced
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let resultLine = "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"\(escaped)\"}"
        let exe = try makeFakeScript(emitting: [resultLine])

        var result: SummaryEvent?
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            if case .result = event { result = event }
        }
        guard case .result(let what, _, _) = result else {
            XCTFail("expected .result; got \(String(describing: result))")
            return
        }
        XCTAssertEqual(what, "Fenced what")
    }

    // MARK: - Prose preamble

    func testProsePreambleStrippedViaBalancedExtraction() async throws {
        let inner = #"{"what":"Prose what","why":"Prose why","risk":"Prose risk"}"#
        let withProse = "Here is the summary:\n\(inner)\nHope that helps!"
        let escaped = withProse
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let resultLine = "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"\(escaped)\"}"
        let exe = try makeFakeScript(emitting: [resultLine])

        var result: SummaryEvent?
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            if case .result = event { result = event }
        }
        guard case .result(let what, _, _) = result else {
            XCTFail("expected .result; got \(String(describing: result))")
            return
        }
        XCTAssertEqual(what, "Prose what")
    }

    // MARK: - Non-zero exit → .error

    func testNonZeroExitYieldsError() async throws {
        let exe = try makeShellScript(body: """
        #!/bin/sh
        echo "summary failed" 1>&2
        exit 1
        """)

        var errors: [String] = []
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        XCTAssertEqual(errors.count, 1, "expected exactly one error event")
        XCTAssertTrue(
            errors[0].contains("summary failed"),
            "expected stderr in error message; got: \(errors[0])"
        )
    }

    // MARK: - Timeout → .error("timeout")

    func testTimeoutKillsProcessAndYieldsTimeoutError() async throws {
        // Fake claude that hangs indefinitely. Timeout is 2s for the test.
        let exe = try makeShellScript(body: """
        #!/bin/sh
        exec sleep 30
        """)

        var errors: [String] = []
        let start = Date()
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(2)
        )
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 10.0, "timeout must fire before the 30s sleep")
        XCTAssertTrue(errors.contains("timeout"), "expected 'timeout' error; got \(errors)")
    }

    // MARK: - Decode failure → .error

    func testGarbagePayloadYieldsError() async throws {
        let resultLine = #"{"type":"result","subtype":"success","result":"not json at all"}"#
        let exe = try makeFakeScript(emitting: [resultLine])

        var errors: [String] = []
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        XCTAssertFalse(errors.isEmpty, "garbage payload must yield an error event")
    }

    // MARK: - Error subtype from result event

    func testResultErrorSubtypeYieldsError() async throws {
        let line = #"{"type":"result","subtype":"error_max_turns","result":"exceeded max turns"}"#
        let exe = try makeFakeScript(emitting: [line])

        var errors: [String] = []
        let stream = PreReviewSummaryRunner.makeStream(
            executable: exe,
            arguments: [],
            timeout: .seconds(10)
        )
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        XCTAssertFalse(errors.isEmpty, "error subtype must yield a .error event")
    }

    // MARK: - decodeLine unit tests

    func testDecodeLineTextDeltaYieldsDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"foo"}}}"#
        let events = PreReviewSummaryRunner.decodeLine(line)
        XCTAssertEqual(events.count, 1)
        guard case .delta(let field, let text) = events[0] else {
            XCTFail("expected .delta; got \(events[0])")
            return
        }
        XCTAssertEqual(field, .what)
        XCTAssertEqual(text, "foo")
    }

    func testDecodeLineUnknownTypeIsDropped() {
        let line = #"{"type":"assistant","message":{}}"#
        let events = PreReviewSummaryRunner.decodeLine(line)
        XCTAssertTrue(events.isEmpty, "assistant bookkeeping must be dropped")
    }

    // MARK: - Helpers

    private func makeFakeScript(emitting lines: [String]) throws -> URL {
        var script = "#!/bin/sh\n"
        for line in lines {
            let escaped = line.replacingOccurrences(of: "'", with: "'\\''")
            script += "printf '%s\\n' '\(escaped)'\n"
        }
        script += "exit 0\n"
        return try makeShellScript(body: script)
    }

    private func makeShellScript(body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("fake-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
