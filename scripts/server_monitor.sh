#!/usr/bin/env bash
set -euo pipefail

# server_monitor.sh — мониторинг VPS
# Cron: */15 * * * *
# Метрики: disk, RAM, CPU load, Docker
# Алерт в Telegram при критических порогах

LOG_TAG="dsbot-monitor"
LOGFILE="/var/log/dsbot-server.csv"
ALERT_LOCK="/tmp/dsbot-monitor-alert.lock"
ALERT_INTERVAL=1800  # не чаще 1 алерта в 30 мин

# Пороги
DISK_THRESHOLD=90
MEM_THRESHOLD=90

# Telegram credentials
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
        return
    fi

    if [ -f "$ALERT_LOCK" ]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$ALERT_LOCK" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -lt "$ALERT_INTERVAL" ]; then
            return
        fi
    fi

    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$ADMIN_ID" \
        -d text="🖥 VPS Alert: ${msg}" \
        -d parse_mode="HTML" > /dev/null 2>&1 || true

    touch "$ALERT_LOCK"
    logger -t "$LOG_TAG" "Alert: $msg"
}

# Собираем метрики
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DISK_USED=$(df / --output=pcent | tail -1 | tr -d ' %')
MEM_TOTAL=$(free -m | awk '/Mem:/{print $2}')
MEM_USED=$(free -m | awk '/Mem:/{print $3}')
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_5=$(awk '{print $2}' /proc/loadavg)

# Docker контейнеры
DOCKER_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l || echo 0)
DOCKER_TOTAL=$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l || echo 0)
DOCKER_DOWN=$((DOCKER_TOTAL - DOCKER_RUNNING))

# Имена упавших контейнеров
DOCKER_DOWN_NAMES=""
if [ "$DOCKER_DOWN" -gt 0 ]; then
    DOCKER_DOWN_NAMES=$(comm -23 \
        <(docker ps -a --format '{{.Names}}' 2>/dev/null | sort) \
        <(docker ps --format '{{.Names}}' 2>/dev/null | sort) \
        | tr '\n' ',' | sed 's/,$//')
fi

# CSV header (если файл не существует)
if [ ! -f "$LOGFILE" ]; then
    echo "timestamp,disk_pct,mem_pct,mem_used_mb,mem_total_mb,load_1,load_5,docker_running,docker_down,down_names" > "$LOGFILE"
fi

# Записываем
echo "$TIMESTAMP,$DISK_USED,$MEM_PCT,$MEM_USED,$MEM_TOTAL,$LOAD_1,$LOAD_5,$DOCKER_RUNNING,$DOCKER_DOWN,$DOCKER_DOWN_NAMES" >> "$LOGFILE"

# Ротация лога (макс 10000 строк ≈ ~100 дней при */15)
LINE_COUNT=$(wc -l < "$LOGFILE")
if [ "$LINE_COUNT" -gt 10000 ]; then
    tail -5000 "$LOGFILE" > "${LOGFILE}.tmp"
    mv "${LOGFILE}.tmp" "$LOGFILE"
fi

# Алерты
ALERTS=""

if [ "$DISK_USED" -gt "$DISK_THRESHOLD" ]; then
    ALERTS="${ALERTS}Disk: ${DISK_USED}%\n"
fi

if [ "$MEM_PCT" -gt "$MEM_THRESHOLD" ]; then
    ALERTS="${ALERTS}RAM: ${MEM_PCT}% (${MEM_USED}/${MEM_TOTAL}MB)\n"
fi

if [ "$DOCKER_DOWN" -gt 0 ]; then
    ALERTS="${ALERTS}Docker down: ${DOCKER_DOWN_NAMES}\n"
fi

if [ -n "$ALERTS" ]; then
    send_alert "$(echo -e "$ALERTS" | head -c 500)"
    logger -t "$LOG_TAG" "WARN: disk=${DISK_USED}% mem=${MEM_PCT}% docker_down=${DOCKER_DOWN}"
else
    # OK лог каждые 4 часа (каждый 16-й check при */15)
    COUNTER_FILE="/tmp/dsbot-monitor-counter"
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    COUNTER=$((COUNTER + 1))
    echo "$COUNTER" > "$COUNTER_FILE"
    if [ $((COUNTER % 16)) -eq 0 ]; then
        logger -t "$LOG_TAG" "OK disk=${DISK_USED}% mem=${MEM_PCT}% load=${LOAD_1} docker=${DOCKER_RUNNING}/${DOCKER_TOTAL}"
    fi
fi
