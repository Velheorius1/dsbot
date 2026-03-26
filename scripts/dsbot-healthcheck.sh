#!/usr/bin/env bash
set -euo pipefail

LOG_TAG="dsbot-health"
TMUX_SESSION="dsbot"
HEALTH_FILE="/tmp/dsbot-health-status"

check_failed() {
    local reason="$1"
    logger -t "$LOG_TAG" "UNHEALTHY: $reason"
    echo "UNHEALTHY: $reason $(date)" > "$HEALTH_FILE"

    # Prevent double restarts (lock for 120s)
    LOCK_FILE="/tmp/dsbot_restart.lock"
    if [ -f "$LOCK_FILE" ]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -lt 120 ]; then
            logger -t "$LOG_TAG" "Restart lock active (${lock_age}s ago), skipping restart"
            exit 0
        fi
    fi
    touch "$LOCK_FILE"

    # Log crash context BEFORE restart
    CRASH_LOGGER="/opt/second-brain/Projects/dsbot/scripts/crash-logger.sh"
    if [ -x "$CRASH_LOGGER" ]; then
        bash "$CRASH_LOGGER" "$reason" || true
    fi

    # Restart the service
    logger -t "$LOG_TAG" "Triggering restart via systemctl"
    systemctl restart dsbot.service
    exit 0
}

# Check 0: Is dsbot.service even supposed to be running?
SERVICE_STATE=$(systemctl is-active dsbot.service 2>/dev/null || echo "inactive")
if [ "$SERVICE_STATE" = "inactive" ] || [ "$SERVICE_STATE" = "failed" ]; then
    logger -t "$LOG_TAG" "Service is $SERVICE_STATE, skipping health check"
    echo "SKIPPED: service $SERVICE_STATE $(date)" > "$HEALTH_FILE"
    exit 0
fi

# tmux socket for dsbot user (UID 1000)
DSBOT_TMUX_SOCK="/tmp/tmux-$(id -u dsbot 2>/dev/null || echo 1000)/default"
TMUX_OPTS="-S $DSBOT_TMUX_SOCK"

# Check 1: tmux session exists
if ! tmux $TMUX_OPTS has-session -t "$TMUX_SESSION" 2>/dev/null; then
    check_failed "tmux session missing"
fi

# Check 2: claude process is alive (not zombie)
CLAUDE_PID=$(tmux $TMUX_OPTS list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1 || true)
if [ -z "$CLAUDE_PID" ]; then
    check_failed "no pane PID in tmux"
fi

if [ ! -d "/proc/$CLAUDE_PID" ]; then
    check_failed "claude PID $CLAUDE_PID does not exist"
fi

PROC_STATE=$(awk '/^State:/{print $2}' /proc/$CLAUDE_PID/status 2>/dev/null || echo "X")
if [ "$PROC_STATE" = "Z" ]; then
    check_failed "claude process is zombie (PID $CLAUDE_PID)"
fi

# Check 3: bun process exists and is not zombie
BUN_PID=$(pgrep -f "bun.*server\.ts" 2>/dev/null | head -1 || true)
if [ -z "$BUN_PID" ]; then
    # bun may take a moment to start after claude — only fail if uptime > 2 min
    UPTIME_SEC=$(systemctl show dsbot.service --property=ActiveEnterTimestamp --value 2>/dev/null || echo "")
    if [ -n "$UPTIME_SEC" ]; then
        START_EPOCH=$(date -d "$UPTIME_SEC" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        RUNNING_FOR=$((NOW_EPOCH - START_EPOCH))
        if [ "$RUNNING_FOR" -gt 120 ]; then
            check_failed "bun process not found after ${RUNNING_FOR}s uptime"
        fi
    fi
else
    BUN_STATE=$(awk '/^State:/{print $2}' /proc/$BUN_PID/status 2>/dev/null || echo "X")
    if [ "$BUN_STATE" = "Z" ]; then
        check_failed "bun process is zombie (PID $BUN_PID)"
    fi
fi

# Check 4: No duplicate bot polling (409 Conflict prevention)
BOT_COUNT=$(pgrep -fc "bun.*server\.ts" 2>/dev/null || echo 0)
if [ "$BOT_COUNT" -gt 1 ]; then
    logger -t "$LOG_TAG" "WARNING: $BOT_COUNT bun instances detected, killing extras"
    OLDEST_PID=$(pgrep -f "bun.*server\.ts" 2>/dev/null | head -1)
    pgrep -f "bun.*server\.ts" 2>/dev/null | grep -v "^${OLDEST_PID}$" | xargs kill -9 2>/dev/null || true
fi

# Check 5: bun is actually polling Telegram (not just alive but idle)
# CANNOT use getUpdates — it steals the polling slot and kills bun's loop!
# Instead: check if bun has active network connections to api.telegram.org.
# If bun is polling, it has an open TCP connection (long-poll) to Telegram.
if [ -n "$BUN_PID" ]; then
    UPTIME_SEC=$(systemctl show dsbot.service --property=ActiveEnterTimestamp --value 2>/dev/null || echo "")
    RUNNING_FOR=0
    if [ -n "$UPTIME_SEC" ]; then
        START_EPOCH=$(date -d "$UPTIME_SEC" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        RUNNING_FOR=$((NOW_EPOCH - START_EPOCH))
    fi

    if [ "$RUNNING_FOR" -gt 180 ]; then
        # Check if bun has ESTABLISHED connections (long-polling = open TCP to Telegram)
        CONN_COUNT=$(ss -tnp 2>/dev/null | grep "pid=$BUN_PID" | grep -c "ESTAB" || echo 0)
        if [ "$CONN_COUNT" -eq 0 ]; then
            # No network connections at all — bun is idle, not polling
            check_failed "bun alive but no network connections (not polling, ${RUNNING_FOR}s uptime)"
        fi
    fi
fi

# All checks passed
echo "HEALTHY $(date) claude=$CLAUDE_PID bun=${BUN_PID:-starting}" > "$HEALTH_FILE"
# Log OK only every 5th check to reduce noise (check /tmp counter)
COUNTER_FILE="/tmp/dsbot-health-counter"
COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
COUNTER=$((COUNTER + 1))
echo "$COUNTER" > "$COUNTER_FILE"
if [ $((COUNTER % 5)) -eq 0 ]; then
    logger -t "$LOG_TAG" "OK (claude=$CLAUDE_PID, bun=${BUN_PID:-starting}, checks=$COUNTER)"
fi
