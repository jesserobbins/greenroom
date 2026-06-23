---
description: Re-scan a greenroom wrapper and update its VS Code workspace, agent working-dir access, and repo map (run after dropping a new fork/clone under the wrapper)
argument-hint: [--wrapper <dir>] [--canonical <repo-dir>] [--name <project>]
---

Run the greenroom script's `sync` subcommand with the user's arguments.

The script ships with greenroom. Invoke it via Bash, using the form below so it resolves under both a plugin install (`$CLAUDE_PLUGIN_ROOT` is set) and a manual `install.sh` install (the `~/.claude/skills/greenroom` fallback):

```
"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/greenroom}/scripts/greenroom.py" sync $ARGUMENTS
```

With no `--wrapper`, the script detects the wrapper by walking up from the current directory to the nearest non-git folder that contains git repos, so it works from inside any of the project's repos or from the wrapper itself.

What `sync` does (all idempotent and additive):
- **Discovers every git repo** directly under the wrapper and lists each as a `<project>.code-workspace` folder root, canonical repo first.
- **Merges into an existing workspace**: adds newly-found repos and any missing default settings, but never overwrites a folder, setting, task, or customization you added by hand. (If the file has `//` JSONC comments, stdlib JSON can't parse it, so the script leaves it untouched and warns.)
- **Writes `AGENTS.md`** at the wrapper root and in each repo (write-if-absent). Also writes the `CLAUDE.md` pointer (`@AGENTS.md`) for Claude Code and `.gemini/settings.json` for Gemini CLI.
- **Migrates old greenroom-authored `CLAUDE.md` files.** If a wrapper or per-repo `CLAUDE.md` was written by a previous version of greenroom and no `AGENTS.md` exists yet, `sync` writes `AGENTS.md` with the content and replaces `CLAUDE.md` with the `@AGENTS.md` pointer. A hand-edited `CLAUDE.md` (content differs from what greenroom would have written) is left untouched and a note is printed to migrate it manually.
- **Grants Claude the sibling repos** by listing each repo's siblings (`../<name>`) under `permissions.additionalDirectories` in **every** repo's `.claude/settings.local.json` (locally git-excluded, so no private paths leak into the public repo), for defense-in-depth against a stray Claude launch inside a single repo. Add-only: entries you added by hand are kept.
- **Refreshes the wrapper `README.md` repo map** inside `greenroom` marker comments, preserving anything outside the markers. A hand-authored README with no markers is left alone (the script says so).

After it runs:
- Summarize the discovered repos, the canonical repo, and the files written.
- Remind the user that the canonical way to launch is at the wrapper (`cd <wrapper> && <your-agent>`): every repo is then under cwd and each repo's `AGENTS.md` loads as the agent touches its files. The workspace's `Claude Code` task does the same from VS Code. If new folder roots were added, suggest re-opening the `<project>.code-workspace` (or reloading the window) to pick them up.
- If the wrong repo was chosen as canonical, re-run with `--canonical <repo-dir>`.

Reference: full conventions and edge cases live in `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/greenroom}/SKILL.md"`.
