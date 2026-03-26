#!/usr/bin/env bash
set -euo pipefail

TMUX_SESSION="dsbot"
PIDFILE="/tmp/dsbot-tmux.pid"
LOG_TAG="dsbot-launcher"
WORKDIR="/opt/second-brain"
STDERR_LOG="/var/log/dsbot-stderr.log"

# If tmux session already exists, kill it (stale from crash)
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    logger -t "$LOG_TAG" "Stale tmux session found, killing"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    sleep 2
fi

# Pull latest code (same as old start-dsbot.sh)
cd "$WORKDIR" && git pull --ff-only 2>/dev/null || true

# Start tmux detached session (exact format from working start-dsbot.sh)
tmux new-session -d -s "$TMUX_SESSION" "cd $WORKDIR && export PATH=/root/.local/bin:/root/.bun/bin:\$PATH && claude --channels plugin:telegram@claude-plugins-official 2>>$STDERR_LOG"

# Write tmux server PID for systemd tracking
sleep 1
TMUX_PID=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
if [ -n "$TMUX_PID" ]; then
    # Write the tmux server PID (parent of the session)
    TMUX_SERVER_PID=$(ps -o ppid= -p "$TMUX_PID" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$TMUX_SERVER_PID" ]; then
        echo "$TMUX_SERVER_PID" > "$PIDFILE"
    else
        echo "$TMUX_PID" > "$PIDFILE"
    fi
fi

logger -t "$LOG_TAG" "DSBot tmux session started (pane PID: ${TMUX_PID:-unknown})"

# Verify the session is actually running
sleep 3
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    logger -t "$LOG_TAG" "ERROR: tmux session died immediately after start"
    exit 1
fi

logger -t "$LOG_TAG" "DSBot verified running"

# === BOOT PROTOCOL ===
# Wait for Claude to fully initialize (channels + plugin load)
sleep 10

# Send boot prompt — Claude will Read the file via its own tools
BOOT_FILE="$WORKDIR/Projects/dsbot/boot.md"
if [ -f "$BOOT_FILE" ]; then
    tmux send-keys -t "$TMUX_SESSION" "Read /opt/second-brain/Projects/dsbot/boot.md and execute all 7 phases" Enter
    logger -t "$LOG_TAG" "Boot prompt sent to Claude session"
else
    logger -t "$LOG_TAG" "WARNING: boot.md not found at $BOOT_FILE"
fi
