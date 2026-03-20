# DSBot — main.md

## О проекте
Telegram-бот (@ds_brain_bot) на базе официального Claude Telegram Plugin. Использует Claude Code + подписку (без API-расходов). Полный доступ к Second Brain, MCP серверам, коду.

## Job Story (JTBD)
КОГДА я в дороге / не за компом
-> я хочу отправить сообщение в Telegram
-> ЧТОБЫ получить всю мощь Claude Code (файлы, код, CRM, анализ) без ограничений API

## Текущий статус
Фаза: **MVP** — настройка и первый запуск
Дата обновления: 2026-03-20

### Что работает
- Бот @ds_aibrain_bot — отвечает через Claude Code (Opus 4.6, подписка)
- Pairing + allowlist (user ID: 221998785)
- ackReaction 👀 на входящие
- CLAUDE.md инструкции — личность, стиль, задачи
- Bitrix24 MCP подключён
- Bun v1.3.11, плагин telegram@claude-plugins-official

### Что в процессе
- Тестирование Bitrix24 через Telegram
- Тестирование файлов Second Brain

### Следующие шаги
1. Протестировать Bitrix24 запросы через бота
2. Протестировать отправку файлов
3. Деплой на VPS для 24/7

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

## Ключевые решения
- **Официальный плагин > кастомный бот** — без API-расходов, без риска бана, полная мощь Claude Code
- **Bitrix24 = первая интеграция** — уже есть MCP сервер, сразу работает
- **Brain-bot остаётся** — dsbot не заменяет, а дополняет (разные модели, разные возможности)
