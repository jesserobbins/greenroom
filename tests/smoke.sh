#!/usr/bin/env bash
# Smoke test for greenroom.py. Black-box: builds throwaway repos in a temp
# dir, runs the script, asserts behavior. Guards the reliability fixes:
#   1. retrofit works when the parent holds sibling repos (the ~/GitHub case)
#   2. collect classifies private-shaped files at the repo root
#   3. a failed in-place move restores the repo instead of stranding it
#   4. check_plugin_configs matches the old path only at a component boundary
#   5. sync discovers every repo and wires workspace + access + map
#   6. sync merge adds new repos but preserves hand-added customizations
# Run: greenroom/tests/smoke.sh   (exits non-zero on any failure)
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/greenroom.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1"; exit 1; }
ok() { echo "ok: $1"; pass=$((pass + 1)); }

mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q                              # portable: `init -b main` needs git >= 2.28
  git -C "$1" symbolic-ref HEAD refs/heads/main    # name the default branch before the first commit
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  echo x > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

# --- 1. retrofit with a sibling entry in the parent (regression: bug #1) ---
mkdir -p "$T/gh"
echo other > "$T/gh/sibling-file"
mkrepo "$T/gh/myrepo"
"$SCRIPT" retrofit "$T/gh/myrepo" >/dev/null
[ -d "$T/gh/myrepo/myrepo-public/.git" ] || fail "retrofit did not create myrepo-public"
[ -d "$T/gh/myrepo/myrepo-private/.git" ] || fail "retrofit did not create myrepo-private"
[ -f "$T/gh/sibling-file" ] || fail "retrofit disturbed a sibling entry"
ok "retrofit succeeds with sibling repos in the parent"
pcm="$T/gh/myrepo/myrepo-private/AGENTS.md"
grep -q '## Launch from the wrapper' "$pcm" || fail "private AGENTS.md not flipped to wrapper-launch"
! grep -q 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD' "$pcm" || fail "private AGENTS.md still references the env-var task"
ok "private AGENTS.md points launches at the wrapper"

# --- guard: a non-repo dir is still rejected ---
if "$SCRIPT" retrofit "$T/gh" >/dev/null 2>&1; then
  fail "retrofit accepted a non-repo directory"
fi
ok "retrofit rejects a non-git directory"

# --- 2. collect classifies repo-root files (regression: bug #2) ---
mkdir -p "$T/proj/proj-private"
mkrepo "$T/proj/proj-public"
( cd "$T/proj/proj-public"
  echo a > architecture.md
  echo b > notes.md
  echo c > rfc-001.md
  # suffix-glob basename path: **/*-design.md matches root-level foo-design.md
  echo d > foo-design.md
  echo e > bar.draft.md
  git add -A && git commit -qm docs )
out="$( cd "$T/proj/proj-public" && "$SCRIPT" collect )"
echo "$out" | grep -q "architecture.md" || fail "collect missed root architecture.md"
echo "$out" | grep -q "notes/.*notes.md" || fail "collect missed root notes.md"
echo "$out" | grep -q "rfc-001.md" || fail "collect missed root rfc-001.md"
# L4: suffix-glob basename matches for **/*-design.md and **/*.draft.md
echo "$out" | grep -q "foo-design.md" || fail "collect missed root foo-design.md (suffix-glob **/*-design.md)"
echo "$out" | grep -q "bar.draft.md" || fail "collect missed root bar.draft.md (suffix-glob **/*.draft.md)"
ok "collect classifies repo-root files including suffix-glob basenames"

# --- 3. failed in-place move restores the repo (regression: bug #3) ---
mkdir -p "$T/solo"
mkrepo "$T/solo/repo"
SCRIPT="$SCRIPT" python3 - "$T/solo/repo" <<'PY'
import importlib.util, os, sys, argparse
from pathlib import Path
spec = importlib.util.spec_from_file_location("pd", os.environ["SCRIPT"])
pd = importlib.util.module_from_spec(spec); spec.loader.exec_module(pd)
src = sys.argv[1]
orig = Path.rename
def flaky(self, target):
    if str(target).endswith("-public"):
        raise OSError("simulated failure")
    return orig(self, target)
Path.rename = flaky
try:
    pd.cmd_retrofit(argparse.Namespace(path=src, name=None, public_name=None, private_name=None))
except SystemExit:
    pass
Path.rename = orig
PY
[ -d "$T/solo/repo/.git" ] || fail "failed move did not restore the repo"
[ -z "$(find "$T/solo" -name '*.wrap-tmp')" ] || fail "failed move left a temp path"
ok "failed in-place move restores the repo"

# --- 4. check_plugin_configs matches only at a path-component boundary (bug #4) ---
# The function scans ~/.claude/{settings.json,plugins/known_marketplaces.json},
# so point HOME at a temp dir and assert /x/foo is NOT matched by /x/foobar.
mkdir -p "$T/cfghome/.claude"
echo '{ "p": "/Users/x/GitHub/foobar" }' > "$T/cfghome/.claude/settings.json"
if ! HOME="$T/cfghome" SCRIPT="$SCRIPT" python3 - <<'PY'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("pd", os.environ["SCRIPT"])
pd = importlib.util.module_from_spec(spec); spec.loader.exec_module(pd)
cfg = Path(os.environ["HOME"]) / ".claude" / "settings.json"
# superset path must NOT trigger a false positive
assert pd.check_plugin_configs(Path("/Users/x/GitHub/foo"), Path("/new")) == [], "matched superset /x/foobar"
# exact path must be flagged
cfg.write_text('{ "p": "/Users/x/GitHub/foo" }')
assert pd.check_plugin_configs(Path("/Users/x/GitHub/foo"), Path("/new")) == [cfg], "exact path not flagged"
PY
then
  fail "check_plugin_configs did not match at a component boundary"
fi
ok "check_plugin_configs matches only at path-component boundaries"

# --- 5. sync wires workspace + access + map for a multi-repo wrapper (feature) ---
mkdir -p "$T/multi"
mkrepo "$T/multi/multi-public"
mkrepo "$T/multi/multi-public-fork"
mkrepo "$T/multi/multi-private"
"$SCRIPT" sync --wrapper "$T/multi" >/dev/null
ws="$T/multi/multi.code-workspace"
[ -f "$ws" ] || fail "sync did not write the workspace file"
if ! python3 - "$ws" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
paths = [f["path"] for f in w["folders"]]
assert paths[0] == "multi-public", f"canonical not first: {paths}"
assert set(paths) == {"multi-public", "multi-public-fork", "multi-private"}, paths
assert w["settings"]["terminal.integrated.cwd"] == "${workspaceFolder:multi-public}/..", w["settings"].get("terminal.integrated.cwd")
assert "workbench.colorCustomizations" in w["settings"]
# launcher runs plain `claude` rooted at the wrapper — no --add-dir, no env var
launcher = w["tasks"]["tasks"][0]
assert launcher["args"] == [], launcher["args"]
assert launcher["options"]["cwd"] == "${workspaceFolder:multi-public}/..", launcher["options"]["cwd"]
assert "env" not in launcher["options"], "env var wiring should be gone"
PY
then
  fail "sync wrote the wrong workspace contents"
fi
# every repo (not just canonical) gets a grant listing its siblings
for r in multi-public multi-public-fork multi-private; do
  sl="$T/multi/$r/.claude/settings.local.json"
  [ -f "$sl" ] || fail "sync did not write settings.local.json in $r"
  grep -q 'settings.local.json' "$T/multi/$r/.git/info/exclude" || fail "settings.local.json not locally excluded in $r"
done
if ! python3 - "$T/multi" <<'PY'
import json, sys, pathlib
wrapper = pathlib.Path(sys.argv[1])
repos = ["multi-public", "multi-public-fork", "multi-private"]
for r in repos:
    d = json.load(open(wrapper / r / ".claude" / "settings.local.json"))
    dirs = set(d["permissions"]["additionalDirectories"])
    expected = {f"../{o}" for o in repos if o != r}
    assert dirs == expected, f"{r}: {dirs} != {expected}"
    assert ".." not in dirs, "should grant enumerated siblings, not the ancestor"
PY
then
  fail "per-repo settings.local.json did not enumerate the correct siblings"
fi
grep -q "workspace map" "$T/multi/README.md" || fail "sync did not write the repo-map README"
grep -q 'cd .* && claude' "$T/multi/README.md" || fail "README does not lead with the launch primitive"
grep -q '/greenroom-sync\|greenroom.py sync' "$T/multi/README.md" || fail "README references a non-runnable sync command"
grep -q 'Launch Claude here, at the wrapper' "$T/multi/README.md" || fail "README trailing paragraph must point launches at the wrapper, not a sub-repo"

# --- wrapper CLAUDE.md (pointer) and AGENTS.md (content) are generated (feature) ---
cm="$T/multi/CLAUDE.md"
am="$T/multi/AGENTS.md"
[ -f "$cm" ] || fail "sync did not write the wrapper CLAUDE.md"
[ -f "$am" ] || fail "sync did not write the wrapper AGENTS.md"
grep -q 'cd .* && claude' "$am" || fail "wrapper AGENTS.md missing the launch primitive"
grep -qi 'never published\|leak' "$am" || fail "wrapper AGENTS.md missing leak-hygiene orientation"
ok "wrapper AGENTS.md is generated with launch + leak guidance; CLAUDE.md pointer exists"

# wrapper CLAUDE.md is write-if-absent: a re-run must not clobber edits
echo 'SENTINEL-keepme' >> "$T/multi/CLAUDE.md"
"$SCRIPT" sync --wrapper "$T/multi" >/dev/null
grep -q 'SENTINEL-keepme' "$T/multi/CLAUDE.md" || fail "sync clobbered a hand-edited wrapper CLAUDE.md"
ok "wrapper CLAUDE.md is preserved on re-run (write-if-absent)"

ok "sync wires workspace, access, and map for a multi-repo wrapper"

# --- 6. sync merge adds a new repo and preserves a hand-added setting (feature) ---
python3 - "$ws" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
w["settings"]["editor.fontSize"] = 14
json.dump(w, open(sys.argv[1], "w"), indent="\t")
PY
mkrepo "$T/multi/multi-private-fork"
"$SCRIPT" sync --wrapper "$T/multi" >/dev/null
if ! python3 - "$ws" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
paths = {f["path"] for f in w["folders"]}
assert "multi-private-fork" in paths, f"new repo not added: {paths}"
assert w["settings"].get("editor.fontSize") == 14, "hand-added setting was clobbered"
PY
then
  fail "sync merge dropped a new repo or clobbered a customization"
fi
ok "sync merge adds new repos and preserves customizations"

# --- upgrade path: an existing workspace with a STALE launcher (no --add-dir,
#     plus a user's own task) gets the launcher refreshed, user task preserved ---
python3 - "$ws" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
w["tasks"]["tasks"] = [
    {"label": "Claude Code (multi-public)", "type": "shell", "command": "claude", "args": []},
    {"label": "my own task", "type": "shell", "command": "make test"},
]
json.dump(w, open(sys.argv[1], "w"), indent="\t")
PY
"$SCRIPT" sync --wrapper "$T/multi" >/dev/null
if ! python3 - "$ws" <<'PY'
import json, sys
tasks = json.load(open(sys.argv[1]))["tasks"]["tasks"]
labels = [t["label"] for t in tasks]
assert labels.count("Claude Code (multi-public)") == 1, f"launcher not deduped: {labels}"
assert "my own task" in labels, "user's own task was dropped"
launcher = next(t for t in tasks if t["label"].startswith("Claude Code ("))
assert launcher["args"] == [], f"refreshed launcher should drop --add-dir: {launcher['args']}"
assert launcher["options"]["cwd"].endswith("/.."), "refreshed launcher should root at the wrapper"
PY
then
  fail "sync did not refresh a stale launcher while keeping the user's tasks"
fi
ok "sync refreshes a stale launcher and preserves user tasks"

# --- 7. wrapper auto-detection: finds the project from inside a repo, but NOT
#        a generic clone parent like ~/GitHub (which would grant `..` over it) ---
( cd "$T/multi/multi-public-fork" && "$SCRIPT" sync >/dev/null ) || fail "sync could not detect the wrapper from inside a repo"
# A bare dir of repos with no -private sibling and no .code-workspace must be rejected.
mkdir -p "$T/looseGitHub"
mkrepo "$T/looseGitHub/randomtool"
mkrepo "$T/looseGitHub/another"
if ( cd "$T/looseGitHub/randomtool" && "$SCRIPT" sync >/dev/null 2>&1 ); then
  fail "sync wrongly treated a generic clone parent as a wrapper"
fi
[ -f "$T/looseGitHub/looseGitHub.code-workspace" ] && fail "sync wrote a workspace into a generic clone parent"
ok "wrapper auto-detection finds the project but not a generic clone parent"

# --- 8. agent-agnostic: new writes wrapper + per-repo AGENTS.md, Claude pointer, Gemini adapter ---
mkdir -p "$T/agtest"
"$SCRIPT" new agtest --parent "$T/agtest" >/dev/null
w="$T/agtest/agtest"
[ -f "$w/AGENTS.md" ] || fail "new did not write wrapper AGENTS.md"
[ -f "$w/agtest-private/AGENTS.md" ] || fail "new did not write per-repo private AGENTS.md"
ok "core writes wrapper AGENTS.md and per-repo private AGENTS.md"

# --- 9. Claude pointer is exactly '@AGENTS.md' ---
cm="$w/CLAUDE.md"
[ -f "$cm" ] || fail "new did not write wrapper CLAUDE.md"
[ "$(cat "$cm")" = "@AGENTS.md" ] || fail "wrapper CLAUDE.md content is not '@AGENTS.md' (got: $(cat "$cm"))"
ok "Claude pointer CLAUDE.md contains exactly '@AGENTS.md'"

# --- 10. Gemini adapter sets contextFileName = AGENTS.md ---
gf="$w/.gemini/settings.json"
[ -f "$gf" ] || fail "new did not write .gemini/settings.json"
if ! python3 - "$gf" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("context", {}).get("fileName") == "AGENTS.md", f"wrong fileName: {d}"
PY
then
  fail ".gemini/settings.json is not valid JSON or has wrong contextFileName"
fi
ok "Gemini adapter .gemini/settings.json parses as JSON with context.fileName == AGENTS.md"

# --- 11. migration: greenroom-authored CLAUDE.md migrates to AGENTS.md + pointer ---
mkdir -p "$T/mig"
"$SCRIPT" new migtest --parent "$T/mig" >/dev/null
wm="$T/mig/migtest"
# Capture the produced AGENTS.md content, then simulate old layout:
# move AGENTS.md content into CLAUDE.md, remove AGENTS.md.
cp "$wm/AGENTS.md" "$wm/CLAUDE.md"
rm "$wm/AGENTS.md"
# Verify pre-conditions for the test.
[ ! -f "$wm/AGENTS.md" ] || fail "setup error: AGENTS.md should not exist before migration"
[ -f "$wm/CLAUDE.md" ] || fail "setup error: CLAUDE.md should exist before migration"
"$SCRIPT" sync --wrapper "$wm" >/dev/null 2>&1 || true
[ -f "$wm/AGENTS.md" ] || fail "migration: AGENTS.md not created after sync"
[ "$(cat "$wm/CLAUDE.md")" = "@AGENTS.md" ] || fail "migration: CLAUDE.md not replaced with pointer (got: $(cat "$wm/CLAUDE.md"))"
ok "migration: greenroom-authored CLAUDE.md migrates to AGENTS.md + pointer"

# --- 12. migration: hand-edited CLAUDE.md is left untouched ---
mkdir -p "$T/mig2"
"$SCRIPT" new handtest --parent "$T/mig2" >/dev/null
wh="$T/mig2/handtest"
# Write clearly custom content into CLAUDE.md, remove AGENTS.md.
echo '# my hand edited notes
custom stuff' > "$wh/CLAUDE.md"
rm "$wh/AGENTS.md"
"$SCRIPT" sync --wrapper "$wh" >/dev/null 2>&1 || true
actual="$(cat "$wh/CLAUDE.md")"
if [ "$actual" = "@AGENTS.md" ]; then
  fail "migration: hand-edited CLAUDE.md was replaced with pointer"
fi
if ! echo "$actual" | grep -q 'my hand edited notes'; then
  fail "migration: hand-edited CLAUDE.md content was changed (got: $actual)"
fi
ok "migration: hand-edited CLAUDE.md is left untouched"

# --- 13. --with-private-fork creates the fork, wires it, neutralizes public-side PR text ---
mkdir -p "$T/forktest"
out13="$("$SCRIPT" new forkproj --parent "$T/forktest" --init-public --with-private-fork 2>&1)"
fork_dir="$T/forktest/forkproj/forkproj-private-fork"
[ -d "$fork_dir/.git" ] || fail "--with-private-fork: private-fork dir not created as a git repo"

# remote is 'upstream', no 'origin'
remotes="$(git -C "$fork_dir" remote)"
echo "$remotes" | grep -q 'upstream' || fail "--with-private-fork: private-fork has no 'upstream' remote"
if echo "$remotes" | grep -q 'origin'; then
  fail "--with-private-fork: private-fork should have no 'origin' remote"
fi
ok "--with-private-fork: private-fork cloned with 'upstream' remote and no 'origin'"

# fork is a workspace folder root
wsfork="$T/forktest/forkproj/forkproj.code-workspace"
if ! python3 - "$wsfork" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
paths = {f["path"] for f in w["folders"]}
assert "forkproj-private-fork" in paths, f"private-fork not in workspace: {paths}"
PY
then
  fail "--with-private-fork: private-fork not enumerated as a workspace folder root"
fi
ok "--with-private-fork: private-fork appears as workspace folder root"

# fork has a sibling grant (settings.local.json lists the other repos)
sl_fork="$fork_dir/.claude/settings.local.json"
[ -f "$sl_fork" ] || fail "--with-private-fork: private-fork has no settings.local.json"
if ! python3 - "$sl_fork" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
dirs = d["permissions"]["additionalDirectories"]
assert any("forkproj-public" in x for x in dirs), f"sibling public not in grant: {dirs}"
PY
then
  fail "--with-private-fork: private-fork settings.local.json missing sibling grant"
fi
ok "--with-private-fork: private-fork has sibling grant"

# public-side README map has no PR-direction claims
readme_fork="$T/forktest/forkproj/README.md"
if grep -qi 'PRs from here\|PR upstream\|push branches and open PRs\|open PRs from here' "$readme_fork"; then
  fail "README map asserts PR direction (neutralization not applied)"
fi
ok "README map contains no PR-direction claims"

# offer was printed for -private and -private-fork (but script did NOT create any GitHub repo)
echo "$out13" | grep -q 'gh repo create.*forkproj-private\b.*--private' || \
  fail "--with-private-fork: offer does not include forkproj-private"
echo "$out13" | grep -q 'gh repo create.*forkproj-private-fork.*--private' || \
  fail "--with-private-fork: offer does not include forkproj-private-fork"
# public repo must NOT appear in the offer
if echo "$out13" | grep 'gh repo create' | grep -v '\-private' | grep -q 'forkproj'; then
  fail "--with-private-fork: offer wrongly includes public repo"
fi
ok "--with-private-fork: offer printed for -private and -private-fork; public excluded"

# --- 14. collect: apply copies a text file (L1 regression -- binary-safe apply) ---
mkdir -p "$T/applytest/applytest-private"/{design,notes,drafts,reviews,research}
mkrepo "$T/applytest/applytest-public"
( cd "$T/applytest/applytest-public"
  printf 'hello apply\n' > notes.md
  git add -A && git commit -qm "add notes"
)
"$SCRIPT" collect --public "$T/applytest/applytest-public" \
  --private "$T/applytest/applytest-private" --apply >/dev/null
# notes.md gets date-prefixed; just check something landed in notes/
[ -n "$(ls "$T/applytest/applytest-private/notes/")" ] || fail "collect --apply: notes/ is empty after apply"
grep -rq 'hello apply' "$T/applytest/applytest-private/notes/" || fail "collect --apply: content not preserved in notes/"
ok "collect --apply copies a text file with content intact (L1 binary-safe)"

# --- 15. collect: path-collision disambiguation preserves both files (C4 regression) ---
mkdir -p "$T/colltest/colltest-private"/{design,notes,drafts,reviews,research}
mkrepo "$T/colltest/colltest-public"
( cd "$T/colltest/colltest-public"
  mkdir -p sub/a sub/b
  printf 'from a\n' > sub/a/notes.md
  printf 'from b\n' > sub/b/notes.md
  git add -A && git commit -qm "two notes"
)
out_coll="$( "$SCRIPT" collect --public "$T/colltest/colltest-public" \
  --private "$T/colltest/colltest-private" )"
# Both source paths must appear in the plan
echo "$out_coll" | grep -q "sub/a/notes.md" || fail "collect collision: sub/a/notes.md missing from plan"
echo "$out_coll" | grep -q "sub/b/notes.md" || fail "collect collision: sub/b/notes.md missing from plan"
# Both must map to distinct target names (disambiguation happened)
"$SCRIPT" collect --public "$T/colltest/colltest-public" \
  --private "$T/colltest/colltest-private" --apply >/dev/null
notes_count="$(ls "$T/colltest/colltest-private/notes/" | wc -l | tr -d ' ')"
[ "$notes_count" -ge 2 ] || fail "collect collision: only $notes_count file(s) in notes/ -- expected 2 (disambiguation failed)"
ok "collect path-collision disambiguation preserves both files (C4)"

# --- 16. _default_branch prefers local main over origin/HEAD (L3 regression) ---
# Create a repo with local main and a misleading origin/HEAD pointing at a different name.
mkdir -p "$T/branchtest"
mkrepo "$T/branchtest/local-repo"
( cd "$T/branchtest/local-repo"
  # Simulate a stale origin/HEAD pointing at nonexistent 'develop'
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop 2>/dev/null || true
)
db_out="$(SCRIPT="$SCRIPT" python3 - "$T/branchtest/local-repo" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("pd", os.environ["SCRIPT"])
pd = importlib.util.module_from_spec(spec); spec.loader.exec_module(pd)
print(pd._default_branch(Path(sys.argv[1])))
PY
)"
[ "$db_out" = "main" ] || fail "_default_branch: expected 'main', got '$db_out' (should prefer local over origin/HEAD)"
ok "_default_branch prefers local main over stale origin/HEAD (L3)"

echo "all $pass checks passed"
