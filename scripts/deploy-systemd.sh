#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DSBot — Deploy systemd service
# Run on VPS: bash /opt/second-brain/Projects/dsbot/scripts/deploy-systemd.sh
# ==============================================================================

SCRIPTS_DIR="/opt/second-brain/Projects/dsbot/scripts"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== DSBot systemd deployment ==="
echo "Date: $(date)"
echo ""

# Step 1: Make scripts executable
echo "[1/4] Making scripts executable..."
chmod +x "$SCRIPTS_DIR"/dsbot-*.sh
echo "  -> Done"

# Step 2: Symlink service files
echo "[2/4] Installing systemd units..."
ln -sf "$SCRIPTS_DIR/systemd/dsbot.service" "$SYSTEMD_DIR/dsbot.service"
ln -sf "$SCRIPTS_DIR/systemd/dsbot-healthcheck.service" "$SYSTEMD_DIR/dsbot-healthcheck.service"
ln -sf "$SCRIPTS_DIR/systemd/dsbot-healthcheck.timer" "$SYSTEMD_DIR/dsbot-healthcheck.timer"
echo "  -> Symlinked to $SYSTEMD_DIR"

# Step 3: Reload systemd
echo "[3/4] Reloading systemd..."
systemctl daemon-reload
echo "  -> Done"

# Step 4: Show status
echo "[4/4] Checking units..."
systemctl list-unit-files | grep dsbot || true
echo ""

echo "=== Deployment complete ==="
echo ""
echo "Next steps (run manually):"
echo ""
echo "  # 1. Stop current DSBot"
echo "  tmux kill-session -t dsbot 2>/dev/null; killall -9 bun claude 2>/dev/null; sleep 3"
echo ""
echo "  # 2. Remove cron watchdog"
echo "  crontab -l | grep -v 'dsbot-watchdog' | crontab -"
echo ""
echo "  # 3. Enable and start"
echo "  systemctl enable --now dsbot.service"
echo "  systemctl enable --now dsbot-healthcheck.timer"
echo ""
echo "  # 4. Verify"
echo "  systemctl status dsbot"
echo "  journalctl -u dsbot -f"
echo ""
echo "=== Rollback (if something breaks) ==="
echo "  systemctl disable --now dsbot.service dsbot-healthcheck.timer"
echo "  systemctl daemon-reload"
echo '  echo "*/2 * * * * /root/dsbot-watchdog.sh >> /var/log/dsbot-watchdog.log 2>&1" | crontab -'
echo "  /root/start-dsbot.sh"
