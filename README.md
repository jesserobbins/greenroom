# greenroom

> greenroom is a skill that sets up and maintains private spaces for working on your [superpowers](https://github.com/obra/Superpowers) docs, designs, plans, PRDs, and more until you decide what you want to share publicly.

[![skills.sh](https://skills.sh/b/jesserobbins/greenroom)](https://skills.sh/jesserobbins/greenroom)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

```bash
npx skills add jesserobbins/greenroom
```

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

The parent folder has no `.git/` of its own. It is an organizational container, so one `cd ~/src/<project>/` puts both halves of the project in front of you. greenroom wires any coding agent to reach both repos from a single session. It also writes a VS Code workspace when it detects a VS Code-family editor. See ["One entry point, any editor"](#one-entry-point-any-editor).

## Install

**Requirements:** macOS or Linux. Windows is supported through WSL2, which presents a Linux environment. You need Python 3 and `git` on your `PATH`. The standalone skill install also needs Node, for `npx`. The manual install needs `bash`. greenroom uses POSIX paths and `$HOME` semantics, so native Windows (cmd and PowerShell) is not supported. The script refuses to run there.

There are two ways to install, with two different philosophies. A manual `git clone` follows them, for work on greenroom itself.

- **[skills.sh](https://skills.sh/jesserobbins/greenroom)** copies greenroom into your project. Pass `-g` to install it globally instead. You can then edit that copy and make it your own. It works on Claude Code, Codex, Cursor, and the 70+ other agents that the skills CLI supports.
- **The Claude Code plugin** keeps greenroom as a read-only bundle that you do not edit and that stays current. It also adds the `/greenroom:*` slash commands. Use it when you want greenroom to work as shipped, and to follow greenroom as it changes.

### As a standalone skill (any agent)

```bash
npx skills add jesserobbins/greenroom
```

The install copies the whole skill directory: `SKILL.md`, the script, and the templates. greenroom then works with no other setup. Invoke it as `/greenroom`, or describe what you want.

### As a Claude Code plugin (recommended for Claude Code)

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

`install.sh` symlinks the skill into `~/.claude/skills/greenroom` and the slash commands into `~/.claude/commands/`. The skill directory carries its own `scripts/` and `templates/`, so nothing else needs to be wired. The installer is idempotent. It never overwrites a real file that you own, and it cleans up the layout that earlier versions left.

A manual install registers the commands without the plugin namespace. The examples below read `/greenroom:new`, `/greenroom:add`, and `/greenroom:sync`. After a manual install, invoke them as `/new`, `/add`, and `/sync`. The plugin install is the recommended path, and it gives you the namespaced form.

## Quick start

Two commands cover the common cases.

**Add a green room to a repo you already have:**

```
cd <your-repo> && /greenroom:add        # operates on the current directory
/greenroom:add <path-to-repo>           # or point it at a path
```

The most common case is a run from inside a repo that you already cloned. The path is therefore optional, and it defaults to the current directory. The command moves the existing repo into a new parent folder as `<name>-public/`. It then scaffolds `<name>-private/` next to it. The git history and the origin remote come along untouched. The command works whether or not the parent folder holds other repos.

**Start a fresh project:**

```
/greenroom:new <name> --clone <git-url>     # clone an existing public repo into it
/greenroom:new <name> --init-public         # start an empty public repo
/greenroom:new <name>                        # leave the public side for later
```

Add `--with-private-fork` to either command. The script then also scaffolds a `<name>-private-fork/` beside the others. It is a private dev checkout, cloned from the local `-public` repo. Its remote is named `upstream`, so `origin` stays free for a private GitHub repo. The full three-repo shape is `<name>-public` (the stage), `<name>-private-fork` (private dev), and `<name>-private` (the green room).

Both commands run the same script, `skills/greenroom/scripts/greenroom.py`, through its `retrofit` and `new` subcommands. If the default names do not fit, pass `--public-name` or `--private-name`.

**Add more repos to a project later**, like a fork to PR from or another clone:

```
/greenroom:sync     # re-scans the wrapper, wires the new repo into the workspace
```

Drop the new repo directly under the wrapper, then run sync from inside any of the project's repos.

## Why a separate private repo

The private repo's directory is `<project>-private/`, not a plain `private/`. Some tools read project identity from a directory name: git remotes, agent session reporting, and IDE workspace labels. Those tools then see a unique, project-scoped name, instead of a dozen folders all called `private`. Older `private/` dirs keep working, because the script and `collect` recognize both names.

The notes stay under git, not in a notes app. Your design thinking is therefore versioned, diffable, greppable, and reachable by your coding agent in the same session as the code. The notes also stay in a *separate* repo, so they never ride along in a `git push` of the public one.

## One entry point, any editor

The one rule is **launch your agent at the wrapper**: `cd <project> && <your-agent>` from any terminal. Examples:

```
cd ~/src/<project> && claude    # Claude Code
cd ~/src/<project> && codex     # OpenAI Codex
cd ~/src/<project> && gemini    # Gemini CLI
```

Every repo sits under the wrapper, so the session can read and edit all of them with no extra wiring. Each repo's `AGENTS.md` loads as the agent touches its files. A launch at the wrapper also keeps your session history in one bucket. It does not fragment across `-public`, `-private`, and the rest.

greenroom produces `AGENTS.md` as its orientation standard. More than 25 agents read it natively, among them Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp, Google Jules, Devin, and VS Code. Claude Code reads `CLAUDE.md`, so greenroom writes a thin `CLAUDE.md` pointer (`@AGENTS.md`) that imports the same file. greenroom wires Gemini CLI through `.gemini/settings.json`. Every other agent reads `AGENTS.md` natively, with no other config.

VS Code rides on top of that same wrapper rule, but only if you use it. The script writes a `<project>.code-workspace` file at the parent root when it detects a VS Code-family editor. The signals are `code`, `cursor`, `codium`/`vscodium`, or `windsurf` on your `PATH`, or an existing `.vscode/` or `*.code-workspace` in the wrapper.

That file scans the wrapper and lists every repo it finds as a root, canonical repo first, each with its own Source Control panel. New terminals anchor to the wrapper. The **Claude Code** task launches `claude` there for you. Each project gets a title-bar color derived from its name, so two open projects never look alike.

To force or skip the file regardless of detection, pass `--workspace` or `--no-workspace`. Wrapper identity itself lives in an editor-neutral `.greenroom` marker at the wrapper root, so the workspace file is never required. A terminal-only setup gets none. If you prefer a bare shell, a one-line alias does the same job:

```
gr() { cd ~/src/"$1" && claude; }   # or: codex, gemini, aider, …
```

The script also writes a git-excluded `.claude/settings.local.json` into each repo, which grants that repo's siblings (`../<name>`). This is a safety net for a stray launch *inside* one repo: even then, the other repos stay reachable. Those private paths never reach the public repo.

**Optional boundary.** Set `GREENROOM_ROOT` to the directory your projects live under, for example `export GREENROOM_ROOT="$HOME/GitHub"`. greenroom then operates only at or below that directory, and refuses to scaffold at or above it. It is a safety boundary, not a target. greenroom works without it. greenroom also never treats `$HOME`, the filesystem root, or a standard system directory as a wrapper. `~/Documents` and `~/Desktop` are two such directories. This holds regardless of any signal they carry.

## Recovering docs already in public history

If design docs or notes already landed in the public repo, `collect` pulls them back into the private repo. Run it from inside the public repo. The script always sits inside the skill directory. The path below is where a manual install, or `npx skills add -g`, puts it. On a plugin install the script lives under `~/.claude/plugins/` instead. In that case, use the `/greenroom:*` slash commands, or substitute the plugin path:

```
cd <parent>/<project>-public
python3 ~/.claude/skills/greenroom/scripts/greenroom.py collect          # dry-run, prints the plan
python3 ~/.claude/skills/greenroom/scripts/greenroom.py collect --apply  # copy into <project>-private/
```

It scans two sources:

- Files on the default branch that match private-shaped path rules, such as `docs/design/**`, `**/architecture.md`, and `**/rfc-*.md`.
- Files reachable from unmerged branches whose names start with `design/`, `notes/`, `drafts/`, or `private/`.

It reads each file from git history and writes a copy into the private repo. It never rewrites public history. Read the plan first. Then re-run the command with `--apply`, and commit when you are ready.

## Tests

`tests/smoke.sh` builds throwaway repos in a temp dir. It exercises the script's reliability-critical paths:

- a retrofit when the parent already holds other repos
- `collect` classification of files at the repo root
- crash-safe restore when an in-place move fails
- component-boundary matching in the plugin-config check
- the full `sync` wiring: workspace, access, and map
- the `AGENTS.md` core, plus the Claude and Gemini adapters
- the `--with-private-fork` scaffold

It also covers the wrapper-safety guards:

- refusal of `$HOME` and the other forbidden roots as scaffold targets
- the `GREENROOM_ROOT` boundary
- the workspace sentinel
- the `.greenroom` identity marker, including that a stray marker in a forbidden dir is still refused
- the conditional workspace write, and its `--workspace` and `--no-workspace` flags

Last, it guards the distribution shape:

- that `skills/greenroom/` alone can scaffold, sync, and reach every reference it routes to
- that the skill stays inside its context budget, and relies on no plugin-only path variable
- that the slash commands stay hollow
- that the manual installer migrates its own old layouts, and touches no file, and no live symlink, that the user owns

The installer does claim a *dangling* link at the skill's own path. It claims that link only when the dead target still has our `skills/<name>` shape. An unmounted volume, or anything else, is left alone and reported. Run the tests directly:

```
tests/smoke.sh
```

## See also

greenroom was built using greenroom: this repo is the stage, and the drafts, design notes, and launch thinking behind it live in a private green room right next to it. Nothing from there ships, which is the whole point.

`skills/greenroom/SKILL.md` carries the agent-facing instructions. The detail is in `skills/greenroom/references/`. The script and the templates live inside that same directory, which is the entire installable payload. The slash-command definitions in `commands/` are thin triggers that hold no logic. The design notes on why the layout is shaped this way are in [`docs/design.md`](docs/design.md).

## License

[Apache 2.0](LICENSE) © [Jesse Robbins](https://jesserobbins.com)
