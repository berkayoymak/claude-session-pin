#!/bin/bash
# cspin-hook.sh — Claude Code hook for auto-updating cspin session aliases
#
# Registered for THREE events:
#   Stop         — refreshes PID file + safety-net transition detection
#   PreCompact   — refreshes PID file (so SessionStart can find the old UUID)
#   SessionStart — primary transition handler (compact/clear)
#
# PID-based tracking (no TTY discovery):
#   Uses Claude's PID ($PPID in hook context), which is stable across both
#   compact and /clear events. A .pid-<CLAUDE_PID> file maps the process to
#   its alias + current UUID, enabling transition detection on SessionStart.
#
#   Pending registration walks the process tree:
#     hook → Claude ($PPID) → cspin (Claude's parent from /proc)
#   to find .pending-<cspin_pid> markers written by `cspin new`.

set -euo pipefail

CSPIN_DIR="${CSPIN_DIR:-$HOME/.cspin}"
TRACK_DIR="$CSPIN_DIR/.tracking"

[[ -d "$TRACK_DIR" ]] || exit 0

# Read JSON from stdin
INPUT=$(cat)

read -r SESSION_ID CWD EVENT < <(python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    sid = data.get('session_id', '')
    cwd = data.get('cwd', '')
    event = data.get('hook_event_name', '')
    print(sid, cwd, event)
except Exception:
    print('', '', '')
" <<< "$INPUT" 2>/dev/null) || exit 0

[[ -n "$SESSION_ID" && -n "$CWD" ]] || exit 0

# --- Find stable Claude process PID ---
# $PPID is an ephemeral /bin/sh wrapper spawned by child_process.exec().
# Walk up the process tree to find the long-lived "node" or "claude" process.
# That PID is stable across all hook invocations in the same session.
CLAUDE_PID=$PPID
_WALK_PID=$PPID
for _i in 1 2 3 4 5; do
    _ANCESTOR=$(awk '{print $4}' /proc/$_WALK_PID/stat 2>/dev/null || echo "")
    [[ -n "$_ANCESTOR" && "$_ANCESTOR" != "1" && "$_ANCESTOR" != "0" && "$_ANCESTOR" != "$_WALK_PID" ]] || break
    _COMM=$(cat /proc/$_ANCESTOR/comm 2>/dev/null || echo "")
    case "$_COMM" in
        node|claude) CLAUDE_PID=$_ANCESTOR; break ;;
    esac
    _WALK_PID=$_ANCESTOR
done
PID_FILE="$TRACK_DIR/.pid-$CLAUDE_PID"

# --- Pending registration (from cspin new) ---
# If this UUID has no tracking file, check for a pending registration
# by walking the process tree upward: hook → node → claude → cspin.
# The claude CLI is a compiled binary that spawns node, so we may need
# to walk 2-3 levels to reach the cspin bash process.
# Age guard: reject markers older than 2 minutes (stale from crashed cspin).
_PENDING_MAX_AGE=120
if [[ ! -f "$TRACK_DIR/$SESSION_ID" ]]; then
    _PENDING_FILE=""
    _WALK_PID=$CLAUDE_PID
    _WALK_DEPTH=0
    while (( _WALK_DEPTH < 5 )); do
        _ANCESTOR=$(awk '{print $4}' /proc/$_WALK_PID/stat 2>/dev/null || echo "")
        [[ -n "$_ANCESTOR" && "$_ANCESTOR" != "1" && "$_ANCESTOR" != "0" && "$_ANCESTOR" != "$_WALK_PID" ]] || break
        if [[ -f "$TRACK_DIR/.pending-$_ANCESTOR" ]]; then
            _PENDING_FILE="$TRACK_DIR/.pending-$_ANCESTOR"
            break
        fi
        _WALK_PID=$_ANCESTOR
        _WALK_DEPTH=$((_WALK_DEPTH + 1))
    done

    if [[ -n "$_PENDING_FILE" ]]; then
        _PENDING_AGE=$(( $(date +%s) - $(stat --format='%Y' "$_PENDING_FILE" 2>/dev/null || echo 0) ))
        if (( _PENDING_AGE > _PENDING_MAX_AGE )); then
            rm -f "$_PENDING_FILE"
        else
            _PENDING_NAME=$(sed -n '1p' "$_PENDING_FILE")
            _PENDING_DIR=$(sed -n '2p' "$_PENDING_FILE")
            if [[ -n "$_PENDING_NAME" ]]; then
                if [[ ! -f "$CSPIN_DIR/$_PENDING_NAME" ]]; then
                    # Register the alias with the current (live) UUID
                    printf '%s\n%s\n' "$SESSION_ID" "${_PENDING_DIR:-$CWD}" > "$CSPIN_DIR/$_PENDING_NAME"
                    echo "$_PENDING_NAME" > "$TRACK_DIR/$SESSION_ID"
                    rm -f "$_PENDING_FILE"
                else
                    # Alias already exists (EXIT trap won the race) — clean up
                    rm -f "$_PENDING_FILE"
                fi
            fi
        fi
    fi
fi

# --- Refresh PID file (on every event when session is tracked) ---
if [[ -f "$TRACK_DIR/$SESSION_ID" ]]; then
    _ALIAS_NAME=$(cat "$TRACK_DIR/$SESSION_ID")
    printf '%s\n%s\n' "$_ALIAS_NAME" "$SESSION_ID" > "$PID_FILE"
fi

# --- Transition logic ---
# Called from both SessionStart (primary) and Stop (safety net).
# Returns 0 if transition was performed, 1 otherwise.
do_transition() {
    local event_name="$1"

    # Already tracked? Nothing to do.
    [[ -f "$TRACK_DIR/$SESSION_ID" ]] && return 1

    # No PID file → nothing to transition from
    [[ -f "$PID_FILE" ]] || return 1

    local ALIAS_NAME OLD_UUID
    ALIAS_NAME=$(sed -n '1p' "$PID_FILE")
    OLD_UUID=$(sed -n '2p' "$PID_FILE")

    [[ -n "$ALIAS_NAME" && -n "$OLD_UUID" ]] || return 1
    [[ "$OLD_UUID" != "$SESSION_ID" ]] || return 1

    # Verify tracking file for old UUID exists
    if [[ ! -f "$TRACK_DIR/$OLD_UUID" ]]; then
        # Reverse-lookup fallback: scan alias files for this UUID
        local _found=false
        for af in "$CSPIN_DIR"/[!.]*; do
            [[ -f "$af" ]] || continue
            local af_name="${af##*/}"
            [[ "$af_name" == *~* ]] && continue
            if [[ "$(head -1 "$af")" == "$OLD_UUID" ]]; then
                echo "$ALIAS_NAME" > "$TRACK_DIR/$OLD_UUID"
                _found=true
                break
            fi
        done
        [[ "$_found" == "true" ]] || return 1
    fi

    local ALIAS_FILE="$CSPIN_DIR/$ALIAS_NAME"
    [[ -f "$ALIAS_FILE" ]] || return 1

    # Verify stored UUID matches
    local STORED_UUID
    STORED_UUID=$(head -1 "$ALIAS_FILE")
    [[ "$STORED_UUID" == "$OLD_UUID" ]] || return 1

    # Archive old session under a derived alias (name~1, name~2, ...)
    local STORED_DIR
    STORED_DIR=$(sed -n '2p' "$ALIAS_FILE")
    local ARCHIVE_NUM=1
    while [[ -f "$CSPIN_DIR/${ALIAS_NAME}~${ARCHIVE_NUM}" ]]; do
        ARCHIVE_NUM=$((ARCHIVE_NUM + 1))
    done
    printf '%s\n%s\n' "$OLD_UUID" "${STORED_DIR:-$CWD}" > "$CSPIN_DIR/${ALIAS_NAME}~${ARCHIVE_NUM}"

    # Update alias to new UUID
    printf '%s\n%s\n' "$SESSION_ID" "${STORED_DIR:-$CWD}" > "$ALIAS_FILE"

    # Move tracking: old UUID → new UUID
    rm -f "$TRACK_DIR/$OLD_UUID"
    echo "$ALIAS_NAME" > "$TRACK_DIR/$SESSION_ID"

    # Update PID file to new UUID
    printf '%s\n%s\n' "$ALIAS_NAME" "$SESSION_ID" > "$PID_FILE"

    return 0
}

if [[ "$EVENT" == "PreCompact" ]]; then
    # PID file already refreshed above
    exit 0
fi

if [[ "$EVENT" == "SessionStart" ]]; then
    do_transition "SessionStart" || true
    exit 0
fi

if [[ "$EVENT" == "Stop" ]]; then
    # Safety net: catch transitions missed by SessionStart
    do_transition "Stop" || true
    exit 0
fi

exit 0
