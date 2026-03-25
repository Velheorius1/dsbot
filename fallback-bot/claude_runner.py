import asyncio
import logging
import os
import signal
from typing import Optional

from config import CLAUDE_BIN, CLAUDE_TIMEOUT, SECOND_BRAIN_DIR

logger = logging.getLogger(__name__)

_lock = None  # type: Optional[asyncio.Lock]


def _get_lock():
    # type: () -> asyncio.Lock
    global _lock
    if _lock is None:
        _lock = asyncio.Lock()
    return _lock


async def run_claude(prompt, cwd=None):
    # type: (str, Optional[str]) -> str
    if cwd is None:
        cwd = str(SECOND_BRAIN_DIR)

    cmd = [
        CLAUDE_BIN,
        "-p", "-",
        "--output-format", "text",
        "--no-session-persistence",
    ]

    async with _get_lock():
        try:
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd,
                start_new_session=True,
            )
            stdout, stderr = await asyncio.wait_for(
                process.communicate(input=prompt.encode()),
                timeout=CLAUDE_TIMEOUT,
            )
        except asyncio.TimeoutError:
            logger.error("Claude timed out after %d seconds", CLAUDE_TIMEOUT)
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                process.kill()
            try:
                await asyncio.wait_for(process.wait(), timeout=5)
            except asyncio.TimeoutError:
                pass
            return "Таймаут: Claude не ответил за {} сек.".format(CLAUDE_TIMEOUT)
        except FileNotFoundError:
            logger.error("Claude binary not found: %s", CLAUDE_BIN)
            return "Ошибка: claude CLI не найден ({}).".format(CLAUDE_BIN)
        except Exception as e:
            logger.exception("Unexpected error running claude")
            return "Ошибка запуска Claude: {}".format(str(e))

    if process.returncode != 0:
        error = stderr.decode().strip()
        logger.error("Claude returned code %d: %s", process.returncode, error)
        return "Ошибка Claude Code:\n{}".format(error)

    result = stdout.decode().strip()
    if not result:
        return "Claude вернул пустой ответ."
    return result
