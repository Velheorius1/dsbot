# DSBot — main.md

## О проекте
Telegram-бот (@ds_brain_bot) на базе официального Claude Telegram Plugin. Использует Claude Code + подписку (без API-расходов). Полный доступ к Second Brain, MCP серверам, коду.

## Job Story (JTBD)
КОГДА я в дороге / не за компом
-> я хочу отправить сообщение в Telegram
-> ЧТОБЫ получить всю мощь Claude Code (файлы, код, CRM, анализ) без ограничений API

## Текущий статус
Фаза: **MVP работает, стабилизация**
Дата обновления: 2026-03-20

### Что работает
- Бот @ds_brain_bot отвечает в Telegram (Opus 4.6, 1M ctx, Max подписка)
- Работает из `/opt/second-brain/` — видит все проекты (sync через GitHub каждые 5 мин)
- Permissions предодобрены в `.claude/settings.json` — не блокируется на промптах
- Bitrix24 MCP подключён, Knowledge/ доступен
- Автозапуск при reboot: `@reboot /root/start-dsbot.sh`
- **Фото:** плагин скачивает в inbox/, передаёт `image_path` → Claude читает через Read
- **Голосовые/аудио:** плагин скачивает .ogg/.mp3, передаёт `audio_path` → Claude транскрибирует через `scripts/transcribe.py` (Gemini Flash)
- **Video notes:** тоже скачиваются и передаются

### Что в процессе
- Долгие задачи (дизайн, анализ URL) занимают 1-3 мин — нормально для Opus
- Плагин пропатчен (voice/audio/video_note handlers) — при обновлении плагина патч слетит

### Следующие шаги
1. Ревью кода проекта
2. Интеграция с ReportsAnalyze как движок анализа

### Управление на VPS
```bash
# Проверить статус
ssh root@46.62.155.190 "tmux capture-pane -t dsbot -p | strings | tail -10"
# Перезапустить
ssh root@46.62.155.190 "tmux kill-server; tmux new-session -d -s dsbot 'cd /opt/second-brain && export PATH=/root/.bun/bin:\$PATH && claude --channels plugin:telegram@claude-plugins-official'"
# Проверить permission промпт
ssh root@46.62.155.190 "tmux capture-pane -t dsbot -p | strings | grep 'Do you want'"
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

## Ключевые решения
- **Официальный плагин > кастомный бот** — без API-расходов, без риска бана, полная мощь Claude Code
- **Bitrix24 = первая интеграция** — уже есть MCP сервер, сразу работает
- **Brain-bot остаётся** — dsbot не заменяет, а дополняет (разные модели, разные возможности)
