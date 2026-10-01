# 05 — Deployments tab parity

> **Removed in the open-source release.** The tab was hard-wired to one organisation's GitHub org, deploy workflow and service list, so it was deleted rather than generalised. Kept here as design history.

## What to build

Port the Deployments tab to SwiftUI at feature parity with `index.html`.

Behavior:

- Hardcoded org `acme`, hardcoded workflow name (`DEPLOY_WORKFLOW`), hardcoded `SERVICES` array. (Configurable settings come later — out of scope here.)
- For each service, query GitHub Actions workflow runs and find the latest run per environment (prod / dev) by paging through up to 200 runs (2 pages × 100). Avoids prod info being buried by frequent dev deploys.
- A pure `DeploymentsParser` service exposes `parse(runName: String) -> Deployment?` that extracts `(env, version)` from run names (e.g. `[dev] Deploy v1.21.1-feature-xyz-snapshot`).
- Cards render progressively: skeleton cards appear immediately, each fills as its API call resolves.
- `GitHubClient` gains `fetchWorkflowRuns(repo, workflow, perPage, pages)`.

## Acceptance criteria

- [ ] All services from `SERVICES` array render skeleton cards on first refresh.
- [ ] Each card progressively fills with prod + dev deployment info.
- [ ] Latest deploy per environment is correctly identified even when later prod runs are buried by dev runs.
- [ ] `DeploymentsParser` correctly extracts env and version from real run names.
- [ ] Cards show service, env, version, and a relative timestamp.
- [ ] Behavior matches current `index.html` Deployments tab.

## Blocked by

- Issue 01 (App skeleton + Reviews tab MVP)
