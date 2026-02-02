# 12 — Jira ticket cache

## What to build

Cache Jira tickets locally in SwiftData and skip refetches when nothing changed.

`JiraTicket` SwiftData model already defined (or added now): `(key, summary, description, parentKey?, updated, fetchedAt)`.

Cache strategy:

- On `JiraClient.fetchTicket(key)`:
  1. Hit Jira with `?fields=updated` first (cheap, returns only the `updated` timestamp).
  2. If a cached row exists with the same `updated`, return the cached ticket — no full fetch.
  3. Otherwise, fetch the full ticket fields and upsert the cache.
- Same cache logic applies to parent tickets fetched in slice 11.
- Cache survives app restart (SwiftData store on disk).
- A "Clear Jira cache" button in Settings drops all cached tickets.

## Acceptance criteria

- [ ] First fetch of a ticket performs a full network request and caches the result.
- [ ] Second fetch within the same session performs only the cheap `?fields=updated` check; if `updated` unchanged, returns cached.
- [ ] When `updated` changes upstream, the next fetch refreshes the cache.
- [ ] Parent ticket fetches (slice 11) participate in the same cache.
- [ ] "Clear Jira cache" button in Settings removes all cached `JiraTicket` rows.
- [ ] Cache miss on the cheap call (network error) falls back to cached value if present, with a warning toast.

## Blocked by

- Issue 10 (Jira basic)
