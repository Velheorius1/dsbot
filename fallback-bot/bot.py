"""DSBot Fallback — lightweight Telegram bot wrapping claude -p CLI."""

import asyncio
import logging
import os
import tempfile

from dotenv import load_dotenv
load_dotenv()

from aiogram import Bot, Dispatcher, Router, F
from aiogram.types import Message, ReactionTypeEmoji

from config import BOT_TOKEN, ADMIN_ID, MAX_MESSAGE_LENGTH
from db import init_db, save_message, get_history
from claude_runner import run_claude

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

router = Router()


def is_admin(message):
    # type: (Message) -> bool
    return bool(message.from_user) and message.from_user.id == ADMIN_ID


def _split_message(text):
    # type: (str) -> list
    if len(text) <= MAX_MESSAGE_LENGTH:
        return [text]
    chunks = []
    while text:
        if len(text) <= MAX_MESSAGE_LENGTH:
            chunks.append(text)
            break
        split_at = text.rfind("\n", 0, MAX_MESSAGE_LENGTH)
        if split_at == -1:
            split_at = MAX_MESSAGE_LENGTH
        chunks.append(text[:split_at])
        text = text[split_at:].lstrip("\n")
    return chunks


async def _set_reaction(message):
    # type: (Message) -> None
    try:
        await message.bot.set_message_reaction(
            chat_id=message.chat.id,
            message_id=message.message_id,
            reaction=[ReactionTypeEmoji(emoji="\U0001f440")],
        )
    except Exception:
        logger.debug("Failed to set reaction", exc_info=True)


async def _send_result(message, status_msg, result):
    # type: (Message, Message, str) -> None
    chunks = _split_message(result)
    try:
        await status_msg.edit_text(chunks[0])
    except Exception:
        await message.answer(chunks[0])
    for chunk in chunks[1:]:
        await message.answer(chunk)


# ── Text handler ──────────────────────────────────────────────────

@router.message(F.text, ~F.text.startswith("/"))
async def handle_text(message):
    # type: (Message) -> None
    if not is_admin(message):
        return

    await _set_reaction(message)
    status_msg = await message.answer("Думаю...")

    try:
        history = get_history(message.chat.id)
        if history:
            prompt = "{}\nUser: {}".format(history, message.text)
        else:
            prompt = "User: {}".format(message.text)

        result = await run_claude(prompt)

        save_message(message.chat.id, "user", message.text)
        save_message(message.chat.id, "assistant", result)

        await _send_result(message, status_msg, result)
    except Exception:
        logger.exception("handle_text failed")
        try:
            await status_msg.edit_text("Произошла ошибка. Попробуй ещё раз.")
        except Exception:
            pass


# ── Photo handler ─────────────────────────────────────────────────

@router.message(F.photo)
async def handle_photo(message):
    # type: (Message) -> None
    """Photos not supported in fallback mode — claude -p accepts text only."""
    if not is_admin(message):
        return

    caption = message.caption or ""
    if caption:
        # Process caption as text, ignore the image
        await _set_reaction(message)
        status_msg = await message.answer("Думаю... (фото не обрабатывается в fallback-режиме, читаю текст)")

        try:
            history = get_history(message.chat.id)
            if history:
                prompt = "{}\nUser: {}".format(history, caption)
            else:
                prompt = "User: {}".format(caption)

            result = await run_claude(prompt)

            save_message(message.chat.id, "user", caption)
            save_message(message.chat.id, "assistant", result)

            await _send_result(message, status_msg, result)
        except Exception:
            logger.exception("handle_photo failed")
            try:
                await status_msg.edit_text("Произошла ошибка. Попробуй ещё раз.")
            except Exception:
                pass
    else:
        await message.answer("Fallback-режим не поддерживает фото. Отправь текстом.")


# ── Voice handler ─────────────────────────────────────────────────

@router.message(F.voice | F.video_note)
async def handle_voice(message):
    # type: (Message) -> None
    if not is_admin(message):
        return

    await _set_reaction(message)
    status_msg = await message.answer("Расшифровываю...")

    tmp_path = None
    try:
        if message.voice:
            file_obj = message.voice
            suffix = ".ogg"
        else:
            file_obj = message.video_note
            suffix = ".mp4"

        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
            tmp_path = f.name
        await message.bot.download(file_obj, destination=tmp_path)

        # Transcribe
        proc = await asyncio.create_subprocess_exec(
            "python3", "/opt/second-brain/scripts/transcribe.py", tmp_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)

        if proc.returncode != 0 or not stdout.decode().strip():
            await status_msg.edit_text("Не удалось распознать голосовое. Попробуй текстом.")
            return

        transcribed = stdout.decode().strip()
        await status_msg.edit_text("Думаю...")

        history = get_history(message.chat.id)
        if history:
            prompt = "{}\nUser: {}".format(history, transcribed)
        else:
            prompt = "User: {}".format(transcribed)

        result = await run_claude(prompt)

        save_message(message.chat.id, "user", transcribed)
        save_message(message.chat.id, "assistant", result)

        await _send_result(message, status_msg, result)
    except asyncio.TimeoutError:
        try:
            await status_msg.edit_text("Таймаут транскрипции. Попробуй текстом.")
        except Exception:
            pass
    except Exception:
        logger.exception("handle_voice failed")
        try:
            await status_msg.edit_text("Ошибка обработки голосового.")
        except Exception:
            pass
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass


# ── Main ──────────────────────────────────────────────────────────

async def main():
    init_db()
    bot = Bot(token=BOT_TOKEN)
    dp = Dispatcher()
    dp.include_router(router)
    logger.info("DSBot Fallback started (admin=%d)", ADMIN_ID)
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
