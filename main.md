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
- Структура проекта создана
- CLAUDE.md с инструкциями
- Bitrix24 MCP подключён

### Что в процессе
- Создание бота в BotFather
- Установка плагина
- Первый запуск и тест

### Следующие шаги
1. Создать бота @ds_brain_bot в BotFather
2. Установить плагин: `/plugin install telegram@claude-plugins-official`
3. Настроить токен и access control
4. Тест на маке
5. Деплой на VPS (фаза 2)

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
