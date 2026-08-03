# Collecting private-shaped docs from public history

Some private-shaped files reach the public repo before the layout is in place.
Once the layout is in place, `collect` recovers those files. It copies each one
into the correct `<project>-private/<bucket>/` directory.

Run `collect` from **inside the public repo**. The `--public` option defaults to
cwd, which must be a git repo. The script then finds the sibling private repo
automatically. To run from elsewhere, pass `--public` and `--private`.

Each run is ONE shell command, built from three parts. `$greenroom` does not
survive between calls, and these fragments do not run on their own:

1. The resolver block from SKILL.md, verbatim. Include its
   `[ -n "$greenroom" ] || { ...; exit 1; }` guard.
2. `cd <wrapper>/<project>-public`
3. `python3 "$greenroom" collect` -- a dry run, which prints the plan.

Read the plan. Then repeat all three parts with
`python3 "$greenroom" collect --apply` to copy the files into
`<project>-private/`.

**Copy-only.** The script reads each file from git at the chosen commit SHA. It
writes the file into `<project>-private/<bucket>/`. It never rewrites public
history. To remove the originals from public history you need `git filter-repo`,
which is out of scope for greenroom on purpose.

## Sources scanned

1. **The default branch (`main` or `master`)**: files that match the path-rule
   list, for example `docs/design/**`, `docs/architecture.md`, and
   `**/rfc-*.md`. These are docs that reached main and belong in the private
   repo.
2. **Unmerged branches whose names start with a private prefix**: `design/`,
   `notes/`, `drafts/`, and `private/`. The script pulls in files that are
   reachable from those branches but absent from the default branch.

The branch-name convention is the retroactive signal. These prefixes mark
branches that hold private-bound work. Anything on such a branch that never
reached main is therefore a candidate. To use different prefixes, pass
`--branch-prefix` once per prefix.

## Classification

Classification is rules-only: the path and filename map the file to a bucket.
The buckets are `docs`, `notes`, `drafts`, `reviews`, and `research`. A file on
a private-prefix branch with no matching rule goes to `docs/`.

Files in the `notes` bucket get a `YYYY-MM-DD-` filename prefix, taken from the
date of the file's last commit. A file that already has a date prefix keeps it.

If the same path is on more than one branch, the script keeps the **latest
version** by commit date.

## After `--apply`

Read `git -C <wrapper>/<project>-private status`, then commit when you are
ready. The provenance of the files belongs in that commit's message, not in a
sidecar manifest.
