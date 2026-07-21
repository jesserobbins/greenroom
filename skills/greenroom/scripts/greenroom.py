#!/usr/bin/env python3
"""greenroom: set up a public code repo with a private notes repo beside it.

A wrapper folder per project contains the public code repo (the "stage") and a
sibling private notes repo (the "green room" — where you prep off-stage):

    <parent>/<project>/
    ├── <project>-public/   # public code repo
    └── <project>-private/  # private notes repo

Modes:
  retrofit <path>            wrap an existing public repo
  new <name>                 create a new wrapper, optionally cloning or init'ing public
  sync                       re-scan the wrapper, refresh workspace + agent wiring + map
  collect                    recover private-shaped docs from public repo history
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
TEMPLATES_DIR = SKILL_DIR / "templates"

PRIVATE_SUBDIRS = ["docs", "notes", "drafts", "reviews", "research"]

# Branch-name prefixes whose unmerged tips signal private-bound work.
# Retroactive heuristic: files reachable from these refs but not from the
# default branch are likely design docs / notes / drafts that were committed
# to the public repo but never landed.
DEFAULT_BRANCH_PREFIXES = ("design/", "notes/", "drafts/", "private/")

# Path-pattern → bucket mapping. First match wins. Patterns are matched as
# fnmatch globs against the repo-relative POSIX path (case-insensitive).
# Conservative defaults: only files that look unambiguously like private
# notes. The user reviews the dry-run plan before anything is copied.
PATH_RULES: list[tuple[str, str]] = [
    # docs/ (design docs, RFCs, ADRs)
    ("docs/design/**", "docs"),
    ("docs/rfcs/**", "docs"),
    ("docs/adr/**", "docs"),
    ("design/**", "docs"),
    ("rfcs/**", "docs"),
    ("**/rfc-*.md", "docs"),
    ("**/*-design.md", "docs"),
    ("**/design.md", "docs"),
    ("**/architecture.md", "docs"),
    # drafts/
    ("drafts/**", "drafts"),
    ("**/draft-*.md", "drafts"),
    ("**/*.draft.md", "drafts"),
    # reviews/
    ("reviews/**", "reviews"),
    ("**/review-*.md", "reviews"),
    # research/
    ("research/**", "research"),
    ("**/research-*.md", "research"),
    # notes/
    ("notes/**", "notes"),
    ("**/notes.md", "notes"),
    ("**/scratch.md", "notes"),
    ("**/*.private.md", "notes"),
]


def discover_repos(parent: Path) -> list[str]:
    """Return the names of immediate subdirectories of `parent` that are git repos.

    This is how the wrapper learns its members: every git repo dropped under
    it — public, public-fork, private, private-fork, or anything else — becomes
    a workspace root on the next `new`/`retrofit`/`sync`. Sorted for determinism.
    """
    if not parent.is_dir():
        return []
    return sorted(
        child.name
        for child in parent.iterdir()
        if child.is_dir() and is_git_repo(child)
    )


def choose_canonical(repos: list[str], known_public: Optional[str] = None) -> Optional[str]:
    """Pick the canonical working dir — the one Claude launches from.

    Preference: an explicitly-known public dir, then a `*-public` repo, then a
    `*-public-fork`, then the first repo alphabetically. Keeping a single
    canonical cwd is what keeps Claude session history in one bucket; the other
    repos are reachable as additional working directories.
    """
    if not repos:
        return None
    if known_public and known_public in repos:
        return known_public
    for r in repos:
        if r.endswith("-public"):
            return r
    for r in repos:
        if r.endswith("-public-fork"):
            return r
    return repos[0]


def _hsl_to_hex(h: float, s: float, l: float) -> str:
    """HSL (h in [0,360), s/l in [0,1]) → #rrggbb."""
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs((h / 60) % 2 - 1))
    m = l - c / 2
    r, g, b = [
        (c, x, 0.0), (x, c, 0.0), (0.0, c, x),
        (0.0, x, c), (x, 0.0, c), (c, 0.0, x),
    ][int(h // 60) % 6]
    return "#{:02x}{:02x}{:02x}".format(
        round((r + m) * 255), round((g + m) * 255), round((b + m) * 255)
    )


def project_accent(project_name: str) -> dict[str, str]:
    """A stable per-project title/activity/status-bar color scheme.

    Derive a hue from the project name so each project's VS Code window is
    visually distinct at a glance — no two open projects share a title-bar color
    unless their names collide.
    """
    hue = int(hashlib.md5(project_name.encode()).hexdigest(), 16) % 360
    base = _hsl_to_hex(hue, 0.42, 0.30)
    dark = _hsl_to_hex(hue, 0.40, 0.24)
    border = _hsl_to_hex(hue, 0.45, 0.38)
    accent = _hsl_to_hex(hue, 0.68, 0.62)
    return {
        "titleBar.activeBackground": base,
        "titleBar.activeForeground": "#ffffff",
        "titleBar.inactiveBackground": dark,
        "titleBar.inactiveForeground": "#c8c8c8",
        "titleBar.border": border,
        "activityBar.background": base,
        "activityBar.foreground": "#ffffff",
        "activityBar.activeBorder": accent,
        "activityBar.activeBackground": border,
        "activityBarBadge.background": accent,
        "activityBarBadge.foreground": "#1e1e1e",
        "statusBar.background": base,
        "statusBar.foreground": "#ffffff",
        "statusBar.border": border,
    }


def _ordered_folders(repos: list[str], canonical: Optional[str]) -> list[str]:
    rest = sorted(r for r in repos if r != canonical)
    return ([canonical] if canonical in repos else []) + rest


CLAUDE_TASK_LABEL_PREFIX = "Claude Code ("

GREENROOM_MARKER = ".greenroom"


def _launcher_task(canonical: Optional[str]) -> dict:
    """The Tasks-based Claude launcher: cwd = the wrapper (the parent of the
    canonical repo), running plain `claude`. The child repos are under the
    wrapper cwd, so no `--add-dir` and no CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD
    are needed — siblings are reachable and each child's CLAUDE.md loads lazily on
    first touch.
    """
    wrapper_cwd = f"${{workspaceFolder:{canonical}}}/.." if canonical else "${workspaceFolder}/.."
    return {
        "label": f"{CLAUDE_TASK_LABEL_PREFIX}{canonical or 'project'})",
        "type": "shell",
        "command": "claude",
        "args": [],
        "options": {"cwd": wrapper_cwd},
        "presentation": {
            "reveal": "always",
            "panel": "dedicated",
            "focus": True,
            "echo": False,
            "showReuseMessage": False,
        },
        "problemMatcher": [],
    }


def _merge_launcher(existing: dict, task: dict) -> None:
    """Refresh the launcher we authored, in place, without touching other tasks.

    On an *existing* workspace the `tasks` key is already present, so a plain
    setdefault would leave a stale launcher (e.g. an older one that still carries
    `--add-dir`/env wiring). Instead: drop any task we authored (label starts
    with "Claude Code (") and append the current wrapper-rooted launcher;
    leave the user's own tasks be.
    """
    block = existing.get("tasks")
    if not isinstance(block, dict) or not isinstance(block.get("tasks"), list):
        existing["tasks"] = {"version": "2.0.0", "tasks": [task]}
        return
    block.setdefault("version", "2.0.0")
    tlist = block["tasks"]
    tlist[:] = [
        t for t in tlist
        if not (isinstance(t, dict) and str(t.get("label", "")).startswith(CLAUDE_TASK_LABEL_PREFIX))
    ]
    tlist.append(task)


_VSCODE_FAMILY = ("code", "cursor", "codium", "vscodium", "windsurf")


def _vscode_family_detected(wrapper: Path) -> bool:
    """True if a VS-Code-family editor is plausibly in use here.

    Signals: a family binary on PATH, an existing `.vscode/` dir, or an existing
    `*.code-workspace` in the wrapper. GREENROOM_TEST_NO_EDITOR forces the PATH
    probe to find nothing (test-only determinism; the file-presence signals still
    apply).
    """
    if not os.environ.get("GREENROOM_TEST_NO_EDITOR"):
        if any(shutil.which(b) for b in _VSCODE_FAMILY):
            return True
    if (wrapper / ".vscode").is_dir():
        return True
    return any(wrapper.glob("*.code-workspace"))


def should_write_workspace(wrapper: Path, flag: Optional[bool]) -> bool:
    """Resolve flag-or-detection. flag True/False forces; None → detect."""
    if flag is not None:
        return flag
    return _vscode_family_detected(wrapper)


def write_code_workspace(
    wrapper: Path, project_name: str, repos: list[str], canonical: Optional[str]
) -> Path:
    """Write (or merge into) a VS Code multi-root workspace file at the wrapper root.

    Lists every discovered repo as a folder root (canonical first), anchors the
    canonical Claude session cwd, disables parent-folder repo scanning, and
    paints the window with a per-project accent color. The Claude launcher task
    is rooted at the wrapper (the parent of the canonical repo), so every child
    repo is under cwd and each child's CLAUDE.md loads lazily on first touch —
    no `--add-dir` or env var needed.

    Idempotent and additive: if the file already exists, only *add* missing
    folder roots and missing settings keys — never overwrite an existing folder,
    setting, task, or hand-added customization. (A `.code-workspace` is JSONC;
    if it has comments, stdlib JSON can't parse it, so the file is left untouched
    and a warning is printed.)
    """
    workspace_path = wrapper / f"{project_name}.code-workspace"
    desired_folders = [{"name": r, "path": r} for r in _ordered_folders(repos, canonical)]
    settings: dict[str, object] = {
        "git.openRepositoryInParentFolders": "never",
        "git.detectSubmodules": False,
        "window.title": f"{project_name}: ${{activeFolderShort}}${{separator}}${{rootName}}",
        "workbench.colorCustomizations": project_accent(project_name),
    }
    if canonical:
        settings["terminal.integrated.cwd"] = f"${{workspaceFolder:{canonical}}}/.."
    task = _launcher_task(canonical)
    extensions = {"recommendations": ["anthropic.claude-code"]}

    if workspace_path.exists():
        try:
            existing = json.loads(workspace_path.read_text())
        except (json.JSONDecodeError, OSError) as e:
            warn(f"could not parse {workspace_path} ({e}); leaving it untouched")
            return workspace_path
        folders = existing.setdefault("folders", [])
        have = {f.get("path") for f in folders if isinstance(f, dict)}
        added = [f["path"] for f in desired_folders if f["path"] not in have]
        folders.extend(f for f in desired_folders if f["path"] not in have)
        es = existing.setdefault("settings", {})
        # Refresh a window.title we generated in an older form (it once used an
        # em dash); match the exact legacy value so a user's custom title, even
        # one ending with the same suffix, is left alone.
        legacy_title = f"{project_name} — ${{activeFolderShort}}${{separator}}${{rootName}}"
        if es.get("window.title") == legacy_title:
            es["window.title"] = settings["window.title"]
        for k, v in settings.items():
            es.setdefault(k, v)
        _merge_launcher(existing, task)  # refresh our launcher, keep the user's tasks
        existing.setdefault("extensions", extensions)
        existing["greenroom"] = {"wrapper": True}  # always stamp the canonical sentinel
        workspace_path.write_text(json.dumps(existing, indent="\t", ensure_ascii=False) + "\n")
        if added:
            info(f"  workspace: added folder(s) {', '.join(added)}")
        return workspace_path

    workspace = {
        "folders": desired_folders,
        "settings": settings,
        "tasks": {"version": "2.0.0", "tasks": [task]},
        "extensions": extensions,
        "greenroom": {"wrapper": True},  # self-identify as a greenroom wrapper
    }
    workspace_path.write_text(json.dumps(workspace, indent="\t", ensure_ascii=False) + "\n")
    return workspace_path


def _exclude_locally(repo: Path, pattern: str) -> None:
    """Add `pattern` to the repo's local .git/info/exclude (untracked ignore).

    Keeps a generated file out of `git status` without touching the tracked
    .gitignore -- so re-running never dirties the public repo's history.

    Uses `git rev-parse --git-path info/exclude` so it works for both normal
    repos (.git/ is a dir) and linked worktrees (.git is a file pointing
    elsewhere). If the directory is not a git repo at all, skips silently.
    """
    r = subprocess.run(
        ["git", "rev-parse", "--git-path", "info/exclude"],
        cwd=repo, capture_output=True, text=True, check=False,
    )
    if r.returncode != 0:
        return  # not a git repo -- skip
    exclude = Path(r.stdout.strip())
    if not exclude.is_absolute():
        exclude = repo / exclude
    try:
        exclude.parent.mkdir(parents=True, exist_ok=True)
        lines = exclude.read_text().splitlines() if exclude.exists() else []
        if pattern not in lines:
            lines.append(pattern)
            exclude.write_text("\n".join(lines) + "\n")
    except OSError:
        pass


def write_claude_settings_local(canonical_dir: Path, siblings: list[str]) -> Optional[Path]:
    """Grant a Claude session in the given repo (`canonical_dir`) access to the sibling repos.

    Writes `<canonical>/.claude/settings.local.json` with each sibling listed in
    `permissions.additionalDirectories` (`../<name>` — the documented form, a
    list of sibling checkouts). Add-only: any current sibling missing from the
    list is appended; existing entries (including ones you added) are kept.
    `.local.json` is gitignored, and locally excluded here too, so the private
    paths it names never land in the public repo's tracked files.

    Returns None when there are no siblings to grant (a lone repo needs nothing).
    """
    if not canonical_dir.is_dir() or not siblings:
        return None
    claude_dir = canonical_dir / ".claude"
    claude_dir.mkdir(exist_ok=True)
    settings_path = claude_dir / "settings.local.json"
    data: dict = {}
    if settings_path.exists():
        try:
            data = json.loads(settings_path.read_text())
        except json.JSONDecodeError:
            warn(f"{settings_path} is malformed JSON; leaving it untouched")
            return settings_path
        except OSError:
            warn(f"{settings_path} could not be read; leaving it untouched")
            return settings_path
    perms = data.setdefault("permissions", {})
    dirs = perms.setdefault("additionalDirectories", [])
    for s in siblings:
        if s not in dirs:
            dirs.append(s)
    settings_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    _exclude_locally(canonical_dir, ".claude/settings.local.json")
    return settings_path


def write_all_grants(wrapper: Path, repos: list[str]) -> list[Path]:
    """Write an `additionalDirectories` grant into EVERY repo, each listing its
    siblings. Defense-in-depth: under the canonical wrapper launch the grants are
    inert (siblings are under cwd), but a stray launch inside any single repo can
    still reach the others.
    """
    written: list[Path] = []
    for repo in repos:
        siblings = [f"../{r}" for r in sorted(repos) if r != repo]
        p = write_claude_settings_local(wrapper / repo, siblings)
        if p:
            written.append(p)
    return written


def write_per_repo_claude_pointers(wrapper: Path, repos: list[str]) -> list[Path]:
    """For each repo that has its own AGENTS.md, write a CLAUDE.md pointer if absent.

    A repo launched standalone should find a CLAUDE.md that points Claude at
    its own AGENTS.md. Write-if-absent: never clobbers a hand-edited CLAUDE.md.
    Only writes where AGENTS.md already exists -- does not create AGENTS.md.
    """
    written: list[Path] = []
    for repo in repos:
        repo_dir = wrapper / repo
        if not (repo_dir / "AGENTS.md").exists():
            continue
        path, _ = write_claude_pointer(repo_dir)
        written.append(path)
    return written


# Detection keys off this stable prefix, never the full sentence: the begin
# marker embeds the command name, which has been renamed across versions
# (`greenroom sync` -> `/greenroom-sync` -> `/greenroom:sync`). Matching the
# whole sentence would silently orphan every README written by an older version
# (#2). The replace below rewrites the span with README_BEGIN, migrating the
# marker in one pass.
BEGIN_TOKEN = "<!-- greenroom:begin"
README_BEGIN = f"{BEGIN_TOKEN} (auto-generated by `/greenroom:sync`; edits inside are overwritten) -->"
README_END = "<!-- greenroom:end -->"


def _repo_role(name: str) -> str:
    if name.endswith("-public-fork"):
        return "your public fork"
    if name.endswith("-private-fork"):
        return "your private dev fork"
    if name.endswith("-public"):
        return "your public repo, the stage; where public work lands"
    if name.endswith("-private"):
        return "private notes: design docs, drafts, reviews (never published)"
    return "repo under this project"


def _readme_block(project_name: str, repos: list[str], canonical: Optional[str]) -> str:
    lines = [
        README_BEGIN,
        "",
        f"## {project_name} workspace map",
        "",
        "Multi-repo project. Launch your agent at this wrapper directory; never "
        "`Open Folder` on a single repo. If a "
        f"`{project_name}.code-workspace` is present (written when a VS Code-family "
        "editor is detected), open it instead of `Open Folder` on the wrapper.",
        "",
    ]
    if canonical:
        lines += [
            f"**Launch home:** this wrapper directory. From any terminal: `cd {project_name} && <your-agent>` "
            "(claude, codex, gemini, and so on). That keeps session history and memory in one bucket and gives "
            "the session every child repo with no extra wiring. If a "
            f"`{project_name}.code-workspace` exists, VS Code-family users can open it or run the "
            f"`Claude Code ({canonical})` task. After adding a new "
            "repo under this wrapper, run `/greenroom:sync` (or the `greenroom` skill's `sync` subcommand) "
            "to wire it in.",
            "",
        ]
    lines += ["| Repo | Role |", "|---|---|"]
    for r in _ordered_folders(repos, canonical):
        marker = " *(canonical)*" if r == canonical else ""
        lines.append(f"| `{r}/`{marker} | {_repo_role(r)} |")
    lines += [
        "",
        "This folder is the project container, not a git repo. **Launch your agent here, at the wrapper** "
        "(`cd <wrapper> && <your-agent>`). Every repo below is then reachable as a subdirectory, and each repo's "
        "own `AGENTS.md` loads automatically the first time the agent touches its files. If you launch inside a single "
        "repo instead, you get a separate session bucket and only that repo's siblings via its "
        "`.claude/settings.local.json` grant.",
        "",
        README_END,
    ]
    return "\n".join(lines)


def write_workspace_readme(
    wrapper: Path, project_name: str, repos: list[str], canonical: Optional[str]
) -> tuple[Path, str]:
    """Write/refresh the wrapper-root README that maps the repos for agents.

    The map lives inside marker comments. Regenerating only rewrites the marked
    block, preserving anything you added around it. A README with no markers
    (hand-authored) is left alone.
    """
    readme = wrapper / "README.md"
    block = _readme_block(project_name, repos, canonical)
    if not readme.exists():
        readme.write_text(f"# {project_name}\n\n{block}\n")
        return readme, "created"
    text = readme.read_text()
    if BEGIN_TOKEN in text and README_END in text:
        pre = text[: text.index(BEGIN_TOKEN)]
        post = text[text.index(README_END) + len(README_END):]
        readme.write_text(pre + block + post)
        return readme, "updated"
    return readme, "skipped"


def write_agents_md(
    wrapper: Path, project_name: str, canonical: Optional[str]
) -> tuple[Path, str]:
    """Write the wrapper-root AGENTS.md (the neutral core instruction file).

    Write-if-absent: never clobber a hand-edited file. Delete it to regenerate.
    """
    path = wrapper / "AGENTS.md"
    if path.exists():
        return path, "exists"
    subs = {
        "{{PROJECT_NAME}}": project_name,
        "{{CANONICAL_DIR_NAME}}": canonical or f"{project_name}-public",
    }
    path.write_text(render_template("wrapper_AGENTS.md", subs))
    return path, "created"


def write_claude_pointer(target_dir: Path) -> tuple[Path, str]:
    """Claude adapter: write CLAUDE.md containing exactly '@AGENTS.md'.

    Write-if-absent: a hand-edited CLAUDE.md is left untouched.
    Works for the wrapper root or any repo dir that has its own AGENTS.md.
    """
    path = target_dir / "CLAUDE.md"
    if path.exists():
        return path, "exists"
    path.write_text("@AGENTS.md\n")
    return path, "created"


def write_gemini_settings(wrapper: Path) -> tuple[Path, str]:
    """Gemini adapter: write .gemini/settings.json pointing at AGENTS.md.

    Merges gracefully if the file already exists (preserves other keys).
    Git-excluded locally like settings.local.json.

    Note: .gemini/settings.json lives inside a git repo, so it needs
    _exclude_locally. The <project>.code-workspace lives in the non-git
    wrapper root, so it needs no exclude.
    """
    gemini_dir = wrapper / ".gemini"
    gemini_dir.mkdir(exist_ok=True)
    settings_path = gemini_dir / "settings.json"
    data: dict = {}
    status = "created"
    if settings_path.exists():
        try:
            data = json.loads(settings_path.read_text())
        except json.JSONDecodeError:
            warn(f"{settings_path} is malformed JSON; leaving it untouched")
            return settings_path, "skipped (malformed)"
        except OSError:
            warn(f"{settings_path} could not be read; leaving it untouched")
            return settings_path, "skipped (unreadable)"
        status = "updated"
    context = data.setdefault("context", {})
    if context.get("fileName") == "AGENTS.md" and status == "updated":
        status = "exists"
    context["fileName"] = "AGENTS.md"
    settings_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    _exclude_locally(wrapper, ".gemini/settings.json")
    return settings_path, status


def write_greenroom_marker(wrapper: Path) -> Path:
    """Write the editor-neutral wrapper identity marker, write-if-absent.

    Existence is the signal; content is a schema version only. Never store repo
    lists or the canonical name — they go stale and are derivable. Lives at the
    non-git wrapper root, so (unlike .gemini/settings.json) it needs no
    .git/info/exclude handling. An existing marker is left untouched so a future
    schema bump is a deliberate migration, not an accidental overwrite.
    """
    path = wrapper / GREENROOM_MARKER
    if not path.exists():
        # Explicit utf-8 to match _has_greenroom_marker's reader (writer/reader
        # symmetry, regardless of the host's locale default encoding).
        path.write_text(json.dumps({"schema": 1}) + "\n", encoding="utf-8")
    return path


def migrate_claude_to_agents(
    wrapper: Path, project_name: str, canonical: Optional[str]
) -> Optional[tuple[Path, str]]:
    """Migrate a greenroom-authored CLAUDE.md to AGENTS.md + pointer, in place.

    Returns (agents_path, "migrated") if migration happened, else None.

    Detection rule: CLAUDE.md content (normalized) equals what greenroom would
    write from the wrapper_AGENTS.md template with the same project/canonical
    subs. If content differs, it is hand-edited and left alone.
    """
    agents_path = wrapper / "AGENTS.md"
    claude_path = wrapper / "CLAUDE.md"

    # Already migrated: idempotent.
    if agents_path.exists():
        return None

    # Nothing to migrate.
    if not claude_path.exists():
        return None

    subs = {
        "{{PROJECT_NAME}}": project_name,
        "{{CANONICAL_DIR_NAME}}": canonical or f"{project_name}-public",
    }
    expected = render_template("wrapper_AGENTS.md", subs)

    actual = claude_path.read_text()
    if actual.rstrip() != expected.rstrip():
        warn(
            f"CLAUDE.md looks hand-edited; add `@AGENTS.md` at the top yourself "
            f"or let it stand. Migration skipped for {claude_path}"
        )
        return None

    # Greenroom-authored: write AGENTS.md with the content, overwrite CLAUDE.md
    # to be the pointer.
    agents_path.write_text(expected)
    claude_path.write_text("@AGENTS.md\n")
    info(f"  migrated: CLAUDE.md → AGENTS.md + pointer ({wrapper})")
    return agents_path, "migrated"


# Dirs greenroom must never treat as a wrapper, wrapper-parent, or scaffold
# target, regardless of any signal they carry. $HOME is the headline case: a
# stray *.code-workspace from another tool once made it classify as a wrapper,
# and greenroom scaffolded ~/CLAUDE.md (loaded into nearly every session).
# Standard top-level $HOME subdirs a user would never intend as a project root.
# Best-effort named floor (the $HOME-itself, filesystem-root, and GREENROOM_ROOT
# guards apply regardless of OS); covers the macOS user dirs plus the XDG dirs
# that differ on Linux (Videos, Templates). Arbitrary locale-localized casings
# are out of scope — set GREENROOM_ROOT for a tighter boundary.
_FORBIDDEN_HOME_SUBDIRS = frozenset({
    "Documents", "Desktop", "Downloads", "Library",
    "Music", "Pictures", "Movies", "Videos", "Templates", "Public",
    ".config", ".claude", ".local",
})


def _greenroom_root() -> Optional[Path]:
    """The GREENROOM_ROOT boundary, resolved, or None if unset/blank."""
    raw = os.environ.get("GREENROOM_ROOT", "").strip()
    if not raw:
        return None
    return Path(raw).expanduser().resolve()


def _is_always_forbidden(d: Path) -> bool:
    """The categorical floor: dirs greenroom must never touch in any role.

    $HOME, the filesystem root, standard $HOME subdirs and dotfile config roots,
    and (when GREENROOM_ROOT is set) any *ancestor* of the boundary. Note this
    does NOT include GREENROOM_ROOT itself: the boundary is a valid parent for a
    project created directly under it (see _is_forbidden_parent), but not a valid
    scaffold target (see _is_forbidden_root).
    """
    d = d.resolve()
    home = Path.home().resolve()
    if d == home:
        return True
    if d.parent == d:  # filesystem root
        return True
    if d.parent == home and d.name in _FORBIDDEN_HOME_SUBDIRS:
        return True
    gr = _greenroom_root()
    if gr is not None and d in gr.parents:  # strictly above the boundary
        return True
    return False


def _is_forbidden_root(d: Path) -> bool:
    """True if `d` must never be a wrapper or scaffold target.

    The always-forbidden floor plus GREENROOM_ROOT itself: greenroom scaffolds
    *under* the boundary, never *at* it. Used by classification, the walk-up,
    and `sync`.
    """
    d = d.resolve()
    if _is_always_forbidden(d):
        return True
    gr = _greenroom_root()
    return gr is not None and d == gr


def _is_forbidden_parent(d: Path) -> bool:
    """True if `d` must never be the *parent* of a new wrapper.

    Same floor as a scaffold target, but GREENROOM_ROOT itself is allowed: the
    documented workflow `GREENROOM_ROOT="$HOME/GitHub"` then `new --parent
    "$HOME/GitHub"` creates a project directly under the boundary. Used by
    `new` and `retrofit`.
    """
    return _is_always_forbidden(d)


def _has_greenroom_marker(d: Path) -> bool:
    """True if `d` holds a `.greenroom` marker with an int `schema` key.

    Mirrors _has_greenroom_workspace's strictness: a stray, non-JSON, or
    schema-less `.greenroom` (e.g. a file another tool happened to drop) does
    not qualify d as a greenroom wrapper.
    """
    marker = d / GREENROOM_MARKER
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError, UnicodeDecodeError):
        return False
    return isinstance(data, dict) and isinstance(data.get("schema"), int)


def _has_greenroom_workspace(d: Path) -> bool:
    """True if `d` holds a *.code-workspace carrying greenroom's sentinel.

    A bare workspace from another tool (chezmoi, a hand-rolled multi-root) must
    NOT qualify d as a greenroom wrapper; only one greenroom itself wrote does.
    """
    for ws in d.glob("*.code-workspace"):
        try:
            # Read UTF-8 explicitly to match the write side (write_code_workspace
            # uses ensure_ascii=False), so a greenroom-authored workspace with
            # non-ASCII paths still qualifies on a non-UTF-8-locale machine.
            data = json.loads(ws.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError, UnicodeDecodeError):
            continue
        gr = data.get("greenroom") if isinstance(data, dict) else None
        if isinstance(gr, dict) and gr.get("wrapper") is True:
            return True
    return False


def _is_project_wrapper(d: Path) -> bool:
    """True if `d` looks like a greenroom wrapper, not just any dir of repos.

    Guard against matching a generic clone parent like `~/GitHub` (which would
    grant `..` over the whole home dir and scan every repo). A real wrapper is a
    non-repo dir holding git repos *and* carrying a wrapper signal: a `.greenroom`
    marker, a greenroom-authored `*.code-workspace`, or a `*-private` repo sibling.
    """
    if _is_forbidden_root(d):
        return False
    if is_git_repo(d):
        return False
    repos = discover_repos(d)
    if not repos:
        return False
    if _has_greenroom_marker(d):
        return True
    if _has_greenroom_workspace(d):
        return True
    return any(r.endswith("-private") for r in repos)


def _find_wrapper(start: Path) -> Optional[Path]:
    """Walk up from `start` to the nearest greenroom wrapper (see _is_project_wrapper).

    Never crosses a forbidden root: the walk stops before testing $HOME, the
    filesystem root, or (when set) GREENROOM_ROOT, so it can never classify a
    high-blast-radius dir as a wrapper.
    """
    cur = start.resolve()
    for _ in range(8):
        if _is_forbidden_root(cur):
            return None
        if _is_project_wrapper(cur):
            return cur
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(msg)


def warn(msg: str) -> None:
    print(f"warn: {msg}", file=sys.stderr)


def run(cmd: list[str], cwd: Optional[Path] = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, capture_output=True, text=True)


def is_git_repo(path: Path) -> bool:
    return (path / ".git").exists()


def working_tree_clean(path: Path) -> bool:
    result = run(["git", "status", "--porcelain"], cwd=path, check=False)
    return result.returncode == 0 and not result.stdout.strip()


def get_github_repo(repo_path: Path) -> Optional[str]:
    """Return 'owner/repo' from origin URL, or None if not a GitHub remote."""
    result = run(["git", "remote", "get-url", "origin"], cwd=repo_path, check=False)
    if result.returncode != 0:
        return None
    url = result.stdout.strip()
    if "github.com" not in url:
        return None
    part = url.split("github.com", 1)[1].lstrip(":/").rstrip("/")
    if part.endswith(".git"):
        part = part[:-4]
    return part if "/" in part else None


def _get_gh_owner() -> Optional[str]:
    """Return the authenticated GitHub login via `gh api user`, or None."""
    if not shutil.which("gh"):
        return None
    try:
        result = subprocess.run(
            ["gh", "api", "user", "--jq", ".login"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            login = result.stdout.strip()
            return login if login else None
    except OSError:
        pass
    return None


def _has_origin(repo_path: Path) -> bool:
    """Return True if the repo at `repo_path` has a remote named 'origin'."""
    result = run(["git", "remote"], cwd=repo_path, check=False)
    return "origin" in result.stdout.split()


def print_repo_creation_offer(wrapper: Path, repos: list[str]) -> None:
    """Print (but never run) `gh repo create --private` commands for private siblings with no origin.

    Only repos whose name ends with -private or -private-fork AND have no origin remote
    are included. The public repo is never offered (leak-hygiene constraint).
    """
    private_suffixes = ("-private", "-private-fork")
    candidates = [
        r for r in repos
        if any(r.endswith(s) for s in private_suffixes)
        and not _has_origin(wrapper / r)
    ]
    if not candidates:
        return

    owner = _get_gh_owner()
    owner_label = owner if owner else "<owner>"
    if not owner:
        info("  (gh not available or not authed -- owner shown as placeholder)")

    info("")
    info("To create private GitHub repos for these (optional):")
    info("  (These are --private; nothing reaches GitHub without running these yourself.)")
    for r in candidates:
        # Every interpolated token here is pasted into a shell, so quote them all:
        # the repo dir name `r` (and thus the spec) can contain spaces, and the
        # `<owner>` placeholder itself carries shell-significant angle brackets.
        spec = shlex.quote(f"{owner_label}/{r}")
        path = shlex.quote(str(wrapper / r))
        info(f"  gh repo create {spec} --private --source={path} --remote=origin")


def create_private_fork(wrapper: Path, public_dir_name: str, project_name: str) -> Optional[Path]:
    """Clone the local public repo into <project>-private-fork with remote named 'upstream'.

    Returns the fork path on success, None on failure.
    Guards: public must exist and be a git repo. Warns and returns None on clone failure.
    """
    public_path = wrapper / public_dir_name
    if not public_path.is_dir() or not is_git_repo(public_path):
        warn(f"--with-private-fork: {public_path} is not a git repo; skipping fork creation")
        return None
    fork_name = f"{project_name}-private-fork"
    fork_path = wrapper / fork_name
    if fork_path.exists():
        warn(f"--with-private-fork: {fork_path} already exists; skipping fork creation")
        return None
    result = run(
        ["git", "clone", "-o", "upstream", str(public_path), str(fork_path)],
        check=False,
    )
    if result.returncode != 0:
        warn(f"--with-private-fork: clone failed ({result.stderr.strip()}); skipping fork creation")
        return None
    return fork_path


def render_template(name: str, subs: dict[str, str]) -> str:
    text = (TEMPLATES_DIR / name).read_text()
    for k, v in subs.items():
        text = text.replace(k, v)
    return text


def write_private_scaffold(
    private_dir: Path,
    project_name: str,
    public_dir_name: str,
    github_repo: Optional[str],
) -> None:
    """Create the <project>-private/ git repo with conventions and dir skeleton."""
    if private_dir.exists():
        die(f"{private_dir} already exists; refusing to overwrite")

    private_dir.mkdir(parents=True)
    run(["git", "init", "-b", "main"], cwd=private_dir)

    repo_link = (
        f"GitHub: [`{github_repo}`](https://github.com/{github_repo})."
        if github_repo
        else "(Not yet pushed to GitHub.)"
    )
    subs = {
        "{{PROJECT_NAME}}": project_name,
        "{{PUBLIC_DIR_NAME}}": public_dir_name,
        "{{PRIVATE_DIR_NAME}}": private_dir.name,
        "{{REPO_LINK}}": repo_link,
    }

    (private_dir / "AGENTS.md").write_text(render_template("private_AGENTS.md", subs))
    (private_dir / "README.md").write_text(render_template("private_README.md", subs))
    (private_dir / ".gitignore").write_text(render_template("private_gitignore", {}))

    for sub in PRIVATE_SUBDIRS:
        d = private_dir / sub
        d.mkdir()
        (d / ".gitkeep").touch()


def check_plugin_configs(old_path: Path) -> list[Path]:
    """Return list of Claude Code config files referencing the old repo path."""
    candidates = [
        Path.home() / ".claude" / "plugins" / "known_marketplaces.json",
        Path.home() / ".claude" / "settings.json",
    ]
    found: list[Path] = []
    # Match the path only at a component boundary so /GitHub/foo doesn't also
    # flag /GitHub/foobar. The path may be followed by a quote, a path
    # separator, or end-of-value, but not another path-name character.
    needle = re.compile(re.escape(str(old_path)) + r"(?![\w.\-])")
    for cfg in candidates:
        if not cfg.exists():
            continue
        try:
            text = cfg.read_text()
        except OSError:
            continue
        if needle.search(text):
            found.append(cfg)
    return found


def _find_existing_private(parent: Path, project_name: str, src: Path) -> Optional[Path]:
    """Return the existing private dir alongside src, if any.

    Recognizes the canonical `<project>-private/` name and the legacy
    plain `private/` name (for projects scaffolded before the rename).
    """
    for candidate_name in (f"{project_name}-private", "private"):
        candidate = parent / candidate_name
        if candidate.is_dir() and candidate != src:
            return candidate
    return None


def _looks_like_wrapper(parent: Path, project_name: str, src: Path) -> bool:
    """Heuristic: src.parent already looks like a greenroom wrapper.

    A wrapper is a non-git folder that contains src plus a sibling
    `<project>-private/` or legacy `private/`. If we see those signals,
    the user is re-running retrofit on something already laid out — even
    if the wrapper's basename doesn't match the public dir's basename.
    """
    if is_git_repo(parent):
        return False  # parent is itself a repo — not a wrapper
    return _find_existing_private(parent, project_name, src) is not None


def cmd_retrofit(args: argparse.Namespace) -> None:
    # Capture the invoking shell's cwd before any move. If we do an in-place
    # wrap, the dir the shell is sitting in gets renamed out from under it, so
    # we warn at the end (the shell keeps a stale handle until it re-resolves).
    try:
        invoked_cwd = Path.cwd()
    except OSError:
        invoked_cwd = None
    src = Path(args.path).expanduser().resolve() if args.path else Path.cwd()
    if not src.is_dir():
        die(f"{src} is not a directory")
    if not is_git_repo(src):
        die(f"{src} is not a git repository")
    if not working_tree_clean(src):
        die(f"{src} has uncommitted changes; commit or stash before retrofitting")

    parent = src.parent
    if _is_forbidden_parent(parent):
        die(f"refusing to wrap {src}: its parent {parent} is $HOME, the "
            "filesystem root, or a standard system directory")

    # If args.name is unset, prefer deriving the project name from the wrapper
    # parent rather than the public dir's basename. This makes retrofit
    # idempotent on the canonical shape: wrapper=<name>/, public=<name>-public/
    # gets recognized from src alone without requiring --name.
    if args.name:
        project_name = args.name
    elif src.name.endswith("-public") and src.name == f"{parent.name}-public":
        project_name = parent.name
    else:
        project_name = src.name

    public_dir_name = args.public_name or (
        src.name if src.name.endswith("-public") else f"{project_name}-public"
    )
    private_dir_name = args.private_name or f"{project_name}-private"

    # Idempotent: if src is already inside a wrapper layout, leave the layout
    # alone and just top up missing pieces (private dir, workspace file).
    # Two recognized shapes:
    #   1. parent.name == project_name AND src.name == public_dir_name (script-created)
    #   2. parent contains a sibling <project>-private/ or legacy private/ dir
    #      and is not itself a git repo (covers user-named wrappers like
    #      bs/ + bs-public/)
    already_wrapped = (
        (parent.name == project_name and src.name == public_dir_name)
        or _looks_like_wrapper(parent, project_name, src)
    )

    if already_wrapped:
        wrapper = parent
        # Re-derive project_name from the wrapper if the user didn't specify
        # one — otherwise we'd write `<src.name>.code-workspace` instead of
        # the conventional `<wrapper.name>.code-workspace`.
        if not args.name:
            project_name = wrapper.name
            if not args.private_name:
                private_dir_name = f"{project_name}-private"
        public_dir_name = src.name
        info(f"{src} is already wrapped at {wrapper}; topping up missing pieces")
        public_path = src
    elif (parent / project_name) == src:
        # In-place wrap: the wrapper path collides with the source repo, so
        # move src aside, create the wrapper at src's old path, then move src
        # into it as <project>-public. Only src is touched — sibling repos in
        # the parent (the usual ~/GitHub case) are irrelevant. Wrapping the
        # parent itself can't happen: is_git_repo(src) already rejected
        # non-repo dirs like ~/GitHub.
        temp = parent / f".{project_name}.wrap-tmp"
        if temp.exists():
            die(f"temp path {temp} already exists; clean up and retry")
        src.rename(temp)
        wrapper = parent / project_name
        try:
            wrapper.mkdir()
            public_path = wrapper / public_dir_name
            temp.rename(public_path)
        except OSError as e:
            # Restore the repo to its original location before bailing so a
            # failed move never strands it at the temp path.
            if wrapper.is_dir() and not any(wrapper.iterdir()):
                wrapper.rmdir()
            if temp.exists() and not src.exists():
                temp.rename(src)
            die(f"failed to wrap {src} in place: {e}; restored to {src}")
    else:
        wrapper = parent / project_name
        if wrapper.exists() and any(wrapper.iterdir()):
            die(f"wrapper {wrapper} already exists and is non-empty")
        wrapper.mkdir(exist_ok=True)
        public_path = wrapper / public_dir_name
        if public_path.exists():
            die(f"target {public_path} already exists")
        src.rename(public_path)

    # The parent passed _is_forbidden_parent (which permits GREENROOM_ROOT as a
    # parent), but the resolved wrapper is the actual scaffold target — it must
    # clear the stricter _is_forbidden_root. Without this, retrofitting an
    # already-wrapped repo whose wrapper IS the boundary (wrapper == parent ==
    # GREENROOM_ROOT) would scaffold into the boundary that sync refuses.
    if _is_forbidden_root(wrapper):
        die(f"refusing to scaffold into {wrapper}: it is $HOME, the filesystem "
            "root, a standard system directory, or GREENROOM_ROOT")

    # Prefer the canonical <project>-private/, but if a legacy `private/`
    # already exists alongside, leave it where it is (don't auto-rename).
    existing_private = _find_existing_private(wrapper, project_name, public_path)
    if existing_private is not None:
        private_path = existing_private
        if private_path.name == "private":
            info(
                f"legacy private/ found at {private_path}; leaving it alone. "
                f"Rename to {project_name}-private to adopt the new convention."
            )
        else:
            info(f"{private_path.name}/ already exists at {private_path}; leaving it alone")
        private_dir_name = private_path.name
    else:
        private_path = wrapper / private_dir_name
        github_repo = get_github_repo(public_path)
        write_private_scaffold(private_path, project_name, public_dir_name, github_repo)

    if getattr(args, "with_private_fork", False):
        fork_path = create_private_fork(wrapper, public_dir_name, project_name)
    else:
        fork_path = None

    repos = discover_repos(wrapper)
    canonical = choose_canonical(repos, known_public=public_dir_name)
    if should_write_workspace(wrapper, getattr(args, "workspace", None)):
        workspace_path = write_code_workspace(wrapper, project_name, repos, canonical)
    else:
        workspace_path = None
    grant_paths = write_all_grants(wrapper, repos)  # Claude adapter: stray-launch safety net
    write_per_repo_claude_pointers(wrapper, repos)  # per-repo CLAUDE.md where AGENTS.md exists
    readme_path, readme_state = write_workspace_readme(wrapper, project_name, repos, canonical)
    agents_path, agents_state = write_agents_md(wrapper, project_name, canonical)
    claude_path, claude_state = write_claude_pointer(wrapper)  # Claude adapter: wrapper pointer
    gemini_path, gemini_state = write_gemini_settings(wrapper)  # Gemini adapter
    write_greenroom_marker(wrapper)  # editor-neutral wrapper identity

    info("")
    info(f"wrapped {project_name}:")
    info(f"  wrapper:    {wrapper}")
    info(f"  public:     {public_path}")
    info(f"  private:    {private_path}")
    if fork_path:
        info(f"  private-fork: {fork_path} (cloned from {public_dir_name}, remote 'upstream')")
    if workspace_path is not None:
        info(f"  workspace:  {workspace_path}")
    else:
        info("  workspace:  (skipped — no editor detected; run with --workspace to add one)")
    if grant_paths:
        info(f"  access:     {len(grant_paths)} repo(s) granted their siblings")
    info(f"  map:        {readme_path} ({readme_state})")
    info(f"  AGENTS.md:  {agents_path} ({agents_state})")
    info(f"  CLAUDE.md:  {claude_path} ({claude_state}) [Claude adapter]")
    info(f"  .gemini/settings.json: {gemini_path} ({gemini_state}) [Gemini adapter]")

    print_repo_creation_offer(wrapper, repos)

    if src != public_path:
        flagged = check_plugin_configs(src)
        if flagged:
            info("")
            info("⚠  Claude Code plugin configs reference the OLD path:")
            for f in flagged:
                info(f"   {f}")
            info(f"   Replace '{src}' → '{public_path}' in those files to keep plugin commands working.")

    # If the repo was moved (src != public_path: in-place or new-wrapper branch)
    # and the invoking shell was sitting inside it, that shell now holds a stale
    # handle to the moved contents (under <public>), so `ls`/`pwd` there look
    # wrong until it re-resolves the path. Tell the user to re-sync; this is
    # cosmetic, not data loss. (already_wrapped sets public_path == src: no move.)
    if src != public_path and invoked_cwd is not None and (
        invoked_cwd == src or src in invoked_cwd.parents
    ):
        info("")
        info(f"Note: your shell's current directory ({invoked_cwd}) was moved into")
        info(f"      {public_path}. The shell still points at the old location, so")
        info( "      `ls`/`pwd` there may look stale. Re-sync it with:")
        info(f"        cd {shlex.quote(str(wrapper))}")


def cmd_new(args: argparse.Namespace) -> None:
    parent = Path(args.parent).expanduser().resolve() if args.parent else Path.cwd()
    if not parent.is_dir():
        die(f"parent dir {parent} does not exist")
    if _is_forbidden_parent(parent):
        die(f"refusing to create a wrapper under {parent} "
            "($HOME, the filesystem root, and standard system directories are "
            "never valid wrapper parents)")

    project_name = args.name
    public_dir_name = args.public_name or f"{project_name}-public"
    private_dir_name = args.private_name or f"{project_name}-private"

    wrapper = parent / project_name
    if wrapper.exists():
        die(f"{wrapper} already exists")
    if not args.parent:
        info(f"creating wrapper in the current directory: {wrapper}")
    wrapper.mkdir()

    public_path = wrapper / public_dir_name
    github_repo: Optional[str] = None
    public_status = "(not created — clone or init it later)"

    if args.clone:
        info(f"cloning {args.clone} → {public_path}")
        run(["git", "clone", args.clone, str(public_path)])
        github_repo = get_github_repo(public_path)
        public_status = "(cloned)"
    elif args.init_public:
        public_path.mkdir()
        run(["git", "init", "-b", "main"], cwd=public_path)
        public_status = "(initialized empty)"

    private_path = wrapper / private_dir_name
    write_private_scaffold(private_path, project_name, public_dir_name, github_repo)

    if getattr(args, "with_private_fork", False):
        fork_path = create_private_fork(wrapper, public_dir_name, project_name)
    else:
        fork_path = None

    repos = discover_repos(wrapper)
    canonical = choose_canonical(
        repos, known_public=public_dir_name if public_path.is_dir() else None
    )
    if should_write_workspace(wrapper, getattr(args, "workspace", None)):
        workspace_path = write_code_workspace(wrapper, project_name, repos, canonical)
    else:
        workspace_path = None
    grant_paths = write_all_grants(wrapper, repos)  # Claude adapter: stray-launch safety net
    write_per_repo_claude_pointers(wrapper, repos)  # per-repo CLAUDE.md where AGENTS.md exists
    readme_path, readme_state = write_workspace_readme(wrapper, project_name, repos, canonical)
    agents_path, agents_state = write_agents_md(wrapper, project_name, canonical)
    claude_path, claude_state = write_claude_pointer(wrapper)  # Claude adapter: wrapper pointer
    gemini_path, gemini_state = write_gemini_settings(wrapper)  # Gemini adapter
    write_greenroom_marker(wrapper)  # editor-neutral wrapper identity

    info("")
    info(f"created {project_name}:")
    info(f"  wrapper:    {wrapper}")
    info(f"  public:     {public_path} {public_status}")
    info(f"  private:    {private_path}")
    if fork_path:
        info(f"  private-fork: {fork_path} (cloned from {public_dir_name}, remote 'upstream')")
    if workspace_path is not None:
        info(f"  workspace:  {workspace_path}")
    else:
        info("  workspace:  (skipped — no editor detected; run with --workspace to add one)")
    if grant_paths:
        info(f"  access:     {len(grant_paths)} repo(s) granted their siblings")
    info(f"  map:        {readme_path} ({readme_state})")
    info(f"  AGENTS.md:  {agents_path} ({agents_state})")
    info(f"  CLAUDE.md:  {claude_path} ({claude_state}) [Claude adapter]")
    info(f"  .gemini/settings.json: {gemini_path} ({gemini_state}) [Gemini adapter]")

    print_repo_creation_offer(wrapper, repos)


def cmd_sync(args: argparse.Namespace) -> None:
    """Re-scan a wrapper and (re)write the workspace + agent wiring + map.

    The re-run trigger: drop a new repo (a fork, another clone) under the
    wrapper, run `sync`, and it gets added as a workspace root, granted to
    Claude (`additionalDirectories`), and listed in the refreshed repo map.
    """
    if args.wrapper:
        wrapper = Path(args.wrapper).expanduser().resolve()
        if not wrapper.is_dir():
            die(f"{wrapper} is not a directory")
    else:
        found = _find_wrapper(Path.cwd())
        if found is None:
            die("could not find a greenroom wrapper from here; pass --wrapper or run from inside the project")
        wrapper = found

    if _is_forbidden_root(wrapper):
        die(f"refusing to treat {wrapper} as a greenroom wrapper "
            "(greenroom never scaffolds into $HOME, the filesystem root, or a "
            "standard system directory)")

    repos = discover_repos(wrapper)
    if not repos:
        die(f"no git repos found under {wrapper}")

    project_name = args.name or wrapper.name
    canonical = args.canonical or choose_canonical(repos)
    if canonical not in repos:
        die(f"canonical '{canonical}' is not a repo under {wrapper}; choices: {', '.join(repos)}")

    migrate_claude_to_agents(wrapper, project_name, canonical)  # legacy layout migration

    if should_write_workspace(wrapper, getattr(args, "workspace", None)):
        workspace_path = write_code_workspace(wrapper, project_name, repos, canonical)
    else:
        workspace_path = None
    grant_paths = write_all_grants(wrapper, repos)  # Claude adapter: stray-launch safety net
    write_per_repo_claude_pointers(wrapper, repos)  # per-repo CLAUDE.md where AGENTS.md exists
    readme_path, readme_state = write_workspace_readme(wrapper, project_name, repos, canonical)
    agents_path, agents_state = write_agents_md(wrapper, project_name, canonical)
    claude_path, claude_state = write_claude_pointer(wrapper)  # Claude adapter: wrapper pointer
    gemini_path, gemini_state = write_gemini_settings(wrapper)  # Gemini adapter
    write_greenroom_marker(wrapper)  # editor-neutral wrapper identity

    info("")
    info(f"synced {project_name}:")
    info(f"  wrapper:    {wrapper}")
    info(f"  repos:      {', '.join(repos)}")
    info(f"  canonical:  {canonical}")
    if workspace_path is not None:
        info(f"  workspace:  {workspace_path}")
    else:
        info("  workspace:  (skipped — no editor detected; run with --workspace to add one)")
    if grant_paths:
        info(f"  access:     {len(grant_paths)} repo(s) granted their siblings")
    info(f"  map:        {readme_path} ({readme_state})")
    info(f"  AGENTS.md:  {agents_path} ({agents_state})")
    info(f"  CLAUDE.md:  {claude_path} ({claude_state}) [Claude adapter]")
    info(f"  .gemini/settings.json: {gemini_path} ({gemini_state}) [Gemini adapter]")
    if readme_state == "skipped":
        info(f"  note: {readme_path} has no greenroom markers; left it alone. "
             "Delete it (or paste the map block in) to have sync manage it.")


def _classify(repo_relative_path: str) -> Optional[str]:
    """Return the bucket for a path, or None if no rule matches."""
    import fnmatch
    p = repo_relative_path.lower()
    base = p.rsplit("/", 1)[-1]
    for pattern, bucket in PATH_RULES:
        pat = pattern.lower()
        if fnmatch.fnmatch(p, pat):
            return bucket
        # `**/name` requires at least one directory, so it misses files at the
        # repo root. Also test the basename so root-level architecture.md,
        # notes.md, rfc-*.md, etc. classify the same as their nested twins.
        if pat.startswith("**/") and fnmatch.fnmatch(base, pat[3:]):
            return bucket
    return None


def _default_branch(repo: Path) -> str:
    """Best-effort default branch name.

    Priority:
    1. origin/HEAD (the authoritative remote default): strip to the branch name,
       then return the local counterpart if it exists, else the remote-tracking
       ref if it is reachable. Only when neither is reachable (stale pointer to
       a branch that was never fetched) fall through to the local heuristic.
    2. When origin/HEAD is absent or unresolvable (local-only or unfetched repo):
       try local main, then local master, then give up.

    This avoids the bug where a stray local `main` was preferred over a repo
    whose true default is `master` (or vice versa).
    """
    r = run(["git", "symbolic-ref", "refs/remotes/origin/HEAD"], cwd=repo, check=False)
    if r.returncode == 0 and r.stdout.strip():
        # refs/remotes/origin/HEAD -> refs/remotes/origin/<branch>
        # Use strip-prefix rather than split("/")[-1] so slash-containing branch
        # names like "release/stable" are preserved in full.
        remote_ref = r.stdout.strip()  # e.g. "refs/remotes/origin/release/stable"
        _prefix = "refs/remotes/origin/"
        branch = remote_ref[len(_prefix):] if remote_ref.startswith(_prefix) else remote_ref.split("/")[-1]
        # Prefer the local tracking branch if it exists (avoids "origin/" prefix
        # in git commands and stays close to the locally-committed tree).
        local = run(["git", "rev-parse", "--verify", branch], cwd=repo, check=False)
        if local.returncode == 0:
            return branch
        # No local branch; try the remote-tracking ref (requires a fetch, but may exist).
        remote_tracking = f"origin/{branch}"
        rt = run(["git", "rev-parse", "--verify", remote_tracking], cwd=repo, check=False)
        if rt.returncode == 0:
            return remote_tracking
        # origin/HEAD exists but points at a ref that is not reachable locally
        # (stale pointer, branch never fetched). Fall through to local heuristic.
    # No usable origin/HEAD -- local-only or unfetched. Try well-known defaults.
    for candidate in ("main", "master"):
        r = run(["git", "rev-parse", "--verify", candidate], cwd=repo, check=False)
        if r.returncode == 0:
            return candidate
    die(f"could not determine default branch for {repo}")
    return ""  # unreachable


def _list_branches(repo: Path, prefixes: tuple[str, ...]) -> list[str]:
    """Return local + remote branch refs whose short name starts with any prefix."""
    out = run(["git", "for-each-ref", "--format=%(refname)", "refs/heads/", "refs/remotes/"], cwd=repo).stdout
    refs: list[str] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        # Strip refs/heads/ or refs/remotes/<remote>/ to get the short name
        if line.startswith("refs/heads/"):
            short = line[len("refs/heads/"):]
        elif line.startswith("refs/remotes/"):
            rest = line[len("refs/remotes/"):]
            if "/" not in rest:
                continue
            short = rest.split("/", 1)[1]
            if short == "HEAD":
                continue
        else:
            continue
        if any(short.startswith(p) for p in prefixes):
            refs.append(line)
    return refs


def _files_at_ref(repo: Path, ref: str) -> list[str]:
    r = run(["git", "ls-tree", "-r", "--name-only", ref], cwd=repo, check=False)
    if r.returncode != 0:
        return []
    return [line for line in r.stdout.splitlines() if line.strip()]


def _last_commit_for_path(repo: Path, ref: str, path: str) -> Optional[tuple[str, str]]:
    """Return (sha, iso-date) of the last commit on `ref` that touched `path`."""
    r = run(["git", "log", "-1", "--format=%H%x09%cI", ref, "--", path], cwd=repo, check=False)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    sha, _, date = r.stdout.strip().partition("\t")
    return (sha, date)


def cmd_collect(args: argparse.Namespace) -> None:
    public = Path(args.public or ".").expanduser().resolve()
    if not is_git_repo(public):
        die(f"{public} is not a git repository")

    # Locate sibling private dir. Default: <wrapper>/<project>-private where
    # wrapper = public.parent and project is wrapper.name. Falls back to
    # legacy <wrapper>/private/ if the canonical name isn't found.
    if args.private:
        private = Path(args.private).expanduser().resolve()
    else:
        wrapper = public.parent
        canonical = wrapper / f"{wrapper.name}-private"
        legacy = wrapper / "private"
        if canonical.is_dir():
            private = canonical
        elif legacy.is_dir():
            private = legacy
        else:
            private = canonical  # for the dry-run / error message
    if not args.apply:
        pass  # private dir existence not required for dry-run
    elif not private.is_dir():
        die(f"private dir not found at {private}; run /add-private first or pass --private")

    prefixes = tuple(p if p.endswith("/") else p + "/" for p in (args.branch_prefix or list(DEFAULT_BRANCH_PREFIXES)))
    default_branch = _default_branch(public)

    # Files reachable from default branch — used to skip already-public content.
    public_files = set(_files_at_ref(public, default_branch))

    # Candidates: (path, source_ref, sha, date)
    candidates: dict[str, tuple[str, str, str]] = {}  # path -> (ref, sha, date); keep latest by date

    # Source 1: current tree files matching path rules.
    for path in sorted(public_files):
        if _classify(path) is None:
            continue
        meta = _last_commit_for_path(public, default_branch, path)
        if meta is None:
            continue
        sha, date = meta
        candidates[path] = (default_branch, sha, date)

    # Source 2: files reachable from prefixed branches but NOT in the default branch.
    branch_refs = _list_branches(public, prefixes)
    for ref in branch_refs:
        for path in _files_at_ref(public, ref):
            if path in public_files:
                continue  # already on the default branch — skip; handled by Source 1 if rules match
            meta = _last_commit_for_path(public, ref, path)
            if meta is None:
                continue
            sha, date = meta
            existing = candidates.get(path)
            if existing is None or date > existing[2]:
                candidates[path] = (ref, sha, date)

    if not candidates:
        info("no candidates found.")
        return

    # Plan: assign each candidate a bucket and target path.
    # Generic basenames that need disambiguation when two different source paths
    # share the same name (e.g. internal/query/DESIGN.md and
    # internal/router/DESIGN.md both -> DESIGN.md in the same bucket).
    generic = {
        "design.md", "readme.md", "notes.md", "rfc.md", "architecture.md",
        "scratch.md", "draft.md", "review.md", "research.md", "spec.md",
    }

    # First pass: compute target_name for each source path and detect collisions.
    # target_name is the flat filename (with date prefix for notes, parent prefix
    # for generic basenames). Collision detection uses (bucket, target_name_lower).
    _target_names: dict[str, str] = {}  # src_path -> target_name
    _src_by_name: dict[tuple[str, str], list[str]] = {}  # (bucket, target_name_lower) -> [src_paths]
    for path, (ref, sha, date) in sorted(candidates.items()):
        bucket = _classify(path)
        if bucket is None:
            bucket = "docs"
        src = Path(path)
        target_name = src.name
        if target_name.lower() in generic and src.parent != Path("."):
            target_name = f"{src.parent.name}-{target_name}"
        if bucket == "notes":
            if not re.match(r"^\d{4}-\d{2}-\d{2}-", target_name):
                target_name = f"{date[:10]}-{target_name}"
        _target_names[path] = target_name
        key = (bucket, target_name.lower())
        _src_by_name.setdefault(key, []).append(path)

    # Detect collisions: (bucket, target_name_lower) keys with more than one source path.
    _colliding_keys: set[tuple[str, str]] = {
        key for key, paths_for_name in _src_by_name.items() if len(paths_for_name) > 1
    }
    # Track which src_paths are in a collision (for plan display).
    _colliding_srcs: set[str] = {
        path
        for key in _colliding_keys
        for path in _src_by_name[key]
    }

    plan: list[tuple[str, str, Path, str, str, str]] = []  # (src_path, bucket, target, ref, sha, date)
    for path, (ref, sha, date) in sorted(candidates.items()):
        bucket = _classify(path)
        if bucket is None:
            # On a private-prefix branch but no path rule matched -- default to docs/.
            # User reviews before --apply.
            bucket = "docs"
        target_name = _target_names[path]
        if (bucket, target_name.lower()) in _colliding_keys:
            # Collision resolution: place under a fixed-depth stable-hash directory
            # derived from the full source path.  Two distinct source paths always
            # produce distinct hashes; the hex directory can never equal a target
            # filename or be an ancestor of another target.  target_name (with its
            # date prefix, generic-basename parent prefix, etc.) is preserved inside.
            shorthash = hashlib.sha256(path.encode()).hexdigest()[:16]
            target = private / bucket / shorthash / target_name
        else:
            target = private / bucket / target_name
        plan.append((path, bucket, target, ref, sha, date))

    # Programming-error guard: (a) all target paths must be unique, and
    # (b) no target path may be a prefix (ancestor) of another target path.
    seen_targets: list[Path] = []
    for _, _, target, _, _, _ in plan:
        for prior in seen_targets:
            if target == prior:
                raise RuntimeError(
                    f"collect produced duplicate target path: {target} -- "
                    "this is a bug; please report it"
                )
            # Check ancestor relationship in both directions.
            try:
                target.relative_to(prior)
                raise RuntimeError(
                    f"collect: target {target} is nested under another target {prior} -- "
                    "this is a bug; please report it"
                )
            except ValueError:
                pass
            try:
                prior.relative_to(target)
                raise RuntimeError(
                    f"collect: target {prior} is nested under another target {target} -- "
                    "this is a bug; please report it"
                )
            except ValueError:
                pass
        seen_targets.append(target)

    # Render plan.
    info(f"public:  {public}")
    info(f"private: {private}")
    info(f"default branch: {default_branch}")
    info(f"branch prefixes: {', '.join(prefixes)}")
    info(f"candidates: {len(plan)}")
    info("")
    for src_path, bucket, target, ref, sha, _ in plan:
        rel_target = target.relative_to(private.parent) if target.is_relative_to(private.parent) else target
        info(f"  [{bucket:<8}] {src_path}")
        if src_path in _colliding_srcs:
            info(f"             note: {src_path} -> {bucket}/{target.parent.name}/{target.name} (collision)")
        info(f"             -> {rel_target}")
        info(f"             from {ref} @ {sha[:10]}")

    if not args.apply:
        info("")
        info("dry run. re-run with --apply to copy these files into private/.")
        return

    # Apply: extract file content at the chosen sha and write to target.
    # Read blobs as bytes (binary-safe) so non-UTF-8 files are preserved intact.
    copied = 0
    skipped = 0
    for src, bucket, target, ref, sha, _ in plan:
        if target.exists():
            warn(f"target exists, skipping: {target}")
            skipped += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(
            ["git", "show", f"{sha}:{src}"],
            cwd=public, capture_output=True, check=False,
        )
        if r.returncode != 0:
            warn(f"could not extract {src}@{sha[:10]}: {r.stderr.decode(errors='replace').strip()}")
            skipped += 1
            continue
        target.write_bytes(r.stdout)
        copied += 1

    info("")
    info(f"copied {copied} file(s) into {private}; skipped {skipped}.")
    info(f"review with `git -C {shlex.quote(str(private))} status`, then commit when ready.")


def _add_workspace_flags(p: argparse.ArgumentParser) -> None:
    """Tri-state --workspace / --no-workspace (default None → detect).

    Shared by new/retrofit/sync: --workspace forces the .code-workspace write,
    --no-workspace skips it, neither lets should_write_workspace detect.
    """
    ws = p.add_mutually_exclusive_group()
    ws.add_argument("--workspace", dest="workspace", action="store_true", default=None,
                    help="Force-write the VS Code .code-workspace file")
    ws.add_argument("--no-workspace", dest="workspace", action="store_false",
                    help="Never write the .code-workspace file")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="greenroom",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_retro = sub.add_parser(
        "retrofit",
        help="Wrap an existing public repo",
        description="Move an existing public repo into a wrapper folder and add a sibling private notes repo.",
    )
    p_retro.add_argument(
        "path", nargs="?", help="Path to existing public repo (default: current directory)"
    )
    p_retro.add_argument("--name", help="Project name (default: basename of path)")
    p_retro.add_argument(
        "--public-name",
        dest="public_name",
        help="Public dir name inside wrapper (default: <name>-public)",
    )
    p_retro.add_argument(
        "--private-name",
        dest="private_name",
        help="Private dir name inside wrapper (default: <name>-private)",
    )
    p_retro.add_argument(
        "--with-private-fork",
        dest="with_private_fork",
        action="store_true",
        help="Clone <project>-public into <project>-private-fork (local 'upstream' remote, no origin)",
    )
    _add_workspace_flags(p_retro)
    p_retro.set_defaults(func=cmd_retrofit)

    p_new = sub.add_parser(
        "new",
        help="Create a new wrapped project",
        description="Create a new wrapper folder with a private notes repo and (optionally) a public code repo.",
    )
    p_new.add_argument("name", help="Project name (becomes wrapper dir name)")
    p_new.add_argument("--parent", help="Parent dir for the wrapper (default: current directory)")
    p_new.add_argument(
        "--public-name",
        dest="public_name",
        help="Public dir name inside wrapper (default: <name>-public)",
    )
    p_new.add_argument(
        "--private-name",
        dest="private_name",
        help="Private dir name inside wrapper (default: <name>-private)",
    )
    g = p_new.add_mutually_exclusive_group()
    g.add_argument("--clone", help="Git URL to clone into the public dir")
    g.add_argument(
        "--init-public",
        dest="init_public",
        action="store_true",
        help="Init an empty git repo in the public dir",
    )
    p_new.add_argument(
        "--with-private-fork",
        dest="with_private_fork",
        action="store_true",
        help="Clone <project>-public into <project>-private-fork (local 'upstream' remote, no origin)",
    )
    _add_workspace_flags(p_new)
    p_new.set_defaults(func=cmd_new)

    p_collect = sub.add_parser(
        "collect",
        help="Recover private-shaped docs from public repo history into private/",
        description=(
            "Scan a public repo for files that look private (design docs, notes, "
            "drafts). Sources: path-rule matches in the default branch, plus files "
            "reachable from unmerged branches whose names start with design/, notes/, "
            "drafts/, private/. Default is dry-run; pass --apply to copy."
        ),
    )
    p_collect.add_argument("--public", help="Path to the public repo (default: cwd; must be inside the public repo)")
    p_collect.add_argument(
        "--private",
        help="Path to the private repo (default: <wrapper>/<wrapper-name>-private, falling back to legacy private/)",
    )
    p_collect.add_argument(
        "--branch-prefix",
        action="append",
        help=f"Branch-name prefix to scan (repeatable). Default: {', '.join(DEFAULT_BRANCH_PREFIXES)}",
    )
    p_collect.add_argument("--apply", action="store_true", help="Actually copy files (default: dry-run)")
    p_collect.set_defaults(func=cmd_collect)

    p_sync = sub.add_parser(
        "sync",
        help="Re-scan the wrapper and update the workspace, agent wiring, and repo map",
        description=(
            "Re-scan a project wrapper for git repos and (re)write the "
            "<project>.code-workspace (add new folder roots, keep customizations), the "
            "canonical repo's .claude/settings.local.json (grant Claude the sibling repos), "
            "and the wrapper README repo-map. Run after dropping a new fork/clone under the wrapper."
        ),
    )
    p_sync.add_argument("--wrapper", help="Wrapper dir (default: detect from cwd)")
    p_sync.add_argument("--name", help="Project name (default: wrapper basename)")
    p_sync.add_argument("--canonical", help="Canonical repo dir name (default: prefer a *-public repo)")
    _add_workspace_flags(p_sync)
    p_sync.set_defaults(func=cmd_sync)

    return parser


def main(argv: Optional[list[str]] = None) -> None:
    if sys.platform == "win32":
        die("greenroom supports macOS and Linux only (Windows via WSL2). "
            "Native Windows is not supported.")
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except subprocess.CalledProcessError as e:
        cmd_str = " ".join(e.cmd) if isinstance(e.cmd, list) else str(e.cmd)
        msg = e.stderr.strip() if e.stderr else str(e)
        die(f"command failed: {cmd_str}\n{msg}")


if __name__ == "__main__":
    main()
