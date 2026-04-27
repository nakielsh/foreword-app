//
//  PreReviewSummaryRunnerProcessTests.swift
//  WorkHomepageTests
//
//  Real-process tests for `PreReviewSummaryRunner`. Existing
//  `PreReviewSummaryRunnerTests` only exercises `decodeJSONOutput` /
//  `decodeLine` / `decodeSummaryPayload` in isolation — none of them
//  spawn an actual child. This file drives `summarize(...)` end-to-end
//  against a fake binary script written to a temp dir and pinned via
//  `claudePath:`. No real `claude` invoked.
//
//  Coverage:
//   - Happy path: the script emits a JSON-array stdout containing a
//     `result` event with `structured_output.text`, and the runner yields
//     a single `.result(text:)`.
//   - Non-zero exit: stderr is captured and surfaced as `.error(message:)`.
//   - Empty stdout: the runner emits `.error(...)` rather than hanging.
//   - Timeout: a deliberately-slow child is reaped and `.error("timeout")`
//     is observed.
//

import XCTest
@testable import WorkHomepage

final class PreReviewSummaryRunnerProcessTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PreReviewSummaryRunnerProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Happy path

    func testHappyPathYieldsResultText() async throws {
        // The runner uses --output-format json (whole array), so emit a
        // single JSON value on stdout and exit 0.
        let payload = #"[{"type":"result","subtype":"success","result":"ok","structured_output":{"text":"PR adds retry with backoff"}}]"#
        let exe = try makeShellScript(body: """
        #!/bin/sh
        cat <<'EOF'
        \(payload)
        EOF
        exit 0
        """)

        var collected: [SummaryEvent] = []
        let stream = PreReviewSummaryRunner.summarize(
            repo: "Ala-com/foo",
            prNumber: 7,
            headSha: "deadbeef",
            timeout: .seconds(10),
            claudePath: exe
        )
        for await event in stream {
            collected.append(event)
        }

        // Exactly one .result event with the structured text.
        let resultTexts: [String] = collected.compactMap {
            if case .result(let t) = $0 { return t } else { return nil }
        }
        assertThat(resultTexts).containsExactly(["PR adds retry with backoff"])

        // No .error events on a clean run.
        let errors = collected.compactMap { event -> String? in
            if case .error(let m) = event { return m } else { return nil }
        }
        assertThat(errors).isEmpty()
    }

    // MARK: - Non-zero exit captures stderr

    func testNonZeroExitYieldsErrorWithStderr() async throws {
        let exe = try makeShellScript(body: """
        #!/bin/sh
        echo "permission denied" 1>&2
        exit 9
        """)

        var collected: [SummaryEvent] = []
        let stream = PreReviewSummaryRunner.summarize(
            repo: "x/y",
            prNumber: 1,
            headSha: "abc",
            timeout: .seconds(10),
            claudePath: exe
        )
        for await event in stream {
            collected.append(event)
        }

        // No .result events.
        let results = collected.compactMap { event -> String? in
            if case .result(let t) = event { return t } else { return nil }
        }
        assertThat(results).isEmpty()

        // Exactly one .error event carrying stderr.
        let errors: [String] = collected.compactMap {
            if case .error(let m) = $0 { return m } else { return nil }
        }
        assertThat(errors).hasSize(1)
        assertThat(errors[0]).contains("permission denied")
    }

    // MARK: - Empty stdout → typed error

    func testEmptyStdoutYieldsError() async throws {
        let exe = try makeShellScript(body: """
        #!/bin/sh
        exit 0
        """)

        var collected: [SummaryEvent] = []
        let stream = PreReviewSummaryRunner.summarize(
            repo: "x/y",
            prNumber: 1,
            headSha: "abc",
            timeout: .seconds(10),
            claudePath: exe
        )
        for await event in stream {
            collected.append(event)
        }

        let errors: [String] = collected.compactMap {
            if case .error(let m) = $0 { return m } else { return nil }
        }
        assertThat(errors).hasSize(1)
        assertThat(errors[0]).contains("empty")
    }

    // MARK: - Timeout reaps the child

    func testTimeoutReapsChild() async throws {
        // `exec sleep` so the script process IS the sleep, matching the
        // discipline used in ClaudeRunnerTests.testTimeoutKillsProcessAndYieldsTimeoutError.
        let exe = try makeShellScript(body: """
        #!/bin/sh
        exec sleep 30
        """)

        let start = Date()
        var collected: [SummaryEvent] = []
        let stream = PreReviewSummaryRunner.summarize(
            repo: "x/y",
            prNumber: 1,
            headSha: "abc",
            timeout: .seconds(1),
            claudePath: exe
        )
        for await event in stream {
            collected.append(event)
        }
        let elapsed = Date().timeIntervalSince(start)

        // Must have surfaced "timeout" inside ~5s (1s timeout + 2s grace
        // before SIGKILL + slop).
        assertThat(elapsed).isLessThan(10)
        let errors: [String] = collected.compactMap {
            if case .error(let m) = $0 { return m } else { return nil }
        }
        assertThat(errors).contains("timeout")
    }

    // MARK: - Helpers

    private func makeShellScript(body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
