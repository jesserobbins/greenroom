#!/usr/bin/env bash
# Symlink each skill under skills/*/ into ~/.claude/skills/greenroom-<name> and
# the commands/*.md into ~/.claude/commands/, so Claude Code loads the skills and
# slash commands. Also exposes the repo root at ~/.claude/skills/greenroom so the
# commands' script-path fallback (and the README/SKILL collect examples) resolve
# greenroom.py on a manual install. Idempotent: safe to re-run after cloning.
#
# (If you instead install greenroom as a Claude Code plugin via the marketplace
#  (`/plugin marketplace add jesserobbins/greenroom` then `/plugin install
#  greenroom@jesserobbins`), you do NOT need this script; the plugin system wires
#  everything for you. This is the manual path for a direct `git clone`.)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DEST="$HOME/.claude/skills"
CMD_DEST="$HOME/.claude/commands"
mkdir -p "$SKILL_DEST" "$CMD_DEST"

# link <target> <link-path> <label>: refresh our own symlinks, never clobber a
# real file the user owns. Sets `link_result` to "linked" or "skip".
link_one() {
  local target="$1" link="$2" label="$3"
  if [ -L "$link" ]; then
    rm "$link"                                     # refresh existing symlink
  elif [ -e "$link" ]; then
    echo "SKIP $label: $link exists and is not a symlink (leaving it untouched)"
    link_result="skip"
    return
  fi
  ln -s "$target" "$link"
  echo "linked $label"
  link_result="linked"
}

# Expose the script (and its templates) at the commands' tier-3 fallback path
# ($HOME/.claude/skills/greenroom/scripts/greenroom.py) and the README/SKILL
# collect examples. This is a plain directory holding two symlinks, NOT a copy
# of the repo root: symlinking the whole root would drag in .claude-plugin/
# plugin.json and the nested skills/, which Claude Code would auto-load as a
# `greenroom@skills-dir` plugin (reintroducing the /greenroom:setup stutter).
# Exposing only scripts/ and templates/ keeps script resolution working with no
# manifest and no nested skill in scope.
SCRIPT_ROOT="$SKILL_DEST/greenroom"
# Migrate an older installer's layout: it symlinked this path straight at the
# repo root, which exposes the plugin manifest (auto-loaded as greenroom@skills-dir).
# Replace that symlink with a real directory so we link only scripts/ + templates/
# into it. (Removing a symlink here never deletes the repo it points at.)
[ -L "$SCRIPT_ROOT" ] && { rm "$SCRIPT_ROOT"; echo "migrated: replaced the old greenroom root symlink with a script-only dir"; }
mkdir -p "$SCRIPT_ROOT"
link_one "$REPO_DIR/scripts" "$SCRIPT_ROOT/scripts" "greenroom scripts"
link_one "$REPO_DIR/templates" "$SCRIPT_ROOT/templates" "greenroom templates"

# Link each skill under a greenroom- prefix so a manual install gets a
# namespaced /greenroom-<name> instead of a generic /<name> that could collide
# with the user's own skills. (A plugin install gives /greenroom:<name>.)
skill_linked=0
for skill_dir in "$REPO_DIR"/skills/*/; do
  [ -f "$skill_dir/SKILL.md" ] || continue          # only dirs that hold a skill
  sname="$(basename "$skill_dir")"
  link_result=""
  link_one "${skill_dir%/}" "$SKILL_DEST/greenroom-$sname" "skill greenroom-$sname"
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
