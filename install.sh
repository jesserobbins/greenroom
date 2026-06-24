#!/usr/bin/env bash
# Symlink each skill under skills/*/ into ~/.claude/skills/<name> and the
# commands/*.md into ~/.claude/commands/, so Claude Code loads the skills and
# slash commands. Idempotent: safe to re-run. Run after cloning the repo.
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
