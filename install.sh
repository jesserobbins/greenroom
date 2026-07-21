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

# normalize_target_dir <symlink>: the directory part of a symlink's target, made
# absolute and canonical TEXTUALLY -- the target may not exist, so resolve_link's
# `cd` cannot be used. Two links written with differently-spelled but identical
# targets (absolute vs relative, trailing slash, a `..` hop) must compare equal, or
# a shim that really is ours is refused and the install aborts.
normalize_target_dir() {
  local raw dir out part
  raw="$(readlink "$1")" || return 1
  case "$raw" in /*) ;; *) raw="$(dirname "$1")/$raw" ;; esac
  dir="$(dirname "$raw")"
  out=""
  local IFS=/ globstate="$-"
  set -f                                 # splitting on / must not glob a component
  for part in $dir; do
    case "$part" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  case "$globstate" in *f*) ;; *) set +f ;; esac
  printf '%s\n' "${out:-/}"
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
#
# BOTH branches demand the same evidence: the entry sits where a greenroom
# checkout would put it, AND that checkout's plugin manifest names greenroom. The
# manifest is the only real proof. Matching a SKILL.md's `name:` alone would mean
# that once greenroom ships a `skills/notes/`, a user's own ~/.claude/skills/notes
# link -- pointing at their `name: notes` skill -- gets seized and repointed.
looks_like_ours() {
  local dest="$1" name declared
  name="$(basename "$2")"
  if [ -d "$dest" ]; then                            # <checkout>/skills/<name>/
    [ -f "$dest/SKILL.md" ] || return 1
    # exact compare, not an interpolated regex: a name holding `.` or `*` would
    # otherwise match more loosely than intended
    declared="$(skill_name_of "$dest/SKILL.md")"
    [ "$declared" = "$name" ] || return 1
    is_greenroom_checkout "$(dirname "$(dirname "$dest")")" || return 1
    return 0
  elif [ -f "$dest" ]; then                          # <checkout>/commands/<name>
    case "$dest" in
      */commands/"$name")
        is_greenroom_checkout "$(dirname "$(dirname "$dest")")" || return 1
        return 0
        ;;
    esac
  fi
  return 1
}

# skill_name_of <SKILL.md>: the declared `name:` value, whitespace stripped, read
# ONLY from the leading `---` frontmatter. Scanning the whole file would let a
# `name:` line in the body -- a YAML example, a table row -- masquerade as the
# declared name, and three ownership decisions rest on this. Fails closed: no
# frontmatter, no name.
skill_name_of() {
  awk '
    { sub(/\r$/, "") }                 # a CRLF checkout must not read as "no frontmatter"
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    # Quoting is valid YAML, and the smoke suite parse accepts it. Returning
    # `"greenroom"` with its quotes would fail every ownership compare -- and each
    # one fails in the direction that tells a user to remove a working install.
    /^name:/ {
      sub(/^name:[[:space:]]*/, ""); gsub(/[[:space:]]/, "")
      q = substr($0, 1, 1)                       # \047 is a single quote: keeping it
      if ((q == "\"" || q == "\047") \
          && length($0) > 1 && substr($0, length($0), 1) == q) {
        $0 = substr($0, 2, length($0) - 2)       # as an escape avoids ending this
      }                                          # single-quoted awk program early
      print; exit
    }
  ' "$1"
}

# is_greenroom_skill_dir <dir>: true if <dir> is any skill directory belonging to a
# greenroom checkout -- <checkout>/skills/<anything>. Used for the retired
# greenroom-setup path, which has pointed at `skills/setup` (0.1.4-0.1.7),
# `skills/greenroom-setup` (0.1.8), and, for anyone who repointed it by hand, the
# renamed `skills/greenroom`. The declared name is not the test; whose checkout it
# is, is. Anything greenroom owns at that retired path should stop resolving.
is_greenroom_skill_dir() {
  [ -d "$1" ] && [ -f "$1/SKILL.md" ] || return 1
  [ "$(basename "$(dirname "$1")")" = "skills" ] || return 1
  is_greenroom_checkout "$(dirname "$(dirname "$1")")"
}

# OS droppings that are never "a file the user left behind".
SHIM_NOISE=".DS_Store Thumbs.db .localized"

# purge_shim_noise <dir>: remove the OS droppings named in $SHIM_NOISE from <dir>.
# Guarded on being a file or a link, because `rm -f` on a DIRECTORY returns
# non-zero and under set -e would abort mid-migration with no message -- and every
# other failure in this script is a SKIP with a printed remedy.
purge_shim_noise() {
  local n
  for n in $SHIM_NOISE; do
    if [ -f "$1/$n" ] || [ -L "$1/$n" ]; then rm -f "$1/$n"; fi
  done
}

# is_greenroom_checkout <dir>: true if <dir> is the root of a greenroom checkout.
is_greenroom_checkout() {
  [ -f "$1/.claude-plugin/plugin.json" ] \
    && grep -q '"name"[[:space:]]*:[[:space:]]*"greenroom"' "$1/.claude-plugin/plugin.json"
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
  elif root_dest="$(resolve_link "$OLD_SHIM")" && is_greenroom_checkout "$root_dest"; then
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
  shim_is_ours=""
  shim_has_extras=""
  shim_dangling=""
  shim_dangle_n=0
  shim_dangle_parents=()
  shim_ours_parents=()
  shim_rmdir_failed=""
  shim_undeletable=""
  for entry in "$OLD_SHIM"/* "$OLD_SHIM"/.[!.]* "$OLD_SHIM"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue       # unmatched glob
    ename="$(basename "$entry")"
    is_noise=""
    for n in $SHIM_NOISE; do
      if [ "$ename" = "$n" ]; then is_noise=yes; fi
    done
    if [ -n "$is_noise" ]; then
      # A noise NAME that is really a directory cannot be purged, so rmdir will
      # refuse. Learn that HERE, while we can still decide without having touched
      # anything -- the branch below must not delete our links and only then
      # discover it cannot finish.
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then shim_undeletable=yes; fi
      continue
    fi
    case "$ename" in
      scripts|templates)
        if points_at_repo "$entry"; then
          shim_is_ours=yes
          shim_ours_parents+=("$(normalize_target_dir "$entry")")
        elif [ -L "$entry" ] && [ ! -e "$entry" ] \
             && [ "$(basename "$(readlink "$entry")")" = "$ename" ]; then
          # Dangling, and shaped like ours. Deliberately NOT enough on its own:
          # `-> /Volumes/ext/scripts` on an unmounted volume is the most natural
          # name a user would pick and is indistinguishable at this point. Recorded
          # as a candidate; the pair check below decides.
          shim_dangle_n=$((shim_dangle_n + 1))
          shim_dangle_parents+=("$(normalize_target_dir "$entry")")
          shim_dangling="$shim_dangling $ename -> $(readlink "$entry")"
        elif edest="$(resolve_link "$entry")" && is_greenroom_checkout "$(dirname "$edest")"; then
          shim_is_ours=yes                               # a link into ANOTHER live checkout
          shim_ours_parents+=("$(normalize_target_dir "$entry")")
        else
          shim_has_extras=yes                            # a real dir or a foreign link
        fi
        ;;
      *) shim_has_extras=yes ;;
    esac
  done
  # A dangling link is claimed on inference, never on proof, so the inference has to
  # be narrow. Two ways to earn it, and they must ALL agree on one parent directory:
  #   - the pair signature: both links dangling into the same clone, which is
  #     exactly what the old installer wrote; or
  #   - a sibling already PROVEN ours pointing into that same clone.
  # Anything else -- a lone dangling `scripts`, or a `-> /Volumes/ext/templates`
  # beside a link that is genuinely ours -- is the user's, and is left alone.
  # Parents compare as array elements, not a split string: a clone under
  # "~/My Projects" would otherwise look like several parents and be refused.
  if [ "$shim_dangle_n" -gt 0 ]; then
    shim_dangle_ok=""
    shim_dangle_home="${shim_dangle_parents[0]}"
    for p in "${shim_dangle_parents[@]}"; do
      if [ "$p" != "$shim_dangle_home" ]; then shim_dangle_home=""; break; fi
    done
    if [ -n "$shim_dangle_home" ]; then
      if [ "$shim_dangle_n" -eq 2 ]; then
        shim_dangle_ok=yes                               # the pair signature
      else
        for p in ${shim_ours_parents[@]+"${shim_ours_parents[@]}"}; do
          if [ "$p" = "$shim_dangle_home" ]; then shim_dangle_ok=yes; break; fi
        done
      fi
    fi
    if [ -n "$shim_dangle_ok" ]; then
      shim_is_ours=yes
    else
      shim_has_extras=yes
      shim_dangling=""
    fi
  fi
  # One link proven ours and its sibling merely dangling is still ours -- that is a
  # plain in-place upgrade where git could not remove one of the old directories
  # (an untracked .DS_Store inside is enough), so one link stayed live and the
  # other died. Calling that "files we did not create" aborted the upgrade.
  if [ -n "$shim_undeletable" ]; then
    # Decided before mutating: our links stay put, so "leaving it untouched" is
    # true and the old script fallback keeps working until the user clears it.
    echo "SKIP migration: could not empty $OLD_SHIM (leaving it untouched)"
    echo "     the skill cannot be linked over a real directory -- move what you want to keep"
    echo "     out of $OLD_SHIM, remove the directory, then re-run install.sh"
  elif [ -z "$shim_is_ours" ] && [ -z "$shim_has_extras" ]; then
    # Empty, or nothing but OS noise -- a partially cleaned or interrupted prior
    # install. Nothing to weigh, and leaving it would block the skill link and
    # fail the run over a file the user cannot see.
    purge_shim_noise "$OLD_SHIM"
    if rmdir "$OLD_SHIM" 2>/dev/null; then
      echo "migrated: removed an empty or noise-only $OLD_SHIM"
    else
      shim_rmdir_failed=yes
    fi
  elif [ -n "$shim_is_ours" ] && [ -z "$shim_has_extras" ]; then
    rm -f "$OLD_SHIM/scripts" "$OLD_SHIM/templates"
    purge_shim_noise "$OLD_SHIM"
    if rmdir "$OLD_SHIM" 2>/dev/null; then
      echo "migrated: removed the old script-root shim at $OLD_SHIM"
      # Name what was dropped: a dangling link is removed on inference, not proof,
      # so the user should be able to see exactly what went.
      if [ -n "$shim_dangling" ]; then echo "     (dead links removed:$shim_dangling)"; fi
    else
      shim_rmdir_failed=yes
    fi
  elif [ -n "$shim_is_ours" ]; then
    echo "SKIP migration: $OLD_SHIM holds files we did not create (leaving it untouched)"
    echo "     the skill cannot be linked over a real directory -- move what you want to keep"
    echo "     out of $OLD_SHIM, remove the directory, then re-run install.sh"
  else
    echo "SKIP migration: $OLD_SHIM is a directory we do not recognize (leaving it untouched)"
    echo "     the skill cannot be linked over a real directory -- move what you want to keep"
    echo "     out of $OLD_SHIM, remove the directory, then re-run install.sh"
  fi
  # rmdir refused: something we did not classify is still in there (a noise NAME
  # that is really a directory, say). Report it like every other failure rather
  # than letting set -e kill the run before any remedy is printed.
  if [ -n "$shim_rmdir_failed" ]; then
    echo "SKIP migration: could not empty $OLD_SHIM (leaving it untouched)"
    echo "     the skill cannot be linked over a real directory -- move what you want to keep"
    echo "     out of $OLD_SHIM, remove the directory, then re-run install.sh"
  fi
fi

# Link each skill under its own name. Skill names carry the greenroom identity
# (e.g. `greenroom`), so a manual install gets a distinctive /greenroom rather
# than a generic name that could collide with the user's own skills. (A plugin
# install gives /greenroom:<name>.)
skill_found=0
skill_linked=0
skill_ok=0        # linked by us, OR already present as a standalone install
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
  # A real directory here that declares this very skill is a standalone install
  # (`npx skills add -g`), not an obstacle. Left to link_one it becomes SKIP ->
  # exit 1, telling the user to remove a perfectly good install of greenroom.
  # The payload check is not decoration: a name match alone would also accept a
  # stale pre-0.2 copy with no scripts/ inside, and we would report success while
  # the hollow commands point at a skill whose script is not there. Anything that
  # fails it falls through to link_one's SKIP, which prints the remedy.
  if [ -d "$SKILL_DEST/$sname" ] && [ ! -L "$SKILL_DEST/$sname" ] \
     && [ -f "$SKILL_DEST/$sname/SKILL.md" ] \
     && [ "$(skill_name_of "$SKILL_DEST/$sname/SKILL.md")" = "$sname" ] \
     && [ -f "$SKILL_DEST/$sname/scripts/greenroom.py" ] \
     && [ -d "$SKILL_DEST/$sname/templates" ]; then
    echo "NOTE: $SKILL_DEST/$sname is already a standalone install of the $sname skill."
    echo "      Leaving it alone. Remove it first if you want this clone symlinked instead."
    skill_ok=$((skill_ok + 1))
    continue
  fi
  link_one "${skill_dir%/}" "$SKILL_DEST/$sname" "skill $sname" "$claim"
  if [ "$link_result" = "linked" ]; then
    skill_linked=$((skill_linked + 1))
    skill_ok=$((skill_ok + 1))
  fi
done

# A checkout with no skills/*/SKILL.md at all is a partial or corrupt clone, not
# a successful install of nothing. Counted as a failure alongside a skipped skill,
# or "0 of 0" would sail through both guards below.
install_failed=""
if [ "$skill_found" -eq 0 ] || [ "$skill_ok" -lt "$skill_found" ]; then
  install_failed=yes
fi

# The commands are hollow -- each one just says "invoke the greenroom skill". If
# the skill did not install, registering them hands the user a /new, /add, /sync
# that fail at use time instead of failing here, where the remedy is printed.
cmd_linked=0
cmd_skipped=0
if [ -n "$install_failed" ]; then
  echo "not linking the commands: they only invoke the skill, which did not install"
  # Withholding new links is only half the invariant. A PREVIOUS successful run may
  # have left ours in place, and if its clone is gone they are registered and
  # broken -- the use-time failure this guard exists to prevent, just arrived by a
  # different route. Report them; do not remove, since the user may be mid-repair.
  for cmd in "$REPO_DIR"/commands/*.md; do
    [ -f "$cmd" ] || continue
    stale_cmd="$CMD_DEST/$(basename "$cmd")"
    [ -L "$stale_cmd" ] || continue
    # Only a link that actually DANGLES is broken. A working link here is none of
    # our business whoever owns it -- warning about it would tell the user /new is
    # about to fail when it works perfectly well.
    if [ -e "$stale_cmd" ]; then continue; fi
    # The same remedy link_one gives. A later successful run does NOT repair this:
    # the command loop does not claim dangling links (these are generic names), so
    # it would skip this one too. Saying "until this run succeeds" was false.
    # Ownership is unprovable here -- the target is gone -- and these are generic
    # names a user may own, so this states the fact and leaves the conclusion to
    # them rather than telling them to delete something that might be theirs.
    echo "     NOTE: $stale_cmd is a symlink whose target no longer exists."
    echo "           If it is greenroom's, rm it and re-run to reinstall /$(basename "$cmd" .md)."
  done
else
  for cmd in "$REPO_DIR"/commands/*.md; do
    [ -f "$cmd" ] || continue                      # no commands dir / no matches
    cname="$(basename "$cmd")"
    link_result=""
    link_one "$cmd" "$CMD_DEST/$cname" "command $cname"
    if [ "$link_result" = "linked" ]; then
      cmd_linked=$((cmd_linked + 1))
    else
      cmd_skipped=$((cmd_skipped + 1))
    fi
  done
fi

# Migration 2: the skill was renamed greenroom-setup -> greenroom. Drop our own
# stale link so the old name stops resolving. Ownership-checked: a real file or
# an unrelated symlink the user owns is left alone. A dangling link is removed on
# the same reasoning link_one uses -- the old clone was deleted or moved, nothing
# the user actively uses dangles, and leaving it keeps the retired skill name
# registered forever.
#
# Deliberately AFTER the skill loop. A 0.1.8 user has both artifacts, and if the
# shim path is blocked the new skill cannot link -- removing the old name first
# would leave them with no greenroom skill at all, which is the opposite of every
# "leaving it untouched" promise above.
STALE="$SKILL_DEST/greenroom-setup"
if [ -n "$install_failed" ]; then
  if [ -e "$STALE" ] || [ -L "$STALE" ]; then
    echo "NOTE: leaving $STALE registered -- the new skill could not be installed."
    echo "      Resolve the SKIPs above and re-run; this run changed nothing there."
  fi
elif points_at_repo "$STALE"; then
  rm "$STALE"
  echo "migrated: removed the stale greenroom-setup link (renamed to greenroom)"
elif stale_dest="$(resolve_link "$STALE")" && is_greenroom_skill_dir "$stale_dest"; then
  # A link into a DIFFERENT greenroom checkout that still exists on disk. Keyed
  # to $REPO_DIR alone this stayed registered forever after a re-clone -- exactly
  # what this migration exists to prevent. looks_like_ours is the wrong test here:
  # it demands the target's name match the LINK's basename, and this path has
  # pointed at skills/setup, skills/greenroom-setup, and (by hand) the renamed
  # skills/greenroom. Whose checkout it is, is the test -- not what it declares.
  rm "$STALE"
  echo "migrated: removed a greenroom-setup link into another checkout at $stale_dest"
elif [ -L "$STALE" ] && [ ! -e "$STALE" ]; then
  rm "$STALE"
  echo "migrated: removed a dangling greenroom-setup link (its target no longer exists)"
elif [ -d "$STALE" ] && [ ! -L "$STALE" ] && [ -f "$STALE/SKILL.md" ] \
     && [ "$(skill_name_of "$STALE/SKILL.md")" = "greenroom-setup" ]; then
  # A COPIED payload, from `npx skills add ...@greenroom-setup`. Not a link we
  # made, so not ours to delete -- but left alone the retired name resolves
  # forever, which is the whole point of this migration.
  echo "NOTE: $STALE is a copied install of the retired greenroom-setup skill."
  echo "      Remove it (rm -rf $STALE) so the old name stops resolving."
fi

# Migration 3: the ORIGINAL collision. Before 0.1.8 the skill was called `setup`,
# and `npx skills add` derives the install directory from `name:` -- so those users
# have a copied ~/.claude/skills/setup/ that still resolves as /setup forever. It is
# a copy, not a link we made, so it is only ever reported. `setup` is exactly the
# generic name the rename was about, so ownership must be PROVEN, not assumed: the
# declared name must be `setup` and the payload must identify itself as greenroom.
LEGACY_SETUP="$SKILL_DEST/setup"
if [ -d "$LEGACY_SETUP" ] && [ ! -L "$LEGACY_SETUP" ] && [ -f "$LEGACY_SETUP/SKILL.md" ] \
   && [ "$(skill_name_of "$LEGACY_SETUP/SKILL.md")" = "setup" ] \
   && grep -q '^description:.*greenroom layout' "$LEGACY_SETUP/SKILL.md"; then
  # `skills/setup/` only ever shipped SKILL.md -- scripts/ and templates/ moved
  # inside the skill dir in 0.2.0 -- so a payload-file signature can never match a
  # real legacy install. The proof is the retired skill describing ITSELF: every
  # 0.1.4-0.1.7 description opens "Set up the greenroom layout". A stranger whose
  # prose merely mentions greenroom does not say that about itself.
  echo "NOTE: $LEGACY_SETUP is a copied install of greenroom under its original name."
  echo "      Remove it (rm -rf $LEGACY_SETUP) so /setup stops resolving to greenroom."
fi

# Count the skills already present as a standalone install, or a successful run
# over one reports "Done. 0 skill(s)" -- the misleading summary this release set
# out to remove.
skill_already=$((skill_ok - skill_linked))
skill_summary="$skill_linked skill(s)"
if [ "$skill_already" -gt 0 ]; then
  skill_summary="$skill_summary linked, $skill_already already installed"
fi
cmd_summary="$cmd_linked command(s)"
if [ "$cmd_skipped" -gt 0 ]; then
  # Do not let a green-looking summary bury a half-broken command set: after a
  # moved clone these dangle with no provable owner, so each is skipped and the
  # user's /new, /add and /sync stay broken until they remove the links.
  cmd_summary="$cmd_summary ($cmd_skipped skipped -- see the SKIPs above)"
fi
# The headline must match the outcome. Printing "Done." and then failing on stderr
# is the mixed signal this was supposed to remove, not a smaller version of it.
if [ -n "$install_failed" ]; then
  echo "Incomplete. $skill_summary → $SKILL_DEST; $cmd_summary → $CMD_DEST"
else
  echo "Done. $skill_summary → $SKILL_DEST; $cmd_summary → $CMD_DEST"
fi

# A skill we ship did not get installed. The SKIPs above say what to do; exit
# non-zero so the failure is not buried under a cheerful summary -- a partial
# install is a failed install, not a quiet no-op.
if [ -n "$install_failed" ]; then
  if [ "$skill_found" -eq 0 ]; then
    echo "install.sh found no skills under $REPO_DIR/skills/ -- is this a complete clone?" >&2
  else
    echo "install.sh installed $skill_ok of $skill_found skill(s). See the SKIP notes above." >&2
  fi
  exit 1
fi
