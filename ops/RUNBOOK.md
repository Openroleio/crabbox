# Openroleio Crabbox Ops

Everything crabbox-specific for Openroleio lives in this fork: the
coordinator deployment config (`worker/wrangler.jsonc` on
`openroleio-deploy`), the lane scripts in `ops/`, and this runbook.
Upstream code is UNMODIFIED — our diff is deployment vars only, plus
this `ops/` directory (which upstream does not have, so upgrades never
conflict here).

## The deployment

- Coordinator: https://crabbox-coordinator.casey-7c6.workers.dev
  (portal at `/portal`; health at `/v1/health`)
- Cloudflare account: casey@openrole.io (Workers Paid — Durable Objects)
- Login gate: GitHub org `Openroleio`
  (admins: `github:61361` jesserankin, `github:1229043` caseyrankin)
- Caps (vars in `worker/wrangler.jsonc`): $75/mo global, $50/owner,
  6 active leases, 3/owner
- Lease defaults: idle timeout 30m, TTL 1h30m (cap 24h). Idle expiry is
  heartbeat-extended; verified 2026-07-23: an idle box is deleted ~its
  idle window after last activity by per-lease DO alarm, no client
  involvement. NOTE: no Hetzner orphan sweep upstream (AWS/Azure only) —
  `ops/crabbox-reaper.k8s.yaml` is the unapplied backstop for the
  provisioning-crash window.

## Secrets (Cloudflare, via `wrangler secret put` — never in this repo)

`HETZNER_TOKEN`, `CRABBOX_GITHUB_CLIENT_ID`, `CRABBOX_GITHUB_CLIENT_SECRET`,
`CRABBOX_SESSION_SECRET`, `CRABBOX_ADMIN_TOKEN`.
The GitHub OAuth app lives under the Openroleio org
("Crabbox Coordinator"; callback `<public-url>/v1/auth/github/callback`).

## Redeploy (config change)

```sh
# needs CLOUDFLARE_API_TOKEN in env ("Edit Cloudflare Workers" template)
cd worker && npm ci && npx wrangler deploy
curl -s https://crabbox-coordinator.casey-7c6.workers.dev/v1/health
```

## Upgrade (upstream release)

1. `git fetch upstream` (upstream = openclaw/crabbox); merge a TAGGED
   release into `openroleio-deploy` — not main tip.
2. Read the release CHANGELOG and diff `worker/wrangler.jsonc` for new,
   renamed, or resemantic'd vars and any new required secrets.
3. `cd worker && npm ci && npm run check && npm test && npx wrangler deploy`
4. Verify `/v1/health` and `crabbox doctor` from a laptop.
5. Upgrade the CLI binaries on both machines the same day — CLI and
   coordinator versions should move together.

## Per-project onboarding

A project needs: its own `.crabbox.yaml` (sync excludes + jobs), its own
idempotent bootstrap script, and one documented invocation of
`ops/converge.sh`. See ge (`game-engine-v2`) for the reference:
`.crabbox.yaml`, `scripts/crabbox-bootstrap.sh`, and
`implementation-plans/crabbox-remote-lane.md`. Developers authenticate
once with `crabbox login --url <coordinator>`; no provider tokens on
laptops.
