# The Remote Lane, End to End

How crabbox integrates with the Openroleio development process — from
session start to landing gate. Companion to `RUNBOOK.md` (coordinator
ops) and each project's own AGENTS.md testing conventions. ge
(`game-engine-v2`) is the worked example; any project with a bootstrap
script, a `.crabbox.yaml`, and a thin wrapper gets the same lifecycle.

## Who owns what

| Layer | Home | Contents |
| --- | --- | --- |
| Coordinator | this fork, `worker/` + Cloudflare | lease state, idle/TTL reaping, spend caps, GitHub auth, portal |
| Lane machinery | this fork, `ops/` | `converge.sh` (generic, flag-driven), reaper fallback, runbooks |
| Launcher hook | dev-tools `AgentLaunchers` | the ONLY crabbox awareness in dev-tools: stop the session's lease on clean exit |
| Project surface | each repo | bootstrap script, `.crabbox.yaml` (sync excludes, jobs, class), wrapper (ge: `scripts/remote-box.sh`), AGENTS.md policy |

## Lifecycle

1. **Session start.** Agents launch via `.dev_tools/scripts/agent-*`:
   exports `DEV_TOOLS_AGENT_SESSION=1` (adaptive test deadlines key on
   it) and arms the lease-cleanup exit trap. No box is leased yet —
   leasing is lazy.
2. **Normal work stays local.** Focused/single-file tests and routine
   cached gates never touch the lane. Full local gates serialize
   host-wide (dev-tools lock).
3. **First broad run leases a box.** `scripts/remote-box.sh` (ge) asks
   the coordinator for a lease (GitHub identity; no provider tokens on
   laptops; spend/lease caps enforced server-side), then
   `ops/converge.sh` makes it test-ready: idempotent bootstrap →
   sibling repos → git-bundle seed → `deps.get` (MUST re-run after
   siblings: conditional path deps) → optional gate. Cold ≈ 10 min,
   once per box.
4. **The box serves the whole session.** The wrapper records it
   (`.crabbox/box`), health-checks before reuse, and every
   `gate`/`contracts`/`run` syncs the dirty diff (~1.5s) and executes.
   Runs heartbeat the lease; an active box never idles out. Reconverge
   after commits is cheap: unchanged siblings and git state skip
   observably.
5. **Completion checks route by state** (project AGENTS.md policy the
   generated workflow checkpoints defer to): live box → full/strict
   check runs remotely; no box → local, and never lease for one gate;
   infrastructure-shaped remote failure → fall back local; genuine
   test failures bind either way; scoped/cached gates always local.
6. **Session end.** Clean exit → launcher trap stops the lease and
   clears state (single owner per worktree assumed). Any other death →
   the coordinator reaps the idle box ~30 min after its last run
   (verified live). The monthly spend cap bounds the worst case.
7. **Oversight.** Both developers are coordinator admins: every lease,
   run log, and the spend ledger are in the portal
   (`<coordinator>/portal`).

## Reference numbers (ge, 2026-07-23 spike)

ccx33-ash (8 dedicated cores, ~EUR 0.27/hr): strict full gate 243s ≈
local idle parity; 27-test latency-contract unit stable 5/5; warm sync
1.5s. Evidence: ge `implementation-plans/crabbox-remote-testing-spike.md`.

## Deferred

- N=2 engine partition re-run on ccx43+ (pending dedicated-core quota
  and its own protocol plan — provisional 27% gate win recorded).
- AWS arm (only if Hetzner disappoints); crabfleet (orchestration
  layer, revisit when the fleet grows); Hetzner orphan sweep gap is
  covered by `ops/crabbox-reaper.k8s.yaml`, unapplied.
