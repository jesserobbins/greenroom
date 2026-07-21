---
name: greenroom
description: Sets up and maintains a greenroom layout — a public code repo beside a private notes repo, so design docs, drafts, and review notes stay in git but never get published. Use when someone asks to "set up a green room", "add private notes beside my public repo", "keep design docs out of the public repo", or starts a public project and mentions drafts or reviews.
---

# greenroom

A per-project layout: one wrapper folder holding two sibling git repos. The
public code is the stage; the private notes are the green room you prep in
before going on.

```
~/src/<project>/                  # wrapper — NOT a git repo
├── AGENTS.md                     # orientation for any agent launched here
├── CLAUDE.md                     # Claude adapter: exactly "@AGENTS.md"
├── README.md                     # repo map (auto-managed)
├── .greenroom                    # wrapper identity marker
├── <project>-public/             # the stage: public code
└── <project>-private/            # the green room: docs, notes, drafts,
                                  #   reviews, research — never published
```

The wrapper has no `.git/`. It is an organizational container, so one `cd` puts
every part of the project in front of you. Any number of extra repos (a
`-public-fork`, another clone) can sit under it; they are auto-discovered.

**Launch at the wrapper**: `cd <wrapper> && <your-agent>`. Every repo is then
under cwd and reachable, each repo's `AGENTS.md` loads as the agent touches its
files, and session history stays in one bucket.

## Running greenroom

The script ships beside this file, at `scripts/greenroom.py` under this skill's
directory. Invoke it by its **absolute path** — where the script lives and what
cwd you invoke it from are two different things, and several subcommands default
a path argument to the current directory.

The skill's directory differs per install shape (plugin, `npx skills add`,
manual clone), so resolve it. **Every shell invocation is a fresh process — `$greenroom`
does not survive between them.** Paste this whole block into each call that runs
the script, ending with the `cd` (if any) and the invocation, as one command:

```bash
# project-local install: walk up from $PWD, so it resolves from a subdirectory
# too. $HOME is skipped -- it is an ancestor of almost every cwd, so matching it
# here would let a global install win the PROJECT tier and shadow the cache below.
proj=""; d="$PWD"
while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
  # Only count a hit at the directory you started in, or at a real project root.
  # Otherwise any ancestor that happens to hold a stale .claude/ outranks the
  # plugin cache -- and `new` is documented as running from a plain parent dir,
  # where nothing on the way up is a project at all.
  if [ "$d" = "$PWD" ] || [ -e "$d/.git" ] || [ -e "$d/.greenroom" ]; then
    if [ -f "$d/.claude/skills/greenroom/scripts/greenroom.py" ]; then
      proj="$d/.claude/skills/greenroom"; break
    fi
  fi
  # Stop at the project boundary: above it a stray .claude/ belongs to something
  # else and must not outrank the plugin cache. Exception: a greenroom wrapper
  # sits one level above its repos, so let the walk cross into it.
  if [ -e "$d/.git" ] || [ -e "$d/.greenroom" ]; then
    if [ ! -e "$(dirname "$d")/.greenroom" ]; then break; fi
  fi
  d="$(dirname "$d")"
done
# newest cached plugin version, keyed on the VERSION dir, not the whole path
# `|| true`: with no cache dir `ls` exits non-zero, which would abort the whole
# pasted block under `set -e -o pipefail` before the guard below can explain why.
cache="$(ls -d "$HOME"/.claude/plugins/cache/*/greenroom/*/skills/greenroom 2>/dev/null \
         | awk -F/ '{print $(NF-2)"\t"$0}' | sort -V | tail -1 | cut -f2- || true)"
greenroom=""
for c in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/greenroom" "$proj" "$cache" \
         "$HOME/.claude/skills/greenroom"; do
  if [ -n "$c" ] && [ -f "$c/scripts/greenroom.py" ]; then
    greenroom="$c/scripts/greenroom.py"; break
  fi
done
[ -n "$greenroom" ] || { echo "greenroom.py not found; see the fallback below" >&2; exit 1; }
```

Copy that block verbatim, then append your own two lines to the same command —
the `cd` (if the subcommand needs one) and the invocation:

```
cd <dir-the-subcommand-wants>
python3 "$greenroom" <subcommand> [args]
```

Order matters: the resolver runs **before** any `cd`, because the project-local
tier is relative to where you start.

`npx skills add` without `-g` installs into the *project*, which is why the
walked-up project tier comes first after the env var — counting only your own
directory and real project roots above it, never an unrelated ancestor that
happens to hold a `.claude/`. The plugin cache outranks
`~/.claude/skills` because `$CLAUDE_PLUGIN_ROOT` is not exported into Bash-tool
shells, so the cache *is* the plugin path — a leftover manual clone must not
shadow it. That tier sorts on the version directory alone, so a second cached
marketplace owner cannot outrank a newer version. The script runs through
`python3` so a payload that lost its exec bit in transit still works.

After a `new` or `retrofit` run, surface any plugin-config warning and any
stale-cwd note **verbatim** — those are the only steps the user must act on by
hand. `references/operations.md` has the rest.

Every tier above is a Claude Code path. The skills CLI supports many other
agents, and their install roots differ — **on a non-Claude agent expect the block
to miss**, which is not a bug in your invocation. When it exits with
`greenroom.py not found`, locate `scripts/greenroom.py` under the directory this
file was read from and call that directly; it always ships beside this file.

Pass the path argument explicitly, or run from the directory noted in the last
column below. Pass `--help` (or `<subcommand> --help`) for the full flag list.
The parser is the source of truth; do not re-document flags from prose.

| Situation | Subcommand | Run from (if the path is omitted) |
|---|---|---|
| Existing public repo, want private notes beside it | `retrofit <path-to-repo>` | the repo to wrap |
| New project, cloning an existing public repo | `new <name> --clone <url>` | the intended parent dir |
| New project, public repo doesn't exist yet | `new <name> --init-public` | the intended parent dir |
| Added a fork or clone under an existing wrapper | `sync` | anywhere inside the wrapper |
| Design docs already landed in the public repo | `collect` (see `references/collect.md`) | inside the public repo |

Add `--with-private-fork` to `new`/`retrofit` for a third repo: a private dev
checkout cloned from the local public repo, with its remote named `upstream` so
`origin` stays free for a private GitHub remote.

On Claude Code these are also `/greenroom:new`, `/greenroom:add`, and
`/greenroom:sync`.

**Supported platforms:** macOS and Linux (Windows via WSL2). The script refuses
to run on native Windows.

## Leak hygiene

These rules are why greenroom exists. They apply to every project using it.

- The private repo is **never published.** Nothing in it ships.
- Reference public artifacts by GitHub URL (commit SHA, PR number), never by
  local path. **The path itself is a small leak** — strip private-dir
  references when pasting into a public PR, commit, or issue.
- New design thinking, drafts, and review notes land in the private repo, not
  the public one.
- If a design doc matters enough to cite from a public PR, publish it (or a
  redacted copy) into the public repo's `docs/` and link there.
- Date-prefix working notes (`YYYY-MM-DD-topic.md`); leave design docs
  unprefixed.

## Creating the private GitHub repo

The script **never pushes and never creates a remote.** Both repos stay local
until the user acts.

When it prints a `To create private GitHub repos for these (optional):` block:

- Relay the `gh repo create ... --private` commands **verbatim**.
- Ask whether to run them. Run only on an explicit yes.
- If the user names an org, substitute it for the `<owner>` prefix.
- Make clear that declining leaves everything local.
- These are always `--private`. Never offer or suggest a public variant.

## Further reference

Read only what the task needs:

- `references/layout.md` — full annotated layout, agent orientation, the
  `AGENTS.md` / `CLAUDE.md` / Gemini adapters, naming rationale
- `references/workspace.md` — VS Code workspace generation, sibling-repo
  access grants, the wrapper repo map
- `references/collect.md` — recovering private-shaped docs from public history
- `references/operations.md` — what the script deliberately does not do, edge
  cases, safety boundaries, and the post-run checklist
