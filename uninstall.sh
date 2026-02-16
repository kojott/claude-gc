#!/usr/bin/env bash
# claude-gc uninstaller
# Usage: curl -fsSL https://raw.githubusercontent.com/kojott/claude-gc/main/uninstall.sh | bash

set -euo pipefail

INSTALL_DIR="${CLAUDE_GC_INSTALL_DIR:-${HOME}/.claude}"
SCRIPT_PATH="${INSTALL_DIR}/claude-gc.sh"
LOG_PATH="${INSTALL_DIR}/claude-gc.log"

OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       PLATFORM="linux" ;;
esac

echo "claude-gc uninstaller"
echo "====================="
echo ""

# ── Remove scheduling ───────────────────────────────────────────────────────

# Cron
if crontab -l 2>/dev/null | grep -q "claude-gc"; then
    crontab -l 2>/dev/null | grep -v "claude-gc" | crontab -
    echo "Removed cron entry"
fi

# Systemd
if [[ "$PLATFORM" == "linux" ]]; then
    local_units="${HOME}/.config/systemd/user"
    if [[ -f "${local_units}/claude-gc.timer" ]]; then
        systemctl --user disable --now claude-gc.timer 2>/dev/null || true
        rm -f "${local_units}/claude-gc.service" "${local_units}/claude-gc.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "Removed systemd timer"
    fi
fi

# LaunchAgent (macOS)
if [[ "$PLATFORM" == "macos" ]]; then
    plist="${HOME}/Library/LaunchAgents/com.claude-gc.plist"
    if [[ -f "$plist" ]]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "Removed LaunchAgent"
    fi
fi

# ── Remove script ───────────────────────────────────────────────────────────

if [[ -f "$SCRIPT_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
    echo "Removed $SCRIPT_PATH"
else
    echo "Script not found at $SCRIPT_PATH (already removed?)"
fi

# ── Handle logs ──────────────────────────────────────────────────────────────

if [[ -f "$LOG_PATH" ]]; then
    if [[ -t 0 ]]; then
        read -rp "Remove log file ($LOG_PATH)? [y/N] " confirm
        if [[ "$confirm" == [yY] ]]; then
            rm -f "$LOG_PATH"
            echo "Removed log file"
        else
            echo "Log file kept at $LOG_PATH"
        fi
    else
        echo "Log file kept at $LOG_PATH (remove manually if desired)"
    fi
fi

echo ""
echo "claude-gc has been uninstalled."
