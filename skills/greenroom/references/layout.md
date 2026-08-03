# Layout and agent orientation

## The full pattern

```
~/src/<project>/                     # wrapper -- NOT a git repo
├── AGENTS.md                        # wrapper orientation: read by any agent at launch
├── CLAUDE.md                        # Claude adapter: exactly "@AGENTS.md"
├── README.md                        # repo map for humans and agents (auto-managed by sync)
├── .greenroom                       # editor-neutral wrapper identity marker ({"schema": 1})
├── <project>.code-workspace         # VS Code entry point -- written only when a VS Code-family editor is detected
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

The wrapper holds **two fixed repos** (`-public` and `-private`). It also holds
**any number of optional ones**: a `-public-fork` to open PRs from, a
`-private-fork`, or more clones. greenroom finds every git repo directly under
the wrapper and adds it to the workspace. `sync` picks up new ones.

## Agent orientation: AGENTS.md

`AGENTS.md` is the cross-agent instructions standard. More than 25 agents read
it natively, among them Codex, Cursor, Aider, GitHub Copilot, Windsurf, Zed,
Warp, Google Jules, Devin, and VS Code.

greenroom writes two kinds of `AGENTS.md`:

- **Wrapper `AGENTS.md`**: orientation for any agent launched at the wrapper.
  It holds the repo map, the launch rule, and the layout.
- **Per-repo `AGENTS.md`**: the conventions for one repo. Nested, nearest-file
  semantics load it as the agent touches files in that repo.

Agents that read `AGENTS.md` natively need no other config. Two adapters wire
the agents that need a pointer:

- **Claude Code**: Claude reads `CLAUDE.md`, not `AGENTS.md`. greenroom writes a
  `CLAUDE.md` that holds exactly `@AGENTS.md`. This is an `@`-import, the bridge
  the Anthropic documentation prescribes. The import resolves to the sibling
  `AGENTS.md` in the same directory. greenroom also writes a
  `.claude/settings.local.json` grant in each repo, as a safety net for a stray
  in-repo launch.
- **Gemini CLI**: greenroom writes `.gemini/settings.json` with
  `{"context": {"fileName": "AGENTS.md"}}`. Gemini then reads `AGENTS.md`
  instead of its default context file.

**Access for all agents comes from the wrapper launch.** When an agent starts at
the wrapper, every child repo is under cwd and reachable. The per-agent grant
files are safety nets only, for a stray launch inside a single repo. The neutral
core writes no access config. Only the Claude and Gemini adapters write theirs.

**No per-editor config beyond these two.** greenroom generates nothing else that
is editor-specific. The only exceptions are the conditional VS Code workspace
and the Gemini pointer. Every other editor reads `AGENTS.md` natively and
reaches both repos from the wrapper cwd. Zed, JetBrains, Helix, vim, Cursor, and
Aider all do this, so there is no `.idea/`, `.zed/`, or similar file to write.
greenroom writes a per-editor file only when the editor cannot otherwise find
its instructions or open both repos. Of these editors, only Gemini met that bar.

## Why `<project>-private/` and not `private/`

Some tools infer project identity from the directory name. Git remotes, agent
session reporting, and IDE workspace labels all do this. The name
`<project>-private/` gives each project a unique, project-scoped name in those
tools.

Legacy projects with a plain `private/` dir keep working. The script and the
`collect` subcommand recognize both names. To migrate, rename the directory. If
a `<project>.code-workspace` file is present, also update the folder name and
the path in it.

## Wrapper identity

Wrapper identity lives in the editor-neutral `.greenroom` marker, which holds
`{"schema": 1}`. It does not live in the workspace file. As a result, a
terminal-only setup is a complete, recognized wrapper with no workspace at all.

## Conventions encoded in the templates

The `<project>-private/AGENTS.md` that the script writes tells any agent that
works there:

- This repo holds material that is under version control but never published.
- Reference public artifacts by GitHub URL (commit SHA or PR number). Never
  reference private-dir paths from public commits or PRs.
- Date-prefix working notes (`YYYY-MM-DD-topic.md`). Leave design docs
  unprefixed.
- If a design doc matters enough to cite from a public PR, publish it into the
  public repo's `docs/` and link there. A redacted copy is also acceptable.
- The path itself is a small leak. Remove private-dir references when you paste
  into public artifacts.
