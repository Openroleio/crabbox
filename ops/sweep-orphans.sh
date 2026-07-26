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
#   SWEEP_ROOTS   space-separated dirs whose children are scanned for
#                 .crabbox/box state files (default: ~/projects)
#   SWEEP_GRACE_MIN  skip state files younger than this (default: 10)
set -uo pipefail

CRABBOX=${CRABBOX:-crabbox}
command -v "$CRABBOX" >/dev/null 2>&1 || CRABBOX="$HOME/Applications/crabbox"
LOG="$HOME/.crabbox-sweep.log"
GRACE_MIN=${SWEEP_GRACE_MIN:-10}
# shellcheck disable=SC2206
ROOTS=(${SWEEP_ROOTS:-$HOME/projects})

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

worktree_live() {
  local wt=$1 cwd
  while IFS= read -r cwd; do
    case "$cwd" in "$wt"|"$wt"/*) return 0 ;; esac
  done < <(readlink /proc/[0-9]*/cwd 2>/dev/null)
  return 1
}

shopt -s nullglob
states=()
for root in "${ROOTS[@]}"; do states+=("$root"/*/.crabbox/box); done
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

# Visibility only: manually-warmed boxes (spike leases) have no state file.
# Log what the broker still sees so a forgotten one shows up in the sweep
# log instead of silently burning until TTL.
live=$("$CRABBOX" list 2>/dev/null)
[ -z "$live" ] || log "broker still lists: $(printf '%s' "$live" | tr '\n' '; ')"
exit 0
