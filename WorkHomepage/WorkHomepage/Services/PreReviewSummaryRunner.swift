//
//  PreReviewSummaryRunner.swift
//  WorkHomepage
//
//  Slice 24 — Pre-Review Summary tracer.
//
//  Spawns `claude -p <prompt> --output-format stream-json --include-partial-messages
//  --json-schema <schema> --allowed-tools "Bash(gh:*)"` and yields `SummaryEvent`s.
//
//  Architectural contract (ADR-0002):
//   - No cwd set — runs from any directory.
//   - Allowed tools: `Bash(gh:*)` only. No Read/Grep/Glob/git.
//   - Separate from `ClaudeRunner`; no concurrency pool yet (slice 25 adds that).
//   - Timeout: 60s default, overridable for tests.
//
//  Stream-json parsing mirrors `ClaudeRunner.decodeLine` but targets the
//  3-field summary schema. The runner emits:
//   - `.delta(field:text:)` — incremental text for live "streaming" preview.
//   - `.result(what:why:risk:)` — final decoded payload.
//   - `.error(message:)` — timeout, non-zero exit, or decode failure.
//
//  Partial-message deltas are plain text_delta events from the assistant's
//  text block. We stream them as `.delta(field: .what, text:)` — at this level
//  we cannot reliably split the stream across the three fields, so the UI
//  treats them as a single flowing preview. The final structured decode is what
//  populates the three individual bullets on completion.
//

import Foundation

// MARK: - Public types

/// Which of the three summary fields a streaming delta belongs to. Since the
/// stream-json deltas are not field-tagged by the Claude CLI, all partial text
/// is attributed to `.what` as a streaming preview. The split into `.what` /
/// `.why` / `.risk` happens only on the final `.result` event once the full
/// JSON is decoded.
/// Events emitted by `PreReviewSummaryRunner.summarize(...)`.
enum SummaryEvent {
    /// Incremental text chunk during streaming. The UI concatenates these to
    /// show a live preview while claude is running.
    case delta(text: String)
    /// Final decoded payload. The runner emits exactly one of `.result` or
    /// `.error` as the last event in the stream; the stream finishes immediately
    /// after.
    case result(text: String)
    /// Terminal error: timeout, non-zero exit, missing binary, or JSON decode
    /// failure. The `message` is displayed inline on the card.
    case error(message: String)
}

// MARK: - Runner

/// Spawns the `claude` CLI for a single PR summary. No cwd, `Bash(gh:*)` only.
/// Pattern-matched from `ClaudeRunner` — share the same stream-json line
/// decoder shape, env construction, and timeout/kill sequence.
struct PreReviewSummaryRunner {

    // MARK: - Public API

    /// Spawn claude and stream `SummaryEvent`s back. The returned stream
    /// finishes after the single `.result` or `.error` terminal event.
    ///
    /// `claudePath` defaults to `BinaryResolver.resolve(.claude)`. Tests
    /// inject a fake binary URL.
    static func summarize(
        repo: String,
        prNumber: Int,
        headSha: String,
        timeout: Duration = .seconds(180),
        claudePath: URL? = nil
    ) -> AsyncStream<SummaryEvent> {
        let resolvedExe: URL
        if let claudePath {
            resolvedExe = claudePath
        } else if let url = BinaryResolver.resolve(.claude) {
            resolvedExe = url
        } else {
            return AsyncStream { continuation in
                continuation.yield(.error(message: "`claude` binary not found. Configure it in Settings."))
                continuation.finish()
            }
        }

        let prompt = buildPrompt(repo: repo, prNumber: prNumber, headSha: headSha)
        // --output-format json: single JSON array on stdout; last element is the
        // result event with `structured_output` holding the schema-validated payload.
        // --mcp-config '{"mcpServers":{}}': suppress user's MCP servers so
        // unrelated tools don't trigger TCC popups during summary spawn.
        // --disallowed-tools: defense in depth; allowed-tools is allowlist
        // semantics, but explicit denials prevent any drift if defaults change.
        let arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", summaryJSONSchema,
            "--allowed-tools", "Bash(gh:*)",
            "--disallowed-tools", "Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,TodoWrite,Task",
            "--mcp-config", "{\"mcpServers\":{}}"
        ]

        return makeStream(
            executable: resolvedExe,
            arguments: arguments,
            timeout: timeout
        )
    }

    // MARK: - Stream construction (internal for testability)

    /// Builds the event stream. Extracted as a static so tests can drive it
    /// directly with a custom argument list, mirroring `ClaudeRunner.makeStream`.
    static func makeStream(
        executable: URL,
        arguments: [String],
        timeout: Duration
    ) -> AsyncStream<SummaryEvent> {
        AsyncStream { continuation in

            final class ProcessBox: @unchecked Sendable {
                var process: Process?
                var didTimeout: Bool = false
            }
            let box = ProcessBox()

            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                // ADR-0002: no project cwd. Use /tmp so claude has nothing in
                // its working directory that could trigger macOS TCC popups
                // for filesystem access.
                process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

                process.environment = ClaudeRunner.buildClaudeEnv(executable: executable)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.yield(.error(message: "Failed to launch \(executable.path): \(error.localizedDescription)"))
                    continuation.finish()
                    return
                }
                box.process = process

                // Timeout: SIGTERM then SIGKILL after 2s grace.
                let timeoutWorkItem = DispatchWorkItem {
                    guard let p = box.process, p.isRunning else { return }
                    box.didTimeout = true
                    kill(p.processIdentifier, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        if p.isRunning {
                            kill(p.processIdentifier, SIGKILL)
                        }
                    }
                }
                let secs = TimeInterval(ClaudeRunner.durationToSeconds(timeout))
                DispatchQueue.global().asyncAfter(deadline: .now() + secs, execute: timeoutWorkItem)

                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                // --output-format json emits one JSON value (array) on stdout,
                // not line-delimited. Drain the whole pipe, then decode.
                let stdoutData = (try? stdoutHandle.readToEnd()) ?? Data()
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                let stderrData = (try? stderrHandle.readToEnd()) ?? Data()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if box.didTimeout {
                    continuation.yield(.error(message: "timeout"))
                    continuation.finish()
                    return
                }

                if process.terminationStatus != 0 {
                    let payload = stderr.isEmpty
                        ? "claude exited with status \(process.terminationStatus)"
                        : stderr
                    continuation.yield(.error(message: payload))
                    continuation.finish()
                    return
                }

                for event in decodeJSONOutput(stdoutData) {
                    continuation.yield(event)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if let p = box.process, p.isRunning {
                    kill(p.processIdentifier, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        if p.isRunning {
                            kill(p.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        }
    }

    // MARK: - JSON-array output decoding (--output-format json)

    /// Parse the entire stdout blob as a JSON array of events. The terminal
    /// `result` event carries `structured_output` when `--json-schema` is set.
    static func decodeJSONOutput(_ data: Data) -> [SummaryEvent] {
        guard !data.isEmpty else {
            return [.error(message: "claude returned empty output")]
        }

        // Try array shape first (--output-format json default).
        if let array = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
            if let resultEvent = array.last(where: { ($0["type"] as? String) == "result" }) {
                return decodeResultEvent(resultEvent)
            }
            // No result event — surface what we got for debugging.
            let types = array.compactMap { $0["type"] as? String }.joined(separator: ", ")
            FileHandle.standardError.write(Data("[PreReviewSummary] no result event. types: \(types)\n".utf8))
            return [.error(message: "no result event. types seen: \(types)")]
        }

        // Fallback: single object (older claude versions or different config).
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            return decodeResultEvent(obj)
        }

        let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
        FileHandle.standardError.write(Data("[PreReviewSummary] unparseable stdout. preview:\n\(preview)\n".utf8))
        return [.error(message: "unparseable claude output. raw: \(preview)")]
    }

    // MARK: - Line decoding (legacy stream-json — kept for tests)

    /// Decode one stream-json line into zero or more `SummaryEvent`s. Parse
    /// failures are silently dropped — permissive contract mirrors ClaudeRunner.
    static func decodeLine(_ line: String) -> [SummaryEvent] {
        guard let data = line.data(using: .utf8) else { return [] }
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return []
        }
        guard let type = raw["type"] as? String else { return [] }

        switch type {
        case "stream_event":
            if let event = raw["event"] as? [String: Any] {
                return decodeStreamEvent(event)
            }
            return []
        case "result":
            return decodeResultEvent(raw)
        default:
            return []
        }
    }

    private static func decodeStreamEvent(_ event: [String: Any]) -> [SummaryEvent] {
        guard let eventType = event["type"] as? String else { return [] }
        switch eventType {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let text = delta["text"] as? String {
                return [.delta(text: text)]
            }
            return []
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any],
               let blockType = block["type"] as? String,
               blockType == "text",
               let text = block["text"] as? String,
               !text.isEmpty {
                return [.delta(text: text)]
            }
            return []
        default:
            return []
        }
    }

    private static func decodeResultEvent(_ raw: [String: Any]) -> [SummaryEvent] {
        let subtype = raw["subtype"] as? String ?? ""

        if subtype.hasPrefix("error") {
            let detail = (raw["result"] as? String) ?? subtype
            return [.error(message: detail)]
        }

        // Try to decode the structured payload. Order matters:
        // 1. `structured_output` (set when --json-schema is honored)
        // 2. `result` as inline object
        // 3. `result` as JSON-encoded string
        let jsonString: String?
        if let obj = raw["structured_output"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let s = String(data: d, encoding: .utf8) {
            jsonString = s
        } else if let obj = raw["result"] as? [String: Any],
                  let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let s = String(data: d, encoding: .utf8) {
            jsonString = s
        } else if let s = raw["result"] as? String, !s.isEmpty {
            jsonString = s
        } else {
            jsonString = nil
        }

        guard let payload = jsonString else {
            // Log the entire result event so we can see what fields claude actually emitted.
            if let dump = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted]),
               let str = String(data: dump, encoding: .utf8) {
                FileHandle.standardError.write(Data("[PreReviewSummary] empty/missing result payload. full event:\n\(str)\n".utf8))
            }
            let keys = Array(raw.keys).joined(separator: ", ")
            return [.error(message: "claude returned no result payload. event keys: \(keys)")]
        }

        return decodeSummaryPayload(payload)
    }

    /// Attempts to decode `payload` as `SummarySchema`, trying the same
    /// candidate-stripping strategy as `ClaudeRunner.decodeResultPayload`:
    /// raw → fence-stripped → balanced-object extraction. Emits `.error` only
    /// when every candidate fails, so a decode failure is a hard terminal state
    /// (unlike `ClaudeRunner` where the review still "completed" with nil
    /// decoded — the summary has no raw-display tab).
    static func decodeSummaryPayload(_ json: String) -> [SummaryEvent] {
        let candidates = ClaudeRunner.candidateJSONStrings(from: json)
        let decoder = JSONDecoder()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let schema = try? decoder.decode(SummarySchema.self, from: data) {
                return [.result(text: schema.text)]
            }
        }
        // Surface the raw payload (truncated) so the failure is debuggable
        // from the card without launching Console.
        let preview = String(json.prefix(400))
        FileHandle.standardError.write(Data("[PreReviewSummary] decode failure. raw payload:\n\(json)\n".utf8))
        return [.error(message: "could not decode summary. raw: \(preview)")]
    }

    // MARK: - Prompt

    static func buildPrompt(repo: String, prNumber: Int, headSha: String) -> String {
        """
        You are summarizing PR #\(prNumber) in \(repo) at SHA \(headSha).

        Use `gh pr view \(prNumber) --repo \(repo)` and `gh pr diff \(prNumber) --repo \(repo)` to fetch the PR and the diff. Read the PR body for any linked Jira context.

        Return JSON conformant to the schema with a single field `text` containing a concise prose summary (2-4 sentences) covering what changed, why, and any risks worth scrutinizing during review.

        No bullets, no markdown, no headings. Plain prose.
        """
    }

    // MARK: - JSON Schema

    /// JSON Schema passed to `claude --json-schema`. Single required string
    /// field; claude can add commentary keys without failing validation.
    static let summaryJSONSchema: String = """
    {
      "type": "object",
      "required": ["text"],
      "properties": {
        "text": {"type": "string"}
      }
    }
    """
}

// MARK: - Decode shape

/// Internal decode target for the `claude --json-schema` result.
private struct SummarySchema: Decodable {
    let text: String
}
