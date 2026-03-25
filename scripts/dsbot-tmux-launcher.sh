#!/usr/bin/env bash
set -euo pipefail

TMUX_SESSION="dsbot"
PIDFILE="/run/dsbot-tmux.pid"
LOG_TAG="dsbot-launcher"
WORKDIR="/opt/second-brain"
CLAUDE_CMD="claude --channels plugin:telegram@claude-plugins-official"

# If tmux session already exists, kill it (stale from crash)
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    logger -t "$LOG_TAG" "Stale tmux session found, killing"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    sleep 2
fi

# Start tmux detached session
cd "$WORKDIR"
tmux new-session -d -s "$TMUX_SESSION" "$CLAUDE_CMD"

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
