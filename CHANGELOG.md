# Changelog

All notable changes to greenroom are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it
reaches a stable release.

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
[0.1.1-alpha]: https://github.com/jesserobbins/greenroom/releases/tag/v0.1.1-alpha
