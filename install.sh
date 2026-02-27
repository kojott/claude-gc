#!/usr/bin/env bash
# claude-gc installer
# Usage: curl -fsSL https://raw.githubusercontent.com/kojott/claude-gc/main/install.sh | bash
#
# Environment variables:
#   CLAUDE_GC_INSTALL_DIR    Installation directory (default: ~/.claude)
#   CLAUDE_GC_CRON_INTERVAL  Cron interval in minutes (default: 15)
#   CLAUDE_GC_USE_SYSTEMD    Set to "1" to prefer systemd over cron on Linux
#   CLAUDE_GC_MAX_AGE        Max process age before force-kill (default: 14400 = 4h)
#   CLAUDE_GC_MAX_DAEMON_AGE Max daemon age before force-kill (default: 86400 = 24h)

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/kojott/claude-gc/main"
INSTALL_DIR="${CLAUDE_GC_INSTALL_DIR:-${HOME}/.claude}"
SCRIPT_NAME="claude-gc.sh"
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
CRON_INTERVAL="${CLAUDE_GC_CRON_INTERVAL:-15}"
USE_SYSTEMD="${CLAUDE_GC_USE_SYSTEMD:-0}"

OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       echo "Unsupported platform: $OS"; exit 1 ;;
esac

echo "claude-gc installer"
echo "==================="
echo ""
echo "Platform: $PLATFORM"
echo "Install dir: $INSTALL_DIR"
echo ""

# ── Step 1: Download cleanup script ─────────────────────────────────────────

mkdir -p "$INSTALL_DIR"

echo "Downloading claude-gc.sh..."
if command -v curl &>/dev/null; then
    curl -fsSL "${REPO_URL}/cleanup.sh" -o "$SCRIPT_PATH"
elif command -v wget &>/dev/null; then
    wget -qO "$SCRIPT_PATH" "${REPO_URL}/cleanup.sh"
else
    echo "Error: curl or wget required" >&2
    exit 1
fi

chmod +x "$SCRIPT_PATH"
echo "Installed: $SCRIPT_PATH"

# ── Step 2: Install scheduling ──────────────────────────────────────────────

install_cron() {
    local cron_cmd="*/${CRON_INTERVAL} * * * * ${SCRIPT_PATH} --force 2>/dev/null"
    local existing
    existing=$(crontab -l 2>/dev/null || true)

    # Remove any existing claude-gc entries
    local cleaned
    cleaned=$(echo "$existing" | grep -v "claude-gc" || true)

    # Add new entry
    echo "$cleaned" | { cat; echo "$cron_cmd"; } | crontab -
    echo "Cron job installed: every ${CRON_INTERVAL} minutes"
}

install_systemd() {
    local user_dir="${HOME}/.config/systemd/user"
    mkdir -p "$user_dir"

    echo "Downloading systemd units..."
    if command -v curl &>/dev/null; then
        curl -fsSL "${REPO_URL}/systemd/claude-gc.service" -o "${user_dir}/claude-gc.service"
        curl -fsSL "${REPO_URL}/systemd/claude-gc.timer" -o "${user_dir}/claude-gc.timer"
    else
        wget -qO "${user_dir}/claude-gc.service" "${REPO_URL}/systemd/claude-gc.service"
        wget -qO "${user_dir}/claude-gc.timer" "${REPO_URL}/systemd/claude-gc.timer"
    fi

    systemctl --user daemon-reload
    systemctl --user enable --now claude-gc.timer
    echo "Systemd timer installed and started (every 15 minutes)"
}

install_launchd() {
    local plist_dir="${HOME}/Library/LaunchAgents"
    local plist_path="${plist_dir}/com.claude-gc.plist"
    mkdir -p "$plist_dir"

    cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-gc</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_PATH}</string>
        <string>--force</string>
    </array>
    <key>StartInterval</key>
    <integer>$(( CRON_INTERVAL * 60 ))</integer>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/claude-gc-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/claude-gc-launchd.log</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_path" 2>/dev/null || true
    launchctl load "$plist_path"
    echo "LaunchAgent installed: every ${CRON_INTERVAL} minutes"
}

case "$PLATFORM" in
    linux)
        if [[ "$USE_SYSTEMD" == "1" ]] && command -v systemctl &>/dev/null; then
            install_systemd
        else
            install_cron
        fi
        ;;
    macos)
        install_launchd
        ;;
esac

# ── Step 3: Initial dry run ─────────────────────────────────────────────────

echo ""
echo "Running initial scan..."
echo ""
bash "$SCRIPT_PATH" --dry-run --verbose || true

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "==================="
echo "Installation complete!"
echo ""
echo "  Script: $SCRIPT_PATH"
echo "  Log:    ${INSTALL_DIR}/claude-gc.log"
echo ""
echo "Manual usage:"
echo "  $SCRIPT_PATH --dry-run --verbose   # Preview"
echo "  $SCRIPT_PATH --force               # Clean now"
echo ""
echo "To uninstall:"
echo "  curl -fsSL ${REPO_URL}/uninstall.sh | bash"
