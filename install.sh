#!/bin/bash
#
# luigis-meter installer
# https://github.com/Luigigreco/luigis-meter
#
# Downloads luigis-meter.sh into ~/.claude/scripts/ and prints the snippet
# to paste into your ~/.claude/statusline.sh. Never modifies your statusline
# without asking.
#

set -e

REPO_RAW="https://raw.githubusercontent.com/Luigigreco/luigis-meter/main"
TARGET_DIR="$HOME/.claude/scripts"
TARGET_FILE="$TARGET_DIR/luigis-meter.sh"

echo "luigis-meter installer"
echo "======================"
echo

mkdir -p "$TARGET_DIR"

if [ -f "$TARGET_FILE" ]; then
    echo "Existing luigis-meter.sh found. Backing up to ${TARGET_FILE}.bak"
    cp "$TARGET_FILE" "${TARGET_FILE}.bak"
fi

echo "Downloading luigis-meter.sh..."
curl -fsSL "$REPO_RAW/luigis-meter.sh" -o "$TARGET_FILE"
chmod +x "$TARGET_FILE"

echo
echo "Installed: $TARGET_FILE"
echo
echo "Next step: add these lines to your ~/.claude/statusline.sh"
echo
echo "-----------------------------8<-----------------------------"
echo '# luigis-meter — Claude Code Max quota estimate'
echo 'METER_LINE=$(bash ~/.claude/scripts/luigis-meter.sh 2>/dev/null)'
echo '# ... your existing echo "$LINE" goes here ...'
echo '[ -n "$METER_LINE" ] && echo -e "$METER_LINE"'
echo "-----------------------------8<-----------------------------"
echo
echo "Done. Open a new Claude Code window to see the meter in action."
echo "To calibrate, see: https://github.com/Luigigreco/luigis-meter#calibration"
