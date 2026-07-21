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
  dir="$(cd "$dir" && pwd -P)"
  printf '%s/%s\n' "${dir%/}" "$(basename "$raw")"   # %/ so a target under / is not //name
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

# looks_like_ours <resolved-target> <link-path>: true if the target is a payload
# this installer produces, even from a DIFFERENT greenroom checkout. Re-cloning
# elsewhere and re-installing is a normal upgrade path; keying ownership to
# $REPO_DIR alone made it a hard failure, since the old clone is still on disk
# and so the link is neither ours nor dangling.
looks_like_ours() {
  local dest="$1" name manifest
  name="$(basename "$2")"
  if [ -d "$dest" ]; then                            # a skill dir declaring itself
    if [ -f "$dest/SKILL.md" ] && grep -q "^name:[[:space:]]*${name}[[:space:]]*\$" "$dest/SKILL.md"; then
      return 0
    fi
  elif [ -f "$dest" ]; then                          # a command file from a greenroom checkout
    case "$dest" in
      */commands/"$name")
        manifest="$(dirname "$(dirname "$dest")")/.claude-plugin/plugin.json"
        if [ -f "$manifest" ] && grep -q '"name"[[:space:]]*:[[:space:]]*"greenroom"' "$manifest"; then
          return 0
        fi
        ;;
    esac
  fi
  return 1
}

# link_one <target> <link-path> <label> [claim-dangling]: refresh our own
# symlinks, never clobber anything the user owns -- neither a real file nor a
# symlink of their own. Sets `link_result` to "linked" or "skip".
#
# Pass a non-empty fourth argument only for a path whose NAME is ours
# (`skills/greenroom`), which opts into claiming a dangling link there. A dangling
# link there is almost certainly our own after the clone moved. The command links
# are generic names -- new.md, add.md, sync.md -- that a user may well have bound
# to their own repo, and a target on an unmounted volume or a moved clone reads
# as dangling too; those we leave alone.
link_one() {
  local target="$1" link="$2" label="$3" claim_dangling="${4:-}" dest
  if [ -L "$link" ]; then
    if points_at_repo "$link"; then
      rm "$link"                                   # our own link: refresh it
    elif dest="$(resolve_link "$link")" && looks_like_ours "$dest" "$link"; then
      rm "$link"                                   # another greenroom checkout: repoint
      echo "repointed $label from another greenroom checkout at $dest"
    elif [ ! -e "$link" ] && [ -n "$claim_dangling" ]; then
      # Our own link looks exactly like this after the clone is moved or renamed,
      # and ownership can no longer be proven -- but nobody is served by a dead
      # link at a path named for us, and a link the user actively uses is not
      # dangling. Replace it, and say that is what happened.
      rm "$link"
      echo "replaced a dangling symlink at $link (its target no longer exists)"
    elif [ ! -e "$link" ]; then
      echo "SKIP $label: $link is a dangling symlink we cannot prove is ours (leaving it untouched)"
      echo "     to install here instead: rm $link && re-run install.sh"
      link_result="skip"
      return
    else
      echo "SKIP $label: $link is a symlink into somewhere else (leaving it untouched)"
      echo "     to install here instead: rm $link && re-run install.sh"
      link_result="skip"
      return
    fi
  elif [ -e "$link" ]; then
    echo "SKIP $label: $link exists and is not a symlink (leaving it untouched)"
    echo "     to install here instead: move or remove $link, then re-run install.sh"
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
  # An even older installer symlinked this path straight at the repo root. It is
  # ours whether it points at THIS clone or another one -- a repo root holds no
  # SKILL.md, so looks_like_ours cannot see it; the plugin manifest is the tell.
  if points_at_repo_root "$OLD_SHIM"; then
    rm "$OLD_SHIM"
    echo "migrated: removed the old greenroom root symlink at $OLD_SHIM"
  elif root_dest="$(resolve_link "$OLD_SHIM")" && [ -f "$root_dest/.claude-plugin/plugin.json" ] \
       && grep -q '"name"[[:space:]]*:[[:space:]]*"greenroom"' "$root_dest/.claude-plugin/plugin.json"; then
    rm "$OLD_SHIM"
    echo "migrated: removed an old greenroom root symlink into another checkout at $root_dest"
  fi
elif [ -d "$OLD_SHIM" ] && [ ! -e "$OLD_SHIM/SKILL.md" ]; then
  # Decide BEFORE mutating. Removing our links first and only then discovering
  # rmdir cannot empty the directory leaves the user worse off than the no-op we
  # claim to have performed: their old script fallback is gone, the skill was
  # never linked over the surviving directory, and the run exits 1.
  #
  # A shim entry is ours if it is a symlink named scripts/templates that either
  # resolves into this repo or dangles -- dangling is what they do in the common
  # upgrade, where the old clone was deleted and greenroom re-cloned elsewhere.
  #
  # OS noise is not the user's -- a Finder-created .DS_Store is invisible to `ls`,
  # and counting it as a file someone left behind would fail the whole install
  # over something nobody put there. Named once, and driven from that one list.
  SHIM_NOISE=".DS_Store Thumbs.db .localized"
  shim_is_ours=""
  shim_has_extras=""
  for entry in "$OLD_SHIM"/* "$OLD_SHIM"/.[!.]* "$OLD_SHIM"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue       # unmatched glob
    ename="$(basename "$entry")"
    is_noise=""
    for n in $SHIM_NOISE; do
      if [ "$ename" = "$n" ]; then is_noise=yes; fi
    done
    if [ -n "$is_noise" ]; then continue; fi
    case "$ename" in
      scripts|templates)
        if points_at_repo "$entry"; then
          shim_is_ours=yes
        elif [ -L "$entry" ] && [ ! -e "$entry" ]; then
          shim_is_ours=yes
        else
          shim_has_extras=yes                            # a real dir or a foreign link
        fi
        ;;
      *) shim_has_extras=yes ;;
    esac
  done
  if [ -z "$shim_is_ours" ] && [ -z "$shim_has_extras" ]; then
    # Empty, or nothing but OS noise -- a partially cleaned or interrupted prior
    # install. Nothing to weigh, and leaving it would block the skill link and
    # fail the run over a file the user cannot see.
    for n in $SHIM_NOISE; do rm -f "$OLD_SHIM/$n"; done
    rmdir "$OLD_SHIM"
    echo "migrated: removed an empty or noise-only $OLD_SHIM"
  elif [ -n "$shim_is_ours" ] && [ -z "$shim_has_extras" ]; then
    rm -f "$OLD_SHIM/scripts" "$OLD_SHIM/templates"
    for n in $SHIM_NOISE; do rm -f "$OLD_SHIM/$n"; done
    rmdir "$OLD_SHIM"
    echo "migrated: removed the old script-root shim at $OLD_SHIM"
  elif [ -n "$shim_is_ours" ]; then
    echo "SKIP migration: $OLD_SHIM holds files we did not create (leaving it untouched)"
    echo "     the skill cannot be linked over a real directory -- move what you want to keep"
    echo "     out of $OLD_SHIM, remove the directory, then re-run install.sh"
  else
    echo "SKIP migration: $OLD_SHIM is a directory we do not recognize (leaving it untouched)"
  fi
fi

# Migration 2: the skill was renamed greenroom-setup -> greenroom. Drop our own
# stale link so the old name stops resolving. Ownership-checked: a real file or
# an unrelated symlink the user owns is left alone. A dangling link is removed on
# the same reasoning link_one uses -- the old clone was deleted or moved, nothing
# the user actively uses dangles, and leaving it keeps the retired skill name
# registered forever.
STALE="$SKILL_DEST/greenroom-setup"
if points_at_repo "$STALE"; then
  rm "$STALE"
  echo "migrated: removed the stale greenroom-setup link (renamed to greenroom)"
elif stale_dest="$(resolve_link "$STALE")" && looks_like_ours "$stale_dest" "$STALE"; then
  # A link into a DIFFERENT greenroom checkout that still exists on disk. Keyed
  # to $REPO_DIR alone this stayed registered forever after a re-clone -- exactly
  # what this migration exists to prevent.
  rm "$STALE"
  echo "migrated: removed a greenroom-setup link into another checkout at $stale_dest"
elif [ -L "$STALE" ] && [ ! -e "$STALE" ]; then
  rm "$STALE"
  echo "migrated: removed a dangling greenroom-setup link (its target no longer exists)"
elif [ -d "$STALE" ] && [ ! -L "$STALE" ] && [ -f "$STALE/SKILL.md" ] \
     && grep -q "^name:[[:space:]]*greenroom-setup[[:space:]]*\$" "$STALE/SKILL.md"; then
  # A COPIED payload, from `npx skills add ...@greenroom-setup`. Not a link we
  # made, so not ours to delete -- but left alone the retired name resolves
  # forever, which is the whole point of this migration.
  echo "NOTE: $STALE is a copied install of the retired greenroom-setup skill."
  echo "      Remove it (rm -rf $STALE) so the old name stops resolving."
fi

# Link each skill under its own name. Skill names carry the greenroom identity
# (e.g. `greenroom`), so a manual install gets a distinctive /greenroom rather
# than a generic name that could collide with the user's own skills. (A plugin
# install gives /greenroom:<name>.)
skill_found=0
skill_linked=0
for skill_dir in "$REPO_DIR"/skills/*/; do
  [ -f "$skill_dir/SKILL.md" ] || continue          # only dirs that hold a skill
  skill_found=$((skill_found + 1))
  sname="$(basename "$skill_dir")"
  link_result=""
  # Only names distinctive enough to be ours opt into claiming a dangling link.
  # `skills/*/` is one directory today, but a future skill called `notes` or
  # `sync` must not silently take over a user's dangling symlink at that name.
  claim=""
  case "$sname" in greenroom|greenroom-*) claim=claim-dangling ;; esac
  link_one "${skill_dir%/}" "$SKILL_DEST/$sname" "skill $sname" "$claim"
  if [ "$link_result" = "linked" ]; then skill_linked=$((skill_linked + 1)); fi
done

# The commands are hollow -- each one just says "invoke the greenroom skill". If
# the skill did not install, registering them hands the user a /new, /add, /sync
# that fail at use time instead of failing here, where the remedy is printed.
cmd_linked=0
if [ "$skill_linked" -lt "$skill_found" ]; then
  echo "not linking the commands: they only invoke the skill, which did not install"
else
  for cmd in "$REPO_DIR"/commands/*.md; do
    [ -f "$cmd" ] || continue                      # no commands dir / no matches
    cname="$(basename "$cmd")"
    link_result=""
    link_one "$cmd" "$CMD_DEST/$cname" "command $cname"
    if [ "$link_result" = "linked" ]; then cmd_linked=$((cmd_linked + 1)); fi
  done
fi

echo "Done. $skill_linked skill(s) → $SKILL_DEST; $cmd_linked command(s) → $CMD_DEST"

# A skill we ship did not get installed. The SKIPs above say what to do; exit
# non-zero so the failure is not buried under a cheerful "Done." line -- a
# partial install is a failed install, not a quiet no-op.
if [ "$skill_linked" -lt "$skill_found" ]; then
  echo "install.sh installed $skill_linked of $skill_found skill(s). See the SKIP notes above." >&2
  exit 1
fi
