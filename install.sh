#!/usr/bin/env bash
# install.sh — Install cspin (Claude Session Pin)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
HOOK_DIR="${HOME}/.claude/hooks"
CSPIN_DIR="${HOME}/.cspin"
SETTINGS="${HOME}/.claude/settings.json"

echo "Installing cspin..."

# 1. Copy cspin to ~/.local/bin
mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/cspin" "$BIN_DIR/cspin"
chmod +x "$BIN_DIR/cspin"
echo "  Installed: $BIN_DIR/cspin"

# 2. Copy hook to ~/.claude/hooks
mkdir -p "$HOOK_DIR"
cp "$SCRIPT_DIR/cspin-hook.sh" "$HOOK_DIR/cspin-hook.sh"
chmod +x "$HOOK_DIR/cspin-hook.sh"
echo "  Installed: $HOOK_DIR/cspin-hook.sh"

# 3. Create storage directory
mkdir -p "$CSPIN_DIR/.tracking"
echo "  Created:   $CSPIN_DIR/"

# 5. Register hooks in settings.json
if [[ ! -f "$SETTINGS" ]]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
fi

python3 -c "
import json, sys

settings_path = sys.argv[1]
hook_cmd = 'bash ~/.claude/hooks/cspin-hook.sh'

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})

# Hook entries to register
entries = {
    'Stop':         {'matcher': '', 'timeout': 5},
    'PreCompact':   {'matcher': '', 'timeout': 5},
    'SessionStart': {'matcher': '', 'timeout': 5},
}

for event, config in entries.items():
    event_hooks = hooks.setdefault(event, [])

    # Check if cspin hook already registered
    already = False
    for group in event_hooks:
        for h in group.get('hooks', []):
            if h.get('command', '') == hook_cmd:
                already = True
                break
        if already:
            break

    if not already:
        # Find existing group with matching matcher, or create new
        target_group = None
        for group in event_hooks:
            if group.get('matcher', '') == config['matcher']:
                target_group = group
                break

        hook_entry = {
            'type': 'command',
            'command': hook_cmd,
            'timeout': config['timeout'],
        }

        if target_group:
            target_group['hooks'].append(hook_entry)
        else:
            event_hooks.append({
                'matcher': config['matcher'],
                'hooks': [hook_entry],
            })

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, sort_keys=False)
    f.write('\n')

print(f'  Added cspin-hook.sh to: {\", \".join(entries.keys())}')
" "$SETTINGS"

echo "  Registered hooks in: $SETTINGS"

# 6. Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo ""
    echo "  NOTE: $BIN_DIR is not in your PATH."
    echo "  Add to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "Done! Usage:"
echo "  cspin new my-session     # Start a named session"
echo "  cspin resume my-session  # Resume by name"
echo "  cspin list               # Show all pins"
