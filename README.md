# claude-session-pin

Pin human-friendly names to Claude Code sessions. A hook auto-follows the name across UUID changes.

## Problem

Claude Code identifies sessions by UUID. Every time context is compacted or `/clear` is used, the session gets a **new UUID** — breaking any external reference to it. There's no built-in way to say "this is my auth-refactor session" and have that name stick.

Related issues:
- [Session ID changes during resume](https://github.com/anthropics/claude-code/issues/12235)
- [Hook breakage from session ID changes](https://github.com/anthropics/claude-code/issues/10806)
- [Compaction failures making sessions unusable](https://github.com/anthropics/claude-code/issues/2423)
- [Session renaming feature request](https://github.com/anthropics/claude-code/issues/6006)

## Solution

`cspin` lets you **pin** a name to a session. A lightweight hook watches for compact/clear events and automatically updates the pin to the new UUID. Old UUIDs are archived as `name~1`, `name~2`, etc.

```
cspin new auth-refactor    # start a named session
# ... work, compact happens, UUID changes ...
cspin resume auth-refactor # always resumes the latest UUID
cspin list                 # see all pins
```

## Install

```bash
git clone https://github.com/nicberk/claude-session-pin.git
cd claude-session-pin
bash install.sh
```

This will:
1. Copy `cspin` to `~/.local/bin/`
2. Copy the hook to `~/.claude/hooks/`
3. Register hook events in `~/.claude/settings.json`
4. Create `~/.cspin/` for storage

### Statusline (optional)

To show the current session's pin name in Claude Code's status bar, add this snippet to your existing statusline script:

```bash
# cspin lookup — add to your statusline command script
cspin_track="${CSPIN_DIR:-$HOME/.cspin}/.tracking/$session_id"
if [[ -f "$cspin_track" ]]; then
    session_name="pin: $(cat "$cspin_track")"
fi
```

If you don't have a statusline yet, see `cspin-statusline.sh` for a standalone example.

## Usage

### Start a new named session

```bash
cspin new my-feature
cspin new debug-api -- --model sonnet  # pass args to claude
```

### Resume by name

```bash
cspin resume my-feature
cspin my-feature  # shorthand
```

### List all pins

```bash
cspin list
cspin  # same thing
```

Output:
```
NAME                 UUID           TRACK DIRECTORY
────                 ────           ───── ─────────
auth-refactor        a1b2c3d4e5f6   *    /home/user/project
debug-api (+2 arch.) 7f8e9d0c1b2a   *    /home/user/api
```

The `*` means auto-tracking is active. Archived counts show how many UUID transitions have occurred.

## How it works

### PID-based tracking

When you run `cspin new my-feature`, the process tree looks like:

```
cspin (PID=1000)  →  claude (PID=1001)  →  hook (PID=1002)
```

1. **Registration**: `cspin` writes `.pending-1000` (its own PID) as a marker, then launches Claude in the foreground.

2. **Hook fires**: The hook reads `$PPID` (Claude's PID = 1001), then reads `/proc/1001/stat` to find Claude's parent PID (1000). It matches `.pending-1000` and registers the alias.

3. **Transition detection**: On every hook event, the hook writes a `.pid-1001` file containing the alias name and current UUID. When a compact/clear creates a new UUID, the hook sees the PID file has the old UUID and performs the transition: archive old, update alias to new UUID.

This approach is robust because:
- **No TTY discovery** — PIDs are always unambiguous
- **No background polling** — registration happens synchronously in the hook
- **No race conditions** — the PID lineage is deterministic

### Storage layout

```
~/.cspin/
├── my-feature              # line 1: current UUID, line 2: CWD
├── my-feature~1            # archived UUID from first compact
├── .tracking/
│   ├── <uuid>              # content: alias name (enables lookup by UUID)
│   └── .pid-<claude_pid>   # content: alias name + UUID (enables transition detection)
```

### Hook events

| Event | What happens |
|-------|-------------|
| `Stop` | Refresh PID file + safety-net transition check |
| `PreCompact` | Refresh PID file (preserves alias→UUID mapping for SessionStart) |
| `SessionStart` | Primary transition handler — detects UUID change and updates alias |

The `SessionStart` hook uses `matcher: "compact|clear"` so it only fires on compaction or `/clear` events (not on fresh starts or resumes).

## Uninstall

```bash
bash uninstall.sh
```

This removes the binary and hook, and cleans up `settings.json`. Your session data in `~/.cspin/` is preserved — delete it manually if you want.

## License

MIT

---

Built with [Claude Code](https://claude.ai/code) (Opus)
