---
description: Add a private notes repo alongside an existing public repo (moves the public repo into a wrapper folder and scaffolds <project>-private/ as a sibling)
argument-hint: [path-to-existing-public-repo] [--name <project>] [--with-private-fork] [--public-name <dir>] [--private-name <dir>]
---

Run the greenroom script's `retrofit` subcommand with the user's arguments. The path is optional: with no path, it operates on the current directory, so a user already inside their repo can just run the command.

The script ships with greenroom. Resolve its path with the block below, then invoke it via Bash. The block tries the plugin env var, then the plugin cache (any owner/version), then the manual `install.sh` location -- so it works on a plugin install and a manual install alike:

```bash
P="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$P" ] && P=$(ls -d "$HOME"/.claude/plugins/cache/*/greenroom/*/ 2>/dev/null | sort -V | tail -1)
[ -z "$P" ] && P="$HOME/.claude/skills/greenroom"
"$P/scripts/greenroom.py" retrofit $ARGUMENTS
```

The script will:
- Refuse if the public repo has uncommitted changes (the user should commit or stash first).
- Move the existing repo into a new `<wrapper>/<project>-public/` directory, preserving git history and the origin remote. The wrapper takes the project's name; the repo's existing parent dir (e.g. `~/src`) stays as the parent, and sibling repos there are untouched.
- Scaffold `<wrapper>/<project>-private/` with a fresh git repo, an `AGENTS.md` with conventions for agents (plus a `CLAUDE.md` pointer for Claude Code), and `docs/notes/drafts/reviews/research/` subdirs.
- Write a `.greenroom` identity marker at the wrapper root, plus wrapper and per-repo `AGENTS.md` files, `<public>/.claude/settings.local.json` (Claude sibling-repo safety-net grant; git-excluded), `.gemini/settings.json` (Gemini adapter; git-excluded), and a wrapper `README.md` repo map. When a VS Code-family editor is detected (or with `--workspace`), it also writes a `<project>.code-workspace` listing every repo under the wrapper as a root; otherwise that file is skipped.
- Detect any Claude Code plugin configs that point at the old path and tell the user exactly which files need updating (it does not auto-edit those -- they are agent config and the user owns them).

## `--with-private-fork`

Pass this flag to also scaffold a `<project>-private-fork/` sibling. The script clones the local `<project>-public` repo into it using `git clone -o upstream`, so the link is named `upstream` (not `origin`). This leaves `origin` free for a private GitHub remote. The fork is enumerated as a workspace root and granted sibling access automatically.

Use this when the project needs a dedicated private dev checkout separate from the public repo (the layout: private dev in `-private-fork`, ready work promoted to `-public`).

## After the script runs

- Confirm the wrapper layout and that the public repo's git history + remote are intact.
- Remind the user: the canonical launch is `cd <wrapper> && <your-agent>` (claude, codex, gemini, etc.). Every repo is then reachable and `AGENTS.md` loads automatically. If a `<project>.code-workspace` was written (VS Code family detected), its `Claude Code` task does the same from VS Code.
- If a plugin-config warning printed, surface it prominently and tell the user the exact substitution to make in the named files.
- **If a stale-cwd note printed** (an in-place wrap, i.e. they ran `add` from inside the repo), surface it: their interactive shell's `cd` still points at the moved directory, so `ls`/`pwd` there look stale until they re-run `cd <wrapper>`. This is cosmetic, not data loss; the layout is correct on disk.
- Remind the user about external follow-ups: updating IDE workspaces or shell aliases that hardcoded the old path.
- If the public repo's history already holds design docs or notes, mention `greenroom.py collect` (run from inside `<project>-public/`) to recover them into the private dir.
- If they later add a fork or another clone under the wrapper, point them at `/greenroom:sync` to wire it into the workspace.

## Relaying the repo-creation offer

If the script printed a "To create private GitHub repos for these (optional):" block, relay it to the user verbatim. Show the exact `gh repo create ... --private` commands. Then:

- Ask the user whether to run them.
- Run them only on an explicit yes.
- If the user types an org name instead of their personal account, substitute it for the `<owner>` prefix in the commands.
- Make clear that declining leaves everything local -- nothing reaches GitHub without running these commands.
- These are always `--private`. Do not offer or suggest a public variant.

Re-running is idempotent, but point at the `-public` dir on the second run (e.g. `~/src/<name>/<name>-public`): after the first run the wrapper is no longer a git repo, so the original path would be rejected.

Reference: full conventions and edge cases live in the greenroom skill (`skills/setup/SKILL.md` in the repo; on a plugin install, `$P/skills/setup/SKILL.md`; on a manual install, `~/.claude/skills/greenroom-setup/SKILL.md`).
