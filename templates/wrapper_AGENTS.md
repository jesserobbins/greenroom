# AGENTS.md -- {{PROJECT_NAME}} (wrapper)

This is the **launch home** for the `{{PROJECT_NAME}}` project: a plain directory (not a git repo) that holds the project's repos as subdirectories. Launching your agent here is the supported, canonical way to work on this project.

## How to launch (any editor)

From a terminal:

```bash
cd <this directory> && claude   # or: codex, gemini, ...
```

That is the whole rule, and it works in any editor or none. Because this directory is the launch cwd, every child repo below is readable and writable with no extra wiring, session history stays in **one** bucket, and each child repo's own `AGENTS.md` loads automatically the first time you touch its files. If you use a VS Code-family editor (VS Code, Cursor, …) and a `*.code-workspace` was written here, you can open it or run the `Claude Code ({{CANONICAL_DIR_NAME}})` task instead. The repo map lives in `README.md` in this directory.

## Where to work

- `{{CANONICAL_DIR_NAME}}/` -- the public code (the published repo). The "stage."
- `*-private/` -- private notes, never published. The "green room."
- Other sibling repos (forks, docs) -- see the README map.

## Leak hygiene (must-know before you touch any repo)

- The `*-private` repo and this wrapper are **never published.** Nothing from them ships.
- Reference public artifacts by GitHub URL (commit SHA / PR number), never by local path. When pasting from private notes into a public PR/commit, strip path references. The path itself is a small leak.
- New design thinking, drafts, and review notes land in `*-private/`, not in the public repo.
