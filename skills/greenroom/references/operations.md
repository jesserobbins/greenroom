# Operations: boundaries, edge cases, aftercare

## Safety boundaries

greenroom never treats `$HOME`, the filesystem root, or standard system
directories as a wrapper or scaffold target, regardless of any signal they
carry.

Set `GREENROOM_ROOT` to your projects' parent directory to tighten this
further; greenroom then refuses to operate at or above it.

## What the script does NOT do, and why

- **Does not push.** Both repos stay local until you push them. Avoids
  accidental publication and lets you review before committing.
- **Does not commit anything in the public repo.** The only thing it writes
  there is `.claude/settings.local.json` (the sibling-repo grant), and that file
  is added to `.git/info/exclude`, so it never appears in `git status` or
  reaches a commit.
- **Does not edit Claude Code plugin configs.** If the public repo is registered
  as a Claude Code plugin (in `~/.claude/plugins/known_marketplaces.json` or
  `~/.claude/settings.json`), a move breaks the registration. Those files are
  agent config and the harness blocks auto-edits. The script detects the
  mismatch and tells you exactly which files and what to change. **Surface this
  warning prominently — it is the user's manual step.**
- **Does not create the private GitHub repo.** It prints the `gh repo create`
  command for you to run.
- **Does not commit.** It leaves the private repo's initial files staged for
  review.

## Edge cases the script handles

- **Parent-name collision** (existing repo already at `~/src/<name>/`): moves
  the repo to a temp path, creates the parent, then moves the repo into the
  parent as `<name>-public/`. If the move fails partway, the repo is restored to
  its original location with no stranded temp path.
- **Working tree dirty**: refuses to retrofit if the public repo has
  uncommitted changes. Commit or stash first.
- **Parent already exists and non-empty**: refuses to overwrite. Manual cleanup
  required.
- **Idempotent re-runs**: if the source path is already inside its target parent
  structure, the script detects this and only adds the missing private dir. It
  recognizes both the canonical `<project>-private/` and legacy `private/` as
  already-existing. **On a second `retrofit`, point at the `<project>-public/`
  dir** (e.g. `~/src/<name>/<name>-public`), not the path you used the first
  time: after the first run the wrapper is no longer a git repo, so the original
  path is rejected.
- **Legacy `private/` dir**: if a wrapper already has a plain `private/`, a
  retrofit leaves it where it is and prints a hint to rename it. To migrate,
  rename the directory (`mv private <project>-private`) and, if a
  `<project>.code-workspace` exists, update the folder name and path in it.
- **Retrofit from inside the repo**: the move renames the directory the user's
  shell is in. The script prints a stale-cwd note telling them to `cd <wrapper>`
  to re-sync. Cosmetic, not data loss — but surface it.

## Aftercare checklist

After the script runs, remind the user to:

1. **Update Claude Code plugin paths** (if the script flagged any): manually
   edit the JSON files it named.
2. **Commit and push the private repo**:
   ```bash
   cd <parent>/<project>-private
   git add . && git commit -m "init: private notes for <project>"
   gh repo create <your-account>/<project>-private --private --source=. --remote=origin
   git push -u origin main
   ```
3. **Launch at the new wrapper** (`cd <wrapper> && <your-agent>`), not inside
   either repo. If a `<project>.code-workspace` was written, open the project
   through it rather than `Open Folder`; if a previous VS Code window had the
   old layout open, close it first.
4. **Update shell aliases** that hardcoded the old `~/src/<name>/` path (now the
   parent folder, not the repo).
5. **One-time global hygiene** (only if not already done): add `.notes`,
   `NOTES.md`, `SCRATCH.md`, `*.private.md`, `.private/` to
   `~/.config/git/ignore` so private-flavored filenames can't accidentally land
   in public repos from a fresh clone.

## Summarizing a run

After `new` or `retrofit`, summarize: the wrapper folder, public repo path,
private repo path, and (if created) the private-fork path, plus the `.greenroom`
marker, the `<project>.code-workspace` (written only when a VS Code-family
editor is detected, or with `--workspace`), wrapper and per-repo `AGENTS.md`
files (plus `CLAUDE.md` pointers and `.gemini/settings.json` adapters), the
canonical repo's `.claude/settings.local.json`, and the wrapper `README.md` repo
map.

After `sync`, summarize the discovered repos, the canonical repo, and the files
written. If the wrong repo was chosen as canonical, re-run with
`--canonical <repo-dir>`. If new folder roots were added to a workspace, suggest
reopening it.

Always remind the user that the canonical launch is `cd <wrapper> && <your-agent>`.
