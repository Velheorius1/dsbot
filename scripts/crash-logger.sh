#!/usr/bin/env bash
set -euo pipefail

# crash-logger.sh — Структурированное логирование падений DSBot
# Вызывается из healthcheck ПЕРЕД рестартом
# Собирает полный контекст: процессы, память, логи, tmux buffer
#
# Лог: /var/log/dsbot-crashes.jsonl (одна JSON-строка на инцидент)
# Саммари: /opt/second-brain/Projects/dsbot/data/crash-summary.md (для Claude/Данияра)

LOG_TAG="dsbot-crash"
CRASH_LOG="/var/log/dsbot-crashes.jsonl"
SUMMARY_FILE="/opt/second-brain/Projects/dsbot/data/crash-summary.md"
DSBOT_TMUX_SOCK="/tmp/tmux-$(id -u dsbot 2>/dev/null || echo 1000)/default"

# Аргумент: причина из healthcheck
REASON="${1:-unknown}"

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TIMESTAMP_LOCAL=$(TZ=Asia/Tashkent date '+%Y-%m-%d %H:%M:%S')
UPTIME_SECS=""

# Собираем контекст
collect_context() {
    # 1. Uptime сервиса (сколько проработал до падения)
    local start_ts
    start_ts=$(systemctl show dsbot.service --property=ActiveEnterTimestamp --value 2>/dev/null || echo "")
    if [ -n "$start_ts" ] && [ "$start_ts" != "" ]; then
        local start_epoch
        start_epoch=$(date -d "$start_ts" +%s 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        UPTIME_SECS=$((now_epoch - start_epoch))
    fi

    # 2. Последние строки journalctl
    JOURNAL_TAIL=$(journalctl -u dsbot.service --since '5 min ago' --no-pager 2>/dev/null | tail -15 | sed 's/"/\\"/g' | tr '\n' '|' || echo "no journal")

    # 3. Последние строки stderr
    STDERR_TAIL=$(tail -10 /var/log/dsbot-stderr.log 2>/dev/null | sed 's/"/\\"/g' | tr '\n' '|' || echo "no stderr")

    # 4. Процессы claude/bun
    CLAUDE_PROCS=$(pgrep -af "claude" 2>/dev/null | head -5 | sed 's/"/\\"/g' | tr '\n' '|' || echo "none")
    BUN_PROCS=$(pgrep -af "bun.*server" 2>/dev/null | head -3 | sed 's/"/\\"/g' | tr '\n' '|' || echo "none")

    # 5. Память и CPU
    MEM_FREE=$(free -m | awk '/Mem:/{printf "%d/%dMB (%.0f%%)", $3, $2, $3/$2*100}')
    LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    DISK=$(df / --output=pcent | tail -1 | tr -d ' ')

    # 6. tmux buffer (последний вывод Claude, если доступен)
    TMUX_BUFFER=""
    if [ -S "$DSBOT_TMUX_SOCK" ]; then
        TMUX_BUFFER=$(tmux -S "$DSBOT_TMUX_SOCK" capture-pane -t dsbot -p 2>/dev/null | tail -20 | sed 's/"/\\"/g' | tr '\n' '|' || echo "no buffer")
    fi

    # 7. Количество рестартов за последний час
    RESTARTS_1H=$(journalctl -u dsbot.service --since '1 hour ago' --no-pager 2>/dev/null | grep -c "Starting dsbot.service" || echo 0)

    # 8. Количество рестартов за последние 24ч
    RESTARTS_24H=$(journalctl -u dsbot.service --since '24 hours ago' --no-pager 2>/dev/null | grep -c "Starting dsbot.service" || echo 0)

    # 9. OOM killer?
    OOM=$(dmesg -T 2>/dev/null | grep -i "oom.*kill" | tail -3 | sed 's/"/\\"/g' | tr '\n' '|' || echo "none")
}

# Пишем JSONL (одна строка = один инцидент)
write_jsonl() {
    cat >> "$CRASH_LOG" <<JSONL
{"ts":"$TIMESTAMP","ts_local":"$TIMESTAMP_LOCAL","reason":"$REASON","uptime_secs":"${UPTIME_SECS:-0}","restarts_1h":$RESTARTS_1H,"restarts_24h":$RESTARTS_24H,"mem":"$MEM_FREE","load":"$LOAD","disk":"$DISK","journal":"$JOURNAL_TAIL","stderr":"$STDERR_TAIL","tmux_buffer":"$TMUX_BUFFER","claude_procs":"$CLAUDE_PROCS","bun_procs":"$BUN_PROCS","oom":"$OOM"}
JSONL
    logger -t "$LOG_TAG" "Crash logged: reason=$REASON uptime=${UPTIME_SECS:-0}s restarts_1h=$RESTARTS_1H"
}

# Обновляем саммари (markdown для Claude/Данияра)
update_summary() {
    # Создаём директорию если нет
    mkdir -p "$(dirname "$SUMMARY_FILE")"

    # Считаем статистику
    local total_crashes
    total_crashes=$(wc -l < "$CRASH_LOG" 2>/dev/null || echo 0)

    local today_crashes
    today_crashes=$(grep -c "$(date -u '+%Y-%m-%d')" "$CRASH_LOG" 2>/dev/null || echo 0)

    # Топ причин за всё время
    local top_reasons
    top_reasons=$(grep -oP '"reason":"[^"]*"' "$CRASH_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 || echo "  нет данных")

    # Среднее uptime до падения
    local avg_uptime
    avg_uptime=$(grep -oP '"uptime_secs":"[0-9]+"' "$CRASH_LOG" 2>/dev/null | grep -oP '[0-9]+' | awk '{s+=$1; n++} END {if(n>0) printf "%.0f", s/n; else print "0"}' || echo "0")

    # Последние 10 инцидентов
    local recent
    recent=$(tail -10 "$CRASH_LOG" 2>/dev/null | while IFS= read -r line; do
        local ts reason uptime
        ts=$(echo "$line" | grep -oP '"ts_local":"[^"]*"' | cut -d'"' -f4)
        reason=$(echo "$line" | grep -oP '"reason":"[^"]*"' | cut -d'"' -f4)
        uptime=$(echo "$line" | grep -oP '"uptime_secs":"[0-9]+"' | grep -oP '[0-9]+')
        echo "| $ts | $reason | ${uptime}s |"
    done || echo "| нет данных | | |")

    cat > "$SUMMARY_FILE" <<MD
# DSBot Crash Summary

Автоматически обновляется при каждом падении.
Последнее обновление: $TIMESTAMP_LOCAL

## Статистика

| Метрика | Значение |
|---------|----------|
| Всего падений | $total_crashes |
| Сегодня | $today_crashes |
| Среднее uptime до падения | ${avg_uptime}s |
| Рестартов за последний час | $RESTARTS_1H |
| Рестартов за 24ч | $RESTARTS_24H |

## Топ причин

\`\`\`
$top_reasons
\`\`\`

## Последние инциденты

| Время | Причина | Uptime до падения |
|-------|---------|-------------------|
$recent

## Паттерны для анализа

Если видишь повторяющийся паттерн — проверь:
- **tmux session missing** → Claude CLI крашится или OOM killer
- **claude process zombie** → Зависание на API-запросе, нужен таймаут
- **bun not polling** → Telegram plugin потерял connection, нужен reconnect
- **no pane PID** → tmux сессия есть но пустая (краш при старте)
- **OOM** → Нужно увеличить RAM или ограничить Claude CLI

## Raw log

Полный лог: \`/var/log/dsbot-crashes.jsonl\`
Команда для анализа:
\`\`\`bash
# Последние 5 падений с деталями
tail -5 /var/log/dsbot-crashes.jsonl | python3 -m json.tool

# Паттерн по времени (почасовая гистограмма)
grep -oP '"ts_local":"\K[0-9-]+ [0-9]{2}' /var/log/dsbot-crashes.jsonl | sort | uniq -c | sort -rn
\`\`\`
MD
}

# Ротация JSONL (макс 1000 строк ≈ 3 мес при 10 crashes/day)
rotate_log() {
    if [ -f "$CRASH_LOG" ]; then
        local lines
        lines=$(wc -l < "$CRASH_LOG")
        if [ "$lines" -gt 1000 ]; then
            tail -500 "$CRASH_LOG" > "${CRASH_LOG}.tmp"
            mv "${CRASH_LOG}.tmp" "$CRASH_LOG"
            logger -t "$LOG_TAG" "Log rotated: $lines -> 500 lines"
        fi
    fi
}

# Main
collect_context
write_jsonl
update_summary
rotate_log
