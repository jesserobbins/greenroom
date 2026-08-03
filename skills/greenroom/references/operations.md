# Operations: boundaries, edge cases, aftercare

## Safety boundaries

greenroom never treats `$HOME`, the filesystem root, or a standard system
directory as a wrapper or a scaffold target. This holds regardless of any signal
those directories carry.

Set `GREENROOM_ROOT` to the parent directory of your projects to tighten this
further. greenroom then refuses to operate at or above that directory.

## What the script does NOT do, and why

- **Does not push.** Both repos stay local until you push them. This prevents
  accidental publication, and it lets you review the work first.
- **Does not commit anything in the public repo.** The only file it writes there
  is `.claude/settings.local.json`, the sibling-repo grant. The script adds that
  file to `.git/info/exclude`, so it never appears in `git status` and never
  reaches a commit.
- **Does not edit Claude Code plugin configs.** The public repo can be
  registered as a Claude Code plugin, in `~/.claude/plugins/known_marketplaces.json`
  or `~/.claude/settings.json`. A move then breaks the registration. Those files
  are agent config, and the harness blocks automatic edits to them. The script
  detects the mismatch and names the exact files and changes. **Relay this
  warning to the user prominently. It is a manual step that only the user can
  do.**
- **Does not create the private GitHub repo.** It prints the `gh repo create`
  command for you to run.
- **Does not commit.** It leaves the private repo's initial files staged for
  review.

## Edge cases the script handles

- **Parent-name collision**, when a repo is already at `~/src/<name>/`: the
  script moves the repo to a temp path, creates the parent, then moves the repo
  into the parent as `<name>-public/`. If the move fails partway, the script
  restores the repo to its original location and strands no temp path.
- **Dirty working tree**: if the public repo has uncommitted changes, the script
  refuses to retrofit. Commit or stash the changes first.
- **Parent exists and is not empty**: the script refuses to overwrite it. Clean
  the directory up by hand.
- **Idempotent re-runs**: if the source path is already inside its target parent
  structure, the script detects this and adds only the missing private repo. It
  recognizes both the canonical `<project>-private/` and the legacy `private/`
  as already-existing. **On a second `retrofit`, point at the
  `<project>-public/` dir** (for example `~/src/<name>/<name>-public`), not at
  the path you used the first time. After the first run the wrapper is no longer
  a git repo, so the script rejects the original path.
- **Legacy `private/` dir**: if a wrapper already holds a plain `private/`, a
  retrofit leaves it where it is and prints a hint to rename it. To migrate,
  rename the directory with `mv private <project>-private`. If a
  `<project>.code-workspace` file is present, also update the folder name and
  the path in it.
- **Retrofit from inside the repo**: the move renames the directory that the
  user's shell is in. The script prints a stale-cwd note that tells them to
  `cd <wrapper>` to re-sync. The condition is cosmetic and causes no data loss.
  Relay the note anyway.

## Aftercare checklist

After the script runs, remind the user to do these steps:

1. **Update the Claude Code plugin paths.** If the script flagged any, edit the
   JSON files it named by hand.
2. **Commit and push the private repo**:
   ```bash
   cd <parent>/<project>-private
   git add . && git commit -m "init: private notes for <project>"
   gh repo create <your-account>/<project>-private --private --source=. --remote=origin
   git push -u origin main
   ```
3. **Launch at the new wrapper** with `cd <wrapper> && <your-agent>`. Do not
   launch inside either repo. If the script wrote a `<project>.code-workspace`
   file, open the project through that file, not with `Open Folder`. If a
   previous VS Code window has the old layout open, close that window first.
4. **Update the shell aliases** that hold the old `~/src/<name>/` path. That
   path is now the parent folder, not the repo.
5. **Do the one-time global hygiene step**, if it is not done already. Add
   `.notes`, `NOTES.md`, `SCRATCH.md`, `*.private.md`, and `.private/` to
   `~/.config/git/ignore`. Those filenames can then never land in a public repo
   by accident, even from a fresh clone.

## Summarizing a run

After `new` or `retrofit`, summarize these items:

- the wrapper folder, the public repo path, and the private repo path
- the private-fork path, if the script created one
- the `.greenroom` marker
- the `<project>.code-workspace` file, if the script wrote one
- the wrapper and per-repo `AGENTS.md` files
- the `CLAUDE.md` pointers and the `.gemini/settings.json` adapters
- the canonical repo's `.claude/settings.local.json`
- the wrapper `README.md` repo map

After `sync`, summarize the discovered repos, the canonical repo, and the files
written. If the script chose the wrong repo as canonical, re-run it with
`--canonical <repo-dir>`. If it added new folder roots to a workspace, tell the
user to reopen that workspace.

Always remind the user that the canonical launch is
`cd <wrapper> && <your-agent>`.
