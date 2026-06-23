---
name: greenroom
description: Set up the greenroom layout: a top-level `<Project>/` directory holding the public code repo (`<project>-public/`) beside a private notes repo (`<project>-private/`) for design docs, drafts, and review notes that belong under git source control but should never be published. The public repo is the stage; the private repo is the green room where you prep off-stage. Use whenever someone wants to keep private design thinking separate from a public-facing project. Triggers include "set up a green room for this repo", "add private notes alongside the public code", "create a new project with private notes", "keep my design docs out of the public repo", "scaffold the greenroom layout", "set up a paired public/private project", "publish in the open without leaking my thinking". Use proactively when someone is starting a public-facing project and mentions design docs, drafts, brainstorming, or review notes, even if they don't name the pattern.
---

# greenroom

A per-project layout: a parent folder per project holding two sibling git repos. The public code sits on one side (the stage) and the private notes on the other (the green room you prep in before you go on).

## The pattern

```
~/GitHub/<project>/                  # parent folder, NOT a git repo
├── AGENTS.md                        # wrapper orientation: read by any agent at launch
├── README.md                        # repo map for humans and agents (auto-managed by sync)
├── <project>.code-workspace         # canonical editor entry point
├── <project>-public/                # public code repo (the thing on GitHub: the stage)
│   ├── AGENTS.md                    # per-repo orientation (nested / nearest-file semantic)
│   ├── CLAUDE.md                    # Claude adapter: exactly "@AGENTS.md" (git-excluded)
│   ├── .claude/settings.local.json  # Claude safety-net grant for sibling repos (git-excluded)
│   └── .gemini/settings.json        # Gemini adapter: points contextFileName at AGENTS.md (git-excluded)
├── <project>-private/               # private notes repo (separate private GitHub repo: the green room)
│   ├── AGENTS.md                    # per-repo private orientation
│   ├── CLAUDE.md                    # Claude adapter: exactly "@AGENTS.md"
│   ├── README.md
│   ├── docs/      # design docs, RFCs, ADR drafts
│   ├── notes/     # dated working notes
│   ├── drafts/    # PR/issue/blog drafts
│   ├── reviews/   # private notes on PRs
│   └── research/  # transcripts, links, experiments
├── <project>-public-fork/           # (optional) your fork: push branches, open PRs from here
└── <any-other-repo>/                # (optional) any git repo dropped under the wrapper
```

The parent folder itself has no `.git/`: it's just an organizational container so that one `cd ~/GitHub/<project>/` puts every part of the project in front of you. The wrapper holds **two fixed repos** (`-public`, `-private`) plus **any number of optional ones**: a `-public-fork` to PR from, a `-private-fork`, more clones. Every git repo directly under the wrapper is auto-discovered and added to the workspace; `/greenroom-sync` picks up new ones.

### Agent orientation: AGENTS.md

`AGENTS.md` is the cross-agent instructions standard, read natively by 25+ agents including Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp, Google Jules, Devin, and VS Code. greenroom writes:

- **Wrapper `AGENTS.md`**: orientation for any agent launched at the wrapper: the repo map, the launch rule, and the layout.
- **Per-repo `AGENTS.md`**: per-repo conventions, loaded via nested / nearest-file semantics as the agent touches files in that repo.

Agents that read `AGENTS.md` natively need no extra config. Two adapters wire the agents that need a pointer:

- **Claude Code**: Claude reads `CLAUDE.md`, not `AGENTS.md`. greenroom writes a `CLAUDE.md` containing exactly `@AGENTS.md` (an `@`-import, the Anthropic-documented bridge). The `@`-import resolves to the sibling `AGENTS.md` in the same directory. A `.claude/settings.local.json` grant is also written per-repo as a safety net for stray in-repo launches.
- **Gemini CLI**: greenroom writes `.gemini/settings.json` with `{"context": {"fileName": "AGENTS.md"}}` so Gemini reads `AGENTS.md` instead of its default context file.

**Access for all agents comes from wrapper-launch.** When an agent starts at the wrapper, every child repo is under cwd and reachable. The per-agent grant files are safety nets only, for a stray launch inside a single repo. The neutral core writes no access config; only the Claude and Gemini adapters write theirs.

The private dir is named `<project>-private/` (not just `private/`) so tools that infer project identity from the directory name (git remotes, agent session reporting, IDE workspace labels) see a unique, project-scoped name. Legacy projects with a plain `private/` dir keep working: the script and `collect` subcommand recognize both names. Migrate by renaming the directory and updating the `<project>.code-workspace` file (folder name + path).

A VS Code multi-root workspace file (`<project>.code-workspace`) sits at the wrapper root and is the canonical entry point for editor work. See "VS Code workspace" below.

## Slash commands

- **`/greenroom-new <name> [--clone <url> | --init-public] [--parent <dir>]`**: create a new project from scratch. Optionally clone an existing public repo into it, init an empty public repo, or leave the public dir for the user to populate later.
- **`/greenroom-add <path-to-existing-public-repo>`**: take an existing public repo (e.g. `~/GitHub/foo/`) and add the greenroom layout around it. Moves the public repo into a new parent folder as `<name>-public/` and scaffolds `<name>-private/` alongside.
- **`/greenroom-sync [--wrapper <dir>] [--canonical <repo-dir>]`**: re-scan an existing wrapper and update the workspace, agent working-dir access, and repo map. Run it after dropping a new repo (a `-public-fork`, another clone) under the wrapper so it gets wired in. Detects the wrapper from cwd; works from inside any of the project's repos.

`/greenroom-new` and `/greenroom-add` invoke the script's `new` and `retrofit` subcommands; both accept `--public-name` and `--private-name` overrides if the defaults don't fit, otherwise the canonical names are derived from the project name. `/greenroom-sync` invokes the `sync` subcommand. All three regenerate the workspace + wiring (see "VS Code workspace" below).

The command definitions are vendored in `commands/` and symlinked into `~/.claude/commands/` by the repo's `install.sh`, so they stay versioned alongside the skill rather than drifting as loose user-config files.

### `--with-private-fork`

Both `/greenroom-new` and `/greenroom-add` accept `--with-private-fork`. Pass it to also scaffold a `<project>-private-fork/` sibling. The script clones the local `<project>-public` repo into it using `git clone -o upstream`, so the remote is named `upstream`, not `origin`. This leaves `origin` free for a private GitHub remote. The fork is auto-discovered as a workspace root and granted sibling access by the next `sync`.

When this flag is used, the script prints `gh repo create --private` commands for the new private repos (including the fork). The agent relays these verbatim and runs them on your explicit yes. Nothing reaches GitHub without that confirmation.

Use this when the project needs a dedicated private dev checkout separate from the public repo. The three-repo shape is: `<project>-public` (the stage), `<project>-private-fork` (private dev work, pushed up into public when ready), and `<project>-private` (the green room for design docs and notes). greenroom scaffolds and wires all three; it never moves code or pushes anything. Because the fork is local, the public-is-upstream relationship needs no special handling: there is no PR direction asserted.

### Collecting docs from public history

Once the layout is in place, `greenroom.py collect` recovers private-shaped files that were committed to the public repo and copies them into the right `<project>-private/<bucket>/`. Run from **inside the public repo** (`--public` defaults to cwd, which must be a git repo); the sibling private dir is auto-detected. Pass `--public`/`--private` to run from elsewhere.

```bash
cd <wrapper>/<project>-public
~/.claude/skills/greenroom/scripts/greenroom.py collect            # dry-run, prints plan
~/.claude/skills/greenroom/scripts/greenroom.py collect --apply    # copy files into <project>-private/
```

**Copy-only.** Files are read from git at the chosen commit SHA and written into `<project>-private/<bucket>/`. Public history is never rewritten. Removing the originals from public history requires `git filter-repo` and is intentionally out of scope.

Sources scanned:

1. **Default branch (`main`/`master`)**: files matching the path-rule list (e.g. `docs/design/**`, `docs/architecture.md`, `**/rfc-*.md`). Docs that landed on main and probably shouldn't have.
2. **Unmerged branches whose names start with a private prefix**: `design/`, `notes/`, `drafts/`, `private/`. Files reachable from those branches but absent from the default branch get pulled in. The branch-name convention is the retroactive signal: these prefixes mark branches that hold private-bound work, so anything on them that never reached main is a candidate. Override with repeated `--branch-prefix` flags.

Classification is rules-only: path/filename maps to bucket (`docs`, `notes`, `drafts`, `reviews`, `research`). Files on a private-prefix branch with no matching rule fall back to `docs/`. Notes get a `YYYY-MM-DD-` filename prefix from the file's last-commit date unless they're already date-prefixed.

Same path on multiple branches → keep the **latest version** by commit date.

After `--apply`, review `git -C <wrapper>/<project>-private status` and commit when ready. Provenance lives in that commit's message, not in sidecar manifests.

## When to use which

| User situation | Command |
|---|---|
| Existing public repo at `~/GitHub/<name>/`, want to add private notes | `/greenroom-add ~/GitHub/<name>` |
| Starting a new project, want to clone an existing public repo into it | `/greenroom-new <name> --clone <git-url>` |
| Starting a new project, public repo doesn't exist yet | `/greenroom-new <name> --init-public` |
| Already laid out, just want to (re-)create the private dir alongside an existing public dir | `/greenroom-add ~/GitHub/<name>/<name>-public` (re-runs are idempotent: detect the existing layout, add only the missing private dir). Point at the `-public` dir, not the wrapper: after the first run the wrapper is no longer a git repo, so the original path would be rejected. |
| Dropped a new repo (fork, extra clone) under an existing wrapper and want it wired into the workspace | `/greenroom-sync` from inside any of the project's repos |

## What the script does NOT do (and why)

- **Does not push.** Both repos stay local until you push them. Avoids accidental publication and lets you review before committing.
- **Does not commit anything in the public repo.** The only thing it writes there is `.claude/settings.local.json` (grants Claude the sibling repos), and that file is added to `.git/info/exclude`, so it never appears in `git status` or reaches a commit.
- **Does not edit Claude Code plugin configs.** If the public repo is registered as a Claude Code plugin (in `~/.claude/plugins/known_marketplaces.json` or `~/.claude/settings.json`), the move breaks the registration. Those files are agent config and the harness blocks auto-edits. The script detects the mismatch and tells you exactly which files and what to change.
- **Does not create the private GitHub repo.** Run `gh repo create <your-account>/<name>-private --private --source=<parent>/<name>-private --remote=origin && git push -u origin main` yourself when ready.
- **Does not commit.** Leaves the private repo's initial files staged for review.

## Conventions encoded in the templates

The `<project>-private/AGENTS.md` written by the script tells any agent working there:
- This repo holds material under version control but never published.
- Reference public artifacts by GitHub URL (commit SHA, PR number). Never reference private-dir paths from public commits or PRs.
- Date-prefix working notes (`YYYY-MM-DD-topic.md`); leave design docs unprefixed.
- When a design doc matters enough to cite from a public PR, publish it (or a redacted copy) into the public repo's `docs/` and link there.
- The path itself is a small leak. Strip private-dir references when pasting into public artifacts.

## Edge cases the script handles

- **Parent-name collision** (existing repo already at `~/GitHub/<name>/`): moves the repo to a temp path, creates the parent, then moves the repo into the parent as `<name>-public/`. If the move fails partway, the repo is restored to its original location with no stranded temp path.
- **Working tree dirty**: refuses to retrofit if the public repo has uncommitted changes. Commit or stash first.
- **Parent already exists and non-empty**: refuses to overwrite. Manual cleanup required.
- **Idempotent re-runs**: if the source path is already inside its target parent structure, the script detects this and only adds the missing private dir (does not double-create). Recognizes both the canonical `<project>-private/` and legacy `private/` as already-existing.
- **Legacy `private/` dir**: if a wrapper already has a plain `private/` (from before the rename), retrofit leaves it where it is and prints a hint to rename it. To migrate, rename the directory (`mv private <project>-private`) and update the folder name and path in `<project>.code-workspace`.

## VS Code workspace

Every entry point (`new`, `retrofit`, `sync`) writes/refreshes a `<project>.code-workspace` file at the wrapper root. It's the canonical entry point for editor work. Never use `Open Folder` on the wrapper or on a repo directly.

**Auto-discovery.** The `folders` array is built by scanning the wrapper for git repos. Every immediate subdirectory containing `.git/` becomes a root, canonical first, the rest alphabetical. So a `-public-fork`, a `-private-fork`, or any other clone dropped under the wrapper shows up as its own root (with its own Source Control panel) on the next `sync`. Canonical = the `-public` repo (a `-public-fork` is the fallback); override with `--canonical`.

What the workspace file sets:

- **Anchors the Claude session cwd to the wrapper** via `terminal.integrated.cwd: ${workspaceFolder:<canonical>}/..`. New integrated terminals open rooted at the wrapper (the non-repo parent), not inside a sub-repo. This keeps Claude session history in one bucket: session bucketing is by launch cwd only, so anchoring to the wrapper prevents fragmentation across `-public`, `-private`, `-public-fork`, etc.
- **Provides a Tasks-based Claude launcher** (`Claude Code (<canonical>)`) via `Cmd+Shift+P → Tasks: Run Task`. It opens a dedicated terminal rooted at the wrapper and runs plain `claude`, with no `--add-dir` and no `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`. Because every child repo is under the wrapper cwd, the session has read/write access to all of them automatically, and each child repo's `AGENTS.md` (imported via the `CLAUDE.md` pointer) loads lazily the first time Claude touches files in that repo. Bind the task to a key in `~/.claude/keybindings.json` for one-shot launch.
- **Disables parent-folder repo scanning** (`git.openRepositoryInParentFolders: never`, `git.detectSubmodules: false`) so VS Code stops treating the wrapper dir as another repo.
- **Sets a window title** showing `<project>: <active folder>`.
- **Paints a per-project accent color** (`workbench.colorCustomizations` for the title/activity/status bars), with a hue derived from the project name so each open project's window is visually distinct.

**Merge-additive, not overwrite.** Re-running on an existing workspace only *adds* missing folder roots and missing default settings keys; it never overwrites a folder, setting, task, or hand-added customization. (`.code-workspace` is JSONC: if you've added `//` comments, stdlib JSON can't parse it, so the script leaves the file untouched and warns rather than risk clobbering it. Remove the comments to let `sync` manage it.)

### Granting Claude access to the sibling repos (Claude adapter)

A `.code-workspace` file has **no** Claude Code integration: listing N folders as roots makes them appear in VS Code's file tree, but Claude launched from one root gets read/edit access to **only that root**. The access is granted separately. The script writes `<canonical>/.claude/settings.local.json` listing each sibling repo:

```json
{ "permissions": { "additionalDirectories": ["../<project>-private", "../<project>-public-fork"] } }
```

This is the documented form: a list of sibling checkouts (`../<name>`), not an ancestor. **The primary access mechanism is the wrapper cwd**: when any agent launches at the wrapper, every child repo is under cwd and automatically reachable with no grant required. These per-repo grants are defense-in-depth for a stray `claude` launched *inside* a single repo; under a normal wrapper-rooted launch they are inert. `sync` re-enumerates the siblings, so adding a repo and re-running picks it up for both VS Code (a folder root) and every repo's grant in one step. The list is add-only: entries you add by hand are kept. `settings.local.json` is gitignored, and the script also adds it to `.git/info/exclude`, so the private-dir paths it names never land in the public repo's tracked files.

### Repo map for agents

The wrapper-root `README.md` carries an auto-managed map (inside `<!-- greenroom:begin -->` … `:end -->` markers): every repo, its inferred role, which one is canonical, and where to work. It lives at the wrapper root (never published, so it's safe to name private paths). It's the **human** entry point: `cd` into the wrapper and it's the first thing there. Agents launched at the wrapper get their orientation from the wrapper's own `AGENTS.md` (loaded at startup) and each child repo's `AGENTS.md` (loaded lazily as the agent touches files there). `sync` rewrites only the marked block, preserving anything around it; a hand-authored README with no markers is left alone.

How to open the project (every time):

1. From VS Code: `File → Open Workspace from File…` → `<wrapper>/<project>.code-workspace`. Or from terminal: `code <wrapper>/<project>.code-workspace`. Subsequent launches: pick `<project> (Workspace)` from "Recent."
2. Run the **`Claude Code (<canonical>)`** task (or open a terminal, which lands at the wrapper, and run `claude`, `codex`, `gemini`, or whichever agent you use). Session history goes to a single bucket; all child repos are reachable; each repo's `AGENTS.md` loads lazily.

## Aftercare checklist

After running the script, the model should remind the user to:

1. **Update Claude Code plugin paths** (if the script flagged any): manually edit the JSON files it named.
2. **Commit and push the private repo**:
   ```bash
   cd <parent>/<project>-private
   git add . && git commit -m "init: private notes for <project>"
   gh repo create <your-account>/<project>-private --private --source=. --remote=origin
   git push -u origin main
   ```
3. **Open VS Code via the new `<project>.code-workspace` file** (not via `Open Folder` on the wrapper or either repo). If a previous VS Code window had the old layout open, close it first.
4. **Update shell aliases** that hardcoded the old `~/GitHub/<name>/` path (now the parent folder, not the repo).
5. **One-time global hygiene** (only if not already done): add `.notes`, `NOTES.md`, `SCRATCH.md`, `*.private.md`, `.private/` to `~/.config/git/ignore` so private-flavored filenames can't accidentally land in public repos from a fresh clone.
