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
#     [--base-ref main] [--gate-job gate]
#
# Omit --slug/--lease to warm up a fresh box (class from the repo's
# .crabbox.yaml). The load-bearing ordering: bootstrap -> siblings ->
# git seed -> config reconcile -> deps.get -> gate. The host-fetched
# origin/<base> seeded by this invocation is authoritative only for a gate job
# run by this same converge; reused boxes still need a host fetch + re-converge
# immediately before freshness-sensitive work. deps.get MUST rerun after siblings land:
# conditional path deps (e.g. ge's ../dev-tools) silently drop their hex
# deps when resolved without the sibling present.
set -euo pipefail

CRABBOX=${CRABBOX:-crabbox}
command -v "$CRABBOX" >/dev/null || CRABBOX=~/Applications/crabbox

SLUG="" LEASE="" BOOTSTRAP="" GATE_JOB="" BASE_REF=""
SIBLINGS=()
# Keep the fingerprint and archive filters identical. Siblings bypass the
# project's normal sync filters, so exclude secrets and native/cache output here.
SIBLING_EXCLUDES=("_build" "deps" ".git" "node_modules" "target" ".cache" ".dev_tools" ".crabbox" ".env" ".env.*" ".envrc" "*.pem" "*.key" "__pycache__" "tmp" "cover" ".elixir_ls" ".lexical")
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG=$2; shift 2 ;;
    --lease) LEASE=$2; shift 2 ;;
    --bootstrap) BOOTSTRAP=$2; shift 2 ;;
    --sibling) SIBLINGS+=("$2"); shift 2 ;;
    --base-ref) BASE_REF=$2; shift 2 ;;
    --gate-job) GATE_JOB=$2; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BOOTSTRAP" ] || { echo "--bootstrap is required" >&2; exit 2; }
if { [ -n "$SLUG" ] && [ -z "$LEASE" ]; } || { [ -z "$SLUG" ] && [ -n "$LEASE" ]; }; then
  echo "--slug and --lease must be supplied together" >&2
  exit 2
fi

FRESH_LEASE=0 BUNDLE="" REMOTE_BUNDLE=0 SSH_COMMAND="" CONFIG_SNAPSHOT=""
cleanup_on_exit() {
  status=$?
  trap - EXIT
  if [ -n "$BUNDLE" ]; then rm -f "$BUNDLE" || true; fi
  if [ -n "$CONFIG_SNAPSHOT" ]; then rm -f "$CONFIG_SNAPSHOT" || true; fi
  if [ "$REMOTE_BUNDLE" -eq 1 ] && [ -n "$SSH_COMMAND" ]; then
    rssh "rm -f /tmp/seed.bundle" </dev/null >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ] && [ "$FRESH_LEASE" -eq 1 ]; then
    cleanup_id=${SLUG:-$LEASE}
    echo "converge failed; stopping fresh lease=$LEASE slug=$SLUG" >&2
    [ -z "$cleanup_id" ] || "$CRABBOX" stop --id "$cleanup_id" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

if [ -z "$SLUG" ]; then
  # Session-length lease parameters, tuned from 2026-07-25 telemetry: the
  # 1h30m default TTL killed an active box mid-Reach, and the 30m idle
  # default caused 5 avoidable re-converges in 2 days (boxes needed again
  # 10-52 min after reaping). Idle cost is ~$0.29/h; a re-converge costs
  # 6-7 min of blocked agent time. Override per session for smaller plans.
  WARMUP_TTL="${CRABBOX_TTL:-8h}"
  WARMUP_IDLE="${CRABBOX_IDLE:-90m}"
  out=$("$CRABBOX" warmup --ttl "$WARMUP_TTL" --idle-timeout "$WARMUP_IDLE" 2>&1) || { echo "$out"; exit 1; }
  LEASE=$(printf '%s\n' "$out" | sed -n 's/.*leased \(cbx_[a-z0-9][a-z0-9]*\).*/\1/p' | head -n 1)
  SLUG=$(printf '%s\n' "$out" | sed -n 's/.*slug=\([a-z0-9-][a-z0-9-]*\).*/\1/p' | head -n 1)
  FRESH_LEASE=1
  trap cleanup_on_exit EXIT
  echo "$out" | tail -2
fi
[ -n "$LEASE" ] && [ -n "$SLUG" ] || { echo "warmup did not report lease and slug" >&2; exit 2; }
trap cleanup_on_exit EXIT
echo "converging lease=$LEASE slug=$SLUG"

run_remote() { "$CRABBOX" run --id "$SLUG" -- "$@"; }

echo "== bootstrap =="
run_remote bash "$BOOTSTRAP"

WORKROOT=$("$CRABBOX" run --id "$SLUG" --no-sync --no-hydrate -- true 2>&1 |
  sed -n 's/.*workdir=\([^[:space:]]*\).*/\1/p' | head -n 1)
case "$WORKROOT" in
  /*) ;;
  *) echo "crabbox run did not report an absolute workdir" >&2; exit 2 ;;
esac
LEASEROOT=$(dirname "$WORKROOT")
SSH_COMMAND=$("$CRABBOX" ssh --id "$SLUG")
rssh() {
  local command
  printf -v command '%s %q' "$SSH_COMMAND" "$1"
  eval "$command"
}
rssh_args() {
  local remote="" quoted arg
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    remote="${remote:+$remote }$quoted"
  done
  rssh "$remote"
}
snapshot_effective_config() {
  local project_root common_dir main_root
  project_root=$(git rev-parse --path-format=absolute --show-toplevel) || return 2
  CONFIG_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/crabbox-config.XXXXXX") || return 2
  if cat "$project_root/.dev_tools/config.toml" >"$CONFIG_SNAPSHOT" 2>/dev/null; then
    return 0
  fi
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir) || return 2
  main_root=$(dirname "$common_dir")
  if [ "$main_root" != "$project_root" ] &&
    cat "$main_root/.dev_tools/config.toml" >"$CONFIG_SNAPSHOT" 2>/dev/null; then
    return 0
  fi
  rm -f "$CONFIG_SNAPSHOT"
  CONFIG_SNAPSHOT=""
  return 1
}
reconcile_dev_tools_config() {
  local status target expected remote_hash remote_state
  target="$WORKROOT/.dev_tools/config.toml"
  echo "== config.toml =="
  if snapshot_effective_config; then
    expected=$(git hash-object --no-filters "$CONFIG_SNAPSHOT")
    # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
    remote_hash=$(rssh_args bash -c 'set -e; cd "$1"; target=$2; if [ -f "$target" ]; then git hash-object --no-filters "$target"; fi' \
      _ "$WORKROOT" "$target")
    if [ "$remote_hash" = "$expected" ]; then
      echo "config.toml: unchanged, skipping"
    else
      echo "config.toml: placing effective config"
      # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
      rssh_args bash -c 'set -e; cd "$1"; target=$2; expected=$3; stage=""; cleanup() { status=$?; trap - EXIT; [ -z "$stage" ] || rm -f -- "$stage"; exit "$status"; }; trap cleanup EXIT; mkdir -p -- "$(dirname "$target")"; stage=$(mktemp "$target.tmp.XXXXXX"); cat >"$stage"; test "$(git hash-object --no-filters "$stage")" = "$expected"; mv -fT -- "$stage" "$target"; stage=""; trap - EXIT' \
        _ "$WORKROOT" "$target" "$expected" <"$CONFIG_SNAPSHOT"
    fi
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
    # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
    remote_state=$(rssh_args bash -c 'set -e; target=$1; if [ -e "$target" ] || [ -L "$target" ]; then rm -f -- "$target"; printf removed; else printf absent; fi' \
      _ "$target")
    if [ "$remote_state" = removed ]; then
      echo "config.toml: stale file removed"
    else
      echo "config.toml: absent, skipping"
    fi
  fi
}
stream_sibling_archive() {
  local sib=$1 name=$2 exclude
  local args=()
  for exclude in "${SIBLING_EXCLUDES[@]}"; do args+=(--exclude="$exclude"); done
  tar -C "$(dirname "$(realpath "$sib")")" -czf - "${args[@]}" "$name"
}
sibling_content_hash() {
  local root temp paths regular_paths hashes manifest exclude path hash kind target size result status
  local LC_ALL=C
  local find_excludes=()
  root=$(realpath "$1")
  temp=$(mktemp -d "${TMPDIR:-/tmp}/crabbox-sibling-hash.XXXXXX")
  paths=$temp/paths
  regular_paths=$temp/regular-paths
  hashes=$temp/hashes
  manifest=$temp/manifest
  for exclude in "${SIBLING_EXCLUDES[@]}"; do
    [ "${#find_excludes[@]}" -eq 0 ] || find_excludes+=(-o)
    find_excludes+=(-name "$exclude")
  done
  if result=$(
    set -e
    find "$root" \( "${find_excludes[@]}" \) -prune -o \( -type f -o -type l \) -print |
      LC_ALL=C sort >"$paths"
    while IFS= read -r path; do [ -L "$path" ] || printf '%s\n' "$path"; done \
      <"$paths" >"$regular_paths"
    git hash-object --no-filters --stdin-paths <"$regular_paths" >"$hashes"
    while IFS= read -r path; do
      if [ -L "$path" ]; then
        target=$(readlink "$path")
        size=${#target}
        printf '%s\0link\0%s\0%s\0' "${path#"$root"/}" "$size" "$target"
      else
        IFS= read -r hash <&3
        [ -x "$path" ] && kind="executable" || kind="file"
        printf '%s\0%s\0%s\0' "${path#"$root"/}" "$kind" "$hash"
      fi
    done <"$paths" 3<"$hashes" >"$manifest"
    git hash-object --stdin <"$manifest"
  ); then
    status=0
  else
    status=$?
  fi
  rm -rf "$temp" || true
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$result"
}

for sib in "${SIBLINGS[@]:-}"; do
  [ -n "$sib" ] || continue
  name=$(basename "$sib")
  echo "== sibling $name =="
  hash=$(sibling_content_hash "$sib")
  marker="$LEASEROOT/.crabbox-converge/siblings/$(printf '%s' "$name" | git hash-object --stdin)"
  # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
  if rssh_args bash -c '[ -f "$1" ] && [ "$(cat "$1")" = "$2" ]' _ "$marker" "$hash" >/dev/null; then
    echo "sibling $name: unchanged, skipping"
  else
    echo "sibling $name: placing content"
    # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
    stream_sibling_archive "$sib" "$name" |
      rssh_args bash -c 'set -e; target=$1; root=$2; marker=$3; hash=$4; name=$5; stage="$root/.crabbox-converge-stage.$$"; backup="$root/.crabbox-converge-backup.$$"; marker_tmp="$marker.tmp.$$"; old=0; swapped=0; rollback() { status=$?; trap - EXIT; set +e; rm -rf "$stage" "$marker_tmp"; if [ "$swapped" -eq 1 ]; then rm -rf "$target"; fi; if [ "$old" -eq 1 ]; then mv "$backup" "$target"; fi; exit "$status"; }; trap rollback EXIT; mkdir "$stage"; tar -xzf - -C "$stage"; test -e "$stage/$name"; if [ -e "$target" ]; then mv "$target" "$backup"; old=1; fi; mv "$stage/$name" "$target"; swapped=1; mkdir -p "$(dirname "$marker")"; printf "%s\n" "$hash" >"$marker_tmp"; mv "$marker_tmp" "$marker"; trap - EXIT; rm -rf "$stage" "$backup" || true' \
        _ "$LEASEROOT/$name" "$LEASEROOT" "$marker" "$hash" "$name"
  fi
done

echo "== git seed =="
BRANCH=$(git rev-parse --abbrev-ref HEAD)
LOCAL_HEAD=$(git rev-parse HEAD)
BASE_BRANCH=$BASE_REF
if [ -z "$BASE_BRANCH" ] && git show-ref --verify --quiet refs/heads/main; then
  BASE_BRANCH=main
elif [ -n "$BASE_BRANCH" ] && ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
  echo "base ref does not exist: refs/heads/$BASE_BRANCH" >&2
  exit 2
fi
LOCAL_BASE=""
[ -z "$BASE_BRANCH" ] || LOCAL_BASE=$(git rev-parse --verify "refs/heads/$BASE_BRANCH")
FETCHED_BASE=""
if [ -n "$BASE_BRANCH" ]; then
  if git fetch -q origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null &&
    FETCHED_BASE=$(git rev-parse --verify "refs/remotes/origin/$BASE_BRANCH^{commit}" 2>/dev/null); then
    :
  else
    FETCHED_BASE=""
    echo "warning: could not refresh origin/$BASE_BRANCH; remote ref seed skipped" >&2
  fi
fi
EXPECTED_CHECKOUT="$BRANCH $LOCAL_HEAD"
[ -z "$LOCAL_BASE" ] || EXPECTED_CHECKOUT="$EXPECTED_CHECKOUT $LOCAL_BASE"
[ -z "$FETCHED_BASE" ] || EXPECTED_CHECKOUT="$EXPECTED_CHECKOUT $FETCHED_BASE"
# shellcheck disable=SC2016 # Variables expand in the remote bash -c.
REMOTE_CHECKOUT=$(rssh_args bash -c 'cd "$1" && branch=$(git symbolic-ref --short HEAD 2>/dev/null) && head=$(git rev-parse HEAD 2>/dev/null) && base="" && origin="" && { [ -z "$2" ] || base=$(git rev-parse "refs/heads/$2" 2>/dev/null || true); } && { [ -z "$3" ] || origin=$(git rev-parse --verify "refs/remotes/origin/$2^{commit}" 2>/dev/null || true); } && printf "%s %s" "$branch" "$head" && { [ -z "$base" ] || printf " %s" "$base"; } && { [ -z "$origin" ] || printf " %s" "$origin"; } && printf "\n"' \
  _ "$WORKROOT" "$BASE_BRANCH" "$FETCHED_BASE" || true)
if [ "$REMOTE_CHECKOUT" = "$EXPECTED_CHECKOUT" ]; then
  echo "git seed: unchanged, skipping"
else
  echo "git seed: placing $LOCAL_HEAD"
  BUNDLE=$(mktemp "${TMPDIR:-/tmp}/crabbox-converge.XXXXXX")
  BUNDLE_REFS=("refs/heads/$BRANCH")
  if [ -n "$LOCAL_BASE" ] && [ "$BASE_BRANCH" != "$BRANCH" ]; then
    BUNDLE_REFS+=("refs/heads/$BASE_BRANCH")
  fi
  [ -z "$FETCHED_BASE" ] || BUNDLE_REFS+=("refs/remotes/origin/$BASE_BRANCH")
  git bundle create "$BUNDLE" "${BUNDLE_REFS[@]}"
  if [ -n "$FETCHED_BASE" ]; then
    test "$(git bundle list-heads "$BUNDLE" "refs/remotes/origin/$BASE_BRANCH")" = \
      "$FETCHED_BASE refs/remotes/origin/$BASE_BRANCH"
  fi
  REMOTE_BUNDLE=1
  rssh "cat > /tmp/seed.bundle" <"$BUNDLE"
  rm -f "$BUNDLE"
  BUNDLE=""
  # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
  rssh_args bash -c 'set -e; cd "$1"; git init -q -b "$2" 2>/dev/null || true; git fetch -q /tmp/seed.bundle "$2"; git update-ref "refs/heads/$2" FETCH_HEAD; if [ -n "$5" ] && [ "$2" != "$4" ]; then git fetch -q /tmp/seed.bundle "$4"; git update-ref "refs/heads/$4" FETCH_HEAD; fi; if [ -n "$6" ]; then git fetch -q /tmp/seed.bundle "refs/remotes/origin/$4"; git update-ref "refs/remotes/origin/$4" "$6"; test "$(git rev-parse "refs/remotes/origin/$4")" = "$6"; git cat-file -e "$6^{commit}"; fi; git symbolic-ref HEAD "refs/heads/$2"; git reset -q --mixed "$2"; test "$(git rev-parse HEAD)" = "$3"; rm -f /tmp/seed.bundle; git log --oneline -1' \
    _ "$WORKROOT" "$BRANCH" "$LOCAL_HEAD" "$BASE_BRANCH" "$LOCAL_BASE" "$FETCHED_BASE"
  REMOTE_BUNDLE=0
fi

if [ -n "$BASE_BRANCH" ] && [ -z "$FETCHED_BASE" ]; then
  # shellcheck disable=SC2016 # Variables expand in the remote bash -c.
  rssh_args bash -c 'set -e; cd "$1"; git update-ref -d "refs/remotes/origin/$2"' \
    _ "$WORKROOT" "$BASE_BRANCH"
fi

reconcile_dev_tools_config

echo "== deps.get (with siblings present) =="
"$CRABBOX" run --id "$SLUG" --no-sync --no-hydrate -- bash -lc "mix deps.get"

if [ -n "$GATE_JOB" ]; then
  echo "== gate job: $GATE_JOB =="
  "$CRABBOX" job run --id "$SLUG" "$GATE_JOB"
fi
echo "converged. release with: $CRABBOX stop --id $SLUG"
