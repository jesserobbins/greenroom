# AGENTS.md -- {{PROJECT_NAME}} (wrapper)

This is the **launch home** for the `{{PROJECT_NAME}}` project. It is a plain directory, not a git repo. It holds the project's repos as subdirectories. Launch your agent here to work on this project.

## How to launch (any editor)

From a terminal:

```bash
cd <this directory> && claude   # or: codex, gemini, ...
```

That is the whole rule. It works in any editor, or in none.

This directory is the launch cwd. As a result:

- Every child repo below is readable and writable with no extra wiring.
- Session history stays in **one** bucket.
- Each child repo's own `AGENTS.md` loads the first time you touch its files.

If you use a VS Code-family editor, look for a `*.code-workspace` file in this directory. If that file is present, you can open it instead, or run the `Claude Code ({{CANONICAL_DIR_NAME}})` task. The repo map is in `README.md` in this directory.

## Where to work

- `{{CANONICAL_DIR_NAME}}/` -- the public code (the published repo). The "stage."
- `*-private/` -- private notes, never published. The "green room."
- Other sibling repos (forks, docs) -- see the README map.

## Leak hygiene (read this before you touch any repo)

- The `*-private` repo and this wrapper are **never published.** Nothing in them ships.
- Reference public artifacts by GitHub URL (commit SHA or PR number), never by local path.
- The path itself is a small leak. When you paste from private notes into a public PR or commit, remove the path references.
- New design thinking, drafts, and review notes go in `*-private/`, not in the public repo.
