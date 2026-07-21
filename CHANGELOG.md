# Changelog

All notable changes to greenroom are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
reaches a stable release.

## [Unreleased]

### Added
- greenroom installs as a standalone skill on any agent:
  `npx skills add jesserobbins/greenroom`. The `skills/greenroom/` directory is
  now self-sufficient — it carries its own `scripts/` and `templates/` — because
  that directory, and nothing else, is what the skills CLI copies. A smoke test
  drives a full scaffold from an isolated copy of it to keep that guarantee
  honest.

### Changed
- **Breaking:** the skill is renamed `greenroom-setup` → `greenroom`, so the
  plugin invocation is now `/greenroom:greenroom` and a standalone install is
  `/greenroom`. The name covered only one of its four subcommands. Plugin users
  need no action; `install.sh` migrates a manual install in place.
- `scripts/` and `templates/` moved from the repo root into
  `skills/greenroom/`. `greenroom.py` resolves templates relative to its own
  location, so this needed no code change.
- Slash commands are now hollow triggers that hold no logic — all behaviour
  lives in the skill. `npx skills` never reads `commands/`, so anything encoded
  there is unreachable for standalone users.
- SKILL.md is a router: detail moved into `skills/greenroom/references/`, which
  costs nothing until read, and flag documentation defers to `--help`. Resident
  context for a typical session drops roughly 72% (~4,650 → ~1,300 tokens) with
  no functionality removed. Smoke tests assert the budget so it cannot silently
  regrow.
- `install.sh` no longer builds a `~/.claude/skills/greenroom/` script-root
  shim; the skill directory carries its own script. It migrates the old shim and
  the stale `greenroom-setup` link, both ownership-checked.
- Smoke tests now parse SKILL.md frontmatter as YAML rather than asserting a
  fixed description string. The skills CLI silently drops a skill whose
  frontmatter fails to parse, so the class of bug matters more than the instance.

### Previously
- The skill was renamed from `setup` to `greenroom-setup`. The `npx skills` CLI
  derives a skill's install directory and `@handle` from the `name:` field, so a
  bare `name: setup` installed as `~/.claude/skills/setup/` and collided with any
  other ecosystem skill named `setup`. Naming it `greenroom-setup` keeps the
  skills.sh handle (`jesserobbins/greenroom@greenroom-setup`), the manual-install
  directory, and the plugin handle identical and collision-free. The plugin
  invocation is now `/greenroom:greenroom-setup`.

### Fixed
- `install.sh` no longer replaces a symlink the user owns. It refreshed any
  symlink at the skill path unconditionally, so a link the migration correctly
  declined to touch was silently repointed one step later. Refreshing is now
  ownership-checked like migration, and both checks resolve relative symlink
  targets instead of only absolute ones.
- The old script-root shim is dismantled by removing the two links we created,
  not by `rm -rf` on the whole directory. Anything else the user left in there
  survives, and the migration says so instead of deleting silently.
- A dangling symlink at the skill path is replaced rather than skipped. Our own
  link becomes dangling the moment the clone is moved, and skipping it made a
  re-run from the relocated clone silently install nothing.
- SKILL.md documents how to *find* `scripts/greenroom.py` — a resolver covering
  the plugin, `npx skills add`, and manual-clone layouts — rather than naming an
  absolute path the agent had no way to derive. The plugin-cache tier is
  version-sorted so the newest cached copy wins over the lexically first, and
  the script is invoked through `python3` so a lost exec bit is not fatal.
- The skill's `description` no longer contains an unquoted colon-space (`layout:`
  → `layout —`). The `npx skills` YAML parser silently dropped the skill when the
  plain-scalar description value contained `: `, which made greenroom
  undiscoverable via `npx skills add` and unlistable on skills.sh.

## [0.1.8-alpha] - 2026-06-25

### Added
- A `.greenroom` marker file at the wrapper root is now the editor-neutral
  signal that identifies a greenroom wrapper. `new`, `retrofit`, and `sync`
  all write it (write-if-absent), and `sync` adds it to older wrappers that
  predate it. Wrapper detection no longer depends on the VS Code workspace file.
- `--workspace` / `--no-workspace` flags on `new`, `retrofit`, and `sync` to
  force or suppress the `<project>.code-workspace` write regardless of detection.

### Changed
- The `<project>.code-workspace` file is now written **only when a VS Code-family
  editor is detected** — `code`, `cursor`, `codium`/`vscodium`, or `windsurf` on
  `PATH`, or an existing `.vscode/` or `*.code-workspace` in the wrapper. A terminal-only
  setup (any editor that reads `AGENTS.md` natively) no longer gets an unused
  workspace file. Existing wrappers are unaffected: a present `*.code-workspace`
  is itself a detection signal, so `sync` keeps refreshing it.

## [0.1.7-alpha] - 2026-06-25

### Changed
- The plugin and marketplace author/owner email is now `code@jesserobbins.com`.

## [0.1.6-alpha] - 2026-06-25

### Fixed
- Every shell command greenroom prints for you to paste now quotes its path
  arguments, so they stay valid when a wrapper, repo, or private-dir path
  contains a space. Affects the stale-cwd `cd <wrapper>` hint, the
  `gh repo create <owner>/<repo> --source=<path>` repo-creation offer, and
  `collect`'s `git -C <private> status` follow-up. Previously a path like
  `~/My Projects/foo` produced a command that split on the space when pasted.

## [0.1.5-alpha] - 2026-06-25

### Added
- `add`/`retrofit` now prints a note when it moves the repo out from under the
  shell you ran it in (running `add` from *inside* the repo). That shell keeps
  a stale handle to the moved directory, so `ls`/`pwd` there look wrong until
  you `cd` to the wrapper; the note says so and gives the exact `cd`. The
  layout on disk is correct — this is cosmetic, not data loss.

## [0.1.4-alpha] - 2026-06-24

### Changed
- The skill now lives at `skills/setup/SKILL.md` instead of a root `SKILL.md`,
  so it invokes as `/greenroom:setup` instead of the stuttering
  `/greenroom:greenroom`. Auto-activation (by description) is unchanged. ([#3])
- `install.sh` now links each skill under a `greenroom-` prefix
  (`~/.claude/skills/greenroom-setup`), so a manual install invokes
  `/greenroom-setup` instead of a generic `/setup` that could collide with your
  own skills. For script resolution it builds `~/.claude/skills/greenroom/` as a
  plain directory holding `scripts/` and `templates/` symlinks, so the commands'
  script-path fallback and the `collect` examples still find `greenroom.py`
  without exposing the plugin manifest (which Claude Code would otherwise
  auto-load as a `greenroom@skills-dir` plugin).
- `install.sh` is safer around a path it does not own: if `~/.claude/skills/
  greenroom` is an unrelated symlink or a real file, it skips the script-root
  setup with a notice (rather than writing `scripts/`/`templates/` through the
  symlink into your directory, or aborting the whole install) and still links
  the skill and commands. The README's manual-install section now documents the
  `greenroom-setup` skill link and the `greenroom/` script-root.

## [0.1.3-alpha] - 2026-06-24

### Fixed
- `sync` no longer treats `$HOME` (or the filesystem root, or a standard system
  directory) as a greenroom wrapper, even when a stray non-greenroom
  `.code-workspace` is present or `--wrapper` points there explicitly. A single
  unrelated workspace file could previously make greenroom scaffold
  `~/CLAUDE.md` and other wrapper files into the home directory, where
  `CLAUDE.md` is loaded into nearly every session. ([#4])
- `retrofit` now refuses when the resolved wrapper is a forbidden root. It
  previously checked only the parent, so retrofitting an already-wrapped repo
  whose wrapper *is* the boundary (`$HOME` or `GREENROOM_ROOT`) could still
  scaffold into it; the final target now clears the same guard `sync` uses.
- Wrapper detection reads `.code-workspace` files as UTF-8 (matching the write
  side) and skips an undecodable file instead of crashing classification.

### Added
- A `.code-workspace` now only marks a directory as a greenroom wrapper if it
  carries the greenroom sentinel `{"greenroom": {"wrapper": true}}`; greenroom
  stamps this into every workspace it writes. A generic `greenroom` key alone
  does not qualify, and a pre-sentinel wrapper still classifies via its
  `-private` sibling.
- Optional `GREENROOM_ROOT` env var: a boundary greenroom never crosses upward.
  Set it to your projects' parent dir (e.g. `export GREENROOM_ROOT="$HOME/GitHub"`).
  greenroom refuses it as a scaffold *target* but accepts it as a *parent*, so
  `new`/`retrofit` can create a project directly under your projects dir while
  `sync` still refuses to treat the boundary itself as a wrapper.
- greenroom now states its supported platforms (macOS and Linux; Windows via
  WSL2) and refuses to run on native Windows.
- The forbidden-root floor of standard `$HOME` subdirectories now includes the
  XDG dirs that differ on Linux (`Videos`, `Templates`) alongside the macOS
  ones, for parity across both supported platforms.

## [0.1.2-alpha] - 2026-06-23

### Fixed
- `sync` no longer orphans a wrapper README written by an older version. The
  README's begin marker embeds the command name, which the 0.1.1-alpha rename
  changed, so detection (an exact-sentence match) stopped recognizing existing
  markers: the map silently went stale and the user was wrongly told to "paste
  the block in." Detection now keys off the stable `<!-- greenroom:begin` token
  and the rewrite migrates the old marker to the current one in one pass.
  ([#2])

## [0.1.1-alpha] - 2026-06-23

First tagged release (0.1.0 shipped untagged). Pre-stable: command names and
behavior may still change.

### Changed
- Renamed the slash commands from `greenroom-new` / `greenroom-add` /
  `greenroom-sync` to `new` / `add` / `sync`, so they invoke as
  `/greenroom:new`, `/greenroom:add`, `/greenroom:sync` instead of the
  stuttering `/greenroom:greenroom-new`. No backward-compatible aliases.

### Fixed
- Commands no longer 127 on a plugin install. `$CLAUDE_PLUGIN_ROOT` is not
  exported into Bash-tool shells, so the old `${CLAUDE_PLUGIN_ROOT:-...}`
  fallback resolved to a nonexistent path. Each command now resolves the script
  via a three-tier lookup: the plugin env var, then the plugin cache
  (`~/.claude/plugins/cache/*/greenroom/*/`, newest), then the manual
  `install.sh` location. ([#1])

[#1]: https://github.com/jesserobbins/greenroom/issues/1
[#2]: https://github.com/jesserobbins/greenroom/issues/2
[#3]: https://github.com/jesserobbins/greenroom/issues/3
[#4]: https://github.com/jesserobbins/greenroom/issues/4
[0.1.7-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.7-alpha
[0.1.6-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.6-alpha
[0.1.5-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.5-alpha
[0.1.4-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.4-alpha
[0.1.3-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.3-alpha
[0.1.2-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.2-alpha
[0.1.1-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.1-alpha
