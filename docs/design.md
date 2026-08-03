# greenroom: design notes

Why the layout is shaped the way it is. This is the public, durable rationale; it's the kind of design doc greenroom itself tells you to publish into `docs/` once it's stable enough to cite.

## The problem

Your [superpowers](https://github.com/obra/Superpowers) docs, designs, plans, PRDs, and intermediate thinking are some of the most valuable context a project has. This is true for humans, and increasingly for coding agents. But checking them into a public repo feels vulnerable, and most of that material does not belong in the shipped artifact anyway.

The usual fallback is to scatter that thinking across notes apps, chat DMs, and untracked scratch files. There you cannot version it, diff it, search it, or hand it to an agent that works in the repo.

greenroom's answer: keep the thinking under git, in a **private** repo that lives right next to the public one. It then has all the benefits of version control and agent-reachability. It never rides along in a public push.

## Why two separate repos, not one

A few alternatives, and why they lose:

- **A gitignored `private/` subdirectory in the public repo.** One `git add -f`, or one misconfigured `.gitignore`, and the notes are public. Ignored files are also not versioned. You get a directory of untracked notes, which is the problem we started with.
- **A long-lived private branch in the public repo.** Branches share an origin. A single `git push --all`, or a fork, publishes everything. The history is entangled, and a clone of the public repo can still hold the private commits.
- **One private repo for *all* projects' notes.** This loses the per-project locality. You cannot `cd` into a project and find its notes right there, and the agent session history does not line up with the code.

Two sibling repos under a non-git parent folder keep the two histories independent: separate `.git/`, separate remotes, separate visibility. The repos stay physically adjacent. You can clone, fork, and push the public repo with no risk of dragging the private one along. Git does not know the sibling exists.

## Why the parent folder has no `.git/`

The wrapper is an organizational container, not a repo. If it were a repo, you would have a repo of repos, which is submodule territory. Tooling would then get confused about which repo it operates on. The wrapper stays inert instead. A `cd ~/src/<project>/` therefore means only "here is everything for this project", and you operate on each repo underneath independently.

## Why `<project>-private`, not `private`

A lot of tooling infers a project's identity from a directory's basename: git remote defaults, IDE window and workspace labels, and agent session-history bucketing. If every project's private repo sits in a directory named `private/`, those tools collapse them all together. The name `<project>-private/` gives each one a unique, project-scoped identity. The script and `collect` still recognize a legacy plain `private/` dir, so older layouts keep working.

## Agent orientation: AGENTS.md

`AGENTS.md` is the cross-agent instructions standard, a "README for agents". More than 25 tools read it natively, among them Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp, Google Jules, and Devin. Its nearest-file semantic maps cleanly onto greenroom's layout. The wrapper `AGENTS.md` loads when an agent launches at the wrapper. Each per-repo `AGENTS.md` loads as the agent touches files in that repo.

Two agents need a pointer to `AGENTS.md`, because they read a different default file:

- **Claude Code** reads `CLAUDE.md`. greenroom writes a `CLAUDE.md` that holds exactly `@AGENTS.md`. This is an `@`-import, the bridge the Anthropic Claude Code docs prescribe. The import resolves to the sibling `AGENTS.md` in the same directory, with no external-path approval dialog.
- **Gemini CLI** is configured through `.gemini/settings.json`, with `{"context": {"fileName": "AGENTS.md"}}`.

Every other agent reads `AGENTS.md` natively, so greenroom writes them no config: documented, not configured.

## Session-history bucketing and the wrapper launch home

Some agents bucket session history by launch directory. Claude Code is the primary example. A launch from inside an individual repo then fragments the history across `-public`, `-private`, `-public-fork`, and the rest.

greenroom makes the **wrapper directory** the launch home. It anchors the editor's integrated-terminal cwd there, with `terminal.integrated.cwd: ${workspaceFolder:<canonical>}/..`. New terminals then open at the wrapper, regardless of which file is active, so sessions land in a single bucket.

The canonical way to launch, on any agent, is `cd <wrapper> && <your-agent>`. Every repo sits under the wrapper, so the session reaches all of them with no extra wiring. Each repo's `AGENTS.md` loads lazily, the first time its files are touched.

## The access model

A `.code-workspace` file lists folders for *VS Code*. It grants a coding agent nothing. An agent launched *inside* one repo gets read and edit access to that repo only. The canonical launch is at the wrapper, where every repo is under cwd and reachable for every agent.

As a safety net for a stray in-repo launch of Claude specifically, greenroom writes:

- `<repo>/.claude/settings.local.json`, into every repo. It lists that repo's siblings under `permissions.additionalDirectories`, as `../<name>`. This is the documented form: a list of sibling checkouts, not an ancestor such as `..`. An ancestor would over-grant the whole parent.
- That file is gitignored. greenroom also adds it to the repo's local `.git/info/exclude`. The private paths it names therefore never appear in the public repo's tracked files, or in `git status`.

The canonical launch is at the wrapper, so this access model is a safety net. When any agent launches at the wrapper, every repo is already under cwd, with read and write access. Each repo's `AGENTS.md` loads lazily, the first time its files are touched. The per-repo Claude grants matter only for a stray `claude` launch *inside* a single repo.

## `collect`: recovering docs already in public history

Some repos already committed private-shaped docs to their public history. For those, `collect` recovers the docs into the private repo. Two design choices matter:

- **Copy-only, never rewrite.** greenroom reads each file from git at a specific commit SHA and writes it into the private repo. It leaves public history exactly as it was. To scrub the public history you need `git filter-repo`, which has a real blast radius, so it is out of scope on purpose. greenroom recovers the content. Removal of the originals is a deliberate, separate decision.
- **Rules-only classification.** Path and filename patterns map a file to a bucket: `docs`, `notes`, `drafts`, `reviews`, or `research`. greenroom scans two sources. The first is the default branch, for files that match private-shaped path rules. The second is the unmerged branches whose names start with `design/`, `notes/`, `drafts/`, or `private/`. That branch-name prefix is a retroactive signal that the work was meant to stay private. The default is a dry run. greenroom copies nothing until you pass `--apply`, so you read the plan first.

## The private fork model

`--with-private-fork` adds a third repo to the wrapper: `<project>-private-fork/`. greenroom clones it from the local `-public` repo with `git clone -o upstream`. Its remote is named `upstream`, not `origin`, which leaves `origin` free for a private GitHub remote. The three-repo layout is `-public` (the stage), `-private-fork` (private dev work, promoted to `-public` when ready), and `-private` (the green room for notes and design docs).

Private work flows up into the public repo through normal pull requests, when it is ready. greenroom scaffolds and wires the layout. It never moves code, never pushes, and never asserts a PR direction. The fork is a local clone whose `upstream` points at the local `-public` repo, so the "you are the upstream" case needs no special handling.

The script prints `gh repo create --private` commands for any new private repos. The agent relays these verbatim and runs them on your explicit yes. Nothing reaches GitHub without that confirmation.

## Design principles

- **Idempotent and additive.** A re-run of `new`, `retrofit`, or `sync` adds only what is missing: new folder roots, new granted siblings, new map rows. It never overwrites a folder, a setting, a task, or a customization added by hand. The stdlib JSON parser cannot read a workspace file with `//` JSONC comments, so greenroom leaves that file untouched rather than risk overwriting it.
- **Never overwrite what the user owns.** The installer refreshes its own symlinks. It skips any real file already at the target path.
- **Fail safe.** A retrofit that must move a repo in place moves it to a temp path first. If any step fails, it restores the repo. A crash therefore never strands the repo.
- **Do not touch what we cannot safely own.** The script never pushes, never commits in the public repo, and never edits Claude Code plugin config. It detects a broken plugin path and tells you what to fix instead.
