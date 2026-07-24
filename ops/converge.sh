#!/usr/bin/env bash
# Converge a crabbox lease into a project test runner, then optionally run
# a gate job. Project-agnostic: everything project-specific arrives as flags.
#
# SPIKE-GRADE: promoted from the ge validation spike (2026-07-23). The
# hardening pass (idempotent skip of git seed / sibling placement, broker-mode
# key-path verification, second-invocation fast path) is specified in ge's
# implementation-plans/crabbox-remote-lane.md Task 1.
#
# Usage (run from the project repo root):
#   ../crabbox/ops/converge.sh --slug <slug> --lease <cbx_id> \
#     --bootstrap scripts/crabbox-bootstrap.sh \
#     --sibling ../dev-tools [--sibling ../other] \
#     [--gate-job gate]
#
# Omit --slug/--lease to warm up a fresh box (class from the repo's
# .crabbox.yaml). The load-bearing ordering: bootstrap -> siblings ->
# git seed -> deps.get -> gate. deps.get MUST rerun after siblings land:
# conditional path deps (e.g. ge's ../dev-tools) silently drop their hex
# deps when resolved without the sibling present.
set -euo pipefail

CRABBOX=${CRABBOX:-crabbox}
command -v "$CRABBOX" >/dev/null || CRABBOX=~/Applications/crabbox

SLUG="" LEASE="" BOOTSTRAP="" GATE_JOB=""
SIBLINGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG=$2; shift 2 ;;
    --lease) LEASE=$2; shift 2 ;;
    --bootstrap) BOOTSTRAP=$2; shift 2 ;;
    --sibling) SIBLINGS+=("$2"); shift 2 ;;
    --gate-job) GATE_JOB=$2; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BOOTSTRAP" ] || { echo "--bootstrap is required" >&2; exit 2; }

if [ -z "$SLUG" ]; then
  out=$($CRABBOX warmup 2>&1) || { echo "$out"; exit 1; }
  echo "$out" | tail -2
  LEASE=$(echo "$out" | grep -oP 'leased \Kcbx_[a-z0-9]+' | head -1)
  SLUG=$(echo "$out" | grep -oP 'slug=\K[a-z-]+' | head -1)
fi
[ -n "$LEASE" ] || { echo "--lease required when --slug is given" >&2; exit 2; }
echo "converging lease=$LEASE slug=$SLUG"

KEYDIR="$HOME/.config/crabbox/testboxes/$LEASE"
run_remote() { $CRABBOX run --id "$SLUG" -- "$@"; }

echo "== bootstrap =="
run_remote bash "$BOOTSTRAP"

HOST=$($CRABBOX run --id "$SLUG" -- true 2>&1 | grep -oP 'ssh=crabbox@\K[0-9.]+' | head -1)
WORKROOT=$($CRABBOX run --id "$SLUG" -- true 2>&1 | grep -oP 'workdir=\K\S+' | head -1)
LEASEROOT=$(dirname "$WORKROOT")
rssh() { ssh -i "$KEYDIR/id_ed25519" -o UserKnownHostsFile="$KEYDIR/known_hosts" -p 2222 "crabbox@$HOST" "$@"; }

for sib in "${SIBLINGS[@]:-}"; do
  [ -n "$sib" ] || continue
  name=$(basename "$sib")
  echo "== sibling $name =="
  tar -C "$(dirname "$(realpath "$sib")")" -czf - \
    --exclude="$name/_build" --exclude="$name/deps" --exclude="$name/.git" \
    --exclude="$name/node_modules" "$name" | rssh "tar -xzf - -C $LEASEROOT"
done

echo "== git seed =="
BUNDLE=$(mktemp --suffix=.bundle)
git bundle create "$BUNDLE" HEAD --branches 2>/dev/null | tail -1 || git bundle create "$BUNDLE" HEAD
scp -q -i "$KEYDIR/id_ed25519" -o UserKnownHostsFile="$KEYDIR/known_hosts" -P 2222 "$BUNDLE" "crabbox@$HOST:/tmp/seed.bundle"
rm -f "$BUNDLE"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
rssh "set -e; cd $WORKROOT; git init -q -b $BRANCH 2>/dev/null || true; \
  git fetch -q /tmp/seed.bundle $BRANCH:refs/heads/_seed && \
  git update-ref refs/heads/$BRANCH refs/heads/_seed && \
  git symbolic-ref HEAD refs/heads/$BRANCH && git branch -D _seed >/dev/null && \
  git reset -q --mixed $BRANCH && rm -f /tmp/seed.bundle && git log --oneline -1"

echo "== deps.get (with siblings present) =="
run_remote bash -lc "mix deps.get" >/dev/null 2>&1 || run_remote bash -lc "mix deps.get"

if [ -n "$GATE_JOB" ]; then
  echo "== gate job: $GATE_JOB =="
  $CRABBOX job run "$GATE_JOB" --id "$SLUG"
fi
echo "converged. release with: $CRABBOX stop --id $SLUG"
