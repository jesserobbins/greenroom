# greenroom: design notes

Why the layout is shaped the way it is. This is the public, durable rationale; it's the kind of design doc greenroom itself tells you to publish into `docs/` once it's stable enough to cite.

## The problem

Your [superpowers](https://github.com/obra/Superpowers) docs, designs, plans, PRDs, and intermediate thinking are some of the most valuable context a project has, for humans and increasingly for coding agents. But checking them into a public repo feels vulnerable, and most of it doesn't belong in the shipped artifact anyway. The usual fallback is to scatter that thinking across notes apps, chat DMs, and untracked scratch files, where it can't be versioned, diffed, searched, or handed to an agent working in the repo.

greenroom's answer: keep the thinking under git, in a **private** repo that lives right next to the public one, so it has all the benefits of version control and agent-reachability while never riding along in a public push.

## Why two separate repos, not one

A few alternatives, and why they lose:

- **A `private/` subdirectory in the public repo, gitignored.** One `git add -f` or a misconfigured `.gitignore` and it's public. Ignored files also aren't versioned: you get a directory of untracked notes, which is the problem we started with.
- **A long-lived private branch in the public repo.** Branches share an origin; a single `git push --all` or a fork publishes everything. History is entangled, and a clone of the public repo can still contain the private commits.
- **One private repo for *all* projects' notes.** Loses the per-project locality: you can't `cd` into a project and have its notes right there, and agent session history doesn't line up with the code.

Two sibling repos under a non-git parent folder keeps the two histories completely independent (separate `.git/`, separate remotes, separate visibility) while keeping them physically adjacent. The public repo can be cloned, forked, and pushed with zero risk of dragging the private one along, because git has no idea the sibling exists.

## Why the parent folder has no `.git/`

The wrapper is an organizational container, not a repo. If it were a repo, you'd have a repo-of-repos (submodule territory) and tooling would get confused about which thing it's operating on. Keeping it inert means `cd ~/src/<project>/` is just "here is everything for this project," and each repo underneath is operated on independently.

## Why `<project>-private`, not `private`

A lot of tooling infers a project's identity from a directory's basename: git remote defaults, IDE window/workspace labels, and agent session-history bucketing. If every project's private dir is named `private/`, those tools collapse them all together. Naming it `<project>-private/` gives each one a unique, project-scoped identity. (Legacy plain `private/` dirs are still recognized by the script and by `collect`, so older layouts keep working.)

## Agent orientation: AGENTS.md

`AGENTS.md` is the cross-agent instructions standard, a "README for agents" read natively by 25+ tools including Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp, Google Jules, and Devin. Its nearest-file semantic maps cleanly onto greenroom's layout: the wrapper `AGENTS.md` loads when an agent launches at the wrapper, and each per-repo `AGENTS.md` loads as the agent touches files in that repo.

Two agents need a pointer to `AGENTS.md` because they read a different default file:

- **Claude Code** reads `CLAUDE.md`. greenroom writes a `CLAUDE.md` containing exactly `@AGENTS.md`, an `@`-import, the bridge prescribed in the Anthropic Claude Code docs. The import resolves to the sibling `AGENTS.md` in the same directory, with no external-path approval dialog.
- **Gemini CLI** is configured via `.gemini/settings.json` with `{"context": {"fileName": "AGENTS.md"}}`.

Every other agent reads `AGENTS.md` natively, so greenroom writes them no config: documented, not configured.

## Session-history bucketing and the wrapper launch home

Agents that bucket session history by launch directory (Claude Code is the primary example) fragment history across `-public`, `-private`, `-public-fork`, and so on when launched from inside individual repos.

greenroom makes the **wrapper directory** the launch home and anchors the editor's integrated-terminal cwd there (`terminal.integrated.cwd: ${workspaceFolder:<canonical>}/..`). New terminals open rooted at the wrapper regardless of which file is active, so sessions land in a single bucket. The canonical way to launch, on any agent, is `cd <wrapper> && <your-agent>`; because every repo sits under the wrapper, the session reaches all of them with no extra wiring, and each repo's `AGENTS.md` loads lazily the first time its files are touched.

## The access model

A `.code-workspace` file lists folders for *VS Code*; it grants any coding agent nothing. An agent launched *inside* one repo gets read/edit access to only that repo. The canonical launch is at the wrapper, where every repo is under cwd and reachable for every agent.

As a safety net for a stray in-repo launch of Claude specifically, greenroom writes:

- `<repo>/.claude/settings.local.json` (written into every repo) lists that repo's siblings under `permissions.additionalDirectories` as `../<name>`, the documented form (a list of sibling checkouts, not an ancestor like `..`, which would over-grant the whole parent).
- That file is gitignored *and* added to the repo's local `.git/info/exclude`, so the private paths it names never appear in the public repo's tracked files or `git status`.

Because the canonical launch is at the wrapper, this access model is a safety net: when any agent launches at the wrapper, every repo is already under cwd (read/write) and each repo's `AGENTS.md` loads lazily the first time its files are touched. The per-repo Claude grants matter only for a stray `claude` launch *inside* a single repo.

## `collect`: recovering docs already in public history

For repos that already committed private-shaped docs to the public history, `collect` recovers them into the private dir. Two design choices matter:

- **Copy-only, never rewrite.** Files are read from git at a specific commit SHA and written into the private dir. Public history is left exactly as it was. Actually scrubbing the public history is a `git filter-repo` operation with real blast radius, so it's intentionally out of scope. greenroom recovers the content; removing the originals is a deliberate, separate decision.
- **Rules-only classification.** Path/filename patterns map a file to a bucket (`docs`, `notes`, `drafts`, `reviews`, `research`). Two sources are scanned: the default branch (files matching private-shaped path rules) and unmerged branches whose names start with `design/`, `notes/`, `drafts/`, or `private/`, the branch-name prefix being a retroactive signal that the work was meant to stay private. The default is a dry run; nothing is copied until you pass `--apply`, so you review the plan first.

## The private fork model

`--with-private-fork` adds a third repo to the wrapper: `<project>-private-fork/`, cloned from the local `-public` with `git clone -o upstream`. Its remote is named `upstream` (not `origin`), leaving `origin` free for a private GitHub remote. The three-repo layout is: `-public` (the stage), `-private-fork` (private dev work, promoted to `-public` when ready), and `-private` (the green room for notes and design docs).

Private work flows up into the public repo through normal pull requests when it's ready. greenroom scaffolds and wires the layout; it never moves code, pushes, or asserts a PR direction. Because the fork is a local clone with `upstream` pointing at the local `-public`, the "you are the upstream" case needs no special handling.

The script prints `gh repo create --private` commands for any new private repos. The agent relays these verbatim and runs them on your explicit yes. Nothing reaches GitHub without that confirmation.

## Design principles

- **Idempotent and additive.** Re-running `new`/`retrofit`/`sync` only adds what's missing: new folder roots, new granted siblings, new map rows. It never overwrites a folder, setting, task, or hand-added customization. A workspace file with `//` JSONC comments is left untouched (stdlib JSON can't parse it) rather than risk clobbering it.
- **Never clobber what the user owns.** The installer refreshes its own symlinks but skips any real file already at the target path.
- **Fail safe.** A retrofit that has to move a repo in place moves it to a temp path first and restores it if any step fails, so a crash never strands the repo.
- **Don't touch what we can't safely own.** The script never pushes, never commits in the public repo, and never edits Claude Code plugin config (it detects a broken plugin path and tells you what to fix instead).
