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

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/greenroom/scripts/greenroom.py"
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

# --- retrofit with NO path argument operates on the current directory ---
mkdir -p "$T/cwdcase"
mkrepo "$T/cwdcase/inrepo"
( cd "$T/cwdcase/inrepo" && "$SCRIPT" retrofit >/dev/null )
[ -d "$T/cwdcase/inrepo/inrepo-public/.git" ] || fail "no-arg retrofit did not wrap the cwd repo"
[ -d "$T/cwdcase/inrepo/inrepo-private/.git" ] || fail "no-arg retrofit did not scaffold the private dir"
ok "retrofit with no path argument operates on the current directory"

# --- new with NO --parent uses the current directory as the wrapper parent ---
mkdir -p "$T/newcwd"
( cd "$T/newcwd" && "$SCRIPT" new noparentproj >/dev/null )
[ -d "$T/newcwd/noparentproj/noparentproj-private/.git" ] || fail "no-parent new did not scaffold under the cwd"
ok "new with no --parent uses the current directory as the wrapper parent"

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

# --- in-place wrap from INSIDE the repo warns about the now-stale shell cwd ---
mkdir -p "$T/ipwarn"
mkrepo "$T/ipwarn/inrepo"
# the script prints resolved paths (macOS /var -> /private/var), so resolve here too
RP="$( cd "$T/ipwarn/inrepo" && pwd -P )"
out_ip="$( cd "$T/ipwarn/inrepo" && "$SCRIPT" retrofit 2>&1 )"
echo "$out_ip" | grep -q "may look stale" || fail "in-place wrap from inside the repo did not warn about the stale shell cwd"
echo "$out_ip" | grep -qF "cd $RP" || fail "stale-cwd note did not point at the wrapper to re-sync"
# the new-wrapper branch (retrofit --name X, a different name) also moves the
# repo out from under the shell, so it must warn too when run from inside
mkrepo "$T/elsewarn/myrepo"
RPE="$( cd "$T/elsewarn/myrepo" && pwd -P )"
out_else="$( cd "$T/elsewarn/myrepo" && "$SCRIPT" retrofit --name otherproj 2>&1 )"
echo "$out_else" | grep -q "may look stale" || fail "rename-from-inside (--name) did not warn about the stale shell cwd"
echo "$out_else" | grep -qF "cd $(dirname "$RPE")/otherproj" || fail "rename-from-inside note did not point at the new wrapper"
# a retrofit run with a path arg from OUTSIDE the repo must NOT warn (shell undisturbed)
mkrepo "$T/ext/extrepo"
out_ext="$( cd "$T" && "$SCRIPT" retrofit "$T/ext/extrepo" 2>&1 )"
echo "$out_ext" | grep -q "may look stale" && fail "retrofit with a path arg from outside wrongly warned about a stale cwd"
ok "in-place and rename-from-inside wraps warn about the stale shell cwd; a path-arg wrap from outside does not"

# --- stale-cwd warning fires when the shell is in a SUBDIRECTORY of the wrapped repo
#     (the `src in invoked_cwd.parents` branch), reached via an explicit path arg ---
mkrepo "$T/subcase/subrepo"
mkdir -p "$T/subcase/subrepo/deep/nested"
RPS="$( cd "$T/subcase/subrepo" && pwd -P )"
out_sub="$( cd "$T/subcase/subrepo/deep/nested" && "$SCRIPT" retrofit "$RPS" 2>&1 )"
echo "$out_sub" | grep -q "may look stale" || fail "retrofit from a subdir of the repo did not warn about the stale shell cwd"
ok "stale-cwd warning fires from a subdirectory of the wrapped repo"

# --- the re-sync `cd` (and the gh repo-create --source) are shell-escaped, so a
#     wrapper path with spaces yields a pasteable command (iter-1 codex L) ---
mkrepo "$T/sp ace/has repo"
out_sp="$( cd "$T/sp ace/has repo" && "$SCRIPT" retrofit 2>&1 )"
echo "$out_sp" | grep -q "may look stale" || fail "spaced-path in-place wrap did not warn"
# the cd line must be quoted/escaped so it pastes as one argument, not split on the
# space: shlex.quote wraps a spaced path in single quotes, so the cd target begins
# with a quote (no bare space between `cd ` and the path).
echo "$out_sp" | grep -qE "cd '/.*/sp ace/has repo'" \
  || fail "stale-cwd cd line is not shell-escaped for a path with spaces"
# the gh repo-create offer must escape BOTH the --source path AND the repo spec
# (the repo name `has repo-private` contains a space and would split when pasted)
gh_line="$( echo "$out_sp" | grep 'gh repo create' )"
echo "$gh_line" | grep -qE "source='/.*/sp ace/.*'" \
  || fail "gh repo-create --source is not shell-escaped for a path with spaces"
echo "$gh_line" | grep -qE "gh repo create '[^']*has repo-private'" \
  || fail "gh repo-create repo spec is not shell-escaped (splits on the space when pasted)"
ok "the re-sync cd and gh repo-create (spec + --source) are shell-escaped for paths with spaces"

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
assert pd.check_plugin_configs(Path("/Users/x/GitHub/foo")) == [], "matched superset /x/foobar"
# exact path must be flagged
cfg.write_text('{ "p": "/Users/x/GitHub/foo" }')
assert pd.check_plugin_configs(Path("/Users/x/GitHub/foo")) == [cfg], "exact path not flagged"
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
# Force the workspace on first create so the contents/merge/launcher sub-tests
# below have a file to inspect regardless of whether a VS Code-family editor is
# on PATH (portable on a headless box). Once it exists, an existing
# *.code-workspace is itself a detection signal, so later plain `sync`s refresh it.
"$SCRIPT" sync --wrapper "$T/multi" --workspace >/dev/null
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
grep -q 'cd .* && <your-agent>' "$T/multi/README.md" || fail "README does not lead with the launch primitive"
grep -q '/greenroom:sync\|greenroom.py sync' "$T/multi/README.md" || fail "README references a non-runnable sync command"
grep -q 'Launch your agent here, at the wrapper' "$T/multi/README.md" || fail "README trailing paragraph must point launches at the wrapper, not a sub-repo"

# --- marker migration: a README with an OLD begin-marker variant (pre-rename,
# embedding the then-current command name) must still be detected and rewritten
# with the current marker, not skipped as "hand-authored" (#2). Detection keys
# off the stable `<!-- greenroom:begin` token, never the renamable command name.
mkdir -p "$T/markmig/markmig-public"; mkrepo "$T/markmig/markmig-public" >/dev/null
printf '# markmig\n\nIntro the user wrote.\n\n<!-- greenroom:begin (auto-generated by `/greenroom-sync`; edits inside are overwritten) -->\nstale map block\n<!-- greenroom:end -->\n\nTrailer the user wrote.\n' > "$T/markmig/README.md"
"$SCRIPT" sync --wrapper "$T/markmig" >/dev/null
grep -q '/greenroom:sync' "$T/markmig/README.md" || fail "sync did not migrate the old begin-marker to the current command name (#2)"
grep -q 'stale map block' "$T/markmig/README.md" && fail "sync left the stale managed block in place (#2)"
grep -q 'Intro the user wrote.' "$T/markmig/README.md" || fail "sync clobbered content before the marker"
grep -q 'Trailer the user wrote.' "$T/markmig/README.md" || fail "sync clobbered content after the marker"
ok "sync migrates an old begin-marker variant and refreshes the managed block (#2)"

# guard: a README with NO greenroom markers is still left alone (don't let the
# stable-token match get so loose it clobbers a hand-authored README).
printf '# handauthored\n\nNo markers here at all.\n' > "$T/markmig/README.md"
"$SCRIPT" sync --wrapper "$T/markmig" >/dev/null
grep -q 'No markers here at all.' "$T/markmig/README.md" || fail "sync clobbered a marker-less hand-authored README"
grep -q 'greenroom:begin' "$T/markmig/README.md" && fail "sync injected a managed block into a marker-less README"
ok "sync leaves a marker-less hand-authored README untouched"

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

# --- upgrade: a legacy em-dash window.title is refreshed; a custom one is kept ---
python3 - "$ws" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
w["settings"]["window.title"] = "multi — ${activeFolderShort}${separator}${rootName}"
json.dump(w, open(sys.argv[1], "w"), indent="\t")
PY
"$SCRIPT" sync --wrapper "$T/multi" >/dev/null
python3 - "$ws" <<'PY' || exit 1
import json, sys
t = json.load(open(sys.argv[1]))["settings"]["window.title"]
assert "—" not in t, f"legacy em-dash window.title was not refreshed: {t!r}"
assert t == "multi: ${activeFolderShort}${separator}${rootName}", t
PY
# a user's custom title must survive
python3 - "$ws" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
w["settings"]["window.title"] = "my custom title"
json.dump(w, open(sys.argv[1], "w"), indent="\t")
PY
"$SCRIPT" sync --wrapper "$T/multi" >/dev/null
python3 - "$ws" <<'PY' || exit 1
import json, sys
t = json.load(open(sys.argv[1]))["settings"]["window.title"]
assert t == "my custom title", f"custom window.title was clobbered: {t!r}"
PY
ok "sync refreshes a legacy em-dash window.title but keeps a custom one"

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
# --workspace so the fork-as-workspace-root assertion below is portable (no PATH probe needed).
out13="$("$SCRIPT" new forkproj --parent "$T/forktest" --init-public --with-private-fork --workspace 2>&1)"
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
mkdir -p "$T/applytest/applytest-private"/{docs,notes,drafts,reviews,research}
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
mkdir -p "$T/colltest/colltest-private"/{docs,notes,drafts,reviews,research}
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

# --- 17. collect: a-b/foo-design.md AND a/b/foo-design.md both survive (M5 regression boundary) ---
# Prior fix (slash-to-dash prefix rename) produced the same flat name for both;
# one file was silently lost. The fix places each colliding file under a distinct
# stable-hash directory: docs/<shorthash>/foo-design.md.
mkdir -p "$T/m5test/m5test-private"/{docs,notes,drafts,reviews,research}
mkrepo "$T/m5test/m5test-public"
( cd "$T/m5test/m5test-public"
  mkdir -p a-b a/b
  printf 'from a-b dir\n' > a-b/foo-design.md
  printf 'from a/b dir\n' > a/b/foo-design.md
  git add -A && git commit -qm "add colliding design files"
)
"$SCRIPT" collect --public "$T/m5test/m5test-public" \
  --private "$T/m5test/m5test-private" --apply >/dev/null
# Both source paths must land as DISTINCT files (not the same target).
found_ab="$(find "$T/m5test/m5test-private" -type f -name 'foo-design.md' | wc -l | tr -d ' ')"
[ "$found_ab" -ge 2 ] || fail "M5: both a-b/foo-design.md and a/b/foo-design.md must land as distinct files; found $found_ab"
# Content from each source must be present somewhere in the private tree.
grep -rq 'from a-b dir' "$T/m5test/m5test-private" || fail "M5: content from a-b/foo-design.md not found in private"
grep -rq 'from a/b dir' "$T/m5test/m5test-private" || fail "M5: content from a/b/foo-design.md not found in private"
# Both files must land in DISTINCT parent directories (distinct hash dirs).
path_ab="$(find "$T/m5test/m5test-private" -type f -name 'foo-design.md' | sort)"
dir1="$(echo "$path_ab" | head -1 | xargs dirname)"
dir2="$(echo "$path_ab" | tail -1 | xargs dirname)"
[ "$dir1" != "$dir2" ] || fail "M5: both foo-design.md files share the same parent dir ($dir1); collision was not separated"
# The hash dirs themselves must be 16-char hex strings (new strategy, not old nesting).
hash1="$(basename "$dir1")"
hash2="$(basename "$dir2")"
echo "$hash1" | grep -qE '^[0-9a-f]{16}$' || fail "M5: hash dir '$hash1' is not 16-char hex (wrong collision strategy?)"
echo "$hash2" | grep -qE '^[0-9a-f]{16}$' || fail "M5: hash dir '$hash2' is not 16-char hex (wrong collision strategy?)"
[ "$hash1" != "$hash2" ] || fail "M5: both files got the same hash dir ($hash1); hashes must differ for distinct source paths"
# Coexistence of two files with the same name proves no file/dir conflict (the ancestor assertion fired pre-apply).
ok "M5: a-b/foo-design.md and a/b/foo-design.md both survive as distinct files under distinct hash dirs (collision boundary)"

# --- 18. _default_branch uses origin/HEAD default over stray local main (M6 regression boundary) ---
# Repo whose true default is master; a stray local main also exists.
# origin/HEAD points at master -- _default_branch must return master.
mkdir -p "$T/m6test"
( cd "$T/m6test"
  git init -q master-repo
  git -C master-repo config user.email t@t
  git -C master-repo config user.name t
  # Start on master branch (default for older git).
  git -C master-repo symbolic-ref HEAD refs/heads/master
  echo x > master-repo/README.md
  git -C master-repo add -A
  git -C master-repo commit -qm init
  # Create a stray local main branch.
  git -C master-repo branch main
  # Wire up a bare "origin" so origin/HEAD can point at master.
  git init --bare -q master-origin
  git -C master-repo remote add origin "$T/m6test/master-origin"
  git -C master-repo push -q origin master
  git -C master-origin symbolic-ref HEAD refs/heads/master
  git -C master-repo fetch -q origin
  git -C master-repo remote set-head origin master
)
m6_out="$(SCRIPT="$SCRIPT" python3 - "$T/m6test/master-repo" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("pd", os.environ["SCRIPT"])
pd = importlib.util.module_from_spec(spec); spec.loader.exec_module(pd)
print(pd._default_branch(Path(sys.argv[1])))
PY
)"
[ "$m6_out" = "master" ] || fail "M6: expected 'master', got '$m6_out' (stray local main must not override origin/HEAD)"
ok "M6: _default_branch returns master when origin/HEAD says master, even with stray local main (M6 boundary)"

# --- 19. _default_branch preserves slash-containing branch names (M7 regression boundary) ---
# origin/HEAD points at refs/remotes/origin/release/stable.
# split("/")[-1] would return "stable" (wrong); the fix strips the fixed prefix
# "refs/remotes/origin/" and keeps the full remainder "release/stable".
mkdir -p "$T/m7test"
( cd "$T/m7test"
  git init -q slash-repo
  git -C slash-repo config user.email t@t
  git -C slash-repo config user.name t
  git -C slash-repo symbolic-ref HEAD refs/heads/release/stable
  echo x > slash-repo/README.md
  git -C slash-repo add -A
  git -C slash-repo commit -qm init
  # Wire up a bare origin so origin/HEAD can point at release/stable.
  git init --bare -q slash-origin
  git -C slash-repo remote add origin "$T/m7test/slash-origin"
  git -C slash-repo push -q origin 'release/stable'
  git -C slash-origin symbolic-ref HEAD refs/heads/release/stable
  git -C slash-repo fetch -q origin
  git -C slash-repo remote set-head origin release/stable
)
# Assert setup is correct before calling _default_branch -- distinguishes setup failure from logic regression.
m7_setup_ref="$(git -C "$T/m7test/slash-repo" symbolic-ref refs/remotes/origin/HEAD)"
[ "$m7_setup_ref" = "refs/remotes/origin/release/stable" ] \
  || fail "M7 setup: origin/HEAD points at '$m7_setup_ref', expected refs/remotes/origin/release/stable"
m7_out="$(SCRIPT="$SCRIPT" python3 - "$T/m7test/slash-repo" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("pd", os.environ["SCRIPT"])
pd = importlib.util.module_from_spec(spec); spec.loader.exec_module(pd)
print(pd._default_branch(Path(sys.argv[1])))
PY
)"
[ "$m7_out" = "release/stable" ] || fail "M7: expected 'release/stable', got '$m7_out' (slash in branch name must be preserved)"
ok "M7: _default_branch returns full slash-containing branch name release/stable (M7 boundary)"

# --- 20. collect: colliding notes both land dated (M8 regression boundary) ---
# Two notes-bucket files that share the same basename but live in different
# parent dirs, so they collide. The collision branch must apply target_name
# (with YYYY-MM-DD- date prefix) rather than src.name (undated).
# Files land at notes/<shorthash>/YYYY-MM-DD-<name> with distinct hash dirs.
# Use *.private.md suffix so both files classify into the notes bucket.
mkdir -p "$T/m8test/m8test-private"/{docs,notes,drafts,reviews,research}
mkrepo "$T/m8test/m8test-public"
( cd "$T/m8test/m8test-public"
  mkdir -p team-a team-b
  printf 'from team-a\n' > team-a/standup.private.md
  printf 'from team-b\n' > team-b/standup.private.md
  git add -A && git commit -qm "add colliding notes"
)
"$SCRIPT" collect --public "$T/m8test/m8test-public" \
  --private "$T/m8test/m8test-private" --apply >/dev/null
# Both files must exist in notes/ (distinct paths).
notes_files="$(find "$T/m8test/m8test-private/notes" -type f | sort)"
notes_count="$(echo "$notes_files" | wc -l | tr -d ' ')"
[ "$notes_count" -ge 2 ] || fail "M8: expected 2 notes files after collision, found $notes_count"
# Both must carry a YYYY-MM-DD- date prefix in their filename.
while IFS= read -r f; do
  fname="$(basename "$f")"
  echo "$fname" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-' \
    || fail "M8: colliding note '$fname' is missing the YYYY-MM-DD- date prefix"
done <<< "$notes_files"
# Both must land at distinct hash dirs (notes/<hash>/YYYY-MM-DD-<name>).
ndir1="$(echo "$notes_files" | head -1 | xargs dirname)"
ndir2="$(echo "$notes_files" | tail -1 | xargs dirname)"
[ "$ndir1" != "$ndir2" ] || fail "M8: both colliding notes share the same parent dir ($ndir1); collision was not separated"
nhash1="$(basename "$ndir1")"
nhash2="$(basename "$ndir2")"
echo "$nhash1" | grep -qE '^[0-9a-f]{16}$' || fail "M8: hash dir '$nhash1' is not 16-char hex"
echo "$nhash2" | grep -qE '^[0-9a-f]{16}$' || fail "M8: hash dir '$nhash2' is not 16-char hex"
[ "$nhash1" != "$nhash2" ] || fail "M8: both colliding notes got the same hash dir ($nhash1); hashes must differ"
ok "M8: colliding notes both land dated under distinct hash dirs (M8 boundary)"

# --- 21. a stray non-greenroom .code-workspace must NOT qualify a dir as a wrapper (issue #4) ---
mkdir -p "$T/strayws"
mkrepo "$T/strayws/somerepo"
echo '{"folders":[{"path":"."}]}' > "$T/strayws/chezmoi.code-workspace"   # not greenroom's
( cd "$T/strayws/somerepo" && "$SCRIPT" sync ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "sync treated a stray-workspace dir as a wrapper"
[ ! -f "$T/strayws/CLAUDE.md" ] || fail "sync scaffolded CLAUDE.md into a stray-workspace dir"
[ ! -f "$T/strayws/AGENTS.md" ] || fail "sync scaffolded AGENTS.md into a stray-workspace dir"
ok "stray non-greenroom .code-workspace does not qualify a wrapper"

# --- 22. explicit --wrapper at a forbidden root is refused, nothing written (issue #4) ---
fake_home="$T/fakehome"
mkdir -p "$fake_home"
mkrepo "$fake_home/proj"
HOME="$fake_home" "$SCRIPT" sync --wrapper "$fake_home" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "sync --wrapper \$HOME was not refused"
[ ! -f "$fake_home/CLAUDE.md" ] || fail "sync wrote CLAUDE.md into \$HOME"
[ ! -f "$fake_home/AGENTS.md" ] || fail "sync wrote AGENTS.md into \$HOME"
ok "explicit --wrapper at \$HOME is refused and writes nothing"

# --- 23. a greenroom sentinel workspace DOES qualify; sentinel-only wrapper re-syncs cleanly ---
mkdir -p "$T/realwrap"
mkrepo "$T/realwrap/realwrap-public"
mkrepo "$T/realwrap/realwrap-private"
# --workspace forces the sentinel-bearing file so this test is about the sentinel,
# not about whether an editor is on PATH.
( cd "$T/realwrap/realwrap-public" && "$SCRIPT" sync --workspace ) >/dev/null
grep -q '"greenroom"' "$T/realwrap"/*.code-workspace || fail "sync did not stamp the greenroom sentinel"
# Isolate the workspace sentinel as the SOLE signal: drop both the -private sibling
# and the .greenroom marker, so only the sentinel can keep it a wrapper on re-sync.
rm -rf "$T/realwrap/realwrap-private"
rm -f "$T/realwrap/.greenroom"
( cd "$T/realwrap/realwrap-public" && "$SCRIPT" sync --workspace ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "sentinel-only wrapper no longer recognized on re-sync"
ok "greenroom sentinel workspace qualifies a wrapper on its own"

# --- 24. GREENROOM_ROOT boundary: a wrapper above the boundary is refused ---
mkdir -p "$T/below/proj"
mkrepo "$T/below/proj/proj-public"
mkrepo "$T/below/proj/proj-private"
# boundary at $T/below: the wrapper $T/below/proj is below it -> allowed
GREENROOM_ROOT="$T/below" sh -c "cd '$T/below/proj/proj-public' && '$SCRIPT' sync" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "GREENROOM_ROOT wrongly refused a wrapper below the boundary"
# boundary at $T/below/proj: $T/below/proj IS the boundary -> refused as a wrapper target
GREENROOM_ROOT="$T/below/proj" "$SCRIPT" sync --wrapper "$T/below/proj" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "GREENROOM_ROOT did not refuse its own dir as a wrapper"
ok "GREENROOM_ROOT refuses its own dir and any ancestor as a wrapper"

# --- 25. GREENROOM_ROOT is a valid PARENT (target vs parent split, issue #4 / iter-1 codex M) ---
# The documented workflow: GREENROOM_ROOT="$HOME/GitHub"; new --parent "$HOME/GitHub".
mkdir -p "$T/grroot"
GREENROOM_ROOT="$T/grroot" "$SCRIPT" new demo --parent "$T/grroot" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "new --parent \$GREENROOM_ROOT was refused (boundary should be a valid parent)"
[ -d "$T/grroot/demo/demo-private" ] || fail "new --parent \$GREENROOM_ROOT did not create the wrapper"
# retrofit of a repo directly under the boundary is likewise allowed
mkrepo "$T/grroot/leaf"
GREENROOM_ROOT="$T/grroot" "$SCRIPT" retrofit "$T/grroot/leaf" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "retrofit of a repo directly under \$GREENROOM_ROOT was refused"
[ -d "$T/grroot/leaf/leaf-private/.git" ] || fail "retrofit under \$GREENROOM_ROOT did not scaffold the private repo"
# but the boundary itself is still refused as a scaffold TARGET, and an ancestor as a parent
GREENROOM_ROOT="$T/grroot" "$SCRIPT" new x --parent "$T" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "new --parent above the boundary was allowed (should be refused)"
# retrofit of an ALREADY-WRAPPED repo whose wrapper IS the boundary must be refused
# (wrapper == parent == GREENROOM_ROOT; the final target must clear _is_forbidden_root,
# not just _is_forbidden_parent) (iter-4 codex M, greenroom.py:913)
mkdir -p "$T/atroot"
mkrepo "$T/atroot/atroot-public"                                  # makes $T/atroot look already-wrapped
mkdir -p "$T/atroot/atroot-private"                               # -private sibling => _looks_like_wrapper
GREENROOM_ROOT="$T/atroot" "$SCRIPT" retrofit "$T/atroot/atroot-public" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "retrofit into a wrapper that IS \$GREENROOM_ROOT was allowed (should be refused)"
[ ! -f "$T/atroot/atroot.code-workspace" ] || fail "retrofit scaffolded into the boundary despite refusal"
# and a project created under the boundary can still be synced afterward (not stranded by the walk-stop)
GREENROOM_ROOT="$T/grroot" sh -c "cd '$T/grroot/leaf/leaf-public' && '$SCRIPT' sync" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "a wrapper created under \$GREENROOM_ROOT could not be synced afterward"
ok "GREENROOM_ROOT is a valid parent for new/retrofit, still refused as a target and above"

# --- 26. workspace sentinel requires {"wrapper": true}, not just any greenroom key (iter-1 claude-code M/L) ---
mkdir -p "$T/sent"
mkrepo "$T/sent/somerepo"
echo '{"folders":[{"path":"."}],"greenroom":{}}' > "$T/sent/x.code-workspace"     # dict but no wrapper:true
( cd "$T/sent/somerepo" && "$SCRIPT" sync ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an empty greenroom:{} workspace wrongly qualified a wrapper"
echo '{"folders":[{"path":"."}],"greenroom":"yes"}' > "$T/sent/x.code-workspace"  # non-dict value
( cd "$T/sent/somerepo" && "$SCRIPT" sync ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a non-dict greenroom value wrongly qualified a wrapper"
ok "workspace sentinel requires {\"wrapper\": true}, not just any greenroom key"

# --- 27. a non-UTF-8 / undecodable .code-workspace is skipped, not a crash (iter-2 claude-code L) ---
mkdir -p "$T/badenc"
mkrepo "$T/badenc/somerepo"
printf '\xff\xfe\x00bad' > "$T/badenc/x.code-workspace"                            # invalid UTF-8 bytes
( cd "$T/badenc/somerepo" && "$SCRIPT" sync ) >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an undecodable .code-workspace wrongly qualified a wrapper"
ok "an undecodable .code-workspace is skipped without crashing classification"

# --- 28. skill identity + frontmatter actually parses as YAML.
#         The npx skills CLI derives the install dir and registry slug from the
#         `name:` field, not the repo directory, and parseSkillMd() wraps the YAML
#         parse in try/catch returning null -- so malformed frontmatter makes the
#         skill vanish from the registry with NO error. Assert it parses, rather
#         than asserting one fixed string, so any future breakage is caught. ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/greenroom/SKILL.md"
[ -f "$SKILL_MD" ] || fail "skills/greenroom/SKILL.md is missing"
[ ! -f "$REPO_ROOT/SKILL.md" ] || fail "a root SKILL.md exists (whole repo would install as one skill)"
[ ! -e "$REPO_ROOT/skills/greenroom-setup" ] || fail "the old skills/greenroom-setup/ still exists"
python3 - "$SKILL_MD" <<'PY' || fail "SKILL.md frontmatter is not valid, parseable YAML"
import re, sys, pathlib
raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n", raw, re.S)
assert m, "no frontmatter block at the very start of the file"
try:
    import yaml
except ImportError:
    # No PyYAML. Do NOT hand-roll a parser -- a strict line check rejects valid
    # YAML (block scalars, nested maps) and would make this test's verdict depend
    # on the developer's Python environment. Assert only what a regex can honestly
    # verify -- a top-level `name: greenroom` line -- and skip the rest.
    assert re.search(r"(?m)^name:[ \t]*greenroom[ \t]*$", m.group(1)), \
        "no top-level `name: greenroom` line in the frontmatter"
    print("NOTE: PyYAML absent -- checked the name: line only, skipped the YAML parse")
    sys.exit(0)
data = yaml.safe_load(m.group(1))
assert isinstance(data, dict), "frontmatter is not a mapping"
for field in ("name", "description"):
    assert isinstance(data.get(field), str) and data[field], f"{field} missing or not a string"
assert data["name"] == "greenroom", f"name is {data['name']!r}, expected 'greenroom'"
assert len(data["description"]) <= 1024, "description exceeds the 1024-char spec cap"
PY
ok "SKILL.md frontmatter parses as YAML with name: greenroom"

# --- 29. PAYLOAD SELF-SUFFICIENCY. `npx skills add` copies skills/greenroom/ and
#         nothing else. Copy that directory ALONE into a bare temp dir and drive a
#         full scaffold from it. This is the exact failure mode that shipped before:
#         a SKILL.md documenting a script and templates that were not in the payload. ---
iso="$T/isolated"
mkdir -p "$iso"
cp -R "$REPO_ROOT/skills/greenroom" "$iso/greenroom"
[ -x "$iso/greenroom/scripts/greenroom.py" ] || fail "greenroom.py is not executable in the copied payload"
mkdir -p "$T/isoparent"
( cd "$iso/greenroom" && ./scripts/greenroom.py new isoproj --init-public --parent "$T/isoparent" ) >/dev/null \
  || fail "the standalone skill payload cannot scaffold a project"
[ -d "$T/isoparent/isoproj/isoproj-public/.git" ] || fail "isolated payload did not init the public repo"
[ -d "$T/isoparent/isoproj/isoproj-private/docs" ] || fail "isolated payload did not create the private buckets"
[ -f "$T/isoparent/isoproj/isoproj-private/AGENTS.md" ] || fail "isolated payload could not render its templates"
[ -f "$T/isoparent/isoproj/.greenroom" ] || fail "isolated payload did not write the .greenroom marker"
# SKILL.md routes to `sync` and `collect` too, and to references/*.md. A typo in a
# router link is a dead pointer -- the same "documented but not shipped" bug class. ---
for ref in $(grep -o 'references/[a-z-]*\.md' "$iso/greenroom/SKILL.md" | sort -u); do
  [ -f "$iso/greenroom/$ref" ] || fail "SKILL.md routes to $ref, which is not in the payload"
done
( cd "$iso/greenroom" && ./scripts/greenroom.py collect --help ) >/dev/null \
  || fail "the isolated payload cannot run the collect subcommand"
( cd "$T/isoparent/isoproj/isoproj-public" && "$iso/greenroom/scripts/greenroom.py" sync ) >/dev/null \
  || fail "the isolated payload cannot sync the wrapper it just scaffolded"
[ -f "$T/isoparent/isoproj/README.md" ] || fail "isolated-payload sync did not write the wrapper repo map"
ok "skills/greenroom/ is self-sufficient: it scaffolds, syncs, and ships every reference it routes to"

# --- 30. context budget. A loaded skill stays resident across turns, and the
#         description sits in the skill listing every session. Both regrow silently
#         unless asserted. ---
desc_len="$(sed -n 's/^description: //p' "$SKILL_MD" | head -1 | tr -d '\n' | wc -c | tr -d ' ')"
[ "$desc_len" -le 400 ] || fail "description is $desc_len chars (budget: 400)"
skill_words="$(wc -w < "$SKILL_MD" | tr -d ' ')"
[ "$skill_words" -le 1200 ] || fail "SKILL.md is $skill_words words (budget: 1200)"
ok "context budget holds (description ${desc_len}c, SKILL.md ${skill_words}w)"

# --- 31. no UNCONDITIONAL reliance on plugin-only variables. ${CLAUDE_PLUGIN_ROOT}
#         is defined only by the Claude Code plugin runtime; it is unset under
#         `npx skills add` and under every other harness. The path resolver may
#         probe it, but only with a `:-` default so an unset value degrades to a
#         miss instead of an empty-prefix path. ---
bare_ref="$(grep -rn 'CLAUDE_PLUGIN_ROOT' "$REPO_ROOT/skills/" | grep -v 'CLAUDE_PLUGIN_ROOT:-' || true)"
[ -z "$bare_ref" ] \
  || fail "skills/ uses \${CLAUDE_PLUGIN_ROOT} without a :- default (undefined on a standalone install): $bare_ref"
ok "skill content relies on no plugin-only path variable"

# --- 32. commands stay hollow. They are Claude-Code-only sugar; `npx skills` never
#         reads commands/. Any logic here is logic a skills.sh user cannot reach. ---
for cmd in "$REPO_ROOT"/commands/*.md; do
  lines="$(wc -l < "$cmd" | tr -d ' ')"
  [ "$lines" -le 15 ] || fail "$(basename "$cmd") is $lines lines (hollow-command budget: 15)"
  ! grep -q '```' "$cmd" || fail "$(basename "$cmd") contains a code block (logic belongs in the skill)"
done
ok "slash commands are hollow triggers with no embedded logic"

# --- 33. manual install links the skill, and the script + templates come with it ---
mh="$T/manualhome"
mkdir -p "$mh"
HOME="$mh" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh failed"
[ -L "$mh/.claude/skills/greenroom" ] || fail "manual install did not create the /greenroom skill link"
[ -f "$mh/.claude/skills/greenroom/SKILL.md" ] || fail "the skill link does not expose a SKILL.md"
[ -e "$mh/.claude/skills/greenroom/scripts/greenroom.py" ] || fail "the skill link does not expose scripts/"
[ -e "$mh/.claude/skills/greenroom/templates/private_AGENTS.md" ] || fail "the skill link does not expose templates/"
[ ! -e "$mh/.claude/skills/greenroom-setup" ] || fail "manual install still creates the old greenroom-setup name"
ok "manual install gives /greenroom with its script and templates attached"

# --- 34. manual install is idempotent: a second run links nothing new and errors nothing ---
out2="$(HOME="$mh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "second install.sh run errored"
echo "$out2" | grep -q "SKIP" && fail "second install.sh run hit an unexpected SKIP: $out2"
# The skill link now lives at the same path an ancient root symlink used, so a
# too-broad migration match would "migrate" the healthy link on every re-run.
echo "$out2" | grep -q "migrated:" && fail "second install.sh run reported a migration that never happened: $out2"
[ -L "$mh/.claude/skills/greenroom" ] || fail "idempotent run dropped the greenroom link"
ok "manual install is idempotent (re-run is clean, no phantom migration)"

# --- 35. migration: the old script-root shim (a real dir of our symlinks, no
#          SKILL.md) sat at exactly the path the renamed skill now claims. Left in
#          place it is not a symlink, so link_one would SKIP it and the install
#          would silently no-op. It must be detected and removed. ---
sh_mig="$T/shimhome"
mkdir -p "$sh_mig/.claude/skills/greenroom"
ln -s "$REPO_ROOT/skills/greenroom/scripts" "$sh_mig/.claude/skills/greenroom/scripts"
ln -s "$REPO_ROOT/skills/greenroom/templates" "$sh_mig/.claude/skills/greenroom/templates"
ln -s "$REPO_ROOT/skills/greenroom" "$sh_mig/.claude/skills/greenroom-setup"   # old skill name too
HOME="$sh_mig" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored migrating the old shim"
[ -L "$sh_mig/.claude/skills/greenroom" ] || fail "the old shim dir was not replaced by the skill symlink"
[ -f "$sh_mig/.claude/skills/greenroom/SKILL.md" ] || fail "post-migration greenroom link has no SKILL.md"
[ ! -e "$sh_mig/.claude/skills/greenroom-setup" ] || fail "the stale greenroom-setup link survived migration"
ok "the old script-root shim and the greenroom-setup link are migrated away"

# --- 36. migration: an even older installer symlinked this path straight at the
#          repo root, which exposed .claude-plugin/plugin.json. ---
gh_mig="$T/mighome"
mkdir -p "$gh_mig/.claude/skills"
ln -s "$REPO_ROOT" "$gh_mig/.claude/skills/greenroom"            # simulate the old root-symlink layout
HOME="$gh_mig" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored migrating an old root symlink"
[ -f "$gh_mig/.claude/skills/greenroom/SKILL.md" ] || fail "migration did not leave a working skill link"
[ ! -e "$gh_mig/.claude/skills/greenroom/.claude-plugin/plugin.json" ] || fail "migration left the plugin manifest exposed"
ok "an old greenroom->repo-root symlink is migrated to the real skill link"

# --- 37. an UNRELATED symlink the user placed at the skill path is NOT removed,
#          repointed, or written through. Migration skips it on ownership, and
#          link_one must skip it too -- otherwise the link survives migration only
#          to be silently replaced one step later. ---
ug="$T/unrelhome"
mkdir -p "$ug/.claude/skills" "$ug/somewhere-else"
ln -s "$ug/somewhere-else" "$ug/.claude/skills/greenroom"        # user's own symlink, not ours
out4="$(HOME="$ug" bash "$REPO_ROOT/install.sh" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "install.sh errored on an unrelated user symlink (rc=$rc)"
[ ! -e "$ug/somewhere-else/SKILL.md" ] || fail "install.sh wrote THROUGH the unrelated symlink into the user's dir"
[ -L "$ug/.claude/skills/greenroom" ] || fail "install.sh removed an unrelated user symlink at the skill path"
[ "$(readlink "$ug/.claude/skills/greenroom")" = "$ug/somewhere-else" ] \
  || fail "install.sh repointed an unrelated user symlink at the skill path"
echo "$out4" | grep -q "SKIP skill greenroom" \
  || fail "install.sh did not report skipping the unrelated user symlink: $out4"
ok "an unrelated user symlink at the skill path is left exactly as the user made it"

# --- 38. install.sh never clobbers a real (non-symlink) file the user owns ---
ch="$T/clobberhome"
mkdir -p "$ch/.claude/skills"
echo "do not touch" > "$ch/.claude/skills/greenroom"              # a real file, not our symlink
out3="$(HOME="$ch" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a pre-existing real file"
echo "$out3" | grep -q "SKIP skill greenroom" || fail "install.sh did not SKIP a pre-existing real greenroom file"
[ "$(cat "$ch/.claude/skills/greenroom")" = "do not touch" ] || fail "install.sh clobbered a real user file"
ok "install.sh skips (never clobbers) a real user file at the skill target"

# --- 39. the shim migration removes only the two links we created. A user file
#          dropped into the old shim dir must survive, and the migration must say
#          so rather than `rm -rf`-ing the whole directory. ---
kh="$T/keephome"
mkdir -p "$kh/.claude/skills/greenroom"
ln -s "$REPO_ROOT/skills/greenroom/scripts" "$kh/.claude/skills/greenroom/scripts"
echo "mine" > "$kh/.claude/skills/greenroom/notes.md"
out5="$(HOME="$kh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a shim holding a user file"
[ -f "$kh/.claude/skills/greenroom/notes.md" ] || fail "shim migration destroyed a user file it did not create"
[ ! -e "$kh/.claude/skills/greenroom/scripts" ] || fail "shim migration left our own stale scripts link behind"
echo "$out5" | grep -q "SKIP migration" || fail "shim migration removed nothing but stayed silent: $out5"
ok "the shim migration removes only our links and reports what it left behind"

# --- 40. ownership checks resolve RELATIVE symlink targets. An install whose links
#          were made from inside ~/.claude/skills (so the target is relative) is
#          still ours, and must be migrated rather than mistaken for a user link. ---
rh="$T/relhome"
mkdir -p "$rh/.claude/skills"
# relpath is textual, so compute it from the PHYSICAL dirs -- on macOS $TMPDIR is
# itself under a symlink and a logical relpath would yield a dangling link.
( cd "$rh/.claude/skills" && ln -s "$(python3 -c \
    'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' \
    "$REPO_ROOT" .)" greenroom )                                    # relative root symlink, still ours
[ -e "$rh/.claude/skills/greenroom/install.sh" ] || fail "test bug: the relative fixture link is dangling"
HOME="$rh" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored on a relative-target link"
[ -f "$rh/.claude/skills/greenroom/SKILL.md" ] || fail "a relative-target root symlink was not migrated to the skill link"
[ ! -e "$rh/.claude/skills/greenroom/.claude-plugin/plugin.json" ] \
  || fail "a relative-target root symlink was left exposing the plugin manifest"
ok "ownership checks resolve relative symlink targets, not just absolute ones"

# --- 39. new/retrofit write a .greenroom marker; sync adds it to a marker-less wrapper ---
mkdir -p "$T/mark"
"$SCRIPT" new markproj --parent "$T/mark" >/dev/null
gm="$T/mark/markproj/.greenroom"
[ -f "$gm" ] || fail "new did not write the .greenroom marker"
python3 - "$gm" <<'PY' || fail ".greenroom is not {\"schema\": <int>}"
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d.get("schema"), int), d
assert "folders" not in d and "repos" not in d and "canonical" not in d, "marker must be minimal"
PY
ok "new writes a minimal .greenroom marker"

# sync adds .greenroom to a pre-marker wrapper (simulate by deleting it).
# `new` with no --init-public/--clone leaves the public dir uncreated, so detect
# the wrapper from the always-present private repo instead.
rm -f "$gm"
( cd "$T/mark/markproj/markproj-private" && "$SCRIPT" sync ) >/dev/null
[ -f "$gm" ] || fail "sync did not add .greenroom to a marker-less wrapper"
ok "sync adds .greenroom to a wrapper that lacks it"

# --- 40. a stray .greenroom in a forbidden dir does NOT make it a wrapper (walk-up guard) ---
fhm="$T/markforbid"
mkdir -p "$fhm"
mkrepo "$fhm/repo-public"
mkrepo "$fhm/repo-private"
echo '{"schema": 1}' > "$fhm/.greenroom"
# point HOME at the forbidden dir so _is_forbidden_root($HOME) fires on the walk-up
HOME="$fhm" sh -c "cd '$fhm/repo-public' && '$SCRIPT' sync" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a stray .greenroom in \$HOME wrongly qualified it as a wrapper"
[ ! -f "$fhm/CLAUDE.md" ] || fail "sync scaffolded into a forbidden dir carrying a stray .greenroom"
ok "a stray .greenroom in a forbidden dir is not treated as a wrapper (walk-up guard)"

# --- 41. workspace is skipped when no VS Code signal; --workspace / --no-workspace override ---
# GREENROOM_TEST_NO_EDITOR makes the PATH probe find nothing, so detection falls to
# .vscode/ and *.code-workspace presence only (deterministic regardless of the dev box).
mkdir -p "$T/nows"
GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" new nowsproj --parent "$T/nows" --init-public >/dev/null
nws="$T/nows/nowsproj/nowsproj.code-workspace"
[ ! -f "$nws" ] || fail "workspace was written despite no VS Code signal"
[ -f "$T/nows/nowsproj/.greenroom" ] || fail "marker missing — wrapper identity must not depend on the workspace"
# iter-1 codex L: the generated README of a no-workspace wrapper must not give an
# unconditional "Open it through <project>.code-workspace" instruction for a file
# that was never written. It leads with wrapper-launch and mentions the workspace
# only as conditional ("if ... present"/"if ... exists").
nows_readme="$T/nows/nowsproj/README.md"
grep -q 'cd nowsproj && <your-agent>' "$nows_readme" || fail "no-workspace README does not lead with wrapper-launch"
# Negative pin: the old unconditional "Open it through <ws>" phrasing must be gone.
grep -qE 'Open it through `nowsproj.code-workspace`' "$nows_readme" \
  && fail "no-workspace README unconditionally tells the user to open a workspace file that was not written"
# Positive property: the workspace must be mentioned conditionally, so the test
# also fails if the wording regresses to a differently-phrased unconditional open.
grep -q 'is present' "$nows_readme" || fail "no-workspace README dropped the conditional ('if present') framing around the workspace file"
ok "a no-workspace wrapper's README leads with wrapper-launch and frames the workspace conditionally"

ok "workspace skipped when no VS Code family is detected (identity via .greenroom)"

# --workspace forces the file even with no editor detected
( cd "$T/nows/nowsproj/nowsproj-public" && GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" sync --workspace ) >/dev/null
[ -f "$nws" ] || fail "--workspace did not force the workspace file"
ok "--workspace forces the workspace file regardless of detection"

# --no-workspace runs cleanly and does not delete an existing workspace file
# (the file here was greenroom-authored by the preceding --workspace sync; the point
# is that --no-workspace means "skip writing", never "remove an existing file").
( cd "$T/nows/nowsproj/nowsproj-public" && GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" sync --no-workspace ) >/dev/null
[ -f "$nws" ] || fail "--no-workspace deleted an existing workspace file (it should only skip writing)"
ok "--no-workspace runs cleanly and leaves an existing workspace untouched"

# --- 42. detection writes the workspace when a .vscode/ dir exists (binary absent) ---
mkdir -p "$T/vscode"
GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" new vscodeproj --parent "$T/vscode" --init-public >/dev/null
vws="$T/vscode/vscodeproj/vscodeproj.code-workspace"
[ ! -f "$vws" ] || fail "setup: workspace should have been skipped before .vscode/ existed"
mkdir -p "$T/vscode/vscodeproj/.vscode"
( cd "$T/vscode/vscodeproj/vscodeproj-public" && GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" sync ) >/dev/null
[ -f "$vws" ] || fail "a present .vscode/ dir did not trigger the workspace write"
ok "detection writes the workspace when .vscode/ exists even with no family binary"

echo "all $pass checks passed"
