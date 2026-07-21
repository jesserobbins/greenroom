# AGENTS.md

This file provides guidance to your agent when working with code in this repository.

## What this repo is

Private notes for the `{{PROJECT_NAME}}` project. The public code repo is the sibling directory `../{{PUBLIC_DIR_NAME}}/`. {{REPO_LINK}}

Both live under the wrapper folder of the same name as this project, which is a plain directory, not a repo.

This repo holds material that is under version control but never published: design docs before they're code, working notes, draft PR/issue bodies, private review notes, and research artifacts.

## Layout

- `docs/` -- design docs, RFCs, ADR drafts
- `notes/` -- dated working notes (`YYYY-MM-DD-topic.md`)
- `drafts/` -- PR/issue/blog drafts before publishing
- `reviews/` -- private notes on PRs (own pre-merge thinking, contributor PRs)
- `research/` -- experiments, transcripts, comparison data, links

## Conventions

- Reference public artifacts by GitHub URL (commit SHA or PR number), not local paths. Survives renames and clones across machines.
- Date-prefix working notes; leave design docs unprefixed so `ls docs/` reads as a table of contents.
- When a design doc matters enough to cite from a public PR, **publish it** (or a redacted version) into `../{{PUBLIC_DIR_NAME}}/docs/` and link there. Never link a public artifact to a path in this repo.

## Leak hygiene

- The path to this repo is itself a small leak. When pasting from these notes into a public PR or commit, strip path references.
- Global gitignore (`~/.config/git/ignore`) should cover `.notes`, `NOTES.md`, `SCRATCH.md`, `*.private.md`, `.private/` so those names can't accidentally land in the public repo.

## When working on the public side

If asked to work in `../{{PUBLIC_DIR_NAME}}/`, check this repo first for prior context. Design decisions, open questions, and draft PR bodies often live here before they become public artifacts. New private material continues to land here, not in the public repo.

## Launch from the wrapper, not from here

The canonical launch home for this project is the **parent wrapper directory** (`../`, which contains this repo and `../{{PUBLIC_DIR_NAME}}/`). Launch your agent there:

```bash
cd .. && claude   # or: codex, gemini, ...
```

From the wrapper, this repo and every sibling are reachable as subdirectories, session history stays in one bucket, and this `AGENTS.md` loads automatically the first time its files are touched. Launching directly inside `{{PRIVATE_DIR_NAME}}/` fragments session history into a separate bucket and breaks continuity with the rest of the project. If you notice the session is rooted here, flag it and relaunch at the wrapper instead of proceeding.

(If you do work inside this repo from a sub-repo-rooted session, `.claude/settings.local.json` grants access to the sibling repos. If you use a VS Code-family editor and a `*.code-workspace` exists at the wrapper root, open the project through it rather than `Open Folder` on this directory; otherwise just launch your agent at the wrapper as above.)
