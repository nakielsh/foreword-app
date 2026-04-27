//
//  ClaudeRunnerCancellationTests.swift
//  WorkHomepageTests
//
//  Covers two failure modes that the existing `ClaudeRunnerTests` didn't:
//
//   1. Consumer-Task cancellation propagates: dropping the stream mid-run
//      SIGTERMs the child and the AsyncThrowingStream finishes cleanly.
//   2. Invalid binary / permission-denied path: launching against a path
//      that doesn't exist (or isn't executable) emits `.error` and the
//      stream finishes — no hang, no crash.
//
//  Both flows go through the real `ClaudeRunner.run(...)` wired against
//  fake shell scripts on disk; no real `claude` CLI is invoked.
//

import XCTest
@testable import WorkHomepage

final class ClaudeRunnerCancellationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeRunnerCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Consumer cancellation propagates SIGTERM to the child

    /// Cancel the consuming Task while the fake claude is still running. The
    /// stream's `onTermination` must fire when the iterator is dropped /
    /// the Task is cancelled, SIGTERM the child, and the surrounding test
    /// code must observe a prompt finish — proves the child was actually
    /// reaped rather than orphaned to outlive the test.
    func testConsumerCancellationReapsChild() async throws {
        // `exec sleep` so the child IS the sleep — same pattern as
        // ClaudeRunnerTests.testTimeoutKillsProcessAndYieldsTimeoutError.
        let exe = try makeShellScript(body: """
        #!/bin/sh
        # Emit one delta so the consumer sees first output, then sleep.
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"alive"}}}'
        exec sleep 60
        """)

        // The cancellation seam we're testing fires when the
        // AsyncThrowingStream's continuation observes that the consumer
        // has gone away. The cleanest reproduction is:
        //   1. Spawn a consumer Task that reads from the stream.
        //   2. Cancel the Task via `task.cancel()`.
        //   3. The stream's iterator inside the Task gets dropped, the
        //      continuation runs `onTermination`, and the child is killed.
        let start = Date()

        let consumer = Task {
            let stream = try ClaudeRunner.run(
                prompt: "x", schema: "{}", cwd: self.tempDir,
                allowedTools: "Read", timeout: .seconds(120), executableURL: exe
            )
            var deltas = 0
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    if case .textDelta = event { deltas += 1 }
                }
            } catch {
                // Cancellation throws CancellationError out of the loop;
                // dropping the stream iterator triggers onTermination.
            }
            return deltas
        }

        // Wait long enough for the child to start and emit the first
        // delta, then cancel the consumer.
        try? await Task.sleep(nanoseconds: 500_000_000)
        consumer.cancel()
        _ = try? await consumer.value
        let elapsed = Date().timeIntervalSince(start)

        // 60s sleep would have blocked us if the child wasn't reaped.
        // Generous bound (10s) tolerates SIGTERM grace + CI variance.
        assertThat(elapsed).isLessThan(10)
    }

    // MARK: - Invalid binary path → .error, no crash

    /// Pointing the runner at a non-existent path must surface an `.error`
    /// event and finish the stream — never crash, never hang. This is the
    /// hot path for "user mis-configured Settings.claudePath".
    func testInvalidBinaryPathEmitsErrorEvent() async throws {
        let bogus = tempDir.appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        var collected: [ClaudeEvent] = []
        let stream = try ClaudeRunner.run(
            prompt: "x", schema: "{}", cwd: tempDir,
            allowedTools: "Read", timeout: .seconds(5), executableURL: bogus
        )
        for try await event in stream {
            collected.append(event)
        }

        // Exactly one error event; no crash, no .finalResult.
        let errors: [String] = collected.compactMap {
            if case .error(let m) = $0 { return m } else { return nil }
        }
        assertThat(errors).hasSize(1)
        // Message references the missing path so the user can debug it.
        assertThat(errors[0]).contains(bogus.path)
    }

    // MARK: - Non-executable file → .error, no crash

    /// Same surface, different mode: file exists but is not executable.
    /// The runner must surface `.error` instead of trapping or hanging on
    /// `Process.run()`'s thrown error.
    func testNonExecutableBinaryEmitsErrorEvent() async throws {
        let path = tempDir.appendingPathComponent("not-exec.sh")
        try "#!/bin/sh\necho hi\n".write(to: path, atomically: true, encoding: .utf8)
        // Mode 0o644 — readable, NOT executable.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

        var collected: [ClaudeEvent] = []
        let stream = try ClaudeRunner.run(
            prompt: "x", schema: "{}", cwd: tempDir,
            allowedTools: "Read", timeout: .seconds(5), executableURL: path
        )
        for try await event in stream {
            collected.append(event)
        }

        let errors: [String] = collected.compactMap {
            if case .error(let m) = $0 { return m } else { return nil }
        }
        // At least one error event, never a crash. We don't pin the exact
        // message because Foundation phrases permission-denied differently
        // across SDK versions ("Permission denied" / "EACCES" / "launch failure").
        assertThat(errors.count).isGreaterThanOrEqualTo(1)
    }

    // MARK: - Helpers

    private func makeShellScript(body: String) throws -> URL {
        let url = tempDir.appendingPathComponent("fake-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
