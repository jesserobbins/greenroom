#!/usr/bin/env bash
# Symlink each skill under skills/*/ into ~/.claude/skills/<name> and the
# commands/*.md into ~/.claude/commands/, so Claude Code loads the skills and
# slash commands. Idempotent: safe to re-run after cloning.
#
# The skill directory is self-contained -- scripts/ and templates/ live inside
# skills/greenroom/ -- so symlinking the skill is all that's needed. There is no
# separate script-root shim to maintain.
#
# (If you instead install greenroom as a Claude Code plugin via the marketplace
#  (`/plugin marketplace add jesserobbins/greenroom` then `/plugin install
#  greenroom@jesserobbins`), or as a standalone skill via
#  `npx skills add jesserobbins/greenroom`, you do NOT need this script. This is
#  the manual path for a direct `git clone`.)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DEST="$HOME/.claude/skills"
CMD_DEST="$HOME/.claude/commands"
mkdir -p "$SKILL_DEST" "$CMD_DEST"

# resolve_link <path>: the absolute, normalized path a symlink points at. A
# relative target (e.g. `../../src/greenroom`) is resolved against the link's own
# directory, so an install whose links were made with a relative target is still
# recognized as ours. Fails if <path> is not a symlink or its target's parent
# does not exist.
resolve_link() {
  [ -L "$1" ] || return 1
  local raw dir
  raw="$(readlink "$1")" || return 1
  case "$raw" in /*) ;; *) raw="$(dirname "$1")/$raw" ;; esac
  dir="$(dirname "$raw")"
  [ -d "$dir" ] || return 1
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$(basename "$raw")"
}

# points_at_repo <path>: true if <path> is a symlink resolving into this repo.
# Used to confirm a link is OURS before removing or refreshing it; a symlink the
# user placed at the same path is left alone.
points_at_repo() {
  local dest
  dest="$(resolve_link "$1")" || return 1
  case "$dest" in "$REPO_DIR"|"$REPO_DIR"/*) return 0 ;; *) return 1 ;; esac
}

# points_at_repo_root <path>: true if <path> is a symlink resolving to the repo
# root itself, not merely into it. The current skill link lives at the same path
# as the ancient root symlink but points at $REPO_DIR/skills/greenroom, so the
# root migration below must not match it.
points_at_repo_root() {
  local dest
  dest="$(resolve_link "$1")" || return 1
  [ "$dest" = "$REPO_DIR" ]
}

# link <target> <link-path> <label>: refresh our own symlinks, never clobber
# anything the user owns -- neither a real file nor a symlink of their own.
# Sets `link_result` to "linked" or "skip".
link_one() {
  local target="$1" link="$2" label="$3"
  if [ -L "$link" ]; then
    if points_at_repo "$link"; then
      rm "$link"                                   # our own link: refresh it
    else
      echo "SKIP $label: $link is a symlink into somewhere else (leaving it untouched)"
      link_result="skip"
      return
    fi
  elif [ -e "$link" ]; then
    echo "SKIP $label: $link exists and is not a symlink (leaving it untouched)"
    link_result="skip"
    return
  fi
  ln -s "$target" "$link"
  echo "linked $label"
  link_result="linked"
}

# Migration 1: older installers created ~/.claude/skills/greenroom as a plain
# directory holding scripts/ + templates/ symlinks, to give the slash commands a
# script-path fallback. The script now ships inside the skill, and the skill is
# named `greenroom`, so that path is where the skill itself belongs. Left in
# place, the directory is not a symlink, so link_one would SKIP it and the
# install would silently no-op. Detect the old shim by its signature -- a real
# directory, no SKILL.md, containing our symlinks -- and remove it.
OLD_SHIM="$SKILL_DEST/greenroom"
if [ -L "$OLD_SHIM" ]; then
  # An even older installer symlinked this path straight at the repo root.
  if points_at_repo_root "$OLD_SHIM"; then
    rm "$OLD_SHIM"
    echo "migrated: removed the old greenroom root symlink at $OLD_SHIM"
  fi
elif [ -d "$OLD_SHIM" ] && [ ! -e "$OLD_SHIM/SKILL.md" ]; then
  if points_at_repo "$OLD_SHIM/scripts" || points_at_repo "$OLD_SHIM/templates"; then
    # Remove only the two links we created, then rmdir. If the user dropped
    # anything else in here, the rmdir fails and their files survive -- better a
    # loud SKIP than a silent `rm -rf` of a directory we only partly own.
    for owned in scripts templates; do
      if points_at_repo "$OLD_SHIM/$owned"; then rm -f "$OLD_SHIM/$owned"; fi
    done
    if rmdir "$OLD_SHIM" 2>/dev/null; then
      echo "migrated: removed the old script-root shim at $OLD_SHIM"
    else
      echo "SKIP migration: $OLD_SHIM still holds files we did not create (leaving it untouched)"
    fi
  else
    echo "SKIP migration: $OLD_SHIM is a directory we do not recognize (leaving it untouched)"
  fi
fi

# Migration 2: the skill was renamed greenroom-setup -> greenroom. Drop our own
# stale link so the old name stops resolving. Ownership-checked: a real file or
# an unrelated symlink the user owns is left alone.
STALE="$SKILL_DEST/greenroom-setup"
if points_at_repo "$STALE"; then
  rm "$STALE"
  echo "migrated: removed the stale greenroom-setup link (renamed to greenroom)"
fi

# Link each skill under its own name. Skill names carry the greenroom identity
# (e.g. `greenroom`), so a manual install gets a distinctive /greenroom rather
# than a generic name that could collide with the user's own skills. (A plugin
# install gives /greenroom:<name>.)
skill_linked=0
for skill_dir in "$REPO_DIR"/skills/*/; do
  [ -f "$skill_dir/SKILL.md" ] || continue          # only dirs that hold a skill
  sname="$(basename "$skill_dir")"
  link_result=""
  link_one "${skill_dir%/}" "$SKILL_DEST/$sname" "skill $sname"
  [ "$link_result" = "linked" ] && skill_linked=$((skill_linked + 1))
done

cmd_linked=0
for cmd in "$REPO_DIR"/commands/*.md; do
  [ -f "$cmd" ] || continue                        # no commands dir / no matches
  cname="$(basename "$cmd")"
  link_result=""
  link_one "$cmd" "$CMD_DEST/$cname" "command $cname"
  [ "$link_result" = "linked" ] && cmd_linked=$((cmd_linked + 1))
done

echo "Done. $skill_linked skill(s) → $SKILL_DEST; $cmd_linked command(s) → $CMD_DEST"
