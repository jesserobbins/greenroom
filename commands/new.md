---
description: Create a new project with the greenroom layout (public code repo + private notes repo under one parent folder)
argument-hint: <project-name> [--clone <git-url> | --init-public] [--with-private-fork] [--parent <dir>] [--public-name <dir>] [--private-name <dir>]
---

Run the greenroom script's `new` subcommand with the user's arguments.

The script ships with greenroom. Resolve its path with the block below, then invoke it via Bash with `$ARGUMENTS` appended. The block tries the plugin env var, then the plugin cache (any owner/version), then the manual `install.sh` location -- so it works on a plugin install and a manual install alike:

```bash
P="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$P" ] && P=$(ls -d "$HOME"/.claude/plugins/cache/*/greenroom/*/ 2>/dev/null | sort -V | tail -1)
[ -z "$P" ] && P="$HOME/.claude/skills/greenroom"
"$P/scripts/greenroom.py" new $ARGUMENTS
```

## `--with-private-fork`

Pass this flag to also scaffold a `<project>-private-fork/` sibling. The script clones the local `<project>-public` repo into it using `git clone -o upstream`, so the link is named `upstream` (not `origin`). This leaves `origin` free for a private GitHub remote. The fork is enumerated as a workspace root and granted sibling access automatically.

Use this when the project needs a dedicated private dev checkout separate from the public repo (the layout: private dev in `-private-fork`, ready work promoted to `-public`).

## After the script runs

- Summarize the wrapper folder, public repo path, private repo path, and (if created) the private-fork path, plus the `.greenroom` identity marker, the `<project>.code-workspace` (written only when a VS Code-family editor is detected, or with `--workspace`), wrapper `AGENTS.md` and per-repo `AGENTS.md` files (plus `CLAUDE.md` pointers and `.gemini/settings.json` adapters), the canonical repo's `.claude/settings.local.json` (Claude sibling-repo safety-net grant), and the wrapper `README.md` repo map.
- Remind the user: the canonical launch is `cd <wrapper> && <your-agent>`. Every repo is then reachable and `AGENTS.md` loads automatically.
- If the script printed a plugin-config warning, surface it prominently. That's the user's manual step.
- If they later add a fork or another clone under the wrapper, point them at `/greenroom:sync` to wire it into the workspace.

## Relaying the repo-creation offer

If the script printed a "To create private GitHub repos for these (optional):" block, relay it to the user verbatim. Show the exact `gh repo create ... --private` commands. Then:

- Ask the user whether to run them.
- Run them only on an explicit yes.
- If the user types an org name instead of their personal account, substitute it for the `<owner>` prefix in the commands.
- Make clear that declining leaves everything local -- nothing reaches GitHub without running these commands.
- These are always `--private`. Do not offer or suggest a public variant.

If the user ran it without arguments, show the script's `--help` for `new` and stop.

Reference: full conventions and edge cases live in the greenroom skill (`skills/setup/SKILL.md` in the repo; on a plugin install, `$P/skills/setup/SKILL.md`; on a manual install, `~/.claude/skills/greenroom-setup/SKILL.md`).
