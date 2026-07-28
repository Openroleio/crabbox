#!/usr/bin/env bash
# Stop crabbox leases whose owning local session is gone.
#
# A lease is bound to a worktree through its .crabbox/box state file
# (written by the project's remote-box.sh wrapper). Launcher EXIT traps
# release the lease on clean exit, but a crashed/killed session leaves the
# box for the coordinator's idle reaper — 90 minutes of paid idle since the
# 2026-07-25 --idle-timeout change (13/36 leases died this way in the
# 07-23..07-26 shakedown, ~44% of spend). This sweeper closes that gap
# locally: if no live process has its cwd inside the owning worktree, the
# session is dead and the box is stopped now instead of in 90 minutes.
#
# Intended to run from a systemd user timer every 10 minutes. Boxes leased
# manually (crabbox warmup, no state file) are outside its reach — it only
# logs `crabbox list` output for those, it never guesses at stopping them.
#
# Static-host lanes (the office box) never reach a coordinator idle reaper at
# all: nothing bills them, so nothing stops them, and their claim files under
# the crabbox state dir outlive the worktree state file they were created for.
# A second pass reaps those orphaned claims directly.
#
#   SWEEP_ROOTS   space-separated dirs whose children are scanned for
#                 .crabbox/box and .crabbox/box-office state files
#                 (default: ~/projects)
#   SWEEP_GRACE_MIN  skip state files and claims younger than this (default: 10)
#   SWEEP_CLAIMS_DIR crabbox claim state dir (default: XDG-derived)
#   SWEEP_CLAIM_GLOB claim files eligible for the claims pass
#                 (default: office-*.json — static lanes only)
#   SWEEP_DRY_RUN=1  report what would be swept and change nothing; also
#                 selected by passing --dry-run
set -uo pipefail

CRABBOX=${CRABBOX:-crabbox}
command -v "$CRABBOX" >/dev/null 2>&1 || CRABBOX="$HOME/Applications/crabbox"
LOG="$HOME/.crabbox-sweep.log"
GRACE_MIN=${SWEEP_GRACE_MIN:-10}
CLAIM_GLOB=${SWEEP_CLAIM_GLOB:-office-*.json}
DRY_RUN=${SWEEP_DRY_RUN:-0}
case "${1:-}" in --dry-run) DRY_RUN=1 ;; esac
# shellcheck disable=SC2206
ROOTS=(${SWEEP_ROOTS:-$HOME/projects})

# A dry run reports to stdout so a rehearsal never lands in the sweep log.
if [ "$DRY_RUN" = 1 ]; then
  log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
else
  log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
fi

worktree_live() {
  local wt=$1 cwd
  while IFS= read -r cwd; do
    case "$cwd" in "$wt"|"$wt"/*) return 0 ;; esac
  done < <(readlink /proc/[0-9]*/cwd 2>/dev/null)
  return 1
}

shopt -s nullglob
states=()
for root in "${ROOTS[@]}"; do
  states+=("$root"/*/.crabbox/box)
  # The office (static-ssh) lane records its lease in box-office, so the
  # original glob never saw it and static leases were never swept.
  states+=("$root"/*/.crabbox/box-office)
done
shopt -u nullglob

swept=0
for state in "${states[@]}"; do
  [ -f "$state" ] || continue
  # A converge in flight writes the state file at the end; leave fresh
  # files alone so we never race a box that is still being set up.
  [ -n "$(find "$state" -mmin +"$GRACE_MIN" 2>/dev/null)" ] || continue
  wt=$(cd "$(dirname "$state")/.." && pwd)
  worktree_live "$wt" && continue

  BOX_SLUG="" BOX_LEASE=""
  # shellcheck disable=SC1090
  source "$state"
  id=${BOX_SLUG:-$BOX_LEASE}
  [ -n "$id" ] || { log "skip state=$state (no slug/lease recorded)"; continue; }
  if [ "$DRY_RUN" = 1 ]; then
    log "would-sweep slug=$id wt=$wt state=$state (no live session)"
    swept=$((swept + 1))
    continue
  fi
  if "$CRABBOX" stop --id "$id" >/dev/null 2>&1; then
    log "swept slug=$id wt=$wt (no live session)"
    printf '%s sweep-stop slug=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" \
      >> "$wt/.crabbox/lane.log" 2>/dev/null || true
  else
    log "stop-failed slug=$id wt=$wt (already reaped?)"
  fi
  rm -f "$state"
  swept=$((swept + 1))
done

# Second pass: claims whose worktree state file is already gone.
#
# A static-lane claim outlives its .crabbox/box-office file whenever the
# launcher dies between converge and release, and no coordinator reaper exists
# for a static host, so the claim pins the lane forever. Reaping requires a
# dead owner: no live process with its cwd inside the claim's recorded
# repoRoot. The recorded idleTimeoutSeconds is logged as context but is never
# sufficient on its own, because lastUsedAt is refreshed only when the lease is
# (re)claimed — a single long converge or test run holds it still for its whole
# duration, so an idle-looking claim can be actively working.
claims_dir() {
  local dir
  if [ -n "${SWEEP_CLAIMS_DIR:-}" ]; then printf '%s\n' "$SWEEP_CLAIMS_DIR"; return 0; fi
  for dir in "${XDG_STATE_HOME:-$HOME/.local/state}/crabbox/claims" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/crabbox/state/claims"; do
    [ -d "$dir" ] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

CLAIMS_DIR=$(claims_dir) || CLAIMS_DIR=""
if [ -n "$CLAIMS_DIR" ] && command -v jq >/dev/null 2>&1; then
  shopt -s nullglob
  # shellcheck disable=SC2206 # CLAIM_GLOB is a glob pattern by design
  claims=("$CLAIMS_DIR"/$CLAIM_GLOB)
  shopt -u nullglob
  now=$(date -u +%s)
  for claim in "${claims[@]}"; do
    [ -f "$claim" ] || continue
    slug=$(jq -r '.slug // .leaseID // empty' "$claim" 2>/dev/null)
    wt=$(jq -r '.repoRoot // empty' "$claim" 2>/dev/null)
    last=$(jq -r '.lastUsedAt // .claimedAt // empty' "$claim" 2>/dev/null)
    idle_timeout=$(jq -r '.idleTimeoutSeconds // 0' "$claim" 2>/dev/null)
    [ -n "$slug" ] || { log "skip claim=$claim (no slug recorded)"; continue; }
    last_epoch=$(date -u -d "$last" +%s 2>/dev/null) || last_epoch=$(stat -c %Y "$claim" 2>/dev/null || echo "$now")
    idle=$((now - last_epoch))
    # Same grace as the state-file pass: never touch a claim that was used in
    # the last few minutes, so a converge still coming up is safe.
    [ "$idle" -ge $((GRACE_MIN * 60)) ] || continue
    # The state-file pass owns worktrees that still have a state file; this
    # pass only cleans up after it.
    [ -n "$wt" ] && [ -f "$wt/.crabbox/box-office" ] && continue
    [ -n "$wt" ] && worktree_live "$wt" && continue

    expired=no
    [ "${idle_timeout:-0}" -gt 0 ] && [ "$idle" -ge "$idle_timeout" ] && expired=yes
    detail="slug=$slug wt=${wt:-none} idle=${idle}s timeout=${idle_timeout}s expired=$expired"
    if [ "$DRY_RUN" = 1 ]; then
      log "would-sweep claim $detail (no live session)"
      swept=$((swept + 1))
      continue
    fi
    if "$CRABBOX" stop --id "$slug" >/dev/null 2>&1; then
      log "swept claim $detail (no live session)"
    else
      log "stop-failed claim $detail (already reaped?)"
    fi
    rm -f "$claim"
    if [ -n "$wt" ]; then
      printf '%s sweep-stop slug=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" \
        >> "$wt/.crabbox/lane.log" 2>/dev/null || true
    fi
    swept=$((swept + 1))
  done
elif [ -n "$CLAIMS_DIR" ]; then
  log "skip claims pass (jq unavailable)"
fi

# Visibility only: manually-warmed boxes (spike leases) have no state file.
# Log what the broker still sees so a forgotten one shows up in the sweep
# log instead of silently burning until TTL.
live=$("$CRABBOX" list 2>/dev/null)
[ -z "$live" ] || log "broker still lists: $(printf '%s' "$live" | tr '\n' '; ')"
exit 0
