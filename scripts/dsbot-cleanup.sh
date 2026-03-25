#!/usr/bin/env bash
set -euo pipefail

LOG_TAG="dsbot-cleanup"

# Kill orphaned claude processes (from previous crashes)
CLAUDE_PIDS=$(pgrep -f "claude.*channels.*telegram" 2>/dev/null || true)
if [ -n "$CLAUDE_PIDS" ]; then
    logger -t "$LOG_TAG" "Killing orphaned claude PIDs: $CLAUDE_PIDS"
    echo "$CLAUDE_PIDS" | xargs kill -9 2>/dev/null || true
    sleep 2
fi

# Kill orphaned bun processes (telegram plugin)
BUN_PIDS=$(pgrep -f "bun.*server\.ts" 2>/dev/null || true)
if [ -n "$BUN_PIDS" ]; then
    logger -t "$LOG_TAG" "Killing orphaned bun PIDs: $BUN_PIDS"
    echo "$BUN_PIDS" | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# Kill stale tmux session
if tmux has-session -t dsbot 2>/dev/null; then
    logger -t "$LOG_TAG" "Killing stale tmux session"
    tmux kill-session -t dsbot 2>/dev/null || true
    sleep 1
fi

# Clean PID file
rm -f /run/dsbot-tmux.pid

logger -t "$LOG_TAG" "Cleanup complete"
