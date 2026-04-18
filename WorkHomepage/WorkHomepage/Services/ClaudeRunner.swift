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
    /// `result` payload (used for the "raw" tab in the modal); `decoded` is
    /// the same payload typed against `ReviewSchema`, or `nil` when the
    /// payload could not be structure-decoded. The orchestrator persists the
    /// raw JSON regardless, so the user always sees what claude actually said.
    case finalResult(rawJSON: String, decoded: ReviewSchema?)
    /// Anything terminal that isn't a structured result: stderr, timeout,
    /// non-zero exit, missing `claude` binary. Decode failure is NOT an error
    /// — it surfaces as `.finalResult(rawJSON:, decoded: nil)`.
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
    /// Hard cap on the per-line stdout buffer. A misbehaving child that emits a
    /// single multi-MB line without a newline must not OOM the app.
    private static let maxLineBufferBytes = 1 * 1024 * 1024
    /// Hard cap on captured stderr. We only need a tail for diagnostics; if a
    /// child spews indefinitely we keep the most-recent slice.
    private static let maxStderrBytes = 256 * 1024

    static func makeStream(
        executable: URL,
        arguments: [String],
        cwd: URL,
        timeout: Duration
    ) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in

            // Lock-protected box so timeout / cancellation / exit handlers can
            // safely observe Process state from any queue. The previous
            // `@unchecked Sendable` mutable struct raced kill() against
            // process construction.
            final class ProcessBox: @unchecked Sendable {
                private let lock = NSLock()
                private var _process: Process?
                private var _didTimeout: Bool = false
                var process: Process? {
                    get { lock.lock(); defer { lock.unlock() }; return _process }
                    set { lock.lock(); defer { lock.unlock() }; _process = newValue }
                }
                var didTimeout: Bool {
                    get { lock.lock(); defer { lock.unlock() }; return _didTimeout }
                    set { lock.lock(); defer { lock.unlock() }; _didTimeout = newValue }
                }
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

                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                // Drain stderr concurrently — Pipe buffer is ~16-64KB. If we
                // wait for the child to exit before reading, a chatty child
                // fills its stderr buffer and blocks on write() forever, hanging
                // the parent on waitUntilExit(). Bounded ring-style: once we hit
                // maxStderrBytes we keep only the trailing slice.
                let stderrLock = NSLock()
                var stderrBuffer = Data()
                stderrHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        // EOF — release the handler so it doesn't leak.
                        handle.readabilityHandler = nil
                        return
                    }
                    stderrLock.lock()
                    stderrBuffer.append(chunk)
                    if stderrBuffer.count > maxStderrBytes {
                        let drop = stderrBuffer.count - maxStderrBytes
                        stderrBuffer.removeFirst(drop)
                    }
                    stderrLock.unlock()
                }

                // Set process box BEFORE run() returns so a fast onTermination
                // (consumer drops the stream during run()) can still find the
                // pid. `p.isRunning` will be false until run() succeeds, so a
                // premature kill is a no-op.
                box.process = process

                do {
                    try process.run()
                } catch {
                    stderrHandle.readabilityHandler = nil
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    continuation.yield(.error("Failed to launch \(executable.path): \(error.localizedDescription)"))
                    continuation.finish()
                    return
                }

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
                var buffer = Data()
                var aborted = false
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
                    // Per-line OOM guard. If the child emits a giant single
                    // line (no newline) we'd otherwise grow buffer without
                    // bound. SIGTERM the child and bail.
                    if buffer.count > maxLineBufferBytes {
                        aborted = true
                        if let p = box.process, p.isRunning {
                            kill(p.processIdentifier, SIGTERM)
                        }
                        continuation.yield(.error("claude output exceeded \(maxLineBufferBytes) bytes on a single line; aborting"))
                        break
                    }
                }
                // Flush trailing buffer (no-newline tail) only if we didn't
                // abort.
                if !aborted, !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    for event in decodeLine(line) {
                        continuation.yield(event)
                    }
                }

                process.waitUntilExit()
                timeoutWorkItem.cancel()

                // Tear down stderr drain and snapshot whatever we accumulated.
                stderrHandle.readabilityHandler = nil
                stderrLock.lock()
                let stderrSnapshot = stderrBuffer
                stderrLock.unlock()
                let stderr = String(data: stderrSnapshot, encoding: .utf8) ?? ""

                // Explicitly close pipe FDs so they're released immediately
                // rather than waiting for ARC to drop the Pipe instance.
                try? stdoutHandle.close()
                try? stderrHandle.close()
                box.process = nil

                if box.didTimeout {
                    continuation.yield(.error("timeout"))
                } else if !aborted, process.terminationStatus != 0 {
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
                guard let p = box.process, p.isRunning else { return }
                kill(p.processIdentifier, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak box] in
                    guard let p = box?.process, p.isRunning else { return }
                    kill(p.processIdentifier, SIGKILL)
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
        // `ReviewSchema`. On decode failure we still emit `.finalResult` with
        // the raw payload preserved and `decoded: nil` — the run finished, the
        // modal needs to surface what came back.
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
        // Couldn't extract any payload at all — emit a finalResult with the
        // raw line so the user still sees something, rather than a useless
        // "unrecognized" error that hides claude's output.
        return [.finalResult(rawJSON: line, decoded: nil)]
    }

    /// Decode a JSON string against `ReviewSchema`. Pretty-print the same
    /// payload to feed `Review.rawResultJSON` and the modal's raw tab.
    ///
    /// Robustness contract: this NEVER returns `.error`. Either it finds
    /// JSON it can decode (returns `.finalResult` with `decoded` set), or it
    /// returns `.finalResult` with `decoded: nil` and the raw payload
    /// preserved verbatim so the user can still read what claude said.
    /// `claude --json-schema` is best-effort, not enforced — the payload may
    /// arrive wrapped in a markdown fence, prefixed with prose, or with
    /// renamed fields.
    static func decodeResultPayload(_ json: String) -> [ClaudeEvent] {
        let candidates = candidateJSONStrings(from: json)
        let decoder = JSONDecoder()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(ReviewSchema.self, from: data) {
                let pretty = prettyPrint(data: data, fallback: candidate)
                return [.finalResult(rawJSON: pretty, decoded: decoded)]
            }
        }
        // No candidate decoded. Preserve the raw payload (prefer the first
        // pretty-printable candidate; otherwise the original input) so the
        // modal can still show the user what came back.
        if let first = candidates.first,
           let data = first.data(using: .utf8) {
            let pretty = prettyPrint(data: data, fallback: first)
            return [.finalResult(rawJSON: pretty, decoded: nil)]
        }
        return [.finalResult(rawJSON: json, decoded: nil)]
    }

    /// Pretty-print JSON if the input parses, otherwise return the fallback
    /// string verbatim. Used so the raw-display tab always shows formatted
    /// JSON when possible without silently dropping the payload on parse
    /// failure.
    private static func prettyPrint(data: Data, fallback: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: prettyData, encoding: .utf8) {
            return s
        }
        return fallback
    }

    /// Produce a list of candidate JSON strings to try, in order of
    /// preference, by stripping common wrappers claude tends to add despite
    /// the `--json-schema` flag:
    ///   1. Input as-is.
    ///   2. Trimmed of leading/trailing whitespace.
    ///   3. Markdown code fence stripped (` ```json\n...\n``` ` or
    ///      ` ```\n...\n``` `).
    ///   4. Largest balanced `{...}` substring (handles prose preamble /
    ///      trailing commentary).
    /// Duplicates and empty strings are filtered out.
    static func candidateJSONStrings(from input: String) -> [String] {
        var candidates: [String] = []
        let seenLock = NSLock()
        var seen = Set<String>()
        func push(_ s: String) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            seenLock.lock()
            defer { seenLock.unlock() }
            if seen.insert(trimmed).inserted {
                candidates.append(trimmed)
            }
        }

        push(input)

        // Strip markdown code fence: ```json\n...\n``` or ```\n...\n```.
        if let fenced = stripCodeFence(input) {
            push(fenced)
        }

        // Extract the largest top-level balanced `{...}` substring.
        if let balanced = extractBalancedObject(from: input) {
            push(balanced)
        }
        // Also try balanced extraction after fence stripping in case the
        // fenced content itself has prose around the JSON.
        if let fenced = stripCodeFence(input),
           let balanced = extractBalancedObject(from: fenced) {
            push(balanced)
        }

        return candidates
    }

    /// Strip a leading ` ```...\n ` and trailing ` ``` ` if both are present.
    /// Returns `nil` when the input isn't fenced (caller falls back to other
    /// strategies).
    private static func stripCodeFence(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return nil }
        // Drop the opening fence line (everything up to and including the
        // first newline). Tolerate ```json, ```JSON, ```  json, etc.
        guard let firstNewline = trimmed.firstIndex(of: "\n") else { return nil }
        let afterOpen = trimmed[trimmed.index(after: firstNewline)...]
        // Drop a trailing ``` (with optional trailing whitespace/newlines).
        let body = String(afterOpen)
        let bodyTrimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bodyTrimmed.hasSuffix("```") else { return nil }
        let withoutClose = bodyTrimmed.dropLast(3)
        return String(withoutClose).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Find the largest balanced `{...}` substring in `input`, ignoring
    /// braces that appear inside JSON string literals (with backslash
    /// escaping). Returns nil when no balanced object is found. This handles
    /// `Here is my review:\n{...}\nHope it helps!` shaped inputs.
    static func extractBalancedObject(from input: String) -> String? {
        let scalars = Array(input)
        var bestStart: Int?
        var bestEnd: Int?
        var bestLength = 0

        var i = 0
        while i < scalars.count {
            if scalars[i] == "{" {
                if let endIdx = matchBalancedObject(scalars, startingAt: i) {
                    let length = endIdx - i + 1
                    if length > bestLength {
                        bestLength = length
                        bestStart = i
                        bestEnd = endIdx
                    }
                    // Skip past this balanced block so we don't re-scan its
                    // interior; nested objects can't be larger than the
                    // enclosing one.
                    i = endIdx + 1
                    continue
                }
            }
            i += 1
        }

        guard let s = bestStart, let e = bestEnd else { return nil }
        return String(scalars[s...e])
    }

    /// Walk forward from `startingAt` (which must point to `{`) and return
    /// the index of the matching `}`, or nil if no match exists. String
    /// literals are skipped over so braces inside `"..."` don't fool the
    /// counter; backslash escapes inside strings are honoured.
    private static func matchBalancedObject(_ scalars: [Character], startingAt: Int) -> Int? {
        guard startingAt < scalars.count, scalars[startingAt] == "{" else { return nil }
        var depth = 0
        var i = startingAt
        var inString = false
        var escape = false
        while i < scalars.count {
            let c = scalars[i]
            if inString {
                if escape {
                    escape = false
                } else if c == "\\" {
                    escape = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return i
                    }
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Helpers

    /// Convert `Duration` to seconds — `Duration` doesn't expose a TimeInterval
    /// accessor in stable Foundation, so we read the components manually.
    static func durationToSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}
