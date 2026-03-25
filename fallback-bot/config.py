import os
from pathlib import Path

# Required — crash-fast if missing
BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_ID = int(os.environ["ADMIN_ID"])

# Claude CLI
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
SECOND_BRAIN_DIR = Path(os.environ.get("SECOND_BRAIN_DIR", "/opt/second-brain"))
CLAUDE_TIMEOUT = int(os.environ.get("CLAUDE_TIMEOUT", "120"))

# Conversation history
MAX_HISTORY = int(os.environ.get("MAX_HISTORY", "10"))

# Telegram limits
MAX_MESSAGE_LENGTH = 4096

# Local data
DATA_DIR = Path(__file__).parent / "data"
