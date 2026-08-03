# AGENTS.md

This file gives your agent guidance for work in this repository.

## What this repo is

Private notes for the `{{PROJECT_NAME}}` project. The public code repo is the sibling directory `../{{PUBLIC_DIR_NAME}}/`. {{REPO_LINK}}

Both repos sit under a wrapper folder with the same name as the project. That wrapper is a plain directory, not a repo.

This repo holds material that is under version control but never published: design docs before they become code, working notes, draft PR and issue bodies, private review notes, and research artifacts.

## Layout

- `docs/` -- design docs, RFCs, ADR drafts
- `notes/` -- dated working notes (`YYYY-MM-DD-topic.md`)
- `drafts/` -- PR/issue/blog drafts before publication
- `reviews/` -- private notes on PRs (own pre-merge thinking, contributor PRs)
- `research/` -- experiments, transcripts, comparison data, links

## Conventions

- Reference public artifacts by GitHub URL (commit SHA or PR number), not by local path. A URL stays correct after a rename, and after a clone to a different machine.
- Date-prefix working notes. Leave design docs unprefixed, so that `ls docs/` reads as a table of contents.
- If a design doc matters enough to cite from a public PR, **publish it**. Put the doc, or a redacted version, into `../{{PUBLIC_DIR_NAME}}/docs/` and link to it there. Never link a public artifact to a path in this repo.

## Leak hygiene

- The path to this repo is itself a small leak. When you paste from these notes into a public PR or commit, remove the path references.
- The global gitignore (`~/.config/git/ignore`) must cover `.notes`, `NOTES.md`, `SCRATCH.md`, `*.private.md`, and `.private/`. Those names can then never land in the public repo by accident.

## When working on the public side

If you are asked to work in `../{{PUBLIC_DIR_NAME}}/`, read this repo first for prior context. Design decisions, open questions, and draft PR bodies often start here, before they become public artifacts. New private material continues to land here, not in the public repo.

## Launch from the wrapper, not from here

The launch home for this project is the **parent wrapper directory** (`../`). It holds this repo and `../{{PUBLIC_DIR_NAME}}/`. Launch your agent there:

```bash
cd .. && claude   # or: codex, gemini, ...
```

From the wrapper, this repo and every sibling are reachable as subdirectories. Session history stays in one bucket. This `AGENTS.md` then loads the first time its files are touched.

A launch inside `{{PRIVATE_DIR_NAME}}/` puts session history in a separate bucket. It also breaks continuity with the rest of the project. If the session is rooted here, tell the user and relaunch at the wrapper. Do not continue.

If you do work in this repo from a session rooted in a sub-repo, `.claude/settings.local.json` grants access to the sibling repos. If you use a VS Code-family editor, look for a `*.code-workspace` file at the wrapper root. If that file is present, open the project through it. Do not use `Open Folder` on this directory.
