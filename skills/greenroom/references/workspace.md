# VS Code workspace, access grants, and the repo map

## VS Code workspace

Each entry point (`new`, `retrofit`, `sync`) writes or refreshes a
`<project>.code-workspace` file at the wrapper root. It does this **only when it
detects a VS Code-family editor**. The signals are `code`, `cursor`,
`codium`/`vscodium`, or `windsurf` on `PATH`, or an existing `.vscode/` or
`*.code-workspace` in the wrapper. If it detects none of these, it skips the
file and prints a one-line hint. A terminal-only user gets no workspace file.

To force the write, pass `--workspace`. To suppress it, pass `--no-workspace`.
Both flags work on all three commands.

When the file is present, it is the VS Code entry point. Never use `Open Folder`
on the wrapper or on a repo directly. The workspace file is not what
*identifies* a wrapper. The `.greenroom` marker does that.

**Auto-discovery.** The script builds the `folders` array by scanning the
wrapper for git repos. Every immediate subdirectory that holds a `.git/` becomes
a root. The canonical repo comes first and the rest follow in alphabetical
order. Drop a `-public-fork`, a `-private-fork`, or any other clone under the
wrapper. On the next `sync` it appears as its own root, with its own Source
Control panel. The canonical repo is the `-public` repo, and a `-public-fork` is
the fallback. To choose a different one, pass `--canonical`.

What the workspace file sets:

- **It anchors the Claude session cwd to the wrapper**, through
  `terminal.integrated.cwd: ${workspaceFolder:<canonical>}/..`. New integrated
  terminals then open at the wrapper, not inside a sub-repo. Session bucketing
  keys on the launch cwd alone. The anchor therefore keeps history from
  fragmenting across `-public`, `-private`, `-public-fork`, and the rest.
- **It provides a Tasks-based Claude launcher**, named
  `Claude Code (<canonical>)`, which you run from `Cmd+Shift+P → Tasks: Run Task`.
  The task opens a dedicated terminal at the wrapper and runs plain `claude`. It
  passes no `--add-dir` and sets no `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`.
  Every child repo is under the wrapper cwd, so the session gets read and write
  access to all of them automatically. Each child repo's `AGENTS.md`, imported
  through the `CLAUDE.md` pointer, then loads the first time Claude touches
  files in that repo. To launch in one step, bind the task to a key in
  `~/.claude/keybindings.json`.
- **It disables parent-folder repo scanning**, with
  `git.openRepositoryInParentFolders: never` and `git.detectSubmodules: false`.
  VS Code then stops treating the wrapper dir as another repo.
- **It sets a window title** that shows `<project>: <active folder>`.
- **It paints a per-project accent color**, through
  `workbench.colorCustomizations`, on the title bar, activity bar, and status
  bar. The hue comes from the project name, so each open project's window looks
  different.

**Merge-additive, not overwrite.** A re-run on an existing workspace adds only
the missing folder roots and the missing default settings keys. It never
overwrites a folder, a setting, a task, or a customization you added by hand.

CAUTION: `.code-workspace` is JSONC. If you add `//` comments to it, the stdlib
JSON parser cannot read the file. The script then leaves the file untouched and
prints a warning, rather than risk overwriting your work. To let `sync` manage
the file again, remove the comments.

## Granting Claude access to the sibling repos

A `.code-workspace` file has **no** Claude Code integration. Listing folders as
roots makes them appear in the VS Code file tree. Claude launched from one root
still gets read and edit access to **that root only**. Access is granted
separately.

The script writes `<canonical>/.claude/settings.local.json`, which lists each
sibling repo:

```json
{ "permissions": { "additionalDirectories": ["../<project>-private", "../<project>-public-fork"] } }
```

This is the documented form: a list of sibling checkouts (`../<name>`), not an
ancestor.

**The primary access mechanism is the wrapper cwd.** When any agent launches at
the wrapper, every child repo is under cwd and reachable with no grant. These
per-repo grants are defense-in-depth for a stray `claude` launched *inside* a
single repo. Under a normal wrapper-rooted launch they do nothing.

`sync` re-reads the siblings. Add a repo, then run `sync` again. One step picks
the new repo up, both as a VS Code folder root and in every repo's grant. The
list is add-only, so entries you add by hand are kept.
`settings.local.json` is gitignored, and the script also adds it to
`.git/info/exclude`. The private-dir paths it names therefore never land in the
public repo's tracked files.

## Repo map for agents

The wrapper-root `README.md` carries an auto-managed map, held inside
`<!-- greenroom:begin -->` and `<!-- greenroom:end -->` markers. The map lists
every repo, its inferred role, which one is canonical, and where to work. It
lives at the wrapper root, which is never published, so it is safe to name
private paths there.

The map is the **human** entry point. You `cd` into the wrapper and it is the
first thing there. Agents launched at the wrapper get their orientation from two
other places: the wrapper's own `AGENTS.md`, which loads at startup, and each
child repo's `AGENTS.md`, which loads lazily. `sync` rewrites only the marked
block and preserves everything around it. A hand-authored README with no markers
is left alone.

## How to open the project, every time

1. From any terminal, run `cd <wrapper> && <your-agent>`. Your agent is
   `claude`, `codex`, `gemini`, or whichever you use. This is the universal
   entry point, and it works in any editor or in none. Session history goes to a
   single bucket. All child repos are reachable. Each repo's `AGENTS.md` loads
   lazily.
2. If the script wrote a `<project>.code-workspace` file, a VS Code user can
   open it instead. Use `File → Open Workspace from File…` and select
   `<wrapper>/<project>.code-workspace`. From a terminal, run
   `code <wrapper>/<project>.code-workspace`. On later launches, pick
   `<project> (Workspace)` from "Recent". Then run the
   **`Claude Code (<canonical>)`** task.
