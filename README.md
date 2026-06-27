# greenroom

> greenroom is a skill that sets up and maintains private spaces for working on your [superpowers](https://github.com/obra/Superpowers) docs, designs, plans, PRDs, and more until you decide what you want to share publicly.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## Why greenroom?

Writing your superpowers docs, designs, plans, and PRDs down generates rich context for both you, your team, and your agents. Checking that thinking into a *public* repo feels vulnerable and intimate for some. For me, it feels like [stepping on to a stage to perform](https://jesserobbins.com/mentions/velocity-2012-changing-culture-force-awesome-oreilly/)... and I only want to do that when I am prepared and ready. In the theatre and conferences, the **[Green Room](https://en.wikipedia.org/wiki/Green_room)** is the private space where performers prepare to take the stage.

greenroom keeps that work under git, in a **private** repo that sits right beside the public one. Two sibling repos under a single project folder: the polished code on one side (the stage), the raw thinking on the other (the green room). You do high-quality work in private, and the only thing that reaches the stage is the finished result.

```
~/src/<project>/                 # parent folder, not a git repo
├── AGENTS.md                   # orientation for any agent launched here
├── <project>-public/           # public code repo (the thing on GitHub: the stage)
└── <project>-private/          # private notes repo (a separate private GitHub repo: the green room)
    ├── AGENTS.md  # private-side orientation
    ├── docs/      # design docs, RFCs, ADR drafts
    ├── notes/     # dated working notes
    ├── drafts/    # PR/issue/blog drafts
    ├── reviews/   # private notes on PRs
    └── research/  # transcripts, links, experiments
```

The parent folder has no `.git/` of its own. It's an organizational container, so one `cd ~/src/<project>/` puts both halves of the project in front of you. greenroom wires any coding agent to reach both repos from a single session, and writes a VS Code workspace too when it detects a VS Code-family editor (see ["One entry point, any editor"](#one-entry-point-any-editor)).

## Different people work differently

Not everyone uses [superpowers](https://github.com/obra/Superpowers), or any agent-context tooling, the same way. Some people are happy to commit their docs, plans, and scratch right into the main repo and think out loud in the open. That's a perfectly good way to work, and if it's yours, you may not need greenroom at all.

But plenty of us don't want our half-formed thinking, working notes, and scratch living in public. For me that's *especially* true when contributing to open source projects: a public repo is a shared, permanent, forkable record, and not every draft, design dead-end, or private review note belongs in it. Wanting to keep that material private isn't a lack of openness, it's wanting to choose, deliberately, what reaches the stage and when.

greenroom exists for that preference. It doesn't change how the public repo works or push any opinion onto your collaborators; it just gives the private thinking a versioned home of its own, right next to the code, so keeping it private is the easy default rather than a thing you have to remember to do.

## Install

**Requirements:** macOS or Linux (Windows is supported via WSL2, which presents a Linux environment). You need Python 3 and `git` on your `PATH`; the manual install also needs `bash`. greenroom uses POSIX paths and `$HOME` semantics, so native Windows (cmd/PowerShell) is not supported, and the script refuses to run there.

### As a Claude Code plugin (recommended)

```
/plugin marketplace add jesserobbins/greenroom
/plugin install greenroom@jesserobbins
```

That registers the skill and the `/greenroom:*` slash commands (`/greenroom:new`, `/greenroom:add`, `/greenroom:sync`).

### Manual (git clone)

```
git clone https://github.com/jesserobbins/greenroom.git
cd greenroom
./install.sh
```

`install.sh` symlinks the skill into `~/.claude/skills/greenroom-setup` (namespaced so it invokes as `/greenroom-setup`, not a generic `/setup`) and the slash commands into `~/.claude/commands/`. It also creates `~/.claude/skills/greenroom/` as a plain directory holding `scripts/` and `templates/` symlinks, so the commands' script-path fallback and the `collect` examples below resolve `greenroom.py`. It's idempotent and never clobbers a real file you own.

A manual install registers the commands without the plugin namespace, so the examples below that read `/greenroom:new`, `/greenroom:add`, and `/greenroom:sync` are invoked as `/new`, `/add`, and `/sync`. The plugin install is the recommended path and gives you the namespaced form.

## Quick start

Two commands cover the common cases.

**Add a green room to a repo you already have:**

```
cd <your-repo> && /greenroom:add        # operates on the current directory
/greenroom:add <path-to-repo>           # or point it at a path
```

The most common case is running it from inside a repo you've already cloned, so the path is optional and defaults to the current directory. It moves the existing repo into a new parent folder as `<name>-public/` and scaffolds `<name>-private/` next to it. Git history and the origin remote come along untouched. It works whether or not the parent holds other repos.

**Start a fresh project:**

```
/greenroom:new <name> --clone <git-url>     # clone an existing public repo into it
/greenroom:new <name> --init-public         # start an empty public repo
/greenroom:new <name>                        # leave the public side for later
```

Add `--with-private-fork` to either command and the script also scaffolds a `<name>-private-fork/` alongside: a private dev checkout cloned from the local `-public` repo, with its remote named `upstream` so `origin` stays free for a private GitHub repo. The full three-repo shape is `<name>-public` (the stage), `<name>-private-fork` (private dev), and `<name>-private` (the green room). Both commands run the same script (`scripts/greenroom.py`, subcommands `retrofit` and `new`) and accept `--public-name` / `--private-name` overrides when the defaults don't fit.

**Add more repos to a project later**, like a fork to PR from or another clone:

```
/greenroom:sync     # re-scans the wrapper, wires the new repo into the workspace
```

Drop the new repo directly under the wrapper, then run sync from inside any of the project's repos.

## Why a separate private repo

The private dir is `<project>-private/`, not a plain `private/`. Tools that read project identity from a directory name (git remotes, agent session reporting, IDE workspace labels) then see a unique, project-scoped name instead of a dozen folders all called `private`. Older `private/` dirs keep working: the script and `collect` recognize both.

Keeping it under git, not in a notes app, means your design thinking is versioned, diffable, greppable, and reachable by your coding agent in the same session as the code. Keeping it in a *separate* repo means it never rides along in a `git push` of the public one.

## One entry point, any editor

The one rule is **launch your agent at the wrapper**: `cd <project> && <your-agent>` from any terminal. Examples:

```
cd ~/src/<project> && claude    # Claude Code
cd ~/src/<project> && codex     # OpenAI Codex
cd ~/src/<project> && gemini    # Gemini CLI
```

Because every repo sits under the wrapper, the session can read and edit all of them with no extra wiring. Each repo's `AGENTS.md` loads automatically as the agent touches its files. Launching at the wrapper also keeps your session history in one bucket instead of fragmenting across `-public`, `-private`, and the rest.

greenroom produces `AGENTS.md` as its orientation standard. It is natively read by 25+ agents, including Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp, Google Jules, Devin, and VS Code. Claude Code reads `CLAUDE.md`, so greenroom writes a thin `CLAUDE.md` pointer (`@AGENTS.md`) that imports the same file. Gemini CLI is wired via `.gemini/settings.json`. Every other agent reads `AGENTS.md` natively with no extra config.

VS Code rides on top of that same wrapper rule — but only if you use it. When a VS Code-family editor is detected (`code`, `cursor`, `codium`/`vscodium`, or `windsurf` on your `PATH`, or an existing `.vscode/` or `*.code-workspace` in the wrapper), the script writes a `<project>.code-workspace` at the parent root that scans the wrapper and lists every repo it finds as a root, each with its own Source Control panel, canonical repo first. New terminals anchor to the wrapper, the **Claude Code** task launches `claude` there for you, and each project gets a title-bar color derived from its name so two open projects never look alike. Force or skip the file regardless of detection with `--workspace` / `--no-workspace`. Wrapper identity itself lives in an editor-neutral `.greenroom` marker at the wrapper root, so the workspace file is never required — a terminal-only setup gets none. Prefer a bare shell? A one-line alias does the same job:

```
gr() { cd ~/src/"$1" && claude; }   # or: codex, gemini, aider, …
```

As a safety net for a stray launch *inside* one repo, the script also writes a git-excluded `.claude/settings.local.json` into each repo granting its siblings (`../<name>`), so even then the others stay reachable. Those private paths never reach the public repo.

**Optional boundary.** Set `GREENROOM_ROOT` (e.g. `export GREENROOM_ROOT="$HOME/GitHub"`) to the directory your projects live under. greenroom then operates only at or below it and refuses to scaffold at or above it. It is a safety boundary, not a target: greenroom works fine without it, and it never treats `$HOME`, the filesystem root, or standard system directories (`~/Documents`, `~/Desktop`, and the like) as a wrapper regardless of any signal they carry.

## Recovering docs already in public history

If design docs or notes already landed in the public repo, `collect` pulls them back into the private dir. Run it from inside the public repo. The script path below assumes a manual `install.sh` install; on a plugin install the script lives under `~/.claude/plugins/` instead, so prefer the `/greenroom:*` slash commands or substitute that path:

```
cd <parent>/<project>-public
~/.claude/skills/greenroom/scripts/greenroom.py collect          # dry-run, prints the plan
~/.claude/skills/greenroom/scripts/greenroom.py collect --apply  # copy into <project>-private/
```

It scans two sources: files on the default branch that match private-shaped path rules (`docs/design/**`, `**/architecture.md`, `**/rfc-*.md`, and the like), and files reachable from unmerged branches whose names start with `design/`, `notes/`, `drafts/`, or `private/`. It reads each file from git history and writes a copy into the private dir. Public history is never rewritten. Review the plan, then re-run with `--apply` and commit when you are ready.

## Tests

`tests/smoke.sh` builds throwaway repos in a temp dir and exercises the script's reliability-critical paths: retrofit when the parent already holds other repos, `collect` classification of files at the repo root, crash-safe restore when an in-place move fails, component-boundary matching in the plugin-config check, the full `sync` wiring (workspace, access, and map), the AGENTS.md core plus the Claude and Gemini adapters, and the `--with-private-fork` scaffold. It also covers the wrapper-safety guards: refusing `$HOME` and other forbidden roots as scaffold targets, the `GREENROOM_ROOT` boundary, the workspace sentinel, the `.greenroom` identity marker (including that a stray marker in a forbidden dir is still refused), the conditional workspace write and its `--workspace`/`--no-workspace` flags, and the namespaced manual install. Run it directly:

```
tests/smoke.sh
```

## See also

greenroom was built using greenroom: this repo is the stage, and the drafts, design notes, and launch thinking behind it live in a private green room right next to it. Nothing from there ships, which is the whole point.

`skills/greenroom-setup/SKILL.md` carries the full conventions, edge cases, and the agent-facing instructions. The slash-command definitions live in `commands/`. Design notes on why the layout is shaped this way are in [`docs/design.md`](docs/design.md).

## License

[Apache 2.0](LICENSE) © [Jesse Robbins](https://jesserobbins.com)
