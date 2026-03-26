#!/usr/bin/env bash
set -euo pipefail

TMUX_SESSION="dsbot"
LOG_TAG="dsbot-stop"

logger -t "$LOG_TAG" "Stopping DSBot..."

# tmux socket for dsbot user
DSBOT_TMUX_SOCK="/tmp/tmux-$(id -u dsbot 2>/dev/null || echo 1000)/default"
TMUX_OPTS="-S $DSBOT_TMUX_SOCK"

# Step 1: Send SIGTERM to claude process inside tmux
CLAUDE_PID=$(tmux $TMUX_OPTS list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1 || true)

if [ -n "$CLAUDE_PID" ]; then
    # Send SIGTERM to the process group (claude + bun children)
    kill -TERM -- "-$CLAUDE_PID" 2>/dev/null || true
    logger -t "$LOG_TAG" "Sent SIGTERM to process group $CLAUDE_PID"

    # Wait up to 15 seconds for graceful shutdown
    for i in $(seq 1 15); do
        if ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
            logger -t "$LOG_TAG" "Claude process exited gracefully after ${i}s"
            break
        fi
        sleep 1
    done

    # SIGKILL if still alive
    if kill -0 "$CLAUDE_PID" 2>/dev/null; then
        logger -t "$LOG_TAG" "SIGKILL after 15s timeout"
        kill -KILL -- "-$CLAUDE_PID" 2>/dev/null || true
        sleep 1
    fi
fi

# Step 2: Kill the tmux session
tmux $TMUX_OPTS kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Step 3: Final cleanup of any orphans
pkill -f "claude.*channels.*telegram" 2>/dev/null || true
sleep 1
pkill -9 -f "bun.*server\.ts" 2>/dev/null || true

# Clean PID file
rm -f /run/dsbot-tmux.pid

logger -t "$LOG_TAG" "DSBot stopped"
