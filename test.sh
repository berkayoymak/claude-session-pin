#!/usr/bin/env bash
# test.sh — Automated tests for cspin
#
# Tests the machinery (storage, tracking, transitions, list) using
# simulated hook invocations. No real Claude sessions needed.
#
# Usage: bash test.sh

set -euo pipefail

# --- Test environment ---
TEST_DIR=$(mktemp -d /tmp/cspin-test-XXXXXX)
export CSPIN_DIR="$TEST_DIR/cspin"
TRACK_DIR="$CSPIN_DIR/.tracking"
mkdir -p "$CSPIN_DIR" "$TRACK_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSPIN="$SCRIPT_DIR/cspin"
HOOK="$SCRIPT_DIR/cspin-hook.sh"

PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR"
    echo ""
    echo "═══════════════════════════════════"
    echo "  Results: $PASS passed, $FAIL failed"
    echo "═══════════════════════════════════"
    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (file not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_not_exists() {
    local label="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (file should not exist: $path)"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: invoke hook with simulated JSON, faking PPID via a wrapper
invoke_hook() {
    local session_id="$1" cwd="$2" event="$3" fake_ppid="$4"
    local json
    json=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s"}' \
        "$session_id" "$cwd" "$event")

    # The hook reads $PPID — we can't fake that directly, but we CAN
    # test the transition logic by pre-populating the PID file.
    # For pending registration, we test the cspin side instead.
    echo "$json" | CSPIN_DIR="$CSPIN_DIR" bash -c '
        # Override PPID for the hook
        export CSPIN_DIR="'"$CSPIN_DIR"'"
        # We source the hook logic inline since $PPID cant be overridden
        exec bash '"$HOOK"'
    '
}

# ══════════════════════════════════════════════════════════════════════
echo "═══ Test 1: cspin list (empty) ═══"
# ══════════════════════════════════════════════════════════════════════

output=$(bash "$CSPIN" list 2>&1)
assert_eq "empty list message" "No pinned sessions. Use 'cspin new <name>' to pin one." "$output"


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 2: Manual alias creation + list ═══"
# ══════════════════════════════════════════════════════════════════════

UUID1="aaaaaaaa-1111-2222-3333-444444444444"
printf '%s\n%s\n' "$UUID1" "/home/user/project-a" > "$CSPIN_DIR/my-feature"
echo "my-feature" > "$TRACK_DIR/$UUID1"

output=$(bash "$CSPIN" list 2>&1)
echo "$output" | grep -q "my-feature" && {
    echo "  PASS: list shows my-feature"
    PASS=$((PASS + 1))
} || {
    echo "  FAIL: list missing 'my-feature'"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
}


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 3: Tracking file activation ═══"
# ══════════════════════════════════════════════════════════════════════

UUID2="bbbbbbbb-1111-2222-3333-444444444444"
printf '%s\n%s\n' "$UUID2" "/home/user/project-b" > "$CSPIN_DIR/debug-api"

# Simulate what cspin resume does: activate tracking
echo "debug-api" > "$TRACK_DIR/$UUID2"

assert_file_exists "tracking file created" "$TRACK_DIR/$UUID2"
assert_eq "tracking content" "debug-api" "$(cat "$TRACK_DIR/$UUID2")"


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 4: Hook — PID file refresh ═══"
# ══════════════════════════════════════════════════════════════════════

# Simulate: session UUID2 is tracked, hook fires Stop event
# The hook will use its actual $PPID, so we pre-populate the tracking file
# and verify that a .pid-$PPID file gets created.

json='{"session_id":"'"$UUID2"'","cwd":"/home/user/project-b","hook_event_name":"Stop"}'
echo "$json" | CSPIN_DIR="$CSPIN_DIR" bash "$HOOK" 2>/dev/null || true

# The hook uses its own $PPID (which is our shell's PID)
# Find the .pid file that was created
pid_files=("$TRACK_DIR"/.pid-*)
if [[ -f "${pid_files[0]}" ]]; then
    echo "  PASS: PID file created"
    PASS=$((PASS + 1))
    pid_content=$(cat "${pid_files[0]}")
    assert_eq "PID file line 1 (alias)" "debug-api" "$(echo "$pid_content" | head -1)"
    assert_eq "PID file line 2 (UUID)" "$UUID2" "$(echo "$pid_content" | sed -n '2p')"
else
    echo "  FAIL: No PID file created"
    FAIL=$((FAIL + 1))
fi


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 5: Hook — Transition detection ═══"
# ══════════════════════════════════════════════════════════════════════

# Setup: PID file exists with old UUID, new session arrives via SessionStart
UUID3="cccccccc-1111-2222-3333-444444444444"

# Write PID file as if PreCompact happened with UUID2
# We need to know the PID that bash will use for the hook subprocess.
# Since we can't predict it, we'll use a wrapper that writes the PID file
# with the correct $PPID before the hook runs.

# Approach: write PID file keyed to the PID of the bash process that will
# run the hook (which is the subshell's $PPID = current shell's PID)
OUR_PID=$$
printf '%s\n%s\n' "debug-api" "$UUID2" > "$TRACK_DIR/.pid-$OUR_PID"

json='{"session_id":"'"$UUID3"'","cwd":"/home/user/project-b","hook_event_name":"SessionStart"}'
echo "$json" | CSPIN_DIR="$CSPIN_DIR" bash "$HOOK" 2>/dev/null || true

# Verify transition occurred
assert_eq "alias updated to new UUID" "$UUID3" "$(head -1 "$CSPIN_DIR/debug-api")"
assert_file_exists "new tracking file" "$TRACK_DIR/$UUID3"
assert_file_not_exists "old tracking file removed" "$TRACK_DIR/$UUID2"

# Verify archive was created
assert_file_exists "archive created" "$CSPIN_DIR/debug-api~1"
assert_eq "archive has old UUID" "$UUID2" "$(head -1 "$CSPIN_DIR/debug-api~1")"


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 6: Hook — Duplicate transition guard ═══"
# ══════════════════════════════════════════════════════════════════════

# If hook fires again with the same UUID3 (already tracked), nothing should change
printf '%s\n%s\n' "debug-api" "$UUID3" > "$TRACK_DIR/.pid-$OUR_PID"

json='{"session_id":"'"$UUID3"'","cwd":"/home/user/project-b","hook_event_name":"SessionStart"}'
echo "$json" | CSPIN_DIR="$CSPIN_DIR" bash "$HOOK" 2>/dev/null || true

# Should still be UUID3, no new archive
assert_eq "no double transition" "$UUID3" "$(head -1 "$CSPIN_DIR/debug-api")"
assert_file_not_exists "no debug-api~2 created" "$CSPIN_DIR/debug-api~2"


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 7: Hook — Pending registration (simulated) ═══"
# ══════════════════════════════════════════════════════════════════════

# Simulate cspin new writing a .pending-<PID> file
# The hook walks: $PPID (Claude PID) → /proc/$PPID/stat field 4 (cspin PID)
# In test: hook's $PPID = our PID, our parent = the terminal/shell
# We write .pending-<our_parent_pid>

PARENT_PID=$(awk '{print $4}' /proc/$OUR_PID/stat 2>/dev/null || echo "")
if [[ -n "$PARENT_PID" && "$PARENT_PID" != "1" ]]; then
    UUID4="dddddddd-1111-2222-3333-444444444444"
    printf '%s\n%s\n' "new-session" "/home/user/project-c" > "$TRACK_DIR/.pending-$PARENT_PID"

    json='{"session_id":"'"$UUID4"'","cwd":"/home/user/project-c","hook_event_name":"Stop"}'
    echo "$json" | CSPIN_DIR="$CSPIN_DIR" bash "$HOOK" 2>/dev/null || true

    assert_file_exists "pending registration created alias" "$CSPIN_DIR/new-session"
    assert_eq "alias has correct UUID" "$UUID4" "$(head -1 "$CSPIN_DIR/new-session")"
    assert_file_exists "tracking file created" "$TRACK_DIR/$UUID4"
    assert_file_not_exists "pending file cleaned up" "$TRACK_DIR/.pending-$PARENT_PID"
else
    echo "  SKIP: Cannot determine parent PID (containerized?)"
fi


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 8: Multiple sessions — no cross-contamination ═══"
# ══════════════════════════════════════════════════════════════════════

UUID5="eeeeeeee-1111-2222-3333-444444444444"
UUID6="ffffffff-1111-2222-3333-444444444444"

printf '%s\n%s\n' "$UUID5" "/home/user/project-d" > "$CSPIN_DIR/session-a"
printf '%s\n%s\n' "$UUID6" "/home/user/project-d" > "$CSPIN_DIR/session-b"
echo "session-a" > "$TRACK_DIR/$UUID5"
echo "session-b" > "$TRACK_DIR/$UUID6"

# Transition only session-a (PID file points to session-a)
UUID5_NEW="55555555-1111-2222-3333-444444444444"
printf '%s\n%s\n' "session-a" "$UUID5" > "$TRACK_DIR/.pid-$OUR_PID"

json='{"session_id":"'"$UUID5_NEW"'","cwd":"/home/user/project-d","hook_event_name":"SessionStart"}'
echo "$json" | CSPIN_DIR="$CSPIN_DIR" bash "$HOOK" 2>/dev/null || true

assert_eq "session-a transitioned" "$UUID5_NEW" "$(head -1 "$CSPIN_DIR/session-a")"
assert_eq "session-b unchanged" "$UUID6" "$(head -1 "$CSPIN_DIR/session-b")"


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 9: cspin list formatting ═══"
# ══════════════════════════════════════════════════════════════════════

output=$(bash "$CSPIN" list 2>&1)

echo "$output" | grep -q "NAME" && {
    echo "  PASS: list has header"
    PASS=$((PASS + 1))
} || {
    echo "  FAIL: list missing header"
    FAIL=$((FAIL + 1))
}

echo "$output" | grep -q "session-a" && {
    echo "  PASS: list shows session-a"
    PASS=$((PASS + 1))
} || {
    echo "  FAIL: list missing session-a"
    FAIL=$((FAIL + 1))
}

echo "$output" | grep -q "session-b" && {
    echo "  PASS: list shows session-b"
    PASS=$((PASS + 1))
} || {
    echo "  FAIL: list missing session-b"
    FAIL=$((FAIL + 1))
}

# Archive count should appear
echo "$output" | grep -q "archived" && {
    echo "  PASS: list shows archive count"
    PASS=$((PASS + 1))
} || {
    echo "  FAIL: list missing archive count indicator"
    FAIL=$((FAIL + 1))
}


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 10: Help output ═══"
# ══════════════════════════════════════════════════════════════════════

output=$(bash "$CSPIN" --help 2>&1)
echo "$output" | grep -q "cspin new" && {
    echo "  PASS: help mentions 'cspin new'"
    PASS=$((PASS + 1))
} || {
    echo "  FAIL: help missing 'cspin new'"
    FAIL=$((FAIL + 1))
}


# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Test 11: Error cases ═══"
# ══════════════════════════════════════════════════════════════════════

# Resume nonexistent
output=$(bash "$CSPIN" resume nonexistent 2>&1) && {
    echo "  FAIL: resume nonexistent should fail"
    FAIL=$((FAIL + 1))
} || {
    echo "$output" | grep -q "No session named" && {
        echo "  PASS: resume nonexistent gives error"
        PASS=$((PASS + 1))
    } || {
        echo "  FAIL: wrong error message: $output"
        FAIL=$((FAIL + 1))
    }
}

# New with existing name
printf '%s\n%s\n' "fake-uuid" "/tmp" > "$CSPIN_DIR/taken-name"
output=$(bash "$CSPIN" new taken-name 2>&1) && {
    echo "  FAIL: new with taken name should fail"
    FAIL=$((FAIL + 1))
} || {
    echo "$output" | grep -q "already exists" && {
        echo "  PASS: new with taken name gives error"
        PASS=$((PASS + 1))
    } || {
        echo "  FAIL: wrong error message: $output"
        FAIL=$((FAIL + 1))
    }
}
