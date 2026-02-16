#!/bin/bash
# cspin-statusline.sh — Output current session's alias for Claude Code statusline
#
# Usage in ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "bash ~/.claude/hooks/cspin-statusline.sh"
#   }
#
# Reads the session_id from stdin JSON (provided by Claude Code),
# looks it up in cspin's tracking directory, and outputs the alias name.

CSPIN_DIR="${CSPIN_DIR:-$HOME/.cspin}"
TRACK_DIR="$CSPIN_DIR/.tracking"

# Read JSON from stdin
INPUT=$(cat)

SESSION_ID=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    print(data.get('session_id', ''))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null) || exit 0

[[ -n "$SESSION_ID" ]] || exit 0

# Look up alias via tracking file
TRACK_FILE="$TRACK_DIR/$SESSION_ID"
if [[ -f "$TRACK_FILE" ]]; then
    ALIAS=$(cat "$TRACK_FILE")
    printf '%s' "📌 $ALIAS"
fi
