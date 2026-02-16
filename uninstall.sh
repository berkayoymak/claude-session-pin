#!/usr/bin/env bash
# uninstall.sh — Remove cspin (Claude Session Pin)
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
HOOK_DIR="${HOME}/.claude/hooks"
SETTINGS="${HOME}/.claude/settings.json"

echo "Uninstalling cspin..."

# 1. Remove binary
if [[ -f "$BIN_DIR/cspin" ]]; then
    rm "$BIN_DIR/cspin"
    echo "  Removed: $BIN_DIR/cspin"
fi

# 2. Remove hook
if [[ -f "$HOOK_DIR/cspin-hook.sh" ]]; then
    rm "$HOOK_DIR/cspin-hook.sh"
    echo "  Removed: $HOOK_DIR/cspin-hook.sh"
fi

# 3. Remove hook entries from settings.json
if [[ -f "$SETTINGS" ]]; then
    python3 -c "
import json, sys

settings_path = sys.argv[1]
hook_cmd = 'bash ~/.claude/hooks/cspin-hook.sh'

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
changed = False

for event in list(hooks.keys()):
    event_hooks = hooks[event]
    for group in event_hooks:
        original = group.get('hooks', [])
        filtered = [h for h in original if h.get('command', '') != hook_cmd]
        if len(filtered) != len(original):
            group['hooks'] = filtered
            changed = True
    # Remove empty groups
    hooks[event] = [g for g in event_hooks if g.get('hooks', [])]
    # Remove empty events
    if not hooks[event]:
        del hooks[event]
        changed = True

if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    print('  Removed hook entries from:', settings_path)
else:
    print('  No hook entries found in:', settings_path)
" "$SETTINGS"
fi

echo ""
echo "Done! Your session data in ~/.cspin/ is preserved."
echo "To remove it completely: rm -rf ~/.cspin/"
