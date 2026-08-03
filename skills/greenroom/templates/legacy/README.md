# Superseded template generations

These files are not templates that greenroom writes. They are the wrapper
orientation texts that **earlier releases** of greenroom wrote, kept so that
`migrate_claude_to_agents` can still recognize its own past output.

## Why they are here

A wrapper made before greenroom used `AGENTS.md` holds that release's
orientation text in its `CLAUDE.md`. `sync` migrates such a wrapper to
`AGENTS.md` plus an `@AGENTS.md` pointer. It decides whether a `CLAUDE.md` is
greenroom-authored by rendering the wrapper template and comparing.

A comparison against the current template alone is correct only until the
template changes. After any reword, a real greenroom-authored `CLAUDE.md` no
longer matches. `sync` then skips the migration and tells the user their file
looks hand-edited, which is wrong. The wrapper is stranded, and the user is
given a false reason.

`migrate_claude_to_agents` therefore matches against the current template and
every file here.

## The rule when you edit `../wrapper_AGENTS.md`

CAUTION: Do not reword `../wrapper_AGENTS.md` on its own. In the same commit,
copy the outgoing text into this directory as the next
`wrapper_AGENTS.<NNN>.md`.

1. Copy the current `../wrapper_AGENTS.md` to `wrapper_AGENTS.<NNN>.md`. Use the
   next free number.
2. Make your edit to `../wrapper_AGENTS.md`.
3. Run `tests/smoke.sh`.

The drift guard in `tests/smoke.sh` reads the git history of
`../wrapper_AGENTS.md`. It fails when a historical version is neither the
current template nor a file here. It needs full git history, so it is skipped on
a shallow clone.

## Only `wrapper_AGENTS.md` needs this

The other templates (`private_AGENTS.md`, `private_README.md`,
`private_gitignore`) need no snapshots. greenroom only writes them. It never
compares a file on disk against them, so a reword of those templates changes
nothing that already exists.

`wrapper_AGENTS.md` is the one exception, because the migration path compares
against it. If you ever add a second comparison against a template, that
template needs snapshots here and a case in the drift guard.

## Naming

`wrapper_AGENTS.<NNN>.md`, numbered from `001` in the order the generations
shipped. The loader reads every file that matches `wrapper_AGENTS.*.md`, so the
numbers order the directory for a reader. They carry no other meaning.

Keep the `{{PROJECT_NAME}}` and `{{CANONICAL_DIR_NAME}}` placeholders exactly as
that generation had them. The loader applies the same substitutions to these
files as to the current template.

## Current generations

- `wrapper_AGENTS.001.md` -- 0.1.0-alpha through 0.1.1-alpha (commit `1fc24de`)
- `wrapper_AGENTS.002.md` -- 0.1.2-alpha through 0.2.1-alpha (commit `592b5f9`)
