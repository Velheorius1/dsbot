#!/usr/bin/env bash
set -euo pipefail

# stability-report.sh — Еженедельный отчёт стабильности DSBot
# Cron: 0 14 * * 1 (каждый понедельник 19:00 Tashkent)
# Отправляет отчёт Данияру в Telegram + обновляет data/stability-history.md

LOG_TAG="dsbot-stability"
CRASH_LOG="/var/log/dsbot-crashes.jsonl"
SUMMARY_FILE="/opt/second-brain/Projects/dsbot/data/crash-summary.md"
HISTORY_FILE="/opt/second-brain/Projects/dsbot/data/stability-history.md"

# Telegram
ENV_FILE="/opt/second-brain/Projects/dsbot/fallback-bot/.env"
if [ -f "$ENV_FILE" ]; then
    BOT_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    ADMIN_ID=$(grep -E '^ADMIN_ID=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
fi

BOT_TOKEN="${BOT_TOKEN:-}"
ADMIN_ID="${ADMIN_ID:-}"

WEEK_START=$(date -d "7 days ago" '+%Y-%m-%d')
WEEK_END=$(date '+%Y-%m-%d')
WEEK_LABEL="$WEEK_START — $WEEK_END"

# Считаем метрики за неделю
CRASHES_WEEK=0
if [ -f "$CRASH_LOG" ]; then
    CRASHES_WEEK=$(awk -v start="$WEEK_START" '$0 ~ start || $0 > start' "$CRASH_LOG" 2>/dev/null | wc -l || echo 0)
fi

# Uptime: считаем из journalctl
TOTAL_STARTS=$(journalctl -u dsbot.service --since "$WEEK_START" --no-pager 2>/dev/null | grep -c "Started dsbot.service" || echo 0)
TOTAL_STOPS=$(journalctl -u dsbot.service --since "$WEEK_START" --no-pager 2>/dev/null | grep -c "Stopped dsbot.service" || echo 0)

# Среднее uptime до падения (за неделю)
AVG_UPTIME="n/a"
if [ -f "$CRASH_LOG" ] && [ "$CRASHES_WEEK" -gt 0 ]; then
    AVG_UPTIME=$(awk -v start="$WEEK_START" '$0 ~ start || $0 > start' "$CRASH_LOG" 2>/dev/null | \
        grep -oP '"uptime_secs":"[0-9]+"' | grep -oP '[0-9]+' | \
        awk '{s+=$1; n++} END {if(n>0) {h=int(s/n/3600); m=int((s/n%3600)/60); printf "%dh%dm", h, m} else print "n/a"}')
fi

# Топ причин за неделю
TOP_REASONS=""
if [ -f "$CRASH_LOG" ] && [ "$CRASHES_WEEK" -gt 0 ]; then
    TOP_REASONS=$(awk -v start="$WEEK_START" '$0 ~ start || $0 > start' "$CRASH_LOG" 2>/dev/null | \
        grep -oP '"reason":"[^"]*"' | sed 's/"reason":"//;s/"//' | \
        sort | uniq -c | sort -rn | head -3 | \
        awk '{printf "  %d× %s\n", $1, substr($0, index($0,$2))}')
fi

# Стабильность (%)
# 7 дней = 604800 сек, uptime = 604800 - (crashes * avg_restart_time ~60s)
STABILITY_PCT="100"
if [ "$CRASHES_WEEK" -gt 0 ]; then
    DOWNTIME_EST=$((CRASHES_WEEK * 60))
    STABILITY_PCT=$(awk "BEGIN {printf \"%.1f\", (604800 - $DOWNTIME_EST) / 604800 * 100}")
fi

# Формируем отчёт
REPORT="📊 DSBot Stability Report
$WEEK_LABEL

🟢 Стабильность: ${STABILITY_PCT}%
💥 Падений: $CRASHES_WEEK
🔄 Рестартов: $TOTAL_STARTS
⏱ Среднее uptime: $AVG_UPTIME"

if [ -n "$TOP_REASONS" ]; then
    REPORT="$REPORT

📋 Топ причин:
$TOP_REASONS"
fi

if [ "$CRASHES_WEEK" -eq 0 ]; then
    REPORT="$REPORT

✅ Без единого падения!"
elif [ "$CRASHES_WEEK" -le 3 ]; then
    REPORT="$REPORT

👍 Приемлемая стабильность"
else
    REPORT="$REPORT

⚠️ Требует внимания — проверь /var/log/dsbot-crashes.jsonl"
fi

# Отправляем в Telegram
if [ -n "$BOT_TOKEN" ] && [ -n "$ADMIN_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$ADMIN_ID" \
        -d text="$REPORT" \
        -d parse_mode="" > /dev/null 2>&1 || true
    logger -t "$LOG_TAG" "Weekly report sent: crashes=$CRASHES_WEEK stability=${STABILITY_PCT}%"
fi

# Сохраняем в history
mkdir -p "$(dirname "$HISTORY_FILE")"
cat >> "$HISTORY_FILE" <<HIST

## $WEEK_LABEL
- Стабильность: ${STABILITY_PCT}%
- Падений: $CRASHES_WEEK
- Рестартов: $TOTAL_STARTS
- Среднее uptime: $AVG_UPTIME
- Топ причин: $(echo "$TOP_REASONS" | tr '\n' '; ' || echo "нет")
HIST

logger -t "$LOG_TAG" "Weekly report saved: crashes=$CRASHES_WEEK"
