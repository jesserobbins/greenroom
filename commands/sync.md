---
description: Re-scan a greenroom wrapper and update its agent working-dir access, repo map, and (when a VS Code-family editor is detected) its workspace file — run after dropping a new fork/clone under the wrapper
argument-hint: [--wrapper <dir>] [--canonical <repo-dir>] [--name <project>]
---

Invoke the `greenroom` skill and run its `sync` subcommand with `$ARGUMENTS`.

With no `--wrapper`, the script detects the wrapper by walking up from the
current directory, so it works from inside any of the project's repos.
