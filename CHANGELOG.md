# Changelog

All notable changes to greenroom are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
reaches a stable release.

## [0.1.4-alpha] - 2026-06-24

### Changed
- The skill now lives at `skills/setup/SKILL.md` instead of a root `SKILL.md`,
  so it invokes as `/greenroom:setup` instead of the stuttering
  `/greenroom:greenroom`. Auto-activation (by description) is unchanged. ([#3])
- `install.sh` now links each skill under a `greenroom-` prefix
  (`~/.claude/skills/greenroom-setup`), so a manual install invokes
  `/greenroom-setup` instead of a generic `/setup` that could collide with your
  own skills. It also keeps `~/.claude/skills/greenroom` pointed at the repo root
  so the commands' script-path fallback and the `collect` examples still resolve
  `greenroom.py` on a manual install.

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
[0.1.4-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.4-alpha
[0.1.3-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.3-alpha
[0.1.2-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.2-alpha
[0.1.1-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.1-alpha
