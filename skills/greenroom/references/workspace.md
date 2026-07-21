# VS Code workspace, access grants, and the repo map

## VS Code workspace

Each entry point (`new`, `retrofit`, `sync`) writes/refreshes a
`<project>.code-workspace` file at the wrapper root **when a VS Code-family
editor is detected** — `code`, `cursor`, `codium`/`vscodium`, or `windsurf` on
`PATH`, or an existing `.vscode/` or `*.code-workspace` in the wrapper.
Otherwise the file is skipped (a terminal-only user gets none) and the command
prints a one-line hint. Force the write with `--workspace` or suppress it with
`--no-workspace`; both flags work on all three commands.

When the file is present, it's the VS Code entry point — never use `Open Folder`
on the wrapper or on a repo directly. It is not what *identifies* a wrapper;
the `.greenroom` marker does that.

**Auto-discovery.** The `folders` array is built by scanning the wrapper for git
repos. Every immediate subdirectory containing `.git/` becomes a root, canonical
first, the rest alphabetical. So a `-public-fork`, a `-private-fork`, or any
other clone dropped under the wrapper shows up as its own root (with its own
Source Control panel) on the next `sync`. Canonical = the `-public` repo (a
`-public-fork` is the fallback); override with `--canonical`.

What the workspace file sets:

- **Anchors the Claude session cwd to the wrapper** via
  `terminal.integrated.cwd: ${workspaceFolder:<canonical>}/..`. New integrated
  terminals open rooted at the wrapper, not inside a sub-repo. Session bucketing
  is by launch cwd only, so anchoring to the wrapper prevents history
  fragmenting across `-public`, `-private`, `-public-fork`, and so on.
- **Provides a Tasks-based Claude launcher** (`Claude Code (<canonical>)`) via
  `Cmd+Shift+P → Tasks: Run Task`. It opens a dedicated terminal rooted at the
  wrapper and runs plain `claude`, with no `--add-dir` and no
  `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`. Because every child repo is
  under the wrapper cwd, the session has read/write access to all of them
  automatically, and each child repo's `AGENTS.md` (imported via the `CLAUDE.md`
  pointer) loads lazily the first time Claude touches files in that repo. Bind
  the task to a key in `~/.claude/keybindings.json` for one-shot launch.
- **Disables parent-folder repo scanning**
  (`git.openRepositoryInParentFolders: never`, `git.detectSubmodules: false`) so
  VS Code stops treating the wrapper dir as another repo.
- **Sets a window title** showing `<project>: <active folder>`.
- **Paints a per-project accent color** (`workbench.colorCustomizations` for the
  title/activity/status bars), with a hue derived from the project name so each
  open project's window is visually distinct.

**Merge-additive, not overwrite.** Re-running on an existing workspace only
*adds* missing folder roots and missing default settings keys; it never
overwrites a folder, setting, task, or hand-added customization.
`.code-workspace` is JSONC: if you've added `//` comments, stdlib JSON can't
parse it, so the script leaves the file untouched and warns rather than risk
clobbering it. Remove the comments to let `sync` manage it.

## Granting Claude access to the sibling repos

A `.code-workspace` file has **no** Claude Code integration: listing N folders as
roots makes them appear in VS Code's file tree, but Claude launched from one
root gets read/edit access to **only that root**. Access is granted separately.
The script writes `<canonical>/.claude/settings.local.json` listing each sibling
repo:

```json
{ "permissions": { "additionalDirectories": ["../<project>-private", "../<project>-public-fork"] } }
```

This is the documented form: a list of sibling checkouts (`../<name>`), not an
ancestor.

**The primary access mechanism is the wrapper cwd**: when any agent launches at
the wrapper, every child repo is under cwd and automatically reachable with no
grant required. These per-repo grants are defense-in-depth for a stray `claude`
launched *inside* a single repo; under a normal wrapper-rooted launch they are
inert.

`sync` re-enumerates the siblings, so adding a repo and re-running picks it up
for both VS Code (a folder root) and every repo's grant in one step. The list is
add-only: entries you add by hand are kept. `settings.local.json` is gitignored,
and the script also adds it to `.git/info/exclude`, so the private-dir paths it
names never land in the public repo's tracked files.

## Repo map for agents

The wrapper-root `README.md` carries an auto-managed map (inside
`<!-- greenroom:begin -->` … `<!-- greenroom:end -->` markers): every repo, its
inferred role, which one is canonical, and where to work. It lives at the
wrapper root (never published, so it's safe to name private paths).

It's the **human** entry point: `cd` into the wrapper and it's the first thing
there. Agents launched at the wrapper get their orientation from the wrapper's
own `AGENTS.md` (loaded at startup) and each child repo's `AGENTS.md` (loaded
lazily). `sync` rewrites only the marked block, preserving anything around it; a
hand-authored README with no markers is left alone.

## How to open the project, every time

1. From any terminal: `cd <wrapper> && <your-agent>` (`claude`, `codex`,
   `gemini`, or whichever). This is the universal entry point — it works in any
   editor or none. Session history goes to a single bucket; all child repos are
   reachable; each repo's `AGENTS.md` loads lazily.
2. If a `<project>.code-workspace` was written, VS Code users can instead open
   it via `File → Open Workspace from File…` → `<wrapper>/<project>.code-workspace`
   (or `code <wrapper>/<project>.code-workspace`; subsequent launches: pick
   `<project> (Workspace)` from "Recent"), then run the
   **`Claude Code (<canonical>)`** task.
