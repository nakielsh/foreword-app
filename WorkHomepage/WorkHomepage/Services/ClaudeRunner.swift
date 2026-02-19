//
//  ClaudeRunner.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Spawns the `claude` CLI with stream-json output and yields decoded
//  `ClaudeEvent`s as they arrive. Hard 10-minute timeout. Captures stderr
//  separately and surfaces it on non-zero exit.
//
//  Stream-json shape (from `claude` CLI docs + observed output): each line on
//  stdout is one JSON object with a `type` field. The shapes we care about for
//  slice 07:
//
//    {"type":"system","subtype":"init",...}
//      — bookkeeping, ignored by the UI but logged.
//    {"type":"stream_event","event":{"type":"content_block_delta",
//        "delta":{"type":"text_delta","text":"…"}}}
//      — incremental text output. Concatenated to feed the live "thinking" view
//        in the modal.
//    {"type":"stream_event","event":{"type":"content_block_start",
//        "content_block":{"type":"tool_use","name":"Read"}}}
//      — surfaces a tool use to the UI. Slice 07 ignores name details and just
//        reports `name`.
//    {"type":"assistant","message":{...}}
//    {"type":"user","message":{...}}
//      — full assistant/user message bookkeeping, dropped (the deltas already
//        cover what the UI needs).
//    {"type":"result","subtype":"success","result":"<json string>",...}
//      — final structured payload. `result` may be a JSON-encoded string or a
//        JSON object; we handle both. This is the event the orchestrator
//        decodes against `ReviewSchema`.
//    {"type":"result","subtype":"error_max_turns",...}
//    {"type":"result","subtype":"error_during_execution",...}
//      — terminal error events; surfaced as `.error(...)`.
//
//  The decoder is intentionally permissive: any line that fails to parse is
//  logged and skipped, never crashed. This keeps slice 07's tracer-bullet
//  resilient against minor schema drift in the CLI between Claude releases.
//

import Foundation

// MARK: - Public event surface

/// Discrete events the orchestrator and modal react to. Internal stream-json
/// types beyond these are dropped on the floor.
enum ClaudeEvent: Equatable {
    /// One incremental chunk of assistant text. Concatenate to render live
    /// "thinking" output.
    case textDelta(String)
    /// Claude invoked a tool. `name` is the tool name (e.g. `Read`, `Grep`,
    /// `Bash`). Slice 07's modal doesn't render this yet; persisted for slice
    /// 08+.
    case toolUse(name: String)
    /// Final structured result. `rawJSON` is the pretty-printed JSON of the
    /// `result` payload (used for the "raw" tab in slice 07's modal); `decoded`
    /// is the same payload typed against `ReviewSchema`.
    case finalResult(rawJSON: String, decoded: ReviewSchema)
    /// Anything terminal that isn't a structured result: stderr, decode
    /// failure, timeout, non-zero exit, missing `claude` binary.
    case error(String)
}

// MARK: - Errors

enum ClaudeRunnerError: Error, Equatable {
    case binaryNotFound
    case spawnFailed(String)
}

// MARK: - Runner

struct ClaudeRunner {

    // MARK: - Public API

    /// Spawn `claude` with the slice 07 default arguments and stream events
    /// back. The returned stream finishes when the child exits, the timeout
    /// fires, or the consumer drops the stream (cancellation propagates via
    /// SIGTERM → SIGKILL).
    ///
    /// `executableURL` defaults to whatever `BinaryResolver.resolve(.claude)`
    /// returns; tests inject a fake binary path.
    static func run(
        prompt: String,
        schema: String,
        cwd: URL,
        allowedTools: String,
        timeout: Duration = .seconds(600),
        executableURL: URL? = nil
    ) throws -> AsyncThrowingStream<ClaudeEvent, Error> {

        let resolvedExe: URL
        if let executableURL {
            resolvedExe = executableURL
        } else if let url = BinaryResolver.resolve(.claude) {
            resolvedExe = url
        } else {
            throw ClaudeRunnerError.binaryNotFound
        }

        let arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--json-schema", schema,
            "--allowed-tools", allowedTools
        ]

        return makeStream(
            executable: resolvedExe,
            arguments: arguments,
            cwd: cwd,
            timeout: timeout
        )
    }

    // MARK: - Stream construction

    /// Builds the event stream. Split out so tests can drive it with a custom
    /// argument list without recreating the whole CLI surface.
    static func makeStream(
        executable: URL,
        arguments: [String],
        cwd: URL,
        timeout: Duration
    ) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in

            // Box for the running process so the timeout / cancellation tasks
            // can reach in. We assign before kicking off the stdout reader,
            // and the box is released on stream finish.
            final class ProcessBox: @unchecked Sendable {
                var process: Process?
                var didTimeout: Bool = false
            }
            let box = ProcessBox()

            // Drive the spawn off-main; `Process.run` + reading pipes blocks.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = cwd

                // Minimal but sufficient env. `claude` reads `ANTHROPIC_API_KEY`
                // / `~/.claude/...`; both come through HOME. PATH is built from
                // the directories of our resolved binaries plus the standard
                // ones, so claude can shell out to gh/git when a tool call asks
                // for it.
                process.environment = buildClaudeEnv(executable: executable)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.yield(.error("Failed to launch \(executable.path): \(error.localizedDescription)"))
                    continuation.finish()
                    return
                }
                box.process = process

                // Schedule the timeout. On expiry, SIGTERM, wait 2s, then
                // SIGKILL. The flag tells the exit-handler block to emit a
                // timeout error rather than the process's stderr.
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
                let secs = TimeInterval(durationToSeconds(timeout))
                DispatchQueue.global().asyncAfter(deadline: .now() + secs, execute: timeoutWorkItem)

                // Stream stdout line-by-line. `FileHandle.bytes` would be
                // ideal, but its line-mode parser doesn't exist on Foundation;
                // we hand-roll it with a buffer that splits on `\n`.
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                var buffer = Data()
                while true {
                    let chunk: Data
                    do {
                        chunk = try stdoutHandle.read(upToCount: 64 * 1024) ?? Data()
                    } catch {
                        chunk = Data()
                    }
                    if chunk.isEmpty {
                        break
                    }
                    buffer.append(chunk)
                    while let nlIndex = buffer.firstIndex(of: 0x0A) { // '\n'
                        let lineData = buffer.subdata(in: 0..<nlIndex)
                        buffer.removeSubrange(0...nlIndex)
                        guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
                            continue
                        }
                        for event in decodeLine(line) {
                            continuation.yield(event)
                        }
                    }
                }
                // Flush trailing buffer (no-newline tail).
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    for event in decodeLine(line) {
                        continuation.yield(event)
                    }
                }

                process.waitUntilExit()
                timeoutWorkItem.cancel()

                // Drain stderr now that the process has exited.
                let stderrData = (try? stderrHandle.readToEnd()) ?? Data()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if box.didTimeout {
                    continuation.yield(.error("timeout"))
                } else if process.terminationStatus != 0 {
                    let payload = stderr.isEmpty
                        ? "claude exited with status \(process.terminationStatus)"
                        : stderr
                    continuation.yield(.error(payload))
                }
                continuation.finish()
            }

            // Cancellation: when the consumer drops the stream, terminate the
            // child cleanly. Slice 07's UI doesn't expose this yet (slice 13
            // does), but having it wired now keeps later slices simple.
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

    // MARK: - Env construction

    /// Builds a minimal env that lets `claude` find HOME (its config /
    /// credentials live there) and includes the standard tool dirs in PATH so
    /// claude's tool calls can shell out to `gh` / `git`. Also includes the
    /// directory containing the resolved `claude` binary itself, in case
    /// `claude` resolves sibling binaries by relative lookups.
    static func buildClaudeEnv(executable: URL) -> [String: String] {
        var env: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        if let home = inherited["HOME"] { env["HOME"] = home }
        if let user = inherited["USER"] { env["USER"] = user }
        if let term = inherited["TERM"] { env["TERM"] = term }

        // Pass through any ANTHROPIC_* / CLAUDE_* env the user has set —
        // necessary for non-default model selection or alternative auth.
        for (k, v) in inherited where k.hasPrefix("ANTHROPIC_") || k.hasPrefix("CLAUDE_") {
            env[k] = v
        }

        // PATH: union of resolved-binary parent dirs and the canonical install
        // locations. Order: most-specific (resolved tool dirs) before generic.
        var pathParts: [String] = []
        let exeDir = executable.deletingLastPathComponent().path
        pathParts.append(exeDir)
        for tool in [Tool.gh, Tool.git, Tool.idea] {
            if let url = BinaryResolver.resolve(tool) {
                let dir = url.deletingLastPathComponent().path
                if !pathParts.contains(dir) { pathParts.append(dir) }
            }
        }
        for dir in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            if !pathParts.contains(dir) { pathParts.append(dir) }
        }
        env["PATH"] = pathParts.joined(separator: ":")
        return env
    }

    // MARK: - Line decoding

    /// Decode one stream-json line into zero or more `ClaudeEvent`s. Multiple
    /// events per line are possible in the partial-content case (e.g. a single
    /// `content_block_start` carrying both a tool name and an initial text
    /// snippet). On parse failure the line is dropped silently — we'd rather
    /// lose one event than crash the stream.
    static func decodeLine(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8) else { return [] }
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return []
        }
        guard let type = raw["type"] as? String else { return [] }

        var events: [ClaudeEvent] = []
        switch type {
        case "stream_event":
            if let event = raw["event"] as? [String: Any] {
                events.append(contentsOf: decodeStreamEvent(event))
            }
        case "result":
            events.append(contentsOf: decodeResultEvent(raw, line: line))
        default:
            // system/init, assistant/user message bookkeeping, etc. — drop.
            break
        }
        return events
    }

    private static func decodeStreamEvent(_ event: [String: Any]) -> [ClaudeEvent] {
        guard let eventType = event["type"] as? String else { return [] }
        switch eventType {
        case "content_block_delta":
            // {"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}
            if let delta = event["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String {
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    return [.textDelta(text)]
                }
                if deltaType == "input_json_delta" {
                    // tool argument streaming — surface nothing; the
                    // content_block_start for the tool already fired.
                    return []
                }
            }
            return []
        case "content_block_start":
            // {"event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"…"}}}
            if let block = event["content_block"] as? [String: Any] {
                if let blockType = block["type"] as? String, blockType == "tool_use",
                   let name = block["name"] as? String {
                    return [.toolUse(name: name)]
                }
                // text blocks may carry an initial chunk — emit it as a delta
                // so the modal sees first-paint output without waiting for the
                // first content_block_delta.
                if let blockType = block["type"] as? String, blockType == "text",
                   let text = block["text"] as? String, !text.isEmpty {
                    return [.textDelta(text)]
                }
            }
            return []
        default:
            return []
        }
    }

    private static func decodeResultEvent(_ raw: [String: Any], line: String) -> [ClaudeEvent] {
        let subtype = raw["subtype"] as? String ?? ""

        // Error subtypes: surface stderr-style payload.
        if subtype.hasPrefix("error") {
            let detail = (raw["result"] as? String) ?? subtype
            return [.error(detail)]
        }

        // Success subtype: structured payload. `result` is either:
        //   - a JSON-encoded string (legacy / common): `"result": "{\"summary\":\"…\"}"`.
        //   - a JSON object directly under `result`.
        // We handle both by re-encoding to canonical JSON and decoding against
        // `ReviewSchema`.
        if let resultString = raw["result"] as? String {
            return decodeResultPayload(resultString)
        }
        if let resultObject = raw["result"] as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: resultObject, options: [.sortedKeys]) {
                if let json = String(data: data, encoding: .utf8) {
                    return decodeResultPayload(json)
                }
            }
        }
        // Couldn't extract a structured payload from a non-error result — log
        // the raw line as an error so the user sees what came back.
        return [.error("Unrecognized result payload: \(line)")]
    }

    /// Decode a JSON string against `ReviewSchema`. Pretty-print the same
    /// payload to feed `Review.rawResultJSON` and the modal's raw tab.
    static func decodeResultPayload(_ json: String) -> [ClaudeEvent] {
        guard let data = json.data(using: .utf8) else {
            return [.error("Result was not valid UTF-8")]
        }
        let decoder = JSONDecoder()
        do {
            let decoded = try decoder.decode(ReviewSchema.self, from: data)
            // Pretty-print for display + persistence. JSONSerialization is
            // happy to round-trip the bytes; if that fails, fall back to the
            // raw string so we never block the success path on cosmetic issues.
            let pretty: String = {
                if let obj = try? JSONSerialization.jsonObject(with: data, options: []),
                   let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: prettyData, encoding: .utf8) {
                    return s
                }
                return json
            }()
            return [.finalResult(rawJSON: pretty, decoded: decoded)]
        } catch {
            return [.error("Failed to decode result against ReviewSchema: \(error)")]
        }
    }

    // MARK: - Helpers

    /// Convert `Duration` to seconds — `Duration` doesn't expose a TimeInterval
    /// accessor in stable Foundation, so we read the components manually.
    static func durationToSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}
