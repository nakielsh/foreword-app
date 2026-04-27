//
//  JiraClient.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//  Slice 11 — adds the subtask parent fallback: when a subtask's own
//  description is too thin to stand alone, we also fetch its parent and
//  attach it under `JiraTicket.parent`. Strictly one level — the parent's
//  own parent is never fetched.
//  Slice 12 — adds an optional SwiftData `ModelContext` cache. Every
//  `fetchTicket(key:)` first hits Jira with `?fields=updated` (cheap), and
//  if a cached row exists with a matching `updated` we skip the full fetch.
//  Parent fallbacks participate in the same cache. Cache I/O is best-effort —
//  any error there just falls back to the network path.
//
//  Thin Atlassian Cloud REST client with one public method:
//  `fetchTicket(key:)`. Reads credentials from `JiraConfig` (base URL in
//  UserDefaults, email + API token in Keychain) and authenticates via
//  HTTP Basic.
//
//  Returns a value-type `JiraTicket` with the description flattened from
//  ADF (Atlassian Document Format) to plaintext. ADF flattening is a
//  small recursive walk — we don't try to render real markdown, the LLM
//  doesn't need it.
//
//  Errors:
//    - `.notConfigured` — base URL / email / token missing. Orchestrator
//       catches and proceeds without Jira context.
//    - `.unauthorized` — 401. Surfaced so settings can prompt the user.
//    - `.ticketNotFound` — 404. Caller should treat the same as "no key
//       on the branch" (return nil from `fetchTicket`).
//    - `.http(status, body)` — other non-2xx. Orchestrator logs + drops.
//
//  TODO (post-slice-18): swap `ReviewOrchestrator.fetchJiraTicket` to
//  construct `JiraClient(context: ...)` so production runs share the cache
//  across reviews. Slice 12 keeps the orchestrator on the no-context path
//  to honour the parallel-agent merge-conflict avoidance rule for slice 14.
//

import Foundation
import SwiftData

struct JiraClient {

    /// Threshold (in plaintext characters, post ADF flatten) below which a
    /// subtask's own description is considered "thin" and we additionally
    /// fetch the parent ticket. ~100 chars is roughly two short sentences:
    /// less than that and the subtask is almost certainly title-only with
    /// the real spec living on the parent (the team's working pattern per
    /// PRD Q6c). Above that we trust the subtask alone and skip the extra
    /// network round-trip.
    static let thinDescriptionThreshold: Int = 100

    enum JiraError: Error, Equatable {
        case notConfigured
        case unauthorized
        case http(Int, String)
        case ticketNotFound
        /// JSON decode / shape failure. Distinct from `.http(0, …)` so
        /// the cache layer knows not to serve stale data — a malformed
        /// response is an upstream incident, not transport flakiness.
        case decoding(String)
    }

    private let session: URLSession
    private let baseURLProvider: () -> String?
    private let emailProvider: () -> String?
    private let tokenProvider: () -> String?

    /// Optional cache backing. When `nil` (the default) every `fetchTicket`
    /// goes straight to the network — no cheap update check, no upsert.
    /// Slice 12 wires this when callers opt in. Marked `@MainActor` because
    /// SwiftData `ModelContext` is main-actor-isolated.
    private let cache: Cache?

    init(
        session: URLSession = .shared,
        baseURLProvider: @escaping () -> String? = { JiraConfig.getBaseURL() },
        emailProvider: @escaping () -> String? = { JiraConfig.getEmail() },
        tokenProvider: @escaping () -> String? = { JiraConfig.getToken() },
        context: ModelContext? = nil
    ) {
        self.session = session
        self.baseURLProvider = baseURLProvider
        self.emailProvider = emailProvider
        self.tokenProvider = tokenProvider
        if let context {
            self.cache = Cache(context: context)
        } else {
            self.cache = nil
        }
    }

    // MARK: - Public API

    /// Fetch a ticket by key. Returns nil for 404 (the caller treats that the
    /// same as no-key-on-branch). Throws for unauthorized, missing config, or
    /// other non-2xx HTTP responses.
    ///
    /// Slice 11: if the fetched ticket is a subtask (`parentKey != nil`) and
    /// its own description is shorter than `thinDescriptionThreshold`
    /// characters of plaintext, also fetch the parent and attach it under
    /// `parent`. Hard rule: never fetch the parent's parent — one level only.
    ///
    /// Slice 12: when a `ModelContext` was supplied, every fetch starts with
    /// a cheap `?fields=updated` projection. A cache hit (same `updated`
    /// timestamp) returns the persisted row without a full fetch; a cache
    /// miss fetches the full ticket and upserts. Network errors on the cheap
    /// call fall back to the cached value when one is present.
    func fetchTicket(key: String) async throws -> JiraTicket? {
        let resolvedSubtask = try await resolveTicket(key: key)

        // No parent → nothing to fall back to.
        guard let parentKey = resolvedSubtask.parentKey, !parentKey.isEmpty else {
            return resolvedSubtask
        }

        // Subtask description is rich enough to stand on its own.
        if resolvedSubtask.description.count >= Self.thinDescriptionThreshold {
            return resolvedSubtask
        }

        // Thin subtask: resolve the parent through the same cache-aware path.
        // We deliberately discard any deeper ancestry — even if the parent
        // itself claims a parent, we drop it so the recursion terminates
        // strictly at one level.
        let parent: JiraTicket
        do {
            let rawParent = try await resolveTicket(key: parentKey)
            parent = JiraTicket(
                key: rawParent.key,
                summary: rawParent.summary,
                description: rawParent.description,
                status: rawParent.status,
                issueType: rawParent.issueType,
                priority: rawParent.priority,
                parentKey: rawParent.parentKey,
                parent: nil // hard cap — no grandparent fetch, ever.
            )
        } catch JiraError.ticketNotFound {
            // Parent vanished or permissions changed: degrade gracefully and
            // return the subtask as-is rather than failing the whole fetch.
            return resolvedSubtask
        }

        return JiraTicket(
            key: resolvedSubtask.key,
            summary: resolvedSubtask.summary,
            description: resolvedSubtask.description,
            status: resolvedSubtask.status,
            issueType: resolvedSubtask.issueType,
            priority: resolvedSubtask.priority,
            parentKey: resolvedSubtask.parentKey,
            parent: parent
        )
    }

    // MARK: - Cache-aware single-ticket resolution

    /// One ticket, possibly served from the cache. Mirrors the shape of
    /// `fetchTicketRaw` but folds in the cheap update check + cache I/O when
    /// a `ModelContext` is configured. Used twice from `fetchTicket(key:)`
    /// (once for the subtask, once for its parent).
    ///
    /// Flow:
    /// 1. If no cache: fall straight through to `fetchTicketRaw`.
    /// 2. With cache: hit `?fields=updated` first.
    ///    a. Cheap call succeeds + cache row matches: serve from cache.
    ///    b. Cheap call succeeds + no row OR `updated` mismatch: do the full
    ///       fetch and upsert.
    ///    c. Cheap call fails with a *network* error: if a cached row
    ///       exists, return it (logged) — we'd rather show stale data than
    ///       block a review on a flaky network. Auth and 404 errors still
    ///       propagate.
    private func resolveTicket(key: String) async throws -> JiraTicket {
        guard let cache else {
            return try await fetchTicketRaw(key: key)
        }

        let updatedResult: Result<String, Error>
        do {
            updatedResult = .success(try await fetchUpdated(key: key))
        } catch {
            updatedResult = .failure(error)
        }

        switch updatedResult {
        case .success(let upstreamUpdated):
            if let cached = await cache.lookup(key: key),
               cached.updated == upstreamUpdated {
                return cached.ticket
            }
            // Cache miss or stale → full fetch + upsert.
            let fresh = try await fetchTicketRaw(key: key)
            await cache.upsert(ticket: fresh, updated: upstreamUpdated)
            return fresh

        case .failure(let error):
            // Auth / 404 / HTTP / decode errors are real signals — propagate.
            // Only pure transport failures fall through to the stale-cache path.
            if let jiraError = error as? JiraError {
                switch jiraError {
                case .notConfigured, .unauthorized, .ticketNotFound, .http, .decoding:
                    throw jiraError
                }
            }
            // Pure network/transport error. Try to ride it out with stale
            // data if we have any.
            if let cached = await cache.lookup(key: key) {
                NSLog("[JiraClient] cheap update check failed for \(key) (\(error)); serving cached row.")
                return cached.ticket
            }
            throw error
        }
    }

    // MARK: - Cheap "?fields=updated" projection

    /// Fetch only the `updated` field for `key`. Pure network — never touches
    /// the cache. Throws the same errors as `fetchTicketRaw` so the caller
    /// can branch on auth vs transport vs not-found.
    ///
    /// Decode failures throw `JiraError.decoding` (not `.http(0,…)`) so the
    /// cache layer can distinguish "Jira returned 200 with garbage" from
    /// "the network dropped". The former is an upstream incident — serving
    /// stale data masks it. The latter is recoverable, and stale data is
    /// the right call.
    private func fetchUpdated(key: String) async throws -> String {
        let request = try makeRequest(key: key, fields: "updated")

        // session.data throws URLError on transport failures. We let those
        // bubble untouched so `resolveTicket` can detect them as
        // non-JiraError and fall through to the stale-cache path.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JiraError.http(0, "No HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                let parsed = try JSONSerialization.jsonObject(with: data)
                guard let json = parsed as? [String: Any] else {
                    throw JiraError.decoding("cheap-fetch response is not a JSON object")
                }
                guard let fields = json["fields"] as? [String: Any] else {
                    throw JiraError.decoding("cheap-fetch response missing `fields`")
                }
                guard let updated = fields["updated"] as? String else {
                    throw JiraError.decoding("cheap-fetch response missing `fields.updated`")
                }
                return updated
            } catch let jiraError as JiraError {
                throw jiraError
            } catch {
                throw JiraError.decoding("cheap-fetch JSON parse failed: \(error.localizedDescription)")
            }
        case 401:
            throw JiraError.unauthorized
        case 404:
            throw JiraError.ticketNotFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JiraError.http(http.statusCode, body)
        }
    }

    // MARK: - Full ticket fetch

    /// Network + decode for a single ticket — no parent-fallback logic, no
    /// cache. Used by `resolveTicket` after a cache miss / mismatch.
    private func fetchTicketRaw(key: String) async throws -> JiraTicket {
        let fields = "summary,description,status,issuetype,priority,parent"
        let request = try makeRequest(key: key, fields: fields)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JiraError.http(0, "No HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            return try Self.decodeTicket(data: data)
        case 401:
            throw JiraError.unauthorized
        case 404:
            throw JiraError.ticketNotFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JiraError.http(http.statusCode, body)
        }
    }

    // MARK: - Request building

    /// Build a `URLRequest` for `GET /rest/api/3/issue/<key>?fields=<fields>`,
    /// including the basic-auth header and our 15s timeout. Centralised so
    /// `fetchUpdated` and `fetchTicketRaw` agree on every header byte.
    private func makeRequest(key: String, fields: String) throws -> URLRequest {
        guard let rawBase = baseURLProvider(), !rawBase.isEmpty,
              let email = emailProvider(), !email.isEmpty,
              let token = tokenProvider(), !token.isEmpty
        else {
            throw JiraError.notConfigured
        }

        // Strip trailing slashes so we don't end up with `//rest/...`.
        var base = rawBase
        while base.hasSuffix("/") { base.removeLast() }

        let path = "/rest/api/3/issue/\(key)?fields=\(fields)"
        guard let url = URL(string: base + path) else {
            throw JiraError.http(0, "Invalid base URL")
        }

        let credential = "\(email):\(token)"
        guard let credData = credential.data(using: .utf8) else {
            throw JiraError.http(0, "Could not encode credentials")
        }
        let basic = "Basic " + credData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basic, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    // MARK: - Decoding

    /// Decodes the Atlassian Cloud `GET /rest/api/3/issue/<key>` response.
    /// Pulled out so tests can exercise it without spinning up URLSession.
    ///
    /// Throws `JiraError.decoding` when the response body is structurally
    /// invalid (not a JSON object, or missing the `key` field). Other
    /// fields stay defaulted — only `key` is load-bearing because the
    /// cache and downstream features are keyed on it.
    static func decodeTicket(data: Data) throws -> JiraTicket {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JiraError.decoding("Response JSON parse failed: \(error.localizedDescription)")
        }
        guard let json = parsed as? [String: Any] else {
            throw JiraError.decoding("Response is not a JSON object")
        }

        let rawKey = (json["key"] as? String) ?? ""
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            throw JiraError.decoding("Ticket payload missing `key`")
        }
        let fields = json["fields"] as? [String: Any] ?? [:]

        let summary = fields["summary"] as? String ?? ""

        let status: String = {
            if let s = fields["status"] as? [String: Any], let name = s["name"] as? String {
                return name
            }
            return ""
        }()

        let issueType: String = {
            if let t = fields["issuetype"] as? [String: Any], let name = t["name"] as? String {
                return name
            }
            return ""
        }()

        let priority: String? = {
            if let p = fields["priority"] as? [String: Any], let name = p["name"] as? String {
                return name.isEmpty ? nil : name
            }
            return nil
        }()

        let parentKey: String? = {
            if let parent = fields["parent"] as? [String: Any], let pk = parent["key"] as? String, !pk.isEmpty {
                return pk
            }
            return nil
        }()

        let description = flattenADF(fields["description"])

        return JiraTicket(
            key: key,
            summary: summary,
            description: description,
            status: status,
            issueType: issueType,
            priority: priority,
            parentKey: parentKey
        )
    }

    // MARK: - ADF flattening

    /// Block-level ADF nodes that should each contribute a paragraph break
    /// after their inline content. List items are blocks too — each bullet
    /// becomes its own paragraph in the flattened text.
    private static let blockTypes: Set<String> = [
        "paragraph",
        "heading",
        "blockquote",
        "codeBlock",
        "listItem",
        "bulletList",
        "orderedList",
        "rule",
        "panel",
        "mediaSingle",
        "mediaGroup"
    ]

    /// Recursion depth ceiling for ADF traversal. Pathological inputs
    /// (deeply nested lists / panels / tables) could otherwise blow the
    /// stack on the main thread when a ticket description is rendered.
    /// 64 is well above any human-authored ticket but cheap to enforce.
    static let maxADFDepth: Int = 64

    /// Walk an ADF document recursively, concatenating `text` fields and
    /// emitting `\n\n` between top-level paragraph / heading / list-item
    /// boundaries.
    ///
    /// `input` is whatever Foundation got back from
    /// `JSONSerialization.jsonObject` for the `description` field — most
    /// commonly a `[String: Any]` document object, but may be `NSNull` /
    /// nil / a String (legacy Wiki Markup tickets).
    static func flattenADF(_ input: Any?) -> String {
        guard let input else { return "" }
        if input is NSNull { return "" }

        // Some Jira instances still return Wiki-Markup descriptions as a
        // bare string. Surface it verbatim — better than dropping it.
        if let s = input as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }

        let raw = walk(input, depth: 0)

        // Collapse runs of 3+ newlines down to exactly two.
        var collapsed = raw
        while collapsed.contains("\n\n\n") {
            collapsed = collapsed.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the inline text + trailing block-break for a single node.
    /// `depth` tracks nesting; once it exceeds `maxADFDepth` we stop
    /// descending and return an empty string. Hard cap on stack growth.
    private static func walk(_ node: Any, depth: Int) -> String {
        if depth > maxADFDepth { return "" }
        guard let dict = node as? [String: Any] else {
            // Unknown node shape (e.g. an array at the top of `walk` —
            // only walkChildren passes those through). Drop it.
            return ""
        }

        let type = dict["type"] as? String ?? ""

        // Leaf text node.
        if type == "text" {
            return (dict["text"] as? String) ?? ""
        }

        // hardBreak — a single newline inside a paragraph.
        if type == "hardBreak" {
            return "\n"
        }

        // mention / emoji / inlineCard — best-effort inline text fallbacks
        // so we don't drop "@john" / ":+1:" / linked card titles.
        if type == "mention" {
            if let attrs = dict["attrs"] as? [String: Any], let text = attrs["text"] as? String {
                return text
            }
            return ""
        }
        if type == "emoji" {
            if let attrs = dict["attrs"] as? [String: Any], let text = attrs["text"] as? String {
                return text
            }
            if let attrs = dict["attrs"] as? [String: Any], let shortName = attrs["shortName"] as? String {
                return shortName
            }
            return ""
        }

        let children = walkChildren(dict["content"], depth: depth + 1)

        if blockTypes.contains(type) {
            // Block-level: end with a paragraph break so siblings stack
            // visibly. The outer flattenADF collapses runs of breaks.
            return children + "\n\n"
        }

        // doc, or any other container we don't specifically know about:
        // pass children through without injecting extra breaks.
        return children
    }

    /// Walk a `content` array and concatenate the result of each child.
    private static func walkChildren(_ content: Any?, depth: Int) -> String {
        if depth > maxADFDepth { return "" }
        guard let array = content as? [Any] else { return "" }
        var out = ""
        for child in array {
            out += walk(child, depth: depth)
        }
        return out
    }
}

// MARK: - Cache wrapper

extension JiraClient {

    /// Snapshot of a cached row, decoupled from SwiftData so it can cross
    /// actor boundaries. We take the values out under the `@MainActor`
    /// `lookup` and ferry them back as plain Sendable strings.
    fileprivate struct CachedSnapshot {
        let ticket: JiraTicket
        let updated: String
    }

    /// Main-actor-bound facade over a `ModelContext`. All SwiftData calls
    /// happen here so the rest of `JiraClient` can stay nonisolated and
    /// continue to do network work off the main thread.
    ///
    /// Marking the class `@MainActor` (rather than the previous
    /// `@unchecked Sendable` wrapper around `MainActor.run`) makes the
    /// isolation explicit to the compiler: `ModelContext` is captured
    /// here and only ever touched on the main actor. Off-main callers
    /// must `await` `lookup` / `upsert`.
    ///
    /// Errors inside the cache are deliberately swallowed: a broken cache
    /// must never break a review. The worst case is "we re-fetch every
    /// time", which is the slice-10 baseline.
    @MainActor
    fileprivate final class Cache {
        private let context: ModelContext

        init(context: ModelContext) {
            self.context = context
        }

        /// Main-actor SwiftData read. Off-main callers `await` this to
        /// hop onto the main actor for cache I/O.
        func lookup(key: String) -> CachedSnapshot? {
            lookupOnMain(key: key)
        }

        /// Main-actor SwiftData write. See `lookup` above.
        func upsert(ticket: JiraTicket, updated: String) {
            upsertOnMain(ticket: ticket, updated: updated)
        }

        private func lookupOnMain(key: String) -> CachedSnapshot? {
            do {
                let predicate = #Predicate<CachedJiraTicket> { $0.key == key }
                var descriptor = FetchDescriptor<CachedJiraTicket>(predicate: predicate)
                descriptor.fetchLimit = 1
                guard let row = try context.fetch(descriptor).first else { return nil }
                // Empty-string ↔ nil at the boundary: see the comment on
                // `CachedJiraTicket.priority` for the rationale.
                let ticket = JiraTicket(
                    key: row.key,
                    summary: row.summary,
                    description: row.descriptionText,
                    status: row.status,
                    issueType: row.issueType,
                    priority: row.priority.isEmpty ? nil : row.priority,
                    parentKey: row.parentKey.isEmpty ? nil : row.parentKey,
                    parent: nil
                )
                return CachedSnapshot(ticket: ticket, updated: row.updatedAt)
            } catch {
                NSLog("[JiraClient] cache lookup failed for \(key): \(error)")
                return nil
            }
        }

        private func upsertOnMain(ticket: JiraTicket, updated: String) {
            do {
                let key = ticket.key
                let predicate = #Predicate<CachedJiraTicket> { $0.key == key }
                var descriptor = FetchDescriptor<CachedJiraTicket>(predicate: predicate)
                descriptor.fetchLimit = 1
                if let existing = try context.fetch(descriptor).first {
                    existing.summary = ticket.summary
                    existing.descriptionText = ticket.description
                    existing.status = ticket.status
                    existing.issueType = ticket.issueType
                    existing.priority = ticket.priority ?? ""
                    existing.parentKey = ticket.parentKey ?? ""
                    existing.updatedAt = updated
                    existing.fetchedAt = Date()
                } else {
                    let row = CachedJiraTicket(
                        key: ticket.key,
                        summary: ticket.summary,
                        descriptionText: ticket.description,
                        status: ticket.status,
                        issueType: ticket.issueType,
                        priority: ticket.priority,
                        parentKey: ticket.parentKey,
                        updated: updated
                    )
                    context.insert(row)
                }
                try context.save()
            } catch {
                NSLog("[JiraClient] cache upsert failed for \(ticket.key): \(error)")
            }
        }
    }
}
