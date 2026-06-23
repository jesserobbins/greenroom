# greenroom

> greenroom is a skill that sets up and maintains a private space for working on docs, plans, and files until you decide what you want to share publicly.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Why greenroom?

Writing your plans, design docs, and half-formed thinking down generates rich context for both you and your agents. Checking that thinking into a *public* repo feels vulnerable and intimate, so most people don't. It ends up scattered across Notes apps, Slack DMs, and untracked scratch files, where it can't be versioned, searched, or handed to an agent.

greenroom keeps that work under git, in a **private** repo that sits right beside the public one. Two sibling repos under a single project folder: the polished code on one side (the stage), the raw thinking on the other (the green room). You do high-quality work in private, and the only thing that reaches the stage is the finished result.

```
~/GitHub/<project>/              # parent folder, not a git repo
├── AGENTS.md                   # orientation for any agent launched here
├── <project>-public/           # public code repo (the thing on GitHub: the stage)
└── <project>-private/          # private notes repo (a separate private GitHub repo: the green room)
    ├── AGENTS.md  # private-side orientation
    ├── design/    # design docs, RFCs, ADR drafts
    ├── notes/     # dated working notes
    ├── drafts/    # PR/issue/blog drafts
    ├── reviews/   # private notes on PRs
    └── research/  # transcripts, links, experiments
```

The parent folder has no `.git/` of its own. It's an organizational container, so one `cd ~/GitHub/<project>/` puts both halves of the project in front of you. greenroom also writes a VS Code workspace and wires any coding agent to reach both repos from a single session (see ["One entry point, any editor"](#one-entry-point-any-editor)).

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add jesserobbins/greenroom
/plugin install greenroom@jesserobbins
```

That registers the skill and the `/greenroom-*` slash commands.

### Manual (git clone)

```
git clone https://github.com/jesserobbins/greenroom.git
cd greenroom
./install.sh
```

`install.sh` symlinks the skill into `~/.claude/skills/greenroom` and the slash commands into `~/.claude/commands/`. It's idempotent and never clobbers a real file you own.

## Quick start

Two commands cover the common cases.

**Add a green room to a repo you already have:**

```
/greenroom-add ~/GitHub/<name>
```

This moves the existing repo into a new parent folder as `<name>-public/` and scaffolds `<name>-private/` next to it. Git history and the origin remote come along untouched. It works whether or not `~/GitHub` holds other repos.

**Start a fresh project:**

```
/greenroom-new <name> --clone <git-url>     # clone an existing public repo into it
/greenroom-new <name> --init-public         # start an empty public repo
/greenroom-new <name>                        # leave the public side for later
```

Add `--with-private-fork` to either command and the script also scaffolds a `<name>-private-fork/` alongside: a private dev checkout cloned from the local `-public` repo, with its remote named `upstream` so `origin` stays free for a private GitHub repo. The full three-repo shape is `<name>-public` (the stage), `<name>-private-fork` (private dev), and `<name>-private` (the green room). Both commands run the same script (`scripts/greenroom.py`, subcommands `retrofit` and `new`) and accept `--public-name` / `--private-name` overrides when the defaults don't fit.

**Add more repos to a project later**, like a fork to PR from or another clone:

```
/greenroom-sync     # re-scans the wrapper, wires the new repo into the workspace
```

Drop the new repo directly under the wrapper, then run sync from inside any of the project's repos.

## Why a separate private repo

The private dir is `<project>-private/`, not a plain `private/`. Tools that read project identity from a directory name (git remotes, agent session reporting, IDE workspace labels) then see a unique, project-scoped name instead of a dozen folders all called `private`. Older `private/` dirs keep working: the script and `collect` recognize both.

Keeping it under git, not in a notes app, means your design thinking is versioned, diffable, greppable, and reachable by your coding agent in the same session as the code. Keeping it in a *separate* repo means it never rides along in a `git push` of the public one.

## One entry point, any editor

The one rule is **launch your agent at the wrapper**: `cd <project> && <your-agent>` from any terminal. Examples:

```
cd ~/GitHub/<project> && claude    # Claude Code
cd ~/GitHub/<project> && codex     # OpenAI Codex
cd ~/GitHub/<project> && gemini    # Gemini CLI
```

Because every repo sits under the wrapper, the session can read and edit all of them with no extra wiring. Each repo's `AGENTS.md` loads automatically as the agent touches its files. Launching at the wrapper also keeps your session history in one bucket instead of fragmenting across `-public`, `-private`, and the rest.

greenroom produces `AGENTS.md` as its orientation standard. It is natively read by 25+ agents, including Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp, Google Jules, Devin, and VS Code. Claude Code reads `CLAUDE.md`, so greenroom writes a thin `CLAUDE.md` pointer (`@AGENTS.md`) that imports the same file. Gemini CLI is wired via `.gemini/settings.json`. Every other agent reads `AGENTS.md` natively with no extra config.

VS Code rides on top of that same wrapper rule. The script writes a `<project>.code-workspace` at the parent root that scans the wrapper and lists every repo it finds as a root, each with its own Source Control panel, canonical repo first. New terminals anchor to the wrapper, the **Claude Code** task launches `claude` there for you, and each project gets a title-bar color derived from its name so two open projects never look alike. Prefer a bare shell? A one-line alias does the same job:

```
gr() { cd ~/GitHub/"$1" && claude; }   # or: codex, gemini, aider, …
```

As a safety net for a stray launch *inside* one repo, the script also writes a git-excluded `.claude/settings.local.json` into each repo granting its siblings (`../<name>`), so even then the others stay reachable. Those private paths never reach the public repo.

## Recovering docs already in public history

If design docs or notes already landed in the public repo, `collect` pulls them back into the private dir. Run it from inside the public repo:

```
cd <parent>/<project>-public
~/.claude/skills/greenroom/scripts/greenroom.py collect          # dry-run, prints the plan
~/.claude/skills/greenroom/scripts/greenroom.py collect --apply  # copy into <project>-private/
```

It scans two sources: files on the default branch that match private-shaped path rules (`docs/design/**`, `**/architecture.md`, `**/rfc-*.md`, and the like), and files reachable from unmerged branches whose names start with `design/`, `notes/`, `drafts/`, or `private/`. It reads each file from git history and writes a copy into the private dir. Public history is never rewritten. Review the plan, then re-run with `--apply` and commit when you are ready.

## What it does not do

- **No push.** Both repos stay local until you push them, so you review before anything reaches GitHub.
- **No commit.** The private repo's initial files are left staged for review.
- **No automatic GitHub repo creation.** The script prints the `gh repo create --private` commands for any new private repos (including the private fork if you used `--with-private-fork`). Your agent relays these and runs them on your explicit yes. Nothing reaches GitHub without that confirmation.
- **No edits to Claude Code plugin config.** If the public repo was registered as a plugin, the move breaks its path. The script detects this and names the files to fix, but it leaves agent config to you.

## Tests

`tests/smoke.sh` builds throwaway repos in a temp dir and exercises the script's reliability-critical paths: retrofit when the parent already holds other repos, `collect` classification of files at the repo root, crash-safe restore when an in-place move fails, component-boundary matching in the plugin-config check, the full `sync` wiring (workspace, access, and map), the AGENTS.md core plus the Claude and Gemini adapters, and the `--with-private-fork` scaffold. A GitHub Actions workflow (`.github/workflows/ci.yml`) runs it on Linux and macOS once the repo is on GitHub.

```
tests/smoke.sh
```

## See also

greenroom was built using greenroom: this repo is the stage, and the drafts, design notes, and launch thinking behind it live in a private green room right next to it. Nothing from there ships, which is the whole point.

`SKILL.md` carries the full conventions, edge cases, and the agent-facing instructions. The slash-command definitions live in `commands/`. Design notes on why the layout is shaped this way are in [`docs/design.md`](docs/design.md).

## License

[MIT](LICENSE) © Jesse Robbins
