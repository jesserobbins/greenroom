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

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/skills/greenroom/scripts/greenroom.py"
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
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SKILL_MD="$REPO_ROOT/skills/greenroom/SKILL.md"
[ -f "$SKILL_MD" ] || fail "skills/greenroom/SKILL.md is missing"
# README's manual-install block says `./install.sh`, which needs the exec bit. The
# suite invokes it as `bash install.sh` everywhere, so nothing else would notice.
[ -x "$REPO_ROOT/install.sh" ] || fail "install.sh is not executable, but README tells users to run ./install.sh"
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
    # Keep the one check that needs no parser: an unquoted `: ` inside the
    # description plain scalar is what silently dropped this skill from the
    # registry once. It costs nothing and is a strict subset of the YAML parse, so
    # the degraded path still guards the known failure rather than just passing.
    desc = re.search(r"(?ms)^description:[ \t]*(.*?)(?=\n[a-zA-Z_-]+:|\Z)", m.group(1))
    assert desc, "no description in the frontmatter"
    assert ": " not in desc.group(1) or desc.group(1).lstrip()[:1] in "\"'|>", \
        "description holds an unquoted `: ` -- the YAML parser will drop this skill"
    print("NOTE: PyYAML absent -- checked name: and the description colon rule only")
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
[ -x "$iso/greenroom/scripts/greenroom.py" ] || fail "greenroom.py is not executable in the tracked payload"
mkdir -p "$T/isoparent"
# ...but the scaffold itself is driven through python3 with the exec bit STRIPPED.
# A tarball/zip channel may not preserve it, and SKILL.md's resolver deliberately
# invokes via python3 for that reason -- exercising ./scripts/greenroom.py here
# would make this test depend on the one bit the distribution may drop.
chmod -x "$iso/greenroom/scripts/greenroom.py"
( cd "$iso/greenroom" && python3 ./scripts/greenroom.py new isoproj --init-public --parent "$T/isoparent" ) >/dev/null \
  || fail "the standalone skill payload cannot scaffold a project with no exec bit"
[ -d "$T/isoparent/isoproj/isoproj-public/.git" ] || fail "isolated payload did not init the public repo"
[ -d "$T/isoparent/isoproj/isoproj-private/docs" ] || fail "isolated payload did not create the private buckets"
[ -f "$T/isoparent/isoproj/isoproj-private/AGENTS.md" ] || fail "isolated payload could not render its templates"
[ -f "$T/isoparent/isoproj/.greenroom" ] || fail "isolated payload did not write the .greenroom marker"
# SKILL.md routes to `sync` and `collect` too, and to references/*.md. A typo in a
# router link is a dead pointer -- the same "documented but not shipped" bug class. ---
for ref in $(grep -o 'references/[A-Za-z0-9_-]*\.md' "$iso/greenroom/SKILL.md" | sort -u); do
  [ -f "$iso/greenroom/$ref" ] || fail "SKILL.md routes to $ref, which is not in the payload"
done
( cd "$iso/greenroom" && python3 ./scripts/greenroom.py collect --help ) >/dev/null \
  || fail "the isolated payload cannot run the collect subcommand"
( cd "$T/isoparent/isoproj/isoproj-public" && python3 "$iso/greenroom/scripts/greenroom.py" sync ) >/dev/null \
  || fail "the isolated payload cannot sync the wrapper it just scaffolded"
[ -f "$T/isoparent/isoproj/README.md" ] || fail "isolated-payload sync did not write the wrapper repo map"
ok "skills/greenroom/ is self-sufficient: it scaffolds, syncs, and ships every reference it routes to"

# --- 30. context budget. A loaded skill stays resident across turns, and the
#         description sits in the skill listing every session. Both regrow silently
#         unless asserted. ---
# The ceilings carry real headroom on purpose: this guards against silent
# REGROWTH, not against a one-sentence clarification. When one does trip, move
# detail into references/ rather than raising the number.
desc_len="$(sed -n 's/^description: //p' "$SKILL_MD" | head -1 | tr -d '\n' | wc -c | tr -d ' ')"
[ "$desc_len" -le 450 ] || fail "description is $desc_len chars (budget: 450) -- trim it"
skill_words="$(wc -w < "$SKILL_MD" | tr -d ' ')"
[ "$skill_words" -le 1500 ] \
  || fail "SKILL.md is $skill_words words (budget: 1500) -- move detail into references/"
ok "context budget holds (description ${desc_len}c, SKILL.md ${skill_words}w)"

# --- 31. no UNCONDITIONAL reliance on plugin-only variables. ${CLAUDE_PLUGIN_ROOT}
#         is defined only by the Claude Code plugin runtime; it is unset under
#         `npx skills add` and under every other harness. The path resolver may
#         probe it, but only with a `:-` default so an unset value degrades to a
#         miss instead of an empty-prefix path. ---
# Matches a PATH BUILT from the variable -- `${CLAUDE_PLUGIN_ROOT}` or a bare
# `$CLAUDE_PLUGIN_ROOT/` -- while leaving prose that merely names it alone. The
# `:-` form is excluded by the `[^:]` after the name.
bare_ref="$(grep -rnE '\$\{CLAUDE_PLUGIN_ROOT[^:]|\$CLAUDE_PLUGIN_ROOT/' "$REPO_ROOT/skills/" || true)"
[ -z "$bare_ref" ] \
  || fail "skills/ builds a path from \${CLAUDE_PLUGIN_ROOT} with no :- default (undefined on a standalone install): $bare_ref"
ok "skill content relies on no plugin-only path variable"

# --- 32. commands stay hollow. They are Claude-Code-only sugar; `npx skills` never
#         reads commands/. Any logic here is logic a skills.sh user cannot reach. ---
skill_name="$(sed -n 's/^name:[[:space:]]*//p' "$SKILL_MD" | head -1 | tr -d '[:space:]')"
for cmd in "$REPO_ROOT"/commands/*.md; do
  lines="$(wc -l < "$cmd" | tr -d ' ')"
  [ "$lines" -le 15 ] || fail "$(basename "$cmd") is $lines lines (hollow-command budget: 15)"
  ! grep -q '```' "$cmd" || fail "$(basename "$cmd") contains a code block (logic belongs in the skill)"
  # Now that the commands are hollow, the skill's NAME is the only thing linking a
  # slash command to any behaviour. This release renamed the skill twice; a third
  # rename would leave /new, /add and /sync invoking nothing, and every other
  # assertion here would still pass. The failure would surface only at use time.
  grep -q "\`$skill_name\` skill" "$cmd" \
    || fail "$(basename "$cmd") does not invoke the \`$skill_name\` skill by name (renamed without updating it?)"
done
ok "slash commands are hollow triggers that name the skill they invoke"

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
# The legacy shim pointed at the REPO ROOT's scripts/ and templates/, which moved
# into skills/greenroom/ -- so in a real upgrade these links are dangling. Use the
# real legacy targets, or the test passes on a layout that never shipped.
ln -s "$REPO_ROOT/scripts" "$sh_mig/.claude/skills/greenroom/scripts"
ln -s "$REPO_ROOT/templates" "$sh_mig/.claude/skills/greenroom/templates"
[ ! -e "$sh_mig/.claude/skills/greenroom/scripts" ] || fail "test bug: the legacy shim fixture is not dangling"
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
# An install that installed no skill is a failed install, not a quiet no-op.
[ "$rc" -ne 0 ] || fail "install.sh reported success after installing no skill: $out4"
echo "$out4" | grep -q "installed 0 of 1 skill" || fail "install.sh did not say it installed nothing: $out4"
echo "$out4" | grep -q "re-run install.sh" || fail "install.sh skipped without telling the user how to recover: $out4"
[ ! -e "$ug/somewhere-else/SKILL.md" ] || fail "install.sh wrote THROUGH the unrelated symlink into the user's dir"
# The commands are hollow -- they only invoke the skill. Registering /new, /add,
# /sync against a skill that did not install just moves the failure to use time.
[ ! -e "$ug/.claude/commands/new.md" ] \
  || fail "install.sh registered the hollow commands while the skill they invoke was skipped"
echo "$out4" | grep -q "not linking the commands" || fail "install.sh skipped the commands silently: $out4"
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
out3="$(HOME="$ch" bash "$REPO_ROOT/install.sh" 2>&1)" && rc3=0 || rc3=$?
echo "$out3" | grep -q "SKIP skill greenroom" || fail "install.sh did not SKIP a pre-existing real greenroom file"
[ "$rc3" -ne 0 ] || fail "install.sh reported success after skipping the only skill: $out3"
echo "$out3" | grep -q "move or remove" || fail "install.sh skipped without telling the user how to recover: $out3"
[ "$(cat "$ch/.claude/skills/greenroom")" = "do not touch" ] || fail "install.sh clobbered a real user file"
ok "install.sh skips (never clobbers) a real user file at the skill target"

# --- 39. the shim migration removes only the two links we created. A user file
#          dropped into the old shim dir must survive, and the migration must say
#          so rather than `rm -rf`-ing the whole directory. ---
kh="$T/keephome"
mkdir -p "$kh/.claude/skills/greenroom"
ln -s "$REPO_ROOT/skills/greenroom/scripts" "$kh/.claude/skills/greenroom/scripts"
echo "mine" > "$kh/.claude/skills/greenroom/notes.md"
out5="$(HOME="$kh" bash "$REPO_ROOT/install.sh" 2>&1)" && rc5=0 || rc5=$?
[ -f "$kh/.claude/skills/greenroom/notes.md" ] || fail "shim migration destroyed a user file it did not create"
# Decide before mutating: a SKIP that says "leaving it untouched" must be true.
# Tearing out the links first and only then finding rmdir fails leaves the user
# with a broken script fallback AND no skill linked over the surviving directory.
[ -L "$kh/.claude/skills/greenroom/scripts" ] \
  || fail "shim migration removed our links, then aborted claiming it touched nothing"
echo "$out5" | grep -q "SKIP migration" || fail "shim migration removed nothing but stayed silent: $out5"
# The surviving directory then blocks the skill link, so this run installs nothing.
[ "$rc5" -ne 0 ] || fail "install.sh reported success after the surviving shim dir blocked the skill: $out5"
echo "$out5" | grep -q "re-run install.sh" || fail "the blocked migration did not tell the user how to recover: $out5"
ok "the shim migration removes only our links and reports what it left behind"

# --- 40. the shim is ours even when its links merely DANGLE. Delete the old clone,
#          re-clone elsewhere, re-run: points_at_repo can prove nothing, so the
#          migration called the user's own shim foreign, link_one then refused the
#          real directory, and the install exited 1 having done nothing. ---
dsm="$T/dangleshimhome"
mkdir -p "$dsm/.claude/skills/greenroom"
ln -s "$T/deleted-clone/scripts" "$dsm/.claude/skills/greenroom/scripts"
ln -s "$T/deleted-clone/templates" "$dsm/.claude/skills/greenroom/templates"
out9="$(HOME="$dsm" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a shim from a deleted clone: $out9"
[ -L "$dsm/.claude/skills/greenroom" ] || fail "the dangling shim was not replaced by the skill symlink"
[ -f "$dsm/.claude/skills/greenroom/SKILL.md" ] || fail "post-migration greenroom link has no SKILL.md"
echo "$out9" | grep -q "do not recognize" && fail "install.sh called our own dangling shim foreign: $out9"
# Claimed by inference, not proof -- so say what was dropped.
echo "$out9" | grep -q "dead links removed" || fail "install.sh removed dead links without naming them: $out9"
ok "a shim whose clone was deleted is still recognized and migrated"

# --- 41. ...and a shim whose links point into ANOTHER LIVE checkout. Upgrading by
#          cloning greenroom somewhere new while the old clone stays on disk left
#          this one path still hard-failing: unrecognized shim, then SKIP on the
#          real directory, then exit 1, blaming the user for our own layout. ---
osm="$T/othershimhome"
osc="$T/othershimclone"
mkdir -p "$osc/scripts" "$osc/.claude-plugin" "$osm/.claude/skills/greenroom"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$osc/.claude-plugin/plugin.json"
ln -s "$osc/scripts" "$osm/.claude/skills/greenroom/scripts"          # into the OTHER clone
out16="$(HOME="$osm" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a shim into another clone: $out16"
[ -L "$osm/.claude/skills/greenroom" ] || fail "a shim into another live checkout was not migrated"
[ -f "$osm/.claude/skills/greenroom/SKILL.md" ] || fail "post-migration greenroom link has no SKILL.md"
[ -d "$osc/scripts" ] || fail "migration deleted the other checkout's files, not just the link"
echo "$out16" | grep -q "do not recognize" && fail "install.sh called a shim into another checkout foreign: $out16"
ok "a shim pointing into another live checkout is migrated, not called foreign"

# --- 42. a dangling shim entry is claimed by INFERENCE, not proof, so the inference
#          must be narrow and the removal visible. Ours pointed at <clone>/scripts,
#          so the target's basename matches the entry name; a user's own link to an
#          unmounted volume does not, and must survive. ---
fsh="$T/foreignshimhome"
mkdir -p "$fsh/.claude/skills/greenroom"
ln -s "/Volumes/ext-that-is-not-mounted/my-scripts" "$fsh/.claude/skills/greenroom/scripts"
out18="$(HOME="$fsh" bash "$REPO_ROOT/install.sh" 2>&1)" && rc18=0 || rc18=$?
[ -L "$fsh/.claude/skills/greenroom/scripts" ] \
  || fail "install.sh deleted a user's dangling link just because it was named scripts"
[ "$rc18" -ne 0 ] || fail "install.sh reported success while blocked by a foreign shim: $out18"
echo "$out18" | grep -q "do not recognize" || fail "install.sh did not report the unrecognized shim: $out18"
echo "$out18" | grep -q "re-run install.sh" || fail "the unrecognized-shim SKIP gave no way to recover: $out18"
ok "a foreign dangling link at the shim path survives, with a recoverable SKIP"

# --- 43. ...and the same when the user's link is named the OBVIOUS thing. A basename
#          match alone cannot tell `-> /Volumes/ext/scripts` from ours. The old
#          installer always made BOTH links into one clone; that pair is the
#          signature, and a lone dangling entry is not it, however it is named. ---
lsh2="$T/lonescriptshome"
mkdir -p "$lsh2/.claude/skills/greenroom"
ln -s "/Volumes/ext-that-is-not-mounted/scripts" "$lsh2/.claude/skills/greenroom/scripts"
out22="$(HOME="$lsh2" bash "$REPO_ROOT/install.sh" 2>&1)" && rc22=0 || rc22=$?
[ -L "$lsh2/.claude/skills/greenroom/scripts" ] \
  || fail "install.sh deleted a user's dangling link that merely shared our naming"
[ "$rc22" -ne 0 ] || fail "install.sh reported success while blocked: $out22"
ok "an unpaired dangling link is not claimed, even named exactly like ours"

# --- 44. ...and the pair check must survive a SPACE in the clone path. Splitting
#          the parents on whitespace turns one shared parent into several, refuses
#          the pair, and the run exits 1 having done nothing -- for no reason but
#          where the user keeps their code. ---
sph="$T/spacedpathhome"
sp_ck="$T/My Projects/greenroom"
mkdir -p "$sp_ck" "$sph/.claude/skills/greenroom"
ln -s "$sp_ck/scripts" "$sph/.claude/skills/greenroom/scripts"       # both dangling,
ln -s "$sp_ck/templates" "$sph/.claude/skills/greenroom/templates"   # one shared parent
rmdir "$sp_ck" && rmdir "$T/My Projects"                             # the clone is gone
out25="$(HOME="$sph" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a clone path with a space: $out25"
[ -L "$sph/.claude/skills/greenroom" ] || fail "a spaced-path shim was not migrated"
[ -f "$sph/.claude/skills/greenroom/SKILL.md" ] || fail "post-migration greenroom link has no SKILL.md"
ok "the dangling-pair check survives a space in the old clone's path"

# --- 45. ...and survives the two links being SPELLED differently. One absolute, one
#          relative, same directory: comparing raw readlink output calls that two
#          parents, refuses the pair, and aborts an install over a shim that is ours.
sph2="$T/spelledpathhome"
mkdir -p "$sph2/.claude/skills/greenroom"
ln -s "$T/gone-clone/scripts" "$sph2/.claude/skills/greenroom/scripts"          # absolute
( cd "$sph2/.claude/skills/greenroom" && ln -s "../../../../gone-clone/templates" templates )  # relative
out27="$(HOME="$sph2" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on differently-spelled targets: $out27"
[ -L "$sph2/.claude/skills/greenroom" ] || fail "a shim with mixed absolute/relative targets was not migrated"
ok "the dangling-pair check normalizes absolute and relative spellings of one target"

# --- 46. one link PROVEN ours and its sibling merely dangling is still ours. That is
#          a plain in-place upgrade: git cannot remove an old scripts/ that still
#          holds an untracked file, so one link stays live while the other dies.
#          Requiring a dangling PAIR called that "files we did not create". ---
hdh="$T/halfdanglinghome"
mkdir -p "$hdh/.claude/skills/greenroom"
ln -s "$REPO_ROOT/skills/greenroom/scripts" "$hdh/.claude/skills/greenroom/scripts"   # live, ours
# The dead sibling must point at a VANISHED parent -- a target merely missing under
# an existing $REPO_DIR still resolves, so points_at_repo proves it and the
# dangling branch is never reached.
ln -s "$T/vanished-clone/templates" "$hdh/.claude/skills/greenroom/templates"
[ ! -e "$hdh/.claude/skills/greenroom/templates" ] || fail "test bug: the sibling fixture is not dangling"
out31="$(HOME="$hdh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a half-dangling shim: $out31"
[ -L "$hdh/.claude/skills/greenroom" ] || fail "a half-dangling shim was not migrated"
[ -f "$hdh/.claude/skills/greenroom/SKILL.md" ] || fail "post-migration greenroom link has no SKILL.md"
echo "$out31" | grep -q "we did not create" && fail "install.sh called our own half-dangling shim foreign: $out31"
ok "a shim with one live and one dead link is still recognized as ours"

# --- 47. a CRLF checkout must not read as "no frontmatter". Three ownership
#          decisions rest on the declared name, and rejecting it here makes the run
#          tell the user to remove a working copy of greenroom. ---
crh="$T/crlfhome"
mkdir -p "$crh/.claude/skills/greenroom/scripts" "$crh/.claude/skills/greenroom/templates"
printf -- '---\r\nname: greenroom\r\ndescription: a CRLF checkout\r\n---\r\n' \
  > "$crh/.claude/skills/greenroom/SKILL.md"
: > "$crh/.claude/skills/greenroom/scripts/greenroom.py"
out32="$(HOME="$crh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a CRLF SKILL.md: $out32"
echo "$out32" | grep -q "already a standalone install" \
  || fail "a CRLF checkout was not recognized as a standalone install: $out32"
ok "the declared name is read correctly from a CRLF checkout"

# --- 48. a QUOTED name is valid YAML and the frontmatter parse above accepts it, so
#          returning it with its quotes would fail every ownership compare -- and
#          each one fails toward telling the user to remove a working install. ---
qnh="$T/quotednamehome"
mkdir -p "$qnh/.claude/skills/greenroom/scripts" "$qnh/.claude/skills/greenroom/templates"
printf -- '---\nname: "greenroom"\ndescription: a quoted plain scalar\n---\n' \
  > "$qnh/.claude/skills/greenroom/SKILL.md"
: > "$qnh/.claude/skills/greenroom/scripts/greenroom.py"
out34="$(HOME="$qnh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a quoted name: $out34"
echo "$out34" | grep -q "already a standalone install" \
  || fail "a double-quoted name was not recognized as the declared name: $out34"
# ...and the single-quoted spelling, read straight from the helper
sed -n '/^skill_name_of() {/,/^}/p' "$REPO_ROOT/install.sh" > "$T/skill_name_of.sh"
printf -- "---\nname: 'setup'\n---\n" > "$T/singlequoted.md"
got_name="$( . "$T/skill_name_of.sh"; skill_name_of "$T/singlequoted.md" )"
[ "$got_name" = "setup" ] || fail "skill_name_of returned '$got_name' for a single-quoted name"
ok "the declared name is read through both quoting styles"

# --- 49. resolve_link must not emit a doubled slash for a target directly under /.
#          points_at_repo compares that string against $REPO_DIR, so `//usr` matches
#          nothing and a link that is genuinely ours reads as foreign. Nothing else
#          exercises a root-level target, so the ${dir%/} could be dropped unseen. ---
helper="$T/resolve_link.sh"
sed -n '/^resolve_link() {/,/^}/p' "$REPO_ROOT/install.sh" > "$helper"
[ -s "$helper" ] || fail "could not extract resolve_link from install.sh"
rl_out="$( . "$helper"; ln -sf /usr "$T/rootlink"; resolve_link "$T/rootlink" )" \
  || fail "resolve_link failed on a target directly under /"
[ "$rl_out" = "/usr" ] || fail "resolve_link returned '$rl_out' for a root-level target (expected /usr)"
case "$rl_out" in *//*) fail "resolve_link emitted a doubled slash: $rl_out" ;; esac
rm -f "$T/rootlink"
ok "resolve_link normalizes a target sitting directly under /"

# --- 50. a real scripts/ DIRECTORY at the shim path is not a link we made. Nothing
#          covered this branch, and it printed a bare SKIP followed by exit 1. ---
rdh="$T/realdirshimhome"
mkdir -p "$rdh/.claude/skills/greenroom/scripts"
: > "$rdh/.claude/skills/greenroom/scripts/mine.sh"
out19="$(HOME="$rdh" bash "$REPO_ROOT/install.sh" 2>&1)" && rc19=0 || rc19=$?
[ -f "$rdh/.claude/skills/greenroom/scripts/mine.sh" ] || fail "install.sh destroyed a real user directory"
[ "$rc19" -ne 0 ] || fail "install.sh reported success while blocked by a real directory: $out19"
echo "$out19" | grep -q "do not recognize" || fail "install.sh did not report the unrecognized directory: $out19"
echo "$out19" | grep -q "move what you want to keep" || fail "the unrecognized-dir SKIP gave no remedy: $out19"
ok "a real directory at the shim path is left alone with a recoverable SKIP"

# --- 51. a 0.1.8 user has BOTH artifacts: the shim dir and the greenroom-setup
#          link. When the shim path is blocked the new skill cannot link, so
#          removing the old name first left them with no greenroom skill at all --
#          strictly worse than before the run, and the opposite of every "leaving
#          it untouched" promise. Migration 2 must wait for the link to succeed. ---
bth="$T/bothartifactshome"
bth_ck="$T/bothartifactsclone"
mkdir -p "$bth_ck/skills/greenroom-setup" "$bth_ck/.claude-plugin" \
         "$bth/.claude/skills/greenroom"
printf -- '---\nname: greenroom-setup\ndescription: the retired name\n---\n' \
  > "$bth_ck/skills/greenroom-setup/SKILL.md"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$bth_ck/.claude-plugin/plugin.json"
ln -s "$bth_ck/skills/greenroom-setup" "$bth/.claude/skills/greenroom-setup"   # working /greenroom-setup
echo "mine" > "$bth/.claude/skills/greenroom/notes.md"                          # blocks the shim path
ln -s "$REPO_ROOT/scripts" "$bth/.claude/skills/greenroom/scripts"
out20="$(HOME="$bth" bash "$REPO_ROOT/install.sh" 2>&1)" && rc20=0 || rc20=$?
[ "$rc20" -ne 0 ] || fail "install.sh reported success while the shim path blocked the skill: $out20"
[ -L "$bth/.claude/skills/greenroom-setup" ] \
  || fail "install.sh removed the working greenroom-setup link while failing to install its replacement"
echo "$out20" | grep -q "leaving .* registered" \
  || fail "install.sh left the old name registered without explaining why: $out20"
ok "the retired skill name survives a run that could not install its replacement"

# --- 52. OS noise must not fail the install. A Finder-created .DS_Store in the old
#          shim is invisible to `ls`, and classifying it as "a file we did not
#          create" blocks the migration, then the skill link, then the whole run. ---
dsm2="$T/dsstorehome"
mkdir -p "$dsm2/.claude/skills/greenroom"
ln -s "$REPO_ROOT/scripts" "$dsm2/.claude/skills/greenroom/scripts"
: > "$dsm2/.claude/skills/greenroom/.DS_Store"
out10="$(HOME="$dsm2" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed over a .DS_Store in the shim: $out10"
[ -L "$dsm2/.claude/skills/greenroom" ] || fail "a .DS_Store blocked the shim migration"
ok "OS noise in the old shim does not block the migration"

# --- 53. an EMPTY ~/.claude/skills/greenroom (a partially cleaned or interrupted
#          prior install) is unambiguously safe to rmdir, and leaving it blocked
#          the skill link and failed the run. ---
emh="$T/emptydirhome"
mkdir -p "$emh/.claude/skills/greenroom"
out11="$(HOME="$emh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on an empty greenroom dir: $out11"
[ -L "$emh/.claude/skills/greenroom" ] || fail "an empty greenroom dir was not removed and relinked"
ok "an empty greenroom directory is removed rather than treated as foreign"

# --- 54. a shim holding ONLY OS noise -- the links already cleaned up, a .DS_Store
#          left behind -- is the empty case wearing a hat. Classifying it as
#          unrecognized failed the run over a file the user cannot see. ---
noh="$T/noiseonlyhome"
mkdir -p "$noh/.claude/skills/greenroom"
: > "$noh/.claude/skills/greenroom/.DS_Store"
out12="$(HOME="$noh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a noise-only dir: $out12"
[ -L "$noh/.claude/skills/greenroom" ] || fail "a noise-only greenroom dir was not removed and relinked"
ok "a greenroom directory holding only OS noise is removed, like an empty one"

# --- 55. a COPIED greenroom-setup payload (from `npx skills add ...@greenroom-setup`)
#          is not a link we made, so it is not ours to delete -- but left silent the
#          retired name resolves forever, which is what migration 2 exists to stop. ---
cph="$T/copiedsetuphome"
mkdir -p "$cph/.claude/skills/greenroom-setup"
printf -- '---\nname: greenroom-setup\ndescription: a copied install of the retired skill\n---\n' \
  > "$cph/.claude/skills/greenroom-setup/SKILL.md"
out13="$(HOME="$cph" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a copied greenroom-setup: $out13"
[ -f "$cph/.claude/skills/greenroom-setup/SKILL.md" ] || fail "install.sh deleted a copied payload it did not create"
echo "$out13" | grep -q "retired greenroom-setup skill" \
  || fail "install.sh left a copied greenroom-setup registered without a word: $out13"
ok "a copied greenroom-setup install is reported, not silently left or deleted"

# --- 56. a greenroom-setup link REPOINTED by hand at the renamed skills/greenroom
#          matched no branch -- not ours by path, not a legacy name, not dangling,
#          not a copied dir -- so the retired /greenroom-setup kept resolving. Whose
#          checkout the target belongs to is the test, not what it declares. ---
rph="$T/repointedsetuphome"
rp_ck="$T/repointedsetupclone"
mkdir -p "$rp_ck/skills" "$rp_ck/.claude-plugin" "$rph/.claude/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$rp_ck/skills/greenroom"      # declares name: greenroom
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$rp_ck/.claude-plugin/plugin.json"
ln -s "$rp_ck/skills/greenroom" "$rph/.claude/skills/greenroom-setup"
HOME="$rph" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored on a repointed setup link"
[ ! -L "$rph/.claude/skills/greenroom-setup" ] \
  || fail "a greenroom-setup link repointed at skills/greenroom survived, keeping the retired name registered"
[ -f "$rp_ck/skills/greenroom/SKILL.md" ] || fail "migration deleted the other checkout, not just the link"
ok "a greenroom-setup link repointed at the renamed skill is migrated away too"

# --- 57. the ORIGINAL collision: pre-0.1.8 the skill was named `setup`, so
#          `npx skills add` copied it to ~/.claude/skills/setup/, which resolves as
#          /setup forever. Report-only -- and `setup` is the generic name the whole
#          rename was about, so ownership must be proven, not assumed. ---
lgh="$T/legacycopyhome"
mkdir -p "$lgh/.claude/skills/setup/scripts" "$lgh/.claude/skills/setup/templates" \
         "$lgh/.claude/skills/notes/scripts" "$lgh/.claude/skills/notes/templates"
printf -- '---\nname: setup\ndescription: Set up the greenroom layout, a public repo beside a private one.\n---\n' \
  > "$lgh/.claude/skills/setup/SKILL.md"
: > "$lgh/.claude/skills/setup/scripts/greenroom.py"                 # the payload signature
# A stranger's `setup` skill that merely MENTIONS greenroom, with the same complete
# payload shape but no greenroom.py. A text match would tell them to rm -rf it.
printf -- '---\nname: setup\ndescription: my own setup skill; pairs well with greenroom.\n---\n' \
  > "$lgh/.claude/skills/notes/SKILL.md"
: > "$lgh/.claude/skills/notes/scripts/something-else.py"
out21="$(HOME="$lgh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a legacy setup copy: $out21"
[ -f "$lgh/.claude/skills/setup/SKILL.md" ] || fail "install.sh deleted a copied payload it did not create"
echo "$out21" | grep -q "original name" || fail "install.sh left /setup resolving to greenroom in silence: $out21"
# ...and an unrelated skill at a generic name is not accused of being ours
echo "$out21" | grep -q "$lgh/.claude/skills/notes" && fail "install.sh claimed an unrelated skill: $out21"
# The stranger's own `setup` skill mentions greenroom but carries no greenroom.py.
# A text match would tell them to rm -rf it; only the payload signature must count.
mnh="$T/mentiononlyhome"
mkdir -p "$mnh/.claude/skills/setup/scripts" "$mnh/.claude/skills/setup/templates"
printf -- '---\nname: setup\ndescription: my own setup skill; pairs well with greenroom.\n---\n' \
  > "$mnh/.claude/skills/setup/SKILL.md"
: > "$mnh/.claude/skills/setup/scripts/my-own.py"
out33="$(HOME="$mnh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a stranger's setup skill: $out33"
echo "$out33" | grep -q "$mnh/.claude/skills/setup" \
  && fail "install.sh told a stranger to rm -rf their own setup skill for mentioning greenroom: $out33"
ok "a pre-rename copied /setup is reported; a skill that merely mentions us is not"

# --- 58. the ancient ROOT symlink is ours whether it points at this clone or
#          another. A repo root holds no SKILL.md, so looks_like_ours cannot see
#          it -- without the plugin-manifest tell, a user on the oldest layout who
#          re-cloned elsewhere hit "symlink into somewhere else" and exit 1. ---
orc="$T/oldrootclone"
mkdir -p "$orc/skills" "$orc/.claude-plugin"
cp -R "$REPO_ROOT/skills/greenroom" "$orc/skills/greenroom"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$orc/.claude-plugin/plugin.json"
orh="$T/oldroothome"
mkdir -p "$orh/.claude/skills"
ln -s "$orc" "$orh/.claude/skills/greenroom"                 # root symlink into the OTHER clone
out14="$(HOME="$orh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed on a foreign root symlink: $out14"
[ -f "$orh/.claude/skills/greenroom/SKILL.md" ] || fail "a foreign root symlink was not migrated to the skill link"
[ ! -e "$orh/.claude/skills/greenroom/.claude-plugin/plugin.json" ] \
  || fail "the migrated link still exposes a plugin manifest"
[ -f "$orc/.claude-plugin/plugin.json" ] || fail "migration deleted the other checkout, not just the link"
ok "an old root symlink into another checkout is migrated too"

# --- 59. migration 2 also drops a DANGLING greenroom-setup link. The old clone was
#          deleted, so ownership cannot be proven -- but leaving it keeps the retired
#          skill name registered forever, and link_one already applies exactly this
#          reasoning at the skill path. The two paths must not disagree. ---
dsh="$T/danglesetuphome"
mkdir -p "$dsh/.claude/skills"
ln -s "$T/deleted-clone/skills/greenroom" "$dsh/.claude/skills/greenroom-setup"
HOME="$dsh" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored on a dangling greenroom-setup link"
[ ! -e "$dsh/.claude/skills/greenroom-setup" ] && [ ! -L "$dsh/.claude/skills/greenroom-setup" ] \
  || fail "a dangling greenroom-setup link survived migration, keeping the retired name registered"
ok "a dangling greenroom-setup link is migrated away like any other stale link"

# --- 60. migration 2 also drops a greenroom-setup link into a DIFFERENT checkout
#          that still exists. Keyed to $REPO_DIR alone it was neither ours nor
#          dangling, so after a re-clone the retired skill name stayed registered
#          forever -- the exact failure this migration exists to prevent. ---
osh="$T/oldsetuphome"
old_ck="$T/oldsetupclone"
mkdir -p "$old_ck/skills/greenroom-setup" "$old_ck/.claude-plugin" "$osh/.claude/skills"
printf -- '---\nname: greenroom-setup\ndescription: the retired name\n---\n' \
  > "$old_ck/skills/greenroom-setup/SKILL.md"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$old_ck/.claude-plugin/plugin.json"   # a real checkout has one
ln -s "$old_ck/skills/greenroom-setup" "$osh/.claude/skills/greenroom-setup"
HOME="$osh" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored on a foreign greenroom-setup link"
[ ! -L "$osh/.claude/skills/greenroom-setup" ] \
  || fail "a greenroom-setup link into another checkout survived, keeping the retired name registered"
[ -f "$old_ck/skills/greenroom-setup/SKILL.md" ] || fail "migration deleted the other checkout's files, not just the link"
ok "a greenroom-setup link into another live checkout is migrated away too"

# --- 61. ...including the 0.1.4-0.1.7 shape, where ~/.claude/skills/greenroom-setup
#          pointed at <checkout>/skills/SETUP, declaring `name: setup`. Matching the
#          target's name against the LINK's basename misses it, so the retired name
#          survived a re-clone in silence. ---
lsh="$T/legacysetuphome"
leg_ck="$T/legacysetupclone"
mkdir -p "$leg_ck/skills/setup" "$leg_ck/.claude-plugin" "$lsh/.claude/skills"
printf -- '---\nname: setup\ndescription: the pre-rename skill name\n---\n' \
  > "$leg_ck/skills/setup/SKILL.md"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$leg_ck/.claude-plugin/plugin.json"
ln -s "$leg_ck/skills/setup" "$lsh/.claude/skills/greenroom-setup"
HOME="$lsh" bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || fail "install.sh errored on a legacy setup link"
[ ! -L "$lsh/.claude/skills/greenroom-setup" ] \
  || fail "a greenroom-setup link at the old skills/setup target survived, keeping the retired name registered"
[ -f "$leg_ck/skills/setup/SKILL.md" ] || fail "migration deleted the other checkout's files, not just the link"
ok "the pre-rename skills/setup link shape is migrated away too"

# --- 62. a checkout with NO skills at all is a partial or corrupt clone, not a
#          successful install of nothing. "0 of 0" satisfied `linked -lt found`, so
#          it printed Done., linked the hollow commands, and exited 0. ---
noskills="$T/noskillsclone"
mkdir -p "$noskills/skills" "$noskills/commands"
cp "$REPO_ROOT/install.sh" "$noskills/install.sh"
cp "$REPO_ROOT"/commands/*.md "$noskills/commands/"
nsh="$T/noskillshome"
mkdir -p "$nsh/.claude"
out15="$(HOME="$nsh" bash "$noskills/install.sh" 2>&1)" && rc15=0 || rc15=$?
[ "$rc15" -ne 0 ] || fail "install.sh reported success from a checkout with no skills: $out15"
[ ! -e "$nsh/.claude/commands/new.md" ] \
  || fail "install.sh registered the hollow commands with no skill to invoke"
echo "$out15" | grep -q "found no skills" || fail "install.sh did not name the cause: $out15"
ok "a checkout with no skills fails loudly instead of installing nothing cheerfully"

# --- 63. a COPIED greenroom at the skill path is a standalone install (`npx skills
#          add -g`), not an obstacle. It is a real directory, so link_one SKIPped it
#          and the run exited 1 -- telling a user who installed the README's headline
#          way to remove a perfectly good install of greenroom. ---
cgh="$T/copiedgreenroomhome"
mkdir -p "$cgh/.claude/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$cgh/.claude/skills/greenroom"
out17="$(HOME="$cgh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed over a standalone install: $out17"
[ ! -L "$cgh/.claude/skills/greenroom" ] || fail "install.sh replaced a standalone install with its own symlink"
[ -f "$cgh/.claude/skills/greenroom/SKILL.md" ] || fail "install.sh damaged the standalone install"
echo "$out17" | grep -q "already a standalone install" || fail "install.sh did not name what it found: $out17"
echo "$out17" | grep -q "already installed" \
  || fail "the summary reported 'Done. 0 skill(s)' over a working standalone install: $out17"
[ -e "$cgh/.claude/commands/new.md" ] || fail "the commands were withheld even though the skill is present"
ok "a standalone install at the skill path is reported and left alone, not a failure"

# --- 64. ...but a STALE copy is not a working install. A pre-0.2 payload has the
#          right name and no scripts/, so accepting it on the name alone reports
#          success while the hollow commands point at a skill whose script is not
#          there. It must fall through to the SKIP that prints the remedy. ---
sch="$T/stalecopyhome"
mkdir -p "$sch/.claude/skills/greenroom"
cp "$REPO_ROOT/skills/greenroom/SKILL.md" "$sch/.claude/skills/greenroom/SKILL.md"   # no scripts/
out23="$(HOME="$sch" bash "$REPO_ROOT/install.sh" 2>&1)" && rc23=0 || rc23=$?
[ "$rc23" -ne 0 ] || fail "install.sh accepted a payload with no scripts/ as a working install: $out23"
echo "$out23" | grep -q "already a standalone install" \
  && fail "install.sh called a scripts-less copy a standalone install: $out23"
echo "$out23" | grep -q "move or remove" || fail "install.sh gave no remedy for the stale copy: $out23"
ok "a stale copy with no scripts/ is not mistaken for a working standalone install"

# --- 65. the declared name is read from the FRONTMATTER, not from anywhere a
#          `name:` line happens to appear. Three ownership decisions rest on it, and
#          a body line (a YAML example, a table row) claiming `name: greenroom`
#          would make install.sh report someone else's skill as ours and exit 0. ---
imh="$T/impostorhome"
# A COMPLETE payload shape (scripts/ and templates/), so the frontmatter scoping is
# the only thing standing between the impostor and an "already installed" verdict.
mkdir -p "$imh/.claude/skills/greenroom/scripts" "$imh/.claude/skills/greenroom/templates"
# No frontmatter at all -- just prose that happens to contain a `name:` line. A
# whole-file scan reads that as the declared name; only a frontmatter-scoped read
# fails closed, which is the safe answer for a file that declares nothing.
printf -- '# Somebody else notes\n\nExample of a skill header:\n\nname: greenroom\n' \
  > "$imh/.claude/skills/greenroom/SKILL.md"
: > "$imh/.claude/skills/greenroom/scripts/greenroom.py"
out26="$(HOME="$imh" bash "$REPO_ROOT/install.sh" 2>&1)" && rc26=0 || rc26=$?
echo "$out26" | grep -q "already a standalone install" \
  && fail "a body 'name: greenroom' line was mistaken for the declared name: $out26"
[ "$rc26" -ne 0 ] || fail "install.sh reported success over somebody else's skill: $out26"
ok "the declared name comes from the frontmatter, not from a line in the body"

# --- 66. after a moved clone the COMMAND links dangle with no provable owner, so
#          each is skipped -- correctly, they are generic names. But only skills are
#          counted, so the run printed a green summary while /new, /add and /sync
#          stayed broken. The summary must say so. ---
csh="$T/cmdskiphome"
mkdir -p "$csh/.claude/skills" "$csh/.claude/commands"
ln -s "$T/moved-clone/commands/new.md" "$csh/.claude/commands/new.md"
out24="$(HOME="$csh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a dangling command link: $out24"
echo "$out24" | grep -q "skipped -- see the SKIPs above" \
  || fail "the summary buried a skipped command behind a green Done. line: $out24"
[ -L "$csh/.claude/skills/greenroom" ] || fail "the skill itself was not installed"
ok "skipped command links are named in the summary, not just in the SKIP lines"

# --- 67. withholding NEW command links when the skill did not install is only half
#          the invariant: a previous successful run may have left ours registered,
#          and if its clone is gone they are broken. Same use-time failure, arrived
#          by another route -- so say so rather than only declining to add more. ---
swh="$T/stalecmdhome"
mkdir -p "$swh/.claude/skills/greenroom" "$swh/.claude/commands"
echo "mine" > "$swh/.claude/skills/greenroom/notes.md"            # blocks the skill link
ln -s "$T/deleted-clone/commands/new.md" "$swh/.claude/commands/new.md"   # from an older run
out28="$(HOME="$swh" bash "$REPO_ROOT/install.sh" 2>&1)" && rc28=0 || rc28=$?
[ "$rc28" -ne 0 ] || fail "install.sh reported success while the skill path was blocked: $out28"
echo "$out28" | grep -q "not linking the commands" || fail "install.sh linked commands with no skill: $out28"
echo "$out28" | grep -q "registered but broken" \
  || fail "install.sh left a broken /new registered without a word: $out28"
# The remedy must be the true one. A later successful run does NOT repair this --
# the command loop does not claim dangling links -- so "until this run succeeds"
# would send the user back for a second disappointment.
echo "$out28" | grep -q "rm $swh/.claude/commands/new.md && re-run" \
  || fail "install.sh gave a remedy that a successful re-run would not deliver: $out28"
[ -L "$swh/.claude/commands/new.md" ] || fail "install.sh removed a command link mid-repair"
# A failed run must not head its summary "Done."
echo "$out28" | grep -q "^Done\." && fail "install.sh printed Done. on a failed run: $out28"
echo "$out28" | grep -q "^Incomplete\." || fail "install.sh did not head the failed summary Incomplete.: $out28"
ok "already-registered but broken command links are reported with a remedy that works"

# --- 68. ...but a WORKING link at one of those generic names is none of our
#          business, whoever owns it. Warning that /new is about to fail when it
#          works perfectly well is the same misjudgement about user links the rest
#          of this file goes out of its way to avoid. ---
wch="$T/workingcmdhome"
mkdir -p "$wch/.claude/skills/greenroom" "$wch/.claude/commands" "$wch/my-own"
echo "mine" > "$wch/.claude/skills/greenroom/notes.md"            # blocks the skill link
echo "my own command" > "$wch/my-own/new.md"
ln -s "$wch/my-own/new.md" "$wch/.claude/commands/new.md"         # user's own, and it WORKS
out29="$(HOME="$wch" bash "$REPO_ROOT/install.sh" 2>&1)" && rc29=0 || rc29=$?
[ "$rc29" -ne 0 ] || fail "install.sh reported success while the skill path was blocked: $out29"
echo "$out29" | grep -q "registered but broken" \
  && fail "install.sh called a working user command link broken: $out29"
[ "$(readlink "$wch/.claude/commands/new.md")" = "$wch/my-own/new.md" ] \
  || fail "install.sh touched a working user command link"
ok "a working command link is not reported as broken, whoever owns it"

# --- 69. a payload with scripts/ but no templates/ is not a working install either:
#          greenroom.py reads templates/ at scaffold time, so accepting it exits 0
#          and defers the failure to the user's first `new`. ---
nth="$T/notemplateshome"
mkdir -p "$nth/.claude/skills/greenroom/scripts"
cp "$REPO_ROOT/skills/greenroom/SKILL.md" "$nth/.claude/skills/greenroom/SKILL.md"
cp "$REPO_ROOT/skills/greenroom/scripts/greenroom.py" "$nth/.claude/skills/greenroom/scripts/"
out30="$(HOME="$nth" bash "$REPO_ROOT/install.sh" 2>&1)" && rc30=0 || rc30=$?
echo "$out30" | grep -q "already a standalone install" \
  && fail "install.sh accepted a payload with no templates/ as a working install: $out30"
[ "$rc30" -ne 0 ] || fail "install.sh reported success over a templates-less payload: $out30"
ok "a payload missing templates/ is not mistaken for a working standalone install"

# --- 70. ownership checks resolve RELATIVE symlink targets. An install whose links
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

# --- 71. a DANGLING link at the skill path is replaced, not skipped. This is what
#          our own link becomes once the clone is moved or renamed: ownership can no
#          longer be proven, but a dead link helps nobody and a link the user
#          actively uses is not dangling. Skipping here would make a re-run from
#          the relocated clone silently install nothing. ---
dh="$T/danglehome"
mkdir -p "$dh/.claude/skills"
ln -s "$T/moved-away/skills/greenroom" "$dh/.claude/skills/greenroom"   # target never existed
out6="$(HOME="$dh" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a dangling skill link"
[ -f "$dh/.claude/skills/greenroom/SKILL.md" ] || fail "a dangling link at the skill path was not replaced"
echo "$out6" | grep -q "SKIP skill greenroom" && fail "install.sh skipped a dangling link instead of replacing it: $out6"
echo "$out6" | grep -q "dangling" || fail "install.sh replaced a dangling link without saying so: $out6"
ok "a dangling link at the skill path is replaced, with a distinct message"

# --- 72. ...but NOT at a command path. new.md/add.md/sync.md are generic names a
#          user may have bound to their own repo, and a target on an unmounted
#          volume or a moved clone reads as dangling too. The claim only holds for
#          a path named for us. ---
dch="$T/danglecmdhome"
mkdir -p "$dch/.claude/skills" "$dch/.claude/commands"
ln -s "$T/unmounted-volume/my-new.md" "$dch/.claude/commands/new.md"    # user's own, target away
out8="$(HOME="$dch" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh errored on a dangling command link"
[ "$(readlink "$dch/.claude/commands/new.md")" = "$T/unmounted-volume/my-new.md" ] \
  || fail "install.sh claimed a dangling link at a generic command name"
echo "$out8" | grep -q "SKIP command new.md" || fail "install.sh did not report skipping the dangling command link: $out8"
[ -L "$dch/.claude/skills/greenroom" ] || fail "the skill itself was not installed"
ok "a dangling link at a generic command name is left alone, unlike the skill path"

# --- 73. re-cloning greenroom somewhere new and re-installing is a normal upgrade
#          path. The old clone is still on disk, so the link is neither ours-by-
#          $REPO_DIR nor dangling -- keying ownership to $REPO_DIR alone turned that
#          into a hard failure that installed nothing. ---
rc_old="$T/oldclone"
mkdir -p "$rc_old"
cp -R "$REPO_ROOT/skills" "$REPO_ROOT/commands" "$REPO_ROOT/.claude-plugin" "$rc_old/"
rch="$T/reclonehome"
mkdir -p "$rch/.claude/skills" "$rch/.claude/commands"
ln -s "$rc_old/skills/greenroom" "$rch/.claude/skills/greenroom"       # link from the OTHER clone
ln -s "$rc_old/commands/new.md" "$rch/.claude/commands/new.md"
out7="$(HOME="$rch" bash "$REPO_ROOT/install.sh" 2>&1)" || fail "install.sh failed re-installing from a new clone: $out7"
[ "$(readlink "$rch/.claude/skills/greenroom")" = "$REPO_ROOT/skills/greenroom" ] \
  || fail "the skill link was not repointed at the current clone"
[ "$(readlink "$rch/.claude/commands/new.md")" = "$REPO_ROOT/commands/new.md" ] \
  || fail "the command link was not repointed at the current clone"
echo "$out7" | grep -q "repointed" || fail "install.sh repointed silently: $out7"
echo "$out7" | grep -q "SKIP skill greenroom" && fail "install.sh treated another greenroom clone as a user symlink: $out7"
ok "re-installing from a second clone repoints the links instead of hard-failing"

# --- 74. the SKILL.md path resolver actually resolves. It is the ONLY thing that
#          tells an agent where greenroom.py lives now that the commands are hollow,
#          and it is prose -- nothing else would catch it drifting out of sync with
#          the install shapes we ship. Extract the snippet and run it for each. ---
resolver="$T/resolver.sh"
python3 - "$SKILL_MD" "$resolver" <<'PY' || fail "could not extract the resolver snippet from SKILL.md"
import re, sys, pathlib
raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blocks = [b for b in re.findall(r"```bash\n(.*?)```", raw, re.S) if "greenroom.py" in b]
assert len(blocks) == 1, f"expected exactly one bash block resolving greenroom.py, found {len(blocks)}"
# Anchor on the guard, which is the block's real last line. The invocation lives
# OUTSIDE the fence on purpose -- an agent is told to paste this block verbatim, so
# it must not contain a placeholder line that would run as a command.
marker = '[ -n "$greenroom" ] ||'
assert marker in blocks[0], f"the resolver block no longer ends with the {marker!r} guard; update this extractor"
assert "<subcommand>" not in blocks[0], \
    "the resolver block contains a placeholder line, but agents are told to paste it verbatim"
body = blocks[0] + '\necho "$greenroom"\n'
pathlib.Path(sys.argv[2]).write_text(body, encoding="utf-8")
PY
# shape 1: project-local `npx skills add` (no -g) -- the headline install path
proj="$T/resolveproj"
mkdir -p "$proj/.claude/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$proj/.claude/skills/greenroom"
got="$( cd "$proj" && HOME="$T/emptyhome" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed on a project-local skills.sh install"
[ "$got" = "$proj/.claude/skills/greenroom/scripts/greenroom.py" ] \
  || fail "resolver picked $got for a project-local install"
# ...and from a SUBDIRECTORY. SKILL.md sends the agent into <project>-public for
# collect and into the repo to wrap for retrofit, so a literal $PWD tier with no
# walk-up would silently fall through to a stale global copy.
mkdir -p "$proj/sub/deeper"
git -C "$proj" init -q                    # a real project has a boundary marker
got="$( cd "$proj/sub/deeper" && HOME="$T/emptyhome" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed from a subdirectory of a project-local install"
[ "$got" = "$proj/.claude/skills/greenroom/scripts/greenroom.py" ] \
  || fail "resolver did not walk up to the project-local install from a subdirectory (picked $got)"
# shape 0: $CLAUDE_PLUGIN_ROOT set, as the plugin runtime does. Every other shape
#          clears it, so without this the first tier -- and the `skills/greenroom`
#          sub-path it appends -- would ship unvalidated. It must outrank a
#          project-local copy and a cached one.
pr="$T/pluginroot"
mkdir -p "$pr/root/skills" "$pr/home/src/myproj/.claude/skills" \
         "$pr/home/.claude/plugins/cache/jesserobbins/greenroom/9.9.9/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$pr/root/skills/greenroom"
cp -R "$REPO_ROOT/skills/greenroom" "$pr/home/src/myproj/.claude/skills/greenroom"
cp -R "$REPO_ROOT/skills/greenroom" "$pr/home/.claude/plugins/cache/jesserobbins/greenroom/9.9.9/skills/greenroom"
got="$( cd "$pr/home/src/myproj" && HOME="$pr/home" CLAUDE_PLUGIN_ROOT="$pr/root" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed with CLAUDE_PLUGIN_ROOT set"
[ "$got" = "$pr/root/skills/greenroom/scripts/greenroom.py" ] \
  || fail "resolver did not honour CLAUDE_PLUGIN_ROOT (picked $got)"

# shape 1b: a project-local install AND a global one, with the project under $HOME
#           as real projects are. The project must win -- and the walk-up must not
#           mistake $HOME's own .claude/skills for the project tier.
both="$T/resolveboth"
mkdir -p "$both/src/myproj/.claude/skills" "$both/.claude/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$both/src/myproj/.claude/skills/greenroom"
cp -R "$REPO_ROOT/skills/greenroom" "$both/.claude/skills/greenroom"
got="$( cd "$both/src/myproj" && HOME="$both" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed with a project-local and a global install"
[ "$got" = "$both/src/myproj/.claude/skills/greenroom/scripts/greenroom.py" ] \
  || fail "the global install beat the project-local one (picked $got)"

# shape 1c: the walk-up stops at the project boundary. An unrelated ancestor that
#           happens to hold .claude/skills/greenroom (a parent workspace, a
#           ~/GitHub/.claude) must NOT outrank a newer plugin cache.
anc="$T/resolveancestor"
mkdir -p "$anc/GitHub/.claude/skills" "$anc/GitHub/myproj/src" \
         "$anc/.claude/plugins/cache/jesserobbins/greenroom/9.9.9/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$anc/GitHub/.claude/skills/greenroom"
cp -R "$REPO_ROOT/skills/greenroom" "$anc/.claude/plugins/cache/jesserobbins/greenroom/9.9.9/skills/greenroom"
git -C "$anc/GitHub/myproj" init -q                       # the project boundary
# ...and the same with NO boundary marker anywhere on the way up, which is the
# state `new <name>` runs in ("from the intended parent dir"). Without requiring a
# project root, the walk sails past ~/GitHub and takes the stale copy.
mkdir -p "$anc/GitHub/newproj-parent"
got="$( cd "$anc/GitHub/newproj-parent" && HOME="$anc" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed from an unmarked parent dir"
case "$got" in
  */plugins/cache/*) ;;
  *) fail "an unrelated ancestor won from an unmarked cwd chain (picked $got)" ;;
esac
got="$( cd "$anc/GitHub/myproj/src" && HOME="$anc" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed below an unrelated ancestor install"
case "$got" in
  */plugins/cache/*) ;;
  *) fail "an unrelated ancestor's .claude/skills outranked the plugin cache (picked $got)" ;;
esac
# ...but a greenroom WRAPPER sits one level above its repos, so the walk crosses it
wrp="$T/resolvewrapper"
mkdir -p "$wrp/home/src/proj/proj-public" "$wrp/home/src/proj/.claude/skills"
: > "$wrp/home/src/proj/.greenroom"
git -C "$wrp/home/src/proj/proj-public" init -q
cp -R "$REPO_ROOT/skills/greenroom" "$wrp/home/src/proj/.claude/skills/greenroom"
got="$( cd "$wrp/home/src/proj/proj-public" && HOME="$wrp/home" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed inside a greenroom wrapper"
[ "$got" = "$wrp/home/src/proj/.claude/skills/greenroom/scripts/greenroom.py" ] \
  || fail "the walk-up stopped at the repo and missed the wrapper-level install (picked $got)"

# shape 2: global install at ~/.claude/skills
gh_res="$T/resolveglobal"
mkdir -p "$gh_res/.claude/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$gh_res/.claude/skills/greenroom"
# cwd must sit UNDER $HOME, as a real project does -- $HOME is an ancestor of
# almost every cwd, and that is exactly what makes the tier ordering delicate.
mkdir -p "$gh_res/src/proj"
got="$( cd "$gh_res/src/proj" && HOME="$gh_res" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed on a global install"
[ "$got" = "$gh_res/.claude/skills/greenroom/scripts/greenroom.py" ] \
  || fail "resolver picked $got for a global install"
# shape 3: plugin cache with several versions -- the NEWEST must win, not the
#          lexically first (0.1.10 sorts before 0.2.0 without sort -V)
pc="$T/resolvecache"
mkdir -p "$pc/src/proj"
for v in 0.1.10 0.2.0 0.1.9; do
  mkdir -p "$pc/.claude/plugins/cache/jesserobbins/greenroom/$v/skills"
  cp -R "$REPO_ROOT/skills/greenroom" "$pc/.claude/plugins/cache/jesserobbins/greenroom/$v/skills/greenroom"
done
got="$( cd "$pc/src/proj" && HOME="$pc" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed on a plugin-cache install"
case "$got" in
  */greenroom/0.2.0/skills/greenroom/scripts/greenroom.py) ;;
  *) fail "resolver picked $got from the plugin cache; expected the newest version (0.2.0)" ;;
esac
# shape 3a: TWO marketplace owners cached. sort -V over the whole path compares
#           the owner segment first, so a lexically-later owner would win with an
#           older version -- the same bug one path component earlier.
mkdir -p "$pc/.claude/plugins/cache/zzz-owner/greenroom/0.1.0/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$pc/.claude/plugins/cache/zzz-owner/greenroom/0.1.0/skills/greenroom"
got="$( cd "$pc/src/proj" && HOME="$pc" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed with two cached marketplace owners"
case "$got" in
  */greenroom/0.2.0/skills/greenroom/scripts/greenroom.py) ;;
  *) fail "a second cached owner outranked the newer version (picked $got)" ;;
esac
# shape 3b: cache AND a global ~/.claude/skills copy present. $CLAUDE_PLUGIN_ROOT
#           is not exported into Bash-tool shells, so the cache IS the plugin path
#           -- a leftover manual clone must not shadow it.
mkdir -p "$pc/.claude/skills"
cp -R "$REPO_ROOT/skills/greenroom" "$pc/.claude/skills/greenroom"
got="$( cd "$pc/src/proj" && HOME="$pc" CLAUDE_PLUGIN_ROOT="" bash "$resolver" )" \
  || fail "the SKILL.md resolver failed with both a cache and a global install present"
case "$got" in
  */plugins/cache/*) ;;
  *) fail "a global ~/.claude/skills copy shadowed the plugin cache (picked $got)" ;;
esac
# a payload that lost its exec bit in transit must still resolve
chmod -x "$proj/.claude/skills/greenroom/scripts/greenroom.py"
( cd "$proj" && HOME="$T/emptyhome" CLAUDE_PLUGIN_ROOT="" bash "$resolver" ) >/dev/null \
  || fail "the SKILL.md resolver failed on a payload with no exec bit"
# and it must fail loudly, not run `python3 ""`, when nothing is installed
( cd "$T/emptyhome" 2>/dev/null || mkdir -p "$T/emptyhome" && cd "$T/emptyhome"
  HOME="$T/emptyhome" CLAUDE_PLUGIN_ROOT="" bash "$resolver" ) >/dev/null 2>&1 \
  && fail "the SKILL.md resolver reported success with no greenroom installed anywhere"
ok "the SKILL.md path resolver finds the script in every install shape we ship"

# --- 75. new/retrofit write a .greenroom marker; sync adds it to a marker-less wrapper ---
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

# --- 76. a stray .greenroom in a forbidden dir does NOT make it a wrapper (walk-up guard) ---
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

# --- 77. workspace is skipped when no VS Code signal; --workspace / --no-workspace override ---
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

# --- 78. detection writes the workspace when a .vscode/ dir exists (binary absent) ---
mkdir -p "$T/vscode"
GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" new vscodeproj --parent "$T/vscode" --init-public >/dev/null
vws="$T/vscode/vscodeproj/vscodeproj.code-workspace"
[ ! -f "$vws" ] || fail "setup: workspace should have been skipped before .vscode/ existed"
mkdir -p "$T/vscode/vscodeproj/.vscode"
( cd "$T/vscode/vscodeproj/vscodeproj-public" && GREENROOM_TEST_NO_EDITOR=1 "$SCRIPT" sync ) >/dev/null
[ -f "$vws" ] || fail "a present .vscode/ dir did not trigger the workspace write"
ok "detection writes the workspace when .vscode/ exists even with no family binary"

# --- 79. the block numbers themselves are unique and sequential. Inserting a test
#          mid-file has collided the numbering twice now; duplicate identifiers make
#          a failure ambiguous to triage, and nothing else notices. ---
nums="$(grep -o '^# --- [0-9]*\.' "${BASH_SOURCE[0]}" | grep -o '[0-9]*')"
dupes="$(printf '%s\n' "$nums" | sort -n | uniq -d | tr '\n' ' ')"
[ -z "$(echo "$dupes" | tr -d ' ')" ] || fail "duplicate test block numbers: $dupes"
expected="$(seq 1 "$(printf '%s\n' "$nums" | wc -l | tr -d ' ')")"
[ "$(printf '%s\n' "$nums" | sort -n | tr '\n' ' ')" = "$(printf '%s\n' "$expected" | tr '\n' ' ')" ] \
  || fail "test block numbers are not a gapless 1..N sequence"
ok "test block numbers are unique and sequential"

# --- 80. every `## [x.y.z]` changelog heading has its reference-link definition.
#          Without one the heading renders with literal brackets on GitHub, which
#          is invisible in the diff and only shows up on the released page. ---
missing=""
while IFS= read -r v; do
  grep -q "^\[$v\]:" "$REPO_ROOT/CHANGELOG.md" || missing="$missing $v"
done < <(grep -o '^## \[[0-9][^]]*\]' "$REPO_ROOT/CHANGELOG.md" | sed 's/^## \[//; s/\]$//')
[ -z "$missing" ] || fail "changelog versions with no reference-link definition:$missing"
# The shipped version must match the newest heading. The resolver's plugin-cache
# tier now sorts on the cached VERSION directory, so a plugin.json drifting behind
# the changelog quietly changes which cached copy wins -- invisible in a diff.
newest_heading="$(grep -o '^## \[[0-9][^]]*\]' "$REPO_ROOT/CHANGELOG.md" | head -1 | sed 's/^## \[//; s/\]$//')"
manifest_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$REPO_ROOT/.claude-plugin/plugin.json" | head -1)"
[ "$newest_heading" = "$manifest_version" ] \
  || fail "plugin.json version is $manifest_version but the newest changelog heading is $newest_heading"
ok "every released changelog heading has its link definition, and matches plugin.json"

echo "all $pass checks passed"
