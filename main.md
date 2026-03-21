# DSBot — main.md

## О проекте
Telegram-бот (@ds_brain_bot) на базе официального Claude Telegram Plugin. Использует Claude Code + подписку (без API-расходов). Полный доступ к Second Brain, MCP серверам, коду.

## Job Story (JTBD)
КОГДА я в дороге / не за компом
-> я хочу отправить сообщение в Telegram
-> ЧТОБЫ получить всю мощь Claude Code (файлы, код, CRM, анализ) без ограничений API

## Текущий статус
Фаза: **Полноценный второй мозг**
Дата обновления: 2026-03-21

### Что работает
- Бот @ds_brain_bot — Opus 4.6, 1M ctx, Max подписка
- **Планировщик:** tasks.md (51 задача), backlog, memories, context.md (сохранение контекста)
- **Брифинги:** cron 07:00/12:00/21:00 + Вс 20:00, standalone
- **Проактивные алерты:** cron каждые 4ч — P1 + Bitrix стухшие сделки
- **Bitrix24 MCP:** собран на VPS, работает
- **Контракты PDF:** `scripts/contract/generator.py` — генерация договоров Winch/Салахутдинов
- **ReportsAnalyze:** CLAUDE.md инструкции для `docker exec winch-bot`
- **Google Calendar:** `scripts/calendar_utils.py` — события, создание встреч (токен нужно обновить)
- **TTS:** `scripts/tts.py` — ElevenLabs голосовые ответы (нужен API key)
- **Фото/голосовые/video notes:** форк плагина + bot.catch()
- **Watchdog + логи:** watchdog.log, stderr.log, briefing.log

### Что требует действий от Данияра
- **Google Calendar:** токен истёк — повторить OAuth через brain-bot `/google_auth`
- **ElevenLabs TTS:** купить Starter ($5/мес), добавить ELEVENLABS_API_KEY в .env

### Следующие шаги
1. Обновить Google Calendar токен
2. Купить ElevenLabs Starter, добавить API key
3. Мониторить логи первые дни (watchdog, briefing, stderr)
4. Архитектурная визуализация: `Projects/dsbot/architecture.html`

### Управление на VPS
```bash
# Проверить статус
ssh root@46.62.155.190 "tmux capture-pane -t dsbot -p | strings | tail -10"
# Перезапустить (применяет форк автоматически)
ssh root@46.62.155.190 "tmux kill-session -t dsbot; sleep 1; /root/start-dsbot.sh"
# Watchdog лог
ssh root@46.62.155.190 "tail -20 /var/log/dsbot-watchdog.log"
```

## Архитектура
```
iPhone/Mac -> Telegram -> @ds_brain_bot
                               |
                     Claude Code (подписка)
                        + CLAUDE.md (инструкции)
                        + MCP Bitrix24
                        + Second Brain (файлы)
                        + Все инструменты Claude Code
```

**Стек:** Claude Code CLI, Official Telegram Plugin (Bun + MCP), Bitrix24 MCP

## Ключевые файлы
| Файл | Что там |
|------|---------|
| `CLAUDE.md` | Инструкции для бота (личность, стиль, задачи) |
| `.mcp.json` | MCP серверы (Bitrix24) |
| `.claude/channels/telegram/.env` | Токен бота |
| `.claude/channels/telegram/access.json` | Политика доступа |
| `scripts/transcribe.py` | Транскрипция аудио через Gemini Flash |
| `scripts/send_briefing.py` | Standalone брифинги (morning/midday/evening/weekly) |
| `scripts/proactive_alerts.py` | P1 задачи + Bitrix стухшие сделки |
| `scripts/planner_utils.py` | Парсер tasks.md + Bitrix API + Telegram sender |
| `planner/tasks.md` | Активные задачи (P1/P2/P3) |
| `planner/memories.md` | Персистентная память |
| `planner/context.md` | Контекст последнего разговора (сохранение между сессиями) |
| `scripts/calendar_utils.py` | Google Calendar CLI (today/tomorrow/week/create) |
| `scripts/contract/generator.py` | PDF контракты Winch/Салахутдинов |
| `scripts/tts.py` | ElevenLabs TTS (текст → .ogg) |
| `plugin-fork/server.ts` | Форк Telegram плагина (voice/audio/video_note + bot.catch) |
| `architecture.html` | Визуализация архитектуры DSBot |

## Ключевые решения
- **Официальный плагин > кастомный бот** — без API-расходов, без риска бана, полная мощь Claude Code
- **Bitrix24 = первая интеграция** — уже есть MCP сервер, сразу работает
- **DSBot = основной "второй мозг"** — Brain Bot остаётся как бэкап
- **Standalone скрипты** — брифинги и алерты не зависят от Claude (работают даже если сессия мертва)
- **Файлы > SQLite** — Claude нативно читает/пишет markdown, git = версионность
