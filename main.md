# DSBot — main.md

## О проекте
Telegram-бот (@ds_brain_bot) на базе официального Claude Telegram Plugin. Использует Claude Code + подписку (без API-расходов). Полный доступ к Second Brain, MCP серверам, коду.

## Job Story (JTBD)
КОГДА я в дороге / не за компом
-> я хочу отправить сообщение в Telegram
-> ЧТОБЫ получить всю мощь Claude Code (файлы, код, CRM, анализ) без ограничений API

## Текущий статус
Фаза: **Полноценный второй мозг + безопасность + мониторинг производства**
Дата обновления: 2026-03-23

### Что работает
- Бот @ds_brain_bot — Opus 4.6, 1M ctx, Max подписка
- **3-tier безопасность:** CLAUDE.md — авто/анонс/подтверждение для деструктивных операций
- **Планировщик:** tasks.md (51 задача), backlog, memories, context.md
- **Брифинги:** cron 07:00/12:00/21:00 + Вс 20:00 — включая production summary
- **Битрикс-дайджест:** в утреннем брифинге — новые сделки, двигавшиеся, зависшие, won/lost
- **Проактивные алерты:** cron каждые 4ч — P1 + стухшие сделки + делегированные + дедлайны <=2д
- **Win/loss analysis:** в weekly брифинге — won/lost за неделю + pipeline velocity + bottleneck
- **Андон:** winch-bot 19:00+21:00 — алерт при KPI >200% или <30%
- **Трекинг молчунов:** winch-bot — кто не отчитался (сверка с employees.json)
- **Аудит-лог:** все bash-команды на VPS → `/var/log/dsbot-bash-audit.log`
- **Bitrix24 MCP:** собран на VPS, webhook в .env (не в коде)
- **Контракты PDF:** `scripts/contract/generator.py`
- **ReportsAnalyze:** production brief в утреннем/недельном брифинге
- **Google Calendar:** `scripts/calendar_utils.py` (токен нужно обновить)
- **TTS:** `scripts/tts.py` (нужен API key)
- **Фото/голосовые/video notes:** форк плагина + bot.catch()
- **Watchdog с backoff:** не рестартит чаще 5 мин
- **Git safety net:** auto-commit перед sync (защита от потери данных)
- **Чтение переписок Telegram:** `scripts/read_chat.py` — Telethon userbot, скачивание фото + Vision-анализ чеков. Запуск: `docker exec winch-bot python3 scripts/read_chat.py <target> [--days N] [--limit N] [--search "text"]`

### Что требует действий от Данияра
- **Google Calendar:** токен истёк — повторить OAuth через brain-bot `/google_auth`
- **ElevenLabs TTS:** купить Starter ($5/мес), добавить ELEVENLABS_API_KEY в .env

### Что не задеплоено (код готов)
- **Bitrix Comment Tracker Bot** — 6 модулей в `scripts/comment_tracker/`. Мониторит комментарии в сделках/задачах, шлёт в TG группу, эскалация 1.5ч/3ч/6ч. Код прошёл review (3 reviewer + tech lead), 6 рисков mitigated. **Нужно от Данияра:** создать бота @BotFather + группу "Битрикс: Вопросы" + скинуть токен и chat_id → деплой на VPS.
  - Дизайн: `docs/plans/2026-03-23-bitrix-comment-tracker-design.md`
  - Cron: `*/5` poll + `*/30 9-17 Mon-Fri` escalate

### Следующие шаги
1. **ДЕПЛОЙ Comment Tracker** — после создания бота и группы Данияром
2. **ДЕПЛОЙ SalesBot stats** — `send_briefing.py` обновлён, нужен push + restart
3. Эскалация-пинг — делегированная задача [d] без обновления >3д → пинг исполнителю
4. Персональные weekly для Оксаны (производственный блок)
5. Constraint report — ТОП-3 узких места производства за неделю
6. WinchERP weekly-отчёт активности (erp_audit_log)

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
                        + CLAUDE.md (3-tier security)
                        + MCP Bitrix24
                        + Second Brain (файлы)
                        + Production monitoring (docker exec winch-bot)
```

**Стек:** Claude Code CLI, Official Telegram Plugin (Bun + MCP), Bitrix24 MCP

## Ключевые файлы
| Файл | Что там |
|------|---------|
| `CLAUDE.md` | Инструкции + 3-tier security (красная зона) |
| `.mcp.json` | MCP серверы (Bitrix24). В .gitignore |
| `.claude/channels/telegram/.env` | Токен бота. В .gitignore |
| `scripts/send_briefing.py` | Брифинги + production summary |
| `scripts/proactive_alerts.py` | P1 + делегированные + стухшие сделки + дедлайны |
| `scripts/planner_utils.py` | Парсер tasks.md + Bitrix API (1 запрос) + chunked Telegram |
| `plugin-fork/server.ts` | Форк плагина (deduplicated downloadTgFile) |
| `scripts/read_chat.py` | Чтение истории Telegram-чатов (Telethon userbot) |
| `scripts/comment_tracker/` | Bitrix Comment Tracker Bot (6 модулей, НЕ задеплоен) |
| `docs/plans/2026-03-23-bitrix-comment-tracker-design.md` | Дизайн Comment Tracker (deep-think 6 экспертов) |
| `docs/plans/2026-03-22-security-and-operations-design.md` | Дизайн-документ безопасности + операционки |

## Ключевые решения
- **Доступ только Данияру** — никому из команды доступ к DSBot не давать
- **3-tier security** — деструктивные операции требуют подтверждения
- **Гибрид для производства** — winch-bot (push-алерты) + DSBot (pull-запросы)
- **Standalone скрипты** — брифинги и алерты не зависят от Claude
- **Git safety net** — auto-commit перед sync, защита от потери данных
