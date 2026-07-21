# Layout and agent orientation

## The full pattern

```
~/src/<project>/                     # parent folder, NOT a git repo
├── AGENTS.md                        # wrapper orientation: read by any agent at launch
├── CLAUDE.md                        # Claude adapter: exactly "@AGENTS.md"
├── README.md                        # repo map for humans and agents (auto-managed by sync)
├── .greenroom                       # editor-neutral wrapper identity marker ({"schema": 1})
├── <project>.code-workspace         # VS Code entry point — written only when a VS Code-family editor is detected
├── .gemini/settings.json            # Gemini adapter: sets context.fileName to AGENTS.md (git-excluded)
├── <project>-public/                # public code repo (the thing on GitHub: the stage)
│   ├── AGENTS.md                    # your own, if any: greenroom does not create this
│   ├── CLAUDE.md                    # Claude adapter: "@AGENTS.md", only if this repo has its own AGENTS.md
│   └── .claude/settings.local.json  # Claude safety-net grant for sibling repos (git-excluded)
├── <project>-private/               # private notes repo (separate private GitHub repo: the green room)
│   ├── AGENTS.md                    # per-repo private orientation
│   ├── CLAUDE.md                    # Claude adapter: exactly "@AGENTS.md"
│   ├── .claude/settings.local.json  # Claude safety-net grant for sibling repos (git-excluded)
│   ├── README.md
│   ├── docs/      # design docs, RFCs, ADR drafts
│   ├── notes/     # dated working notes
│   ├── drafts/    # PR/issue/blog drafts
│   ├── reviews/   # private notes on PRs
│   └── research/  # transcripts, links, experiments
├── <project>-public-fork/           # (optional) your fork: push branches, open PRs from here
└── <any-other-repo>/                # (optional) any git repo dropped under the wrapper
```

The wrapper holds **two fixed repos** (`-public`, `-private`) plus **any number
of optional ones**: a `-public-fork` to PR from, a `-private-fork`, more clones.
Every git repo directly under the wrapper is auto-discovered and added to the
workspace; `sync` picks up new ones.

## Agent orientation: AGENTS.md

`AGENTS.md` is the cross-agent instructions standard, read natively by 25+
agents including Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed, Warp,
Google Jules, Devin, and VS Code. greenroom writes:

- **Wrapper `AGENTS.md`**: orientation for any agent launched at the wrapper —
  the repo map, the launch rule, and the layout.
- **Per-repo `AGENTS.md`**: per-repo conventions, loaded via nested /
  nearest-file semantics as the agent touches files in that repo.

Agents that read `AGENTS.md` natively need no extra config. Two adapters wire
the agents that need a pointer:

- **Claude Code**: Claude reads `CLAUDE.md`, not `AGENTS.md`. greenroom writes a
  `CLAUDE.md` containing exactly `@AGENTS.md` (an `@`-import, the
  Anthropic-documented bridge). It resolves to the sibling `AGENTS.md` in the
  same directory. A `.claude/settings.local.json` grant is also written per-repo
  as a safety net for stray in-repo launches.
- **Gemini CLI**: greenroom writes `.gemini/settings.json` with
  `{"context": {"fileName": "AGENTS.md"}}` so Gemini reads `AGENTS.md` instead
  of its default context file.

**Access for all agents comes from wrapper-launch.** When an agent starts at the
wrapper, every child repo is under cwd and reachable. The per-agent grant files
are safety nets only, for a stray launch inside a single repo. The neutral core
writes no access config; only the Claude and Gemini adapters write theirs.

**No per-editor config beyond these.** greenroom generates nothing
editor-specific apart from the (conditional) VS Code workspace and the Gemini
pointer. Every other editor — Zed, JetBrains, Helix, vim, Cursor, Aider, and the
rest — reads `AGENTS.md` natively and reaches both repos from the wrapper cwd,
so there is no `.idea/`, `.zed/`, or similar to write. The bar for a generated
per-editor file is "the editor can't otherwise find its instructions or open
both repos"; only Gemini cleared it.

## Why `<project>-private/` and not `private/`

The private dir is named `<project>-private/` so tools that infer project
identity from the directory name (git remotes, agent session reporting, IDE
workspace labels) see a unique, project-scoped name.

Legacy projects with a plain `private/` dir keep working: the script and the
`collect` subcommand recognize both names. Migrate by renaming the directory
and, if a `<project>.code-workspace` exists, updating its folder name and path.

## Wrapper identity

Wrapper identity lives in the editor-neutral `.greenroom` marker (content
`{"schema": 1}`), not in the workspace file — so a terminal-only setup is a
complete, recognized wrapper with no workspace at all.

## Conventions encoded in the templates

The `<project>-private/AGENTS.md` written by the script tells any agent working
there:

- This repo holds material under version control but never published.
- Reference public artifacts by GitHub URL (commit SHA, PR number). Never
  reference private-dir paths from public commits or PRs.
- Date-prefix working notes (`YYYY-MM-DD-topic.md`); leave design docs
  unprefixed.
- When a design doc matters enough to cite from a public PR, publish it (or a
  redacted copy) into the public repo's `docs/` and link there.
- The path itself is a small leak. Strip private-dir references when pasting
  into public artifacts.
