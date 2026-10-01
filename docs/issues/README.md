# Issues

Vertical slices for the SwiftUI rewrite + Claude review feature. Source: `docs/PRD.md`.

No tracker configured — issues live as files here. When a tracker comes online, post each with the `ready-for-agent` label per the standard `to-issues` flow.

## Index

| # | Title | Type | Blocked by |
|---|-------|------|------------|
| 01 | App skeleton + Reviews tab MVP | AFK | — |
| 02 | Reviews tab full parity | AFK | 01 |
| 03 | My PRs tab parity | AFK | 01 |
| 04 | Sessions tab parity | AFK | 01 |
| 05 | Deployments tab parity _(removed in the open-source release)_ | AFK | 01 |
| 06 | BinaryResolver + first-run wizard | AFK | 01 |
| 07 | **Tracer bullet — end-to-end review** | **HITL** | 06 |
| 08 | Findings UI | AFK | 07 |
| 09 | IntelliJ launcher + finding click | AFK | 08 |
| 10 | Jira basic | AFK | 07 |
| 11 | Jira subtask parent fallback | AFK | 10 |
| 12 | Jira ticket cache | AFK | 10 |
| 13 | Concurrency cap + queue + cancellation | AFK | 07 |
| 14 | Review versioning + history | AFK | 08 |
| 15 | PR close cleanup + manual evict | AFK | 07 |
| 16 | MenuBarExtra | AFK | 01, 07 |
| 17 | Disk usage + per-repo evict | AFK | 06, 07 |
| 18 | **Cleanup + README/CLAUDE.md rewrite** | **HITL** | 02, 03, 04, 05 |
| 19 | Theme tracer (Botanical Garden palette + fonts + appearance toggle) | AFK | — |
| 20 | Theme rollout to remaining views | AFK | 19 |
| 21 | Avatar tracer (Reviews PR card author) | AFK | 19 |
| 22 | Avatar rollout (MyPRs reviewers + Review modal) | AFK | 21 |
| 23 | Custom Review Prompt Template | AFK | 19 |
| 24 | Pre-Review Summary tracer | AFK | 19 |
| 25 | Pre-Review Summary concurrency pool + retry | AFK | 24 |
| 26 | Jira badge | AFK | 19 |

## Suggested order

1. Foundation: 01 → (02, 03, 04, 05, 06 in parallel).
2. Tracer: 07 (HITL — design-review pipeline before piling features on).
3. Polish + features (most can run in parallel after 07): 08 → 09; 10 → (11, 12); 13; 14; 15; 16; 17.
4. Final cleanup: 18 (HITL — confirm before deleting legacy files).
5. PRD addendum: 19 → (20, 21, 23, 24, 26 in parallel) → (22 after 21, 25 after 24).
