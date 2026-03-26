#!/usr/bin/env bash
set -euo pipefail

# limits_tracker.sh — мониторинг доступности Claude CLI
# Cron: */5 * * * *
# Проверяет что claude отвечает, алертит в Telegram при rate limit

LOG_TAG="dsbot-limits"
LOGFILE="/var/log/dsbot-limits.log"
ALERT_LOCK="/tmp/dsbot-limits-alert.lock"
ALERT_INTERVAL=3600  # не чаще 1 алерта в час

# Telegram credentials (из .env fallback-бота или переменных окружения)
ENV_FILE="/opt/second-brain/Projects/dsbot/fallback-bot/.env"
if [ -f "$ENV_FILE" ]; then
    BOT_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    ADMIN_ID=$(grep -E '^ADMIN_ID=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
fi

BOT_TOKEN="${BOT_TOKEN:-}"
ADMIN_ID="${ADMIN_ID:-}"

send_alert() {
    local msg="$1"
    if [ -z "$BOT_TOKEN" ] || [ -z "$ADMIN_ID" ]; then
        logger -t "$LOG_TAG" "Cannot send alert: no BOT_TOKEN or ADMIN_ID"
        return
    fi

    # Проверяем lock (не спамим)
    if [ -f "$ALERT_LOCK" ]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$ALERT_LOCK" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -lt "$ALERT_INTERVAL" ]; then
            logger -t "$LOG_TAG" "Alert suppressed (lock ${lock_age}s old)"
            return
        fi
    fi

    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$ADMIN_ID" \
        -d text="⚠️ Claude CLI: ${msg}" \
        -d parse_mode="HTML" > /dev/null 2>&1 || true

    touch "$ALERT_LOCK"
    logger -t "$LOG_TAG" "Alert sent: $msg"
}

# Проверяем claude CLI
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" &>/dev/null; then
    # Попробуем стандартные пути
    for path in /root/.local/bin/claude /usr/local/bin/claude /home/dsbot/.local/bin/claude; do
        if [ -x "$path" ]; then
            CLAUDE_BIN="$path"
            break
        fi
    done
fi

START_MS=$(date +%s%N)

# Отправляем минимальный запрос
STDERR_FILE=$(mktemp)
RESULT=$(echo "Reply with just OK" | timeout 30 "$CLAUDE_BIN" -p - --output-format text --no-session-persistence 2>"$STDERR_FILE" || true)
EXIT_CODE=$?

END_MS=$(date +%s%N)
ELAPSED_MS=$(( (END_MS - START_MS) / 1000000 ))

STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null || true)
rm -f "$STDERR_FILE"

# Анализируем результат
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ $EXIT_CODE -ne 0 ]; then
    echo "$TIMESTAMP ERROR exit=$EXIT_CODE elapsed=${ELAPSED_MS}ms" >> "$LOGFILE"
    logger -t "$LOG_TAG" "ERROR: exit=$EXIT_CODE elapsed=${ELAPSED_MS}ms"

    if echo "$STDERR_CONTENT" | grep -qiE "rate.limit|quota|too.many|429|throttl"; then
        send_alert "Rate limited! exit=$EXIT_CODE (${ELAPSED_MS}ms)"
    else
        send_alert "CLI error exit=$EXIT_CODE (${ELAPSED_MS}ms)"
    fi
elif echo "$STDERR_CONTENT" | grep -qiE "rate.limit|quota|too.many|429|throttl"; then
    echo "$TIMESTAMP RATE_LIMITED elapsed=${ELAPSED_MS}ms" >> "$LOGFILE"
    logger -t "$LOG_TAG" "RATE_LIMITED elapsed=${ELAPSED_MS}ms"
    send_alert "Rate limited (stderr) (${ELAPSED_MS}ms)"
else
    echo "$TIMESTAMP OK elapsed=${ELAPSED_MS}ms" >> "$LOGFILE"
    # Логируем OK только каждый 12-й раз (раз в час при */5)
    COUNTER_FILE="/tmp/dsbot-limits-counter"
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    COUNTER=$((COUNTER + 1))
    echo "$COUNTER" > "$COUNTER_FILE"
    if [ $((COUNTER % 12)) -eq 0 ]; then
        logger -t "$LOG_TAG" "OK elapsed=${ELAPSED_MS}ms (check #$COUNTER)"
    fi
fi
