# DSBot — main.md

## О проекте
Telegram-бот (@ds_brain_bot) на базе официального Claude Telegram Plugin. Использует Claude Code + подписку (без API-расходов). Полный доступ к Second Brain, MCP серверам, коду.

## Job Story (JTBD)
КОГДА я в дороге / не за компом
-> я хочу отправить сообщение в Telegram
-> ЧТОБЫ получить всю мощь Claude Code (файлы, код, CRM, анализ) без ограничений API

## Текущий статус
Фаза: **Полноценный второй мозг + Comment Tracker + IM-мониторинг**
Дата обновления: 2026-03-24

### Что работает
- Бот @ds_brain_bot — Opus 4.6, 1M ctx, Max подписка, native installer
- **Watchdog v2:** killall bun/claude перед рестартом (фикс zombie→409)
- **Comment Tracker @bitrix_winch_bot** — задеплоен в группу Winch_Планирование
  - Мониторит комментарии в сделках (crm.timeline.comment) + задачах (task.commentitem)
  - **IM-чаты** (im.recent.list + im.dialog.messages.get) через OAuth с auto-refresh
  - Эскалация: L1 (1.5ч) → L2 (3ч) → L3 (6ч без ответа)
  - Per-chat cursors в SQLite, BB-code stripping
  - Cron: `*/5` poll + `*/30 9-17 Mon-Fri` escalate
- **OAuth приложение Bitrix24:** client_id `local.69c24d72956405.18117904`, scope: crm,im,tasks
  - Auto-refresh токенов в `/opt/second-brain/data/bitrix_oauth.json`
- **Брифинги:** cron 07:00/12:00/21:00 + Вс 20:00
- **Проактивные алерты:** cron каждые 4ч
- **Планировщик, Bitrix MCP, контракты PDF, read_chat, аудит-лог** — всё работает

### Что требует действий от Данияра
- **Google Calendar:** токен истёк — повторить OAuth через brain-bot `/google_auth`
- **ElevenLabs TTS:** купить Starter ($5/мес)

### Следующие шаги
1. Эскалация-пинг — делегированная задача [d] без обновления >3д → пинг исполнителю
2. Персональные weekly для Оксаны (производственный блок)
3. Constraint report — ТОП-3 узких места производства за неделю
4. WinchERP weekly-отчёт активности (erp_audit_log)

### Управление на VPS (systemd)
```bash
# Статус
ssh root@46.62.155.190 "systemctl status dsbot"
# Перезапуск
ssh root@46.62.155.190 "systemctl restart dsbot"
# Логи (live)
ssh root@46.62.155.190 "journalctl -u dsbot -n 30"
# Health check
ssh root@46.62.155.190 "cat /tmp/dsbot-health-status"
# Интерактивный доступ к tmux
ssh root@46.62.155.190 "tmux capture-pane -t dsbot -p | strings | tail -10"
# Comment Tracker лог
ssh root@46.62.155.190 "tail -20 /var/log/comment-tracker.log"
```

## Архитектура
```
iPhone/Mac -> Telegram -> @ds_brain_bot (Claude Code подписка)
                               + CLAUDE.md (3-tier security)
                               + MCP Bitrix24
                               + Second Brain + Production monitoring

Cron scripts:
  send_briefing.py → Telegram (07/12/21 + weekly)
  proactive_alerts.py → Telegram (каждые 4ч)
  comment_tracker/poll_comments.py → @bitrix_winch_bot в Winch_Планирование (*/5)
  comment_tracker/escalate.py → эскалация (*/30 рабочие часы)
```

## Ключевые файлы
| Файл | Что там |
|------|---------|
| `scripts/comment_tracker/` | 8 модулей: config, oauth, bitrix_api, poll_comments, escalate, db, telegram_notify, __init__ |
| `scripts/comment_tracker/oauth.py` | OAuth auto-refresh, token storage в JSON |
| `scripts/send_briefing.py` | Брифинги + production summary |
| `scripts/proactive_alerts.py` | P1 + делегированные + стухшие сделки |
| `docs/plans/2026-03-24-dsbot-salesbot-merge-analysis.md` | Решение: НЕ объединять DSBot+SalesBot |

## Ключевые решения
- **Доступ только Данияру** — никому из команды доступ к DSBot не давать
- **3-tier security** — деструктивные операции требуют подтверждения
- **OAuth для IM, webhook для CRM/tasks** — разные auth, общий rate limit (Semaphore(2))
- **Native Claude installer** — не npm (убирает блокирующее уведомление)
- **Plugin fork отключён** — upstream включил все фиксы
