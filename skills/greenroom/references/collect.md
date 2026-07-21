# Collecting private-shaped docs from public history

Once the layout is in place, `collect` recovers private-shaped files that were
committed to the public repo and copies them into the right
`<project>-private/<bucket>/`.

Run it from **inside the public repo** (`--public` defaults to cwd, which must
be a git repo); the sibling private dir is auto-detected. Pass
`--public`/`--private` to run from elsewhere.

Each run is ONE shell command, built in three parts — `$greenroom` does not
survive between calls, and these fragments are not runnable on their own:

1. SKILL.md's resolver block, verbatim, including its
   `[ -n "$greenroom" ] || { ...; exit 1; }` guard
2. `cd <wrapper>/<project>-public`
3. `python3 "$greenroom" collect` — dry-run, prints the plan

Then repeat all three with `python3 "$greenroom" collect --apply` to copy the
files into `<project>-private/`.

**Copy-only.** Files are read from git at the chosen commit SHA and written into
`<project>-private/<bucket>/`. Public history is never rewritten. Removing the
originals from public history requires `git filter-repo` and is intentionally
out of scope.

## Sources scanned

1. **Default branch (`main`/`master`)**: files matching the path-rule list (for
   example `docs/design/**`, `docs/architecture.md`, `**/rfc-*.md`). Docs that
   landed on main and probably shouldn't have.
2. **Unmerged branches whose names start with a private prefix**: `design/`,
   `notes/`, `drafts/`, `private/`. Files reachable from those branches but
   absent from the default branch get pulled in.

The branch-name convention is the retroactive signal: these prefixes mark
branches that hold private-bound work, so anything on them that never reached
main is a candidate. Override with repeated `--branch-prefix` flags.

## Classification

Rules-only: path/filename maps to a bucket (`docs`, `notes`, `drafts`,
`reviews`, `research`). Files on a private-prefix branch with no matching rule
fall back to `docs/`.

Notes get a `YYYY-MM-DD-` filename prefix from the file's last-commit date
unless they're already date-prefixed.

Same path on multiple branches → keep the **latest version** by commit date.

## After `--apply`

Review `git -C <wrapper>/<project>-private status` and commit when ready.
Provenance lives in that commit's message, not in sidecar manifests.
