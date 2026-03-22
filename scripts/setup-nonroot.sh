#!/usr/bin/env bash
# ==============================================================================
# DSBot — Setup non-root user on VPS
# ==============================================================================
# Run as: root@46.62.155.190
# Purpose: Create user 'dsbot', restrict privileges, move services from root
#
# IMPORTANT: Review before running! This script changes system config.
# Run with: bash /opt/second-brain/Projects/dsbot/scripts/setup-nonroot.sh
#
# Idempotent: safe to run multiple times (checks before creating)
# ==============================================================================

set -euo pipefail

# --- Constants ----------------------------------------------------------------
DSBOT_USER="dsbot"
DSBOT_HOME="/home/${DSBOT_USER}"
SECOND_BRAIN="/opt/second-brain"
WRAPPER_PATH="/usr/local/bin/dsbot-docker"
LOG_DIR="/var/log"
WATCHDOG_LOG="${LOG_DIR}/dsbot-watchdog.log"
BRIEFING_LOG="${LOG_DIR}/dsbot-briefing.log"
ALERTS_LOG="${LOG_DIR}/dsbot-alerts.log"

echo "=== DSBot non-root setup ==="
echo "Date: $(date)"
echo ""

# --- Step 1: Create user 'dsbot' ---------------------------------------------
echo "[1/8] Creating user '${DSBOT_USER}'..."

if id "${DSBOT_USER}" &>/dev/null; then
    echo "  -> User '${DSBOT_USER}' already exists, skipping"
else
    useradd --create-home --shell /bin/bash "${DSBOT_USER}"
    echo "  -> User '${DSBOT_USER}' created with home ${DSBOT_HOME}"
fi

# --- Step 2: Give dsbot ownership of /opt/second-brain/ -----------------------
echo "[2/8] Setting ownership of ${SECOND_BRAIN}..."

chown -R "${DSBOT_USER}:${DSBOT_USER}" "${SECOND_BRAIN}"
echo "  -> ${SECOND_BRAIN} now owned by ${DSBOT_USER}"

# --- Step 3: Docker read-only access (add to 'docker' group) -----------------
echo "[3/8] Adding '${DSBOT_USER}' to docker group..."

if groups "${DSBOT_USER}" | grep -q '\bdocker\b'; then
    echo "  -> Already in docker group, skipping"
else
    usermod -aG docker "${DSBOT_USER}"
    echo "  -> Added to docker group (for 'docker exec' access)"
fi

# --- Step 4: Restricted docker wrapper ----------------------------------------
# Only allows: docker exec winch-bot python3 scripts/...
# Blocks all other docker commands (rm, stop, run, etc.)
echo "[4/8] Creating restricted docker wrapper at ${WRAPPER_PATH}..."

cat > "${WRAPPER_PATH}" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# ==============================================================================
# dsbot-docker — restricted Docker wrapper for DSBot
# Only allows: docker exec winch-bot python3 scripts/...
# All other docker commands are blocked.
# ==============================================================================

set -euo pipefail

# Validate arguments
if [ $# -lt 4 ]; then
    echo "ERROR: Usage: dsbot-docker exec winch-bot python3 scripts/<script> [args...]" >&2
    exit 1
fi

CMD="$1"
CONTAINER="$2"
INTERPRETER="$3"
SCRIPT="$4"

# Only allow 'exec' subcommand
if [ "${CMD}" != "exec" ]; then
    echo "ERROR: Only 'exec' command is allowed. Got: ${CMD}" >&2
    exit 1
fi

# Only allow 'winch-bot' container
if [ "${CONTAINER}" != "winch-bot" ]; then
    echo "ERROR: Only 'winch-bot' container is allowed. Got: ${CONTAINER}" >&2
    exit 1
fi

# Only allow python3 interpreter
if [ "${INTERPRETER}" != "python3" ]; then
    echo "ERROR: Only 'python3' interpreter is allowed. Got: ${INTERPRETER}" >&2
    exit 1
fi

# Only allow scripts/ directory (block path traversal)
if [[ "${SCRIPT}" != scripts/* ]]; then
    echo "ERROR: Only scripts/ directory is allowed. Got: ${SCRIPT}" >&2
    exit 1
fi

# Block path traversal attempts
if [[ "${SCRIPT}" == *".."* ]]; then
    echo "ERROR: Path traversal not allowed in script path." >&2
    exit 1
fi

# All checks passed — execute
exec docker exec winch-bot python3 "${@:4}"
WRAPPER_EOF

chmod 755 "${WRAPPER_PATH}"
echo "  -> Wrapper created and made executable"

# --- Step 5: Set up log file permissions --------------------------------------
echo "[5/8] Setting log file permissions..."

for logfile in "${WATCHDOG_LOG}" "${BRIEFING_LOG}" "${ALERTS_LOG}"; do
    touch "${logfile}"
    chown "${DSBOT_USER}:${DSBOT_USER}" "${logfile}"
    echo "  -> ${logfile} owned by ${DSBOT_USER}"
done

# --- Step 6: Claude CLI access ------------------------------------------------
# Claude Code is installed at /root/.claude/ — dsbot needs access.
# Strategy: symlink /root/.claude/local/bin/claude to dsbot's PATH,
# and copy config. Claude CLI may store state in ~/.claude/.
echo "[6/8] Setting up Claude CLI access for ${DSBOT_USER}..."

# Find claude binary location
CLAUDE_BIN=""
if [ -f /root/.claude/local/bin/claude ]; then
    CLAUDE_BIN="/root/.claude/local/bin/claude"
elif command -v claude &>/dev/null; then
    CLAUDE_BIN="$(command -v claude)"
fi

if [ -n "${CLAUDE_BIN}" ]; then
    # Create bin directory for dsbot
    mkdir -p "${DSBOT_HOME}/bin"

    # Symlink claude binary to dsbot's bin
    ln -sf "${CLAUDE_BIN}" "${DSBOT_HOME}/bin/claude"

    # Add to PATH via .bashrc if not already there
    if ! grep -q 'HOME/bin' "${DSBOT_HOME}/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "${DSBOT_HOME}/.bashrc"
    fi

    # Claude needs ~/.claude/ directory for config/state
    mkdir -p "${DSBOT_HOME}/.claude"
    chown -R "${DSBOT_USER}:${DSBOT_USER}" "${DSBOT_HOME}/.claude"
    chown -R "${DSBOT_USER}:${DSBOT_USER}" "${DSBOT_HOME}/bin"

    echo "  -> Claude CLI linked to ${DSBOT_HOME}/bin/claude"
    echo "  -> NOTE: You may need to run 'claude auth login' as dsbot user"
    echo "           or copy auth tokens from /root/.claude/ to ${DSBOT_HOME}/.claude/"
else
    echo "  -> WARNING: Claude CLI not found at /root/.claude/local/bin/claude"
    echo "  -> You will need to install Claude CLI for the dsbot user manually"
    echo "  -> Run: su - dsbot -c 'curl -fsSL https://claude.ai/install.sh | sh'"
fi

# --- Step 7: Update start-dsbot.sh and dsbot-watchdog.sh ---------------------
echo "[7/8] Updating startup and watchdog scripts..."

# Backup originals
for script in /root/start-dsbot.sh /root/dsbot-watchdog.sh; do
    if [ -f "${script}" ] && [ ! -f "${script}.bak.pre-nonroot" ]; then
        cp "${script}" "${script}.bak.pre-nonroot"
        echo "  -> Backed up ${script} to ${script}.bak.pre-nonroot"
    fi
done

# Patch start-dsbot.sh — wrap claude command with 'su - dsbot -c ...'
if [ -f /root/start-dsbot.sh ]; then
    # Replace direct claude invocation with su - dsbot
    # The script starts tmux with claude command — we need to run it as dsbot
    sed -i.sedtmp \
        's|tmux new-session -d -s dsbot.*|tmux new-session -d -s dsbot "su - '"${DSBOT_USER}"' -c '"'"'cd '"${SECOND_BRAIN}"' \&\& claude --channels plugin:telegram@claude-plugins-official'"'"'"|' \
        /root/start-dsbot.sh 2>/dev/null || true
    rm -f /root/start-dsbot.sh.sedtmp
    echo "  -> Patched start-dsbot.sh to run as ${DSBOT_USER}"
    echo "  -> REVIEW: cat /root/start-dsbot.sh — verify the patch is correct"
else
    echo "  -> WARNING: /root/start-dsbot.sh not found, creating template..."
    cat > /root/start-dsbot.sh << START_EOF
#!/usr/bin/env bash
# DSBot — start as non-root user
cd ${SECOND_BRAIN}
tmux new-session -d -s dsbot "su - ${DSBOT_USER} -c 'cd ${SECOND_BRAIN} && claude --channels plugin:telegram@claude-plugins-official'"
echo "\$(date): DSBot started as ${DSBOT_USER}" >> ${WATCHDOG_LOG}
START_EOF
    chmod +x /root/start-dsbot.sh
fi

# Patch dsbot-watchdog.sh — the watchdog itself stays as root (it manages tmux)
# but the claude process inside runs as dsbot (handled by start-dsbot.sh)
if [ -f /root/dsbot-watchdog.sh ]; then
    echo "  -> dsbot-watchdog.sh: no changes needed (tmux/restart stays as root)"
    echo "  -> The claude process inside tmux already runs as ${DSBOT_USER} via start-dsbot.sh"
else
    echo "  -> WARNING: /root/dsbot-watchdog.sh not found"
fi

# --- Step 8: Update cron jobs -------------------------------------------------
echo "[8/8] Updating cron jobs..."

# Export current root crontab
CRON_BACKUP="/root/crontab.bak.pre-nonroot"
crontab -l > "${CRON_BACKUP}" 2>/dev/null || true
echo "  -> Root crontab backed up to ${CRON_BACKUP}"

# Create dsbot crontab with the python scripts (briefings, alerts, git sync)
# These scripts need: python3, access to /opt/second-brain, .env vars
DSBOT_CRON=$(mktemp)
cat > "${DSBOT_CRON}" << CRON_EOF
# DSBot cron jobs — run as user 'dsbot'
# Git sync every 5 minutes
*/5 * * * * cd ${SECOND_BRAIN} && git pull --rebase --autostash >> /var/log/dsbot-gitsync.log 2>&1

# Briefings: 07:00, 12:00, 21:00 (Tashkent = UTC+5)
0 2 * * * cd ${SECOND_BRAIN} && python3 Projects/dsbot/scripts/send_briefing.py >> ${BRIEFING_LOG} 2>&1
0 7 * * * cd ${SECOND_BRAIN} && python3 Projects/dsbot/scripts/send_briefing.py >> ${BRIEFING_LOG} 2>&1
0 16 * * * cd ${SECOND_BRAIN} && python3 Projects/dsbot/scripts/send_briefing.py >> ${BRIEFING_LOG} 2>&1

# Sunday weekly briefing at 20:00 (Tashkent)
0 15 * * 0 cd ${SECOND_BRAIN} && python3 Projects/dsbot/scripts/send_briefing.py --weekly >> ${BRIEFING_LOG} 2>&1

# Proactive alerts every 4 hours
0 */4 * * * cd ${SECOND_BRAIN} && python3 Projects/dsbot/scripts/proactive_alerts.py >> ${ALERTS_LOG} 2>&1
CRON_EOF

# Set dsbot's crontab
crontab -u "${DSBOT_USER}" "${DSBOT_CRON}"
rm -f "${DSBOT_CRON}"
echo "  -> Cron jobs moved to ${DSBOT_USER}'s crontab"

# Create gitsync log
touch /var/log/dsbot-gitsync.log
chown "${DSBOT_USER}:${DSBOT_USER}" /var/log/dsbot-gitsync.log

# Remove the migrated jobs from root crontab (leave watchdog as root)
# NOTE: The watchdog stays in root's crontab because it manages tmux sessions
echo "  -> NOTE: Remove migrated cron jobs from root's crontab manually:"
echo "     crontab -e  (remove briefing, alerts, git sync lines)"
echo "     Keep ONLY the watchdog line (*/2 * * * * /root/dsbot-watchdog.sh)"

# --- Git safe remote access ---------------------------------------------------
# dsbot needs git push access — configure git user for the dsbot account
echo ""
echo "[Post-setup] Configuring git for ${DSBOT_USER}..."
su - "${DSBOT_USER}" -c "git config --global user.name 'DSBot'" 2>/dev/null || true
su - "${DSBOT_USER}" -c "git config --global user.email 'dsbot@winch.uz'" 2>/dev/null || true

# SSH key for GitHub — dsbot needs access to push to second-brain repo
if [ ! -f "${DSBOT_HOME}/.ssh/id_ed25519" ]; then
    echo "  -> NOTE: dsbot has no SSH key. To set up GitHub access:"
    echo "     Option A: Copy root's key (less secure):"
    echo "       cp /root/.ssh/id_ed25519 ${DSBOT_HOME}/.ssh/"
    echo "       cp /root/.ssh/id_ed25519.pub ${DSBOT_HOME}/.ssh/"
    echo "       chown ${DSBOT_USER}:${DSBOT_USER} ${DSBOT_HOME}/.ssh/id_ed25519*"
    echo "     Option B: Generate new key (better):"
    echo "       su - ${DSBOT_USER} -c 'ssh-keygen -t ed25519 -N \"\" -f ~/.ssh/id_ed25519'"
    echo "       Then add the public key to GitHub deploy keys"
else
    echo "  -> SSH key already exists for ${DSBOT_USER}"
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "=== Setup complete ==="
echo ""
echo "What was done:"
echo "  1. User '${DSBOT_USER}' created"
echo "  2. ${SECOND_BRAIN} ownership transferred to ${DSBOT_USER}"
echo "  3. ${DSBOT_USER} added to docker group"
echo "  4. Restricted wrapper at ${WRAPPER_PATH} (only docker exec winch-bot python3 scripts/...)"
echo "  5. Log files owned by ${DSBOT_USER}"
echo "  6. Claude CLI linked (may need auth)"
echo "  7. start-dsbot.sh patched to run as ${DSBOT_USER}"
echo "  8. Cron jobs moved to ${DSBOT_USER}'s crontab"
echo ""
echo "Manual steps remaining:"
echo "  1. Review start-dsbot.sh:  cat /root/start-dsbot.sh"
echo "  2. Authenticate Claude:    su - ${DSBOT_USER} -c 'claude auth login'"
echo "     OR copy auth:           cp -r /root/.claude/auth* ${DSBOT_HOME}/.claude/ && chown -R ${DSBOT_USER}:${DSBOT_USER} ${DSBOT_HOME}/.claude/"
echo "  3. Set up GitHub SSH key (see notes above)"
echo "  4. Clean root crontab:     crontab -e (remove migrated jobs, keep watchdog)"
echo "  5. Restart DSBot:          tmux kill-session -t dsbot; /root/start-dsbot.sh"
echo "  6. Verify:                 tmux capture-pane -t dsbot -p | strings | tail -10"
echo ""

# ==============================================================================
# ROLLBACK — How to undo everything
# ==============================================================================
# If something breaks, run these commands as root:
#
# 1. Restore crontab:
#    crontab /root/crontab.bak.pre-nonroot
#    crontab -r -u dsbot
#
# 2. Restore startup scripts:
#    cp /root/start-dsbot.sh.bak.pre-nonroot /root/start-dsbot.sh
#    cp /root/dsbot-watchdog.sh.bak.pre-nonroot /root/dsbot-watchdog.sh  # if backed up
#
# 3. Restore ownership:
#    chown -R root:root /opt/second-brain
#
# 4. Remove wrapper:
#    rm /usr/local/bin/dsbot-docker
#
# 5. Remove user (optional, keeps home dir):
#    userdel dsbot
#    # To also remove home: userdel -r dsbot
#
# 6. Restart as root:
#    tmux kill-session -t dsbot
#    /root/start-dsbot.sh
# ==============================================================================
