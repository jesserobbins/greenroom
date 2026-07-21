---
description: Add a private notes repo alongside an existing public repo (moves the public repo into a wrapper folder and scaffolds <project>-private/ as a sibling)
argument-hint: [path-to-existing-public-repo] [--name <project>] [--with-private-fork] [--public-name <dir>] [--private-name <dir>]
---

Invoke the `greenroom` skill and run its `retrofit` subcommand with `$ARGUMENTS`
(defaulting to the current directory when no path is given).

If no arguments were given and the cwd is not a git repo, show `retrofit --help`
and stop.
