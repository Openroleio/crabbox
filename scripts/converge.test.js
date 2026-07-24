import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repoRoot = path.resolve(import.meta.dirname, "..");

function executable(file, body) {
  fs.writeFileSync(file, body, { mode: 0o755 });
}

function fixture(branch = "test") {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "crabbox-converge-"));
  const log = path.join(dir, "calls.log");
  const state = path.join(dir, "remote-state");
  const transport = path.join(dir, "transport");
  const cli = path.join(dir, "crabbox");
  fs.mkdirSync(state);
  executable(path.join(dir, "scp"), "#!/usr/bin/env bash\nexit 91\n");
  executable(
    transport,
    `#!/usr/bin/env bash
printf 'transport argc=%s command=%s\\n' "$#" "$*" >>"$CRABBOX_TEST_LOG"
if [[ "$#" != 1 ]]; then exit 43; fi
if [[ "$1" == 'cat > /tmp/seed.bundle' ]]; then
  if [[ "\${CRABBOX_TEST_EXEC_REMOTE:-0}" == 1 ]]; then
    exec bash -c "$1"
  fi
  cat >"$CRABBOX_TEST_STATE/uploaded.bundle"
  exit
fi
eval "set -- $1"
script="\${3:-}"
if [[ "\${CRABBOX_TEST_EXEC_REMOTE:-0}" == 1 ]]; then
  if [[ "$script" == *'tar -xzf'* && "\${CRABBOX_TEST_FAIL_MARKER:-0}" == 1 ]]; then
    mkdir -p "\${7}.tmp.$$"
  fi
  exec "$@"
fi
if [[ "$script" == *'cat "$1"'* ]]; then
  [[ -f "$CRABBOX_TEST_STATE/sibling-hash" ]] &&
    [[ "\$(cat "$CRABBOX_TEST_STATE/sibling-hash")" == "\${6:-}" ]]
  exit
fi
if [[ "$script" == *'tar -xzf'* ]]; then
  cat >/dev/null
  [[ "\${CRABBOX_TEST_SIBLING_FAIL:-0}" == 1 ]] && exit 44
  printf '%s' "\${8:-}" >"$CRABBOX_TEST_STATE/sibling-hash"
  exit
fi
if [[ "$script" == *'git symbolic-ref --short'* ]]; then
  if [[ -f "$CRABBOX_TEST_STATE/remote-head" ]]; then
    read -r remote_branch <"$CRABBOX_TEST_STATE/remote-branch"
    read -r remote_head <"$CRABBOX_TEST_STATE/remote-head"
    printf '%s %s' "$remote_branch" "$remote_head"
    if [[ -n "\${6:-}" && -f "$CRABBOX_TEST_STATE/remote-base" ]]; then
      read -r remote_base <"$CRABBOX_TEST_STATE/remote-base"
      printf ' %s' "$remote_base"
    fi
    printf '\\n'
  fi
  exit
fi
if [[ "$script" == *'git rev-parse --verify'* ]]; then
  [[ -f "$CRABBOX_TEST_STATE/remote-ref" ]] && cat "$CRABBOX_TEST_STATE/remote-ref"
  exit
fi
if [[ "$script" == *'git fetch -q'* ]]; then
  [[ "\${CRABBOX_TEST_REMOTE_FAIL:-0}" == 1 ]] && exit 41
  printf '%s\\n' "\${6:-}" >"$CRABBOX_TEST_STATE/remote-branch"
  printf '%s\\n' "\${7:-}" >"$CRABBOX_TEST_STATE/remote-ref"
  printf '%s\\n' "\${7:-}" >"$CRABBOX_TEST_STATE/remote-head"
  if [[ -n "\${9:-}" ]]; then
    printf '%s\\n' "\${9:-}" >"$CRABBOX_TEST_STATE/remote-base"
  fi
  exit
fi
cat >/dev/null
`,
  );
  executable(
    cli,
    `#!/usr/bin/env bash
printf 'crabbox %s\\n' "$*" >>"$CRABBOX_TEST_LOG"
case "$1" in
  warmup) printf '%s\\n' "\${CRABBOX_TEST_WARMUP:-ready
leased cbx_fresh slug=fresh-box}" ;;
  ssh) printf '%q\\n' "$CRABBOX_TEST_TRANSPORT" ;;
  run)
    if [[ "$*" == *"bootstrap.sh"* && "\${CRABBOX_TEST_FAIL:-0}" == 1 ]]; then exit 37; fi
    if [[ "$*" == *"mix deps.get"* && "\${CRABBOX_TEST_DEPS_FAIL:-0}" == 1 ]]; then
      printf 'deps failed\\n' >&2
      exit 45
    fi
    if [[ "\${CRABBOX_TEST_NO_WORKROOT:-0}" == 1 ]]; then
      printf 'ssh=crabbox@192.0.2.1\\n'
    else
      printf 'ssh=crabbox@192.0.2.1 workdir=%s\\n' "\${CRABBOX_TEST_WORKROOT:-/tmp/work/cbx_fresh/project}"
    fi
    ;;
  stop|job) ;;
  *) exit 98 ;;
esac
`,
  );
  fs.writeFileSync(path.join(dir, "bootstrap.sh"), "");
  fs.mkdirSync(path.join(dir, "sibling"));
  fs.writeFileSync(path.join(dir, "sibling", "source.txt"), "first\n");
  spawnSync("git", ["init", "-q", "-b", branch], { cwd: dir });
  spawnSync("git", ["config", "user.email", "test@example.com"], { cwd: dir });
  spawnSync("git", ["config", "user.name", "Test"], { cwd: dir });
  spawnSync("git", ["add", "bootstrap.sh"], { cwd: dir });
  spawnSync("git", ["commit", "-qm", "fixture"], { cwd: dir });
  return { dir, log, state, transport, cli };
}

function invoke(f, extraArgs = [], env = {}) {
  return spawnSync(
    "bash",
    [path.join(repoRoot, "ops/converge.sh"), "--bootstrap", "bootstrap.sh", ...extraArgs],
    {
      cwd: f.dir,
      encoding: "utf8",
      env: {
        ...process.env,
        ...env,
        HOME: path.join(f.dir, "empty-home"),
        PATH: `${f.dir}${path.delimiter}${process.env.PATH ?? ""}`,
        TMPDIR: f.dir,
        CRABBOX: f.cli,
        CRABBOX_TEST_LOG: f.log,
        CRABBOX_TEST_STATE: f.state,
        CRABBOX_TEST_TRANSPORT: f.transport,
      },
    },
  );
}

function converge(extraArgs = [], env = {}) {
  const f = fixture(env.CRABBOX_TEST_BRANCH);
  const result = invoke(f, extraArgs, env);
  const calls = fs.existsSync(f.log) ? fs.readFileSync(f.log, "utf8") : "";
  const leftovers = fs.readdirSync(f.dir).filter((name) => name.startsWith("crabbox-converge."));
  fs.rmSync(f.dir, { recursive: true, force: true });
  return { result, calls, leftovers };
}

test("--slug and --lease must be supplied together", () => {
  for (const args of [["--slug", "given-box"], ["--lease", "cbx_given"]]) {
    const { result, calls } = converge(args);
    assert.equal(result.status, 2, result.stdout + result.stderr);
    assert.match(result.stderr, /--slug and --lease must be supplied together/);
    assert.doesNotMatch(calls, /warmup|stop/);
  }
});

test("a fresh successful lease uses CLI SSH access and remains live", () => {
  const { result, calls, leftovers } = converge();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(calls, /crabbox ssh --id fresh-box/);
  assert.match(calls, /run --id fresh-box --no-sync --no-hydrate -- true/);
  assert.match(calls, /transport argc=1 command=cat > \/tmp\/seed.bundle/);
  assert.doesNotMatch(calls, /crabbox stop/);
  assert.deepEqual(leftovers, []);
});

test("malformed fresh output is stopped by whichever identifier was reported", () => {
  for (const [output, id] of [
    ["leased cbx_fresh", "cbx_fresh"],
    ["ready slug=fresh-box", "fresh-box"],
  ]) {
    const { result, calls } = converge([], { CRABBOX_TEST_WARMUP: output });
    assert.equal(result.status, 2, result.stdout + result.stderr);
    assert.match(calls, new RegExp(`crabbox stop --id ${id}`));
  }
});

test("remote workroot and branch arguments remain shell-quoted", () => {
  const { result, calls } = converge([], {
    CRABBOX_TEST_BRANCH: "test;false",
    CRABBOX_TEST_WORKROOT: "/tmp/work/root;false/project",
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(calls, /root\\;false/);
  assert.match(calls, /test\\;false/);
});

test("missing workroot fails before transport and cleans a fresh lease", () => {
  const { result, calls } = converge([], { CRABBOX_TEST_NO_WORKROOT: "1" });
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stderr, /did not report an absolute workdir/);
  assert.doesNotMatch(calls, /crabbox ssh|transport/);
  assert.match(calls, /crabbox stop --id fresh-box/);
});

test("fresh failures are cleaned up without replacing the failing status", () => {
  const { result, calls } = converge([], { CRABBOX_TEST_FAIL: "1" });
  assert.equal(result.status, 37, result.stdout + result.stderr);
  assert.match(calls, /crabbox stop --id fresh-box/);
});

test("a supplied lease is never cleaned up on failure", () => {
  const { result, calls } = converge(["--slug", "given-box", "--lease", "cbx_given"], {
    CRABBOX_TEST_FAIL: "1",
  });
  assert.equal(result.status, 37, result.stdout + result.stderr);
  assert.doesNotMatch(calls, /crabbox (warmup|stop)/);
});

test("seed failures clean local and remote bundles before preserving status", () => {
  const { result, calls, leftovers } = converge([], { CRABBOX_TEST_REMOTE_FAIL: "1" });
  assert.equal(result.status, 41, result.stdout + result.stderr);
  assert.match(calls, /transport argc=1 command=rm -f \/tmp\/seed.bundle/);
  assert.deepEqual(leftovers, []);
});

test("sibling hashes skip excluded changes and replace changed content", () => {
  const f = fixture();
  try {
    const args = [
      "--slug",
      "given-box",
      "--lease",
      "cbx_given",
      "--sibling",
      "sibling",
      "--gate-job",
      "gate",
    ];
    const first = invoke(f, args);
    for (const excluded of ["_build", "deps", ".git", "node_modules"]) {
      fs.mkdirSync(path.join(f.dir, "sibling", excluded));
      fs.writeFileSync(path.join(f.dir, "sibling", excluded, "ignored"), "changed\n");
    }
    fs.utimesSync(path.join(f.dir, "sibling"), new Date(0), new Date(0));
    const excluded = invoke(f, args);
    fs.writeFileSync(path.join(f.dir, "sibling", "source.txt"), "second\n");
    const changed = invoke(f, args);
    assert.equal(first.status, 0, first.stdout + first.stderr);
    assert.match(first.stdout, /sibling sibling: placing content/);
    assert.match(excluded.stdout, /sibling sibling: unchanged, skipping/);
    assert.match(changed.stdout, /sibling sibling: placing content/);
    const order = ["== bootstrap ==", "== sibling", "== git seed ==", "== deps.get", "== gate job"].map(
      (part) => first.stdout.indexOf(part),
    );
    assert.deepEqual(order, [...order].sort((a, b) => a - b));
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("sibling hashes track symlink targets without dereferencing them", () => {
  const f = fixture();
  try {
    const sibling = path.join(f.dir, "sibling");
    fs.writeFileSync(path.join(sibling, "target-a"), "same\n");
    fs.writeFileSync(path.join(sibling, "target-b"), "same\n");
    fs.symlinkSync("target-a", path.join(sibling, "selected"));
    const args = ["--slug", "given-box", "--lease", "cbx_given", "--sibling", "sibling"];
    const first = invoke(f, args);
    fs.unlinkSync(path.join(sibling, "selected"));
    fs.symlinkSync("target-b", path.join(sibling, "selected"));
    const retargeted = invoke(f, args);
    fs.unlinkSync(path.join(sibling, "selected"));
    fs.symlinkSync("missing", path.join(sibling, "selected"));
    const broken = invoke(f, args);
    assert.equal(first.status, 0, first.stdout + first.stderr);
    assert.equal(retargeted.status, 0, retargeted.stdout + retargeted.stderr);
    assert.equal(broken.status, 0, broken.stdout + broken.stderr);
    assert.match(retargeted.stdout, /sibling sibling: placing content/);
    assert.match(broken.stdout, /sibling sibling: placing content/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("reused zero-sibling runs skip matching git seed but always rerun the gate", () => {
  const f = fixture();
  try {
    const args = ["--slug", "given-box", "--lease", "cbx_given", "--gate-job", "gate"];
    const first = invoke(f, args);
    const second = invoke(f, args);
    const calls = fs.readFileSync(f.log, "utf8");
    assert.equal(first.status, 0, first.stdout + first.stderr);
    assert.equal(second.status, 0, second.stdout + second.stderr);
    assert.match(second.stdout, /git seed: unchanged, skipping/);
    assert.equal(calls.match(/crabbox job run --id given-box gate/g)?.length, 2);
    assert.equal(calls.match(/command=cat > \/tmp\/seed\.bundle/g)?.length, 1);
    const order = ["== bootstrap ==", "== git seed ==", "== deps.get", "== gate job"].map((part) =>
      second.stdout.indexOf(part),
    );
    assert.deepEqual(order, [...order].sort((a, b) => a - b));
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("failed sibling staging retains its marker, skips the gate, and cleans a fresh lease", () => {
  const f = fixture();
  try {
    const supplied = ["--slug", "given-box", "--lease", "cbx_given", "--sibling", "sibling"];
    assert.equal(invoke(f, supplied).status, 0);
    const marker = fs.readFileSync(path.join(f.state, "sibling-hash"), "utf8");
    fs.writeFileSync(path.join(f.dir, "sibling", "source.txt"), "replacement\n");
    const failed = invoke(f, ["--sibling", "sibling", "--gate-job", "gate"], {
      CRABBOX_TEST_SIBLING_FAIL: "1",
    });
    const calls = fs.readFileSync(f.log, "utf8");
    assert.equal(failed.status, 44, failed.stdout + failed.stderr);
    assert.equal(fs.readFileSync(path.join(f.state, "sibling-hash"), "utf8"), marker);
    assert.doesNotMatch(calls, /crabbox job run gate/);
    assert.match(calls, /crabbox stop --id fresh-box/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("post-swap marker failure restores the prior remote sibling", () => {
  const f = fixture();
  try {
    const root = path.join(f.state, "remote", "lease");
    const target = path.join(root, "sibling");
    const nameHash = spawnSync("git", ["hash-object", "--stdin"], {
      cwd: f.dir,
      encoding: "utf8",
      input: "sibling",
    }).stdout.trim();
    const marker = path.join(root, ".crabbox-converge", "siblings", nameHash);
    fs.mkdirSync(target, { recursive: true });
    fs.mkdirSync(path.dirname(marker), { recursive: true });
    fs.writeFileSync(path.join(target, "source.txt"), "old remote\n");
    fs.writeFileSync(marker, "old-marker\n");
    const failed = invoke(f, ["--sibling", "sibling", "--gate-job", "gate"], {
      CRABBOX_TEST_EXEC_REMOTE: "1",
      CRABBOX_TEST_FAIL_MARKER: "1",
      CRABBOX_TEST_WORKROOT: path.join(root, "project"),
    });
    const calls = fs.readFileSync(f.log, "utf8");
    assert.notEqual(failed.status, 0, failed.stdout + failed.stderr);
    assert.equal(fs.readFileSync(path.join(target, "source.txt"), "utf8"), "old remote\n");
    assert.equal(fs.readFileSync(marker, "utf8"), "old-marker\n");
    assert.deepEqual(
      fs.readdirSync(root).filter((name) => name.startsWith(".crabbox-converge-")),
      [],
    );
    assert.doesNotMatch(calls, /crabbox job run gate/);
    assert.match(calls, /crabbox stop --id fresh-box/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("git seed does not trust a stale branch ref across A to B to A", () => {
  const f = fixture();
  try {
    const args = ["--slug", "given-box", "--lease", "cbx_given"];
    const commitA = spawnSync("git", ["rev-parse", "HEAD"], { cwd: f.dir, encoding: "utf8" }).stdout.trim();
    assert.equal(invoke(f, args).status, 0);
    fs.writeFileSync(path.join(f.dir, "bootstrap.sh"), "change\n");
    spawnSync("git", ["commit", "-qam", "B"], { cwd: f.dir });
    assert.equal(invoke(f, args).status, 0);
    spawnSync("git", ["update-ref", "refs/heads/test", commitA], { cwd: f.dir });
    fs.writeFileSync(path.join(f.state, "remote-ref"), `${commitA}\n`);
    const returned = invoke(f, args);
    assert.equal(returned.status, 0, returned.stdout + returned.stderr);
    assert.match(returned.stdout, /git seed: placing/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("git seed carries main for remote comparison gates", () => {
  const f = fixture();
  try {
    const main = spawnSync("git", ["rev-parse", "HEAD"], {
      cwd: f.dir,
      encoding: "utf8",
    }).stdout.trim();
    spawnSync("git", ["branch", "main", main], { cwd: f.dir });
    const result = invoke(f, ["--slug", "given-box", "--lease", "cbx_given"]);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(fs.readFileSync(path.join(f.state, "remote-base"), "utf8").trim(), main);
    const heads = spawnSync("git", ["bundle", "list-heads", path.join(f.state, "uploaded.bundle")], {
      encoding: "utf8",
    });
    assert.equal(heads.status, 0, heads.stderr);
    assert.match(heads.stdout, new RegExp(`${main} refs/heads/main`));
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("base movement invalidates reuse and explicit non-main bases are bundled", () => {
  const f = fixture();
  try {
    const oldBase = spawnSync("git", ["rev-parse", "HEAD"], {
      cwd: f.dir,
      encoding: "utf8",
    }).stdout.trim();
    spawnSync("git", ["branch", "trunk", oldBase], { cwd: f.dir });
    const args = [
      "--slug",
      "given-box",
      "--lease",
      "cbx_given",
      "--base-ref",
      "trunk",
    ];
    assert.equal(invoke(f, args).status, 0);
    fs.writeFileSync(path.join(f.dir, "base.txt"), "moved\n");
    spawnSync("git", ["add", "base.txt"], { cwd: f.dir });
    spawnSync("git", ["commit", "-qm", "move base"], { cwd: f.dir });
    const newBase = spawnSync("git", ["rev-parse", "HEAD"], {
      cwd: f.dir,
      encoding: "utf8",
    }).stdout.trim();
    spawnSync("git", ["update-ref", "refs/heads/trunk", newBase], { cwd: f.dir });
    spawnSync("git", ["reset", "--hard", "-q", oldBase], { cwd: f.dir });
    const moved = invoke(f, args);
    assert.equal(moved.status, 0, moved.stdout + moved.stderr);
    assert.match(moved.stdout, /git seed: placing/);
    assert.equal(fs.readFileSync(path.join(f.state, "remote-base"), "utf8").trim(), newBase);
    const heads = spawnSync("git", ["bundle", "list-heads", path.join(f.state, "uploaded.bundle")], {
      encoding: "utf8",
    });
    assert.match(heads.stdout, new RegExp(`${newBase} refs/heads/trunk`));
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("repos without a base ref ignore stale remote main and converge", () => {
  const f = fixture();
  try {
    const args = ["--slug", "given-box", "--lease", "cbx_given"];
    assert.equal(invoke(f, args).status, 0);
    fs.writeFileSync(path.join(f.state, "remote-base"), "deadbeef\n");
    const reused = invoke(f, args);
    assert.equal(reused.status, 0, reused.stdout + reused.stderr);
    assert.match(reused.stdout, /git seed: unchanged, skipping/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("main branch bundles one ref and reuses cleanly", () => {
  const f = fixture("main");
  try {
    const args = ["--slug", "given-box", "--lease", "cbx_given"];
    const first = invoke(f, args);
    const second = invoke(f, args);
    assert.equal(first.status, 0, first.stdout + first.stderr);
    assert.equal(second.status, 0, second.stdout + second.stderr);
    assert.match(second.stdout, /git seed: unchanged, skipping/);
    const heads = spawnSync("git", ["bundle", "list-heads", path.join(f.state, "uploaded.bundle")], {
      encoding: "utf8",
    });
    assert.equal(heads.stdout.trim().split("\n").length, 1);
    assert.match(heads.stdout, /refs\/heads\/main/);
  } finally {
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("real seed transaction permits former scratch branch names", () => {
  const f = fixture("_seed");
  const remote = path.join(f.dir, "remote");
  try {
    const head = spawnSync("git", ["rev-parse", "HEAD"], {
      cwd: f.dir,
      encoding: "utf8",
    }).stdout.trim();
    spawnSync("git", ["branch", "_base_seed", head], { cwd: f.dir });
    fs.mkdirSync(remote);
    const args = [
      "--slug",
      "given-box",
      "--lease",
      "cbx_given",
      "--base-ref",
      "_base_seed",
    ];
    const env = { CRABBOX_TEST_EXEC_REMOTE: "1", CRABBOX_TEST_WORKROOT: remote };
    const first = invoke(f, args, env);
    const second = invoke(f, args, env);
    assert.equal(first.status, 0, first.stdout + first.stderr);
    assert.equal(second.status, 0, second.stdout + second.stderr);
    assert.match(second.stdout, /git seed: unchanged, skipping/);
    for (const branch of ["_seed", "_base_seed"]) {
      const actual = spawnSync("git", ["rev-parse", `refs/heads/${branch}`], {
        cwd: remote,
        encoding: "utf8",
      });
      assert.equal(actual.stdout.trim(), head);
    }
  } finally {
    fs.rmSync("/tmp/seed.bundle", { force: true });
    fs.rmSync(f.dir, { recursive: true, force: true });
  }
});

test("dependency failure is emitted once and prevents the gate", () => {
  const { result, calls } = converge(["--gate-job", "gate"], { CRABBOX_TEST_DEPS_FAIL: "1" });
  assert.equal(result.status, 45, result.stdout + result.stderr);
  assert.match(result.stderr, /deps failed/);
  assert.equal(calls.match(/mix deps.get/g)?.length, 1);
  assert.match(calls, /run --id fresh-box --no-sync --no-hydrate -- bash -lc mix deps.get/);
  assert.doesNotMatch(calls, /crabbox job run gate/);
});
