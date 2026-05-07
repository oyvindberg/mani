#!/usr/bin/env zsh
# Spike 3 setup. Builds HookShim/HookListener, writes a sandboxed
# ~/.claude/settings.json that hooks SessionStart/Stop/SessionEnd into
# our shim, prints the command to run claude inside the sandbox.

set -e
cd "$(dirname "$0")/../.."  # repo root

REPO=$(pwd)
echo "Building HookShim and HookListener..."
swift build --product HookShim --product HookListener 2>&1 | tail -3

SHIM_BIN="$REPO/.build/debug/HookShim"
LISTENER_BIN="$REPO/.build/debug/HookListener"
SOCKET="/tmp/mani-hook-spike.sock"
SPIKE_HOME="/tmp/mani-spike-home"
SPIKE_CWD="/tmp/mani-spike-cwd"

mkdir -p "$SPIKE_HOME/.claude"
mkdir -p "$SPIKE_CWD"

cat > "$SPIKE_HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "$SHIM_BIN"}]}],
    "Stop":         [{"matcher": "", "hooks": [{"type": "command", "command": "$SHIM_BIN"}]}],
    "SessionEnd":   [{"matcher": "", "hooks": [{"type": "command", "command": "$SHIM_BIN"}]}],
    "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "$SHIM_BIN"}]}]
  }
}
EOF

cat <<EOF

Setup complete.

Run these in two separate terminals.

  Terminal 1 (listener):
    $LISTENER_BIN

  Terminal 2 (claude in the sandbox):
    cd $SPIKE_CWD && env HOME=$SPIKE_HOME MANI_TASK_ID=spike-3 claude

  In the claude session: type a short prompt, let it reply, then /quit (or Ctrl-D).

What to look for in the listener output:
  - One envelope tagged hook_event_name=SessionStart shortly after claude starts
  - One Stop envelope after each model turn finishes (i.e., after the reply)
  - One SessionEnd envelope when claude exits

Settings file:  $SPIKE_HOME/.claude/settings.json
Socket path:    $SOCKET
EOF
