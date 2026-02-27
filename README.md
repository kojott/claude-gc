# claude-gc

Automatic cleanup for orphaned Claude Code processes that silently eat your RAM.

## The Problem

Claude Code spawns child processes — subagents, MCP servers, Task tool workers — that don't get cleaned up when you close your terminal. Each orphan consumes **~220MB RAM**. On a typical development server, **100+ orphans** can accumulate in hours, consuming **22GB+** of memory.

This is a known issue:
- [#20369 — Subprocesses not cleaned up](https://github.com/anthropics/claude-code/issues/20369)
- [#4953 — Background processes accumulate](https://github.com/anthropics/claude-code/issues/4953)
- [#11315 — Memory leak from orphaned processes](https://github.com/anthropics/claude-code/issues/11315)

## How It Works

claude-gc uses a multi-layer safety algorithm to clean up two categories of orphans:

### Phase 1: Orphaned Claude processes

1. **Find** claude processes with no controlling terminal (detached from any session)
2. **Exclude** protected processes: chroma-mcp (vector DB), tmux, worker-service/mcp-server daemons, and claude-gc itself
3. **Skip** processes younger than 30 minutes (configurable) — they may still be initializing
4. **Walk parent chain** up to 3 levels — if a detached process is a child/grandchild/great-grandchild of an active terminal session or background daemon, it's protected
5. **Graceful shutdown**: SIGTERM first, wait 2 seconds, then SIGKILL only for survivors

### Phase 2: Orphaned MCP server processes

Claude Code spawns MCP servers (python, uv, node, bun, npm) that don't contain "claude" in their name. These are invisible to simple process matching and can accumulate rapidly — **1000+ orphaned python/uv processes** have been observed consuming 75GB+ on a 32GB server, causing OOM kills.

6. **Scan** for known MCP patterns (`python.*mcp`, `uv.*mcp`, `node.*mcp`, `npm.*exec.*mcp`, `bun.*worker-service`, etc.)
7. **Filter** by current user only — never touches processes owned by other users (e.g., Cursor's MCP servers running as root)
8. **Verify ancestry** — walks 5 levels up the parent chain to check if any living claude process is an ancestor; if so, the MCP process is protected
9. **Same graceful shutdown** as Phase 1

Both phases **log** results with timestamps and freed memory.

This means claude-gc will **never kill your active Claude Code session**, its working subprocesses, or MCP servers belonging to other tools.

## Quick Start

**One-liner install** (sets up automatic cleanup every 15 minutes):

```bash
curl -fsSL https://raw.githubusercontent.com/kojott/claude-gc/main/install.sh | bash
```

**Manual install:**

```bash
# Download
curl -fsSL https://raw.githubusercontent.com/kojott/claude-gc/main/cleanup.sh -o ~/.claude/claude-gc.sh
chmod +x ~/.claude/claude-gc.sh

# Test it
~/.claude/claude-gc.sh --dry-run --verbose

# Add to cron (every 15 minutes)
(crontab -l 2>/dev/null; echo "*/15 * * * * ~/.claude/claude-gc.sh --force 2>/dev/null") | crontab -
```

## Usage

```
claude-gc.sh [OPTIONS]

Options:
  --dry-run            Show what would be killed without killing
  --verbose            Print detailed output
  --force              Skip interactive confirmation
  --min-age SECS       Minimum process age before eligible for cleanup (default: 1800 = 30min)
  --max-age SECS       Force-kill even protected processes older than this (default: 14400 = 4h)
  --max-daemon-age SECS  Force-kill daemon processes older than this (default: 86400 = 24h)
  --log PATH           Log file path (default: ~/.claude/claude-gc.log)
  --no-log             Disable logging
  -h, --help           Show this help message
```

### Examples

```bash
# Preview what would be cleaned
claude-gc.sh --dry-run --verbose

# Clean immediately (no confirmation)
claude-gc.sh --force

# More aggressive: kill processes older than 10 minutes
claude-gc.sh --force --min-age 600

# Force-kill protected processes after 1 hour (instead of default 4h)
claude-gc.sh --force --max-age 3600

# Force-kill daemons after 12 hours (instead of default 24h)
claude-gc.sh --force --max-daemon-age 43200

# Verbose with custom log
claude-gc.sh --force --verbose --log /tmp/claude-gc.log
```

## Configuration

| Option | Env Variable | Default | Description |
|--------|-------------|---------|-------------|
| `--min-age` | `CLAUDE_GC_MIN_AGE` | `1800` (30 min) | Minimum process age before eligible for cleanup |
| `--max-age` | `CLAUDE_GC_MAX_AGE` | `14400` (4 hours) | Force-kill even protected processes older than this |
| `--max-daemon-age` | `CLAUDE_GC_MAX_DAEMON_AGE` | `86400` (24 hours) | Force-kill daemon processes (worker-service, mcp-server) older than this |
| `--log` | `CLAUDE_GC_LOG` | `~/.claude/claude-gc.log` | Log file path |
| — | `CLAUDE_GC_INSTALL_DIR` | `~/.claude` | Installation directory (install.sh) |
| — | `CLAUDE_GC_CRON_INTERVAL` | `15` | Cron interval in minutes (install.sh) |
| — | `CLAUDE_GC_USE_SYSTEMD` | `0` | Set to `1` for systemd instead of cron |

## Scheduling Options

### Cron (default on Linux)

The installer sets this up automatically. To customize:

```bash
# Every 5 minutes (aggressive)
CLAUDE_GC_CRON_INTERVAL=5 bash install.sh

# Or edit manually
crontab -e
# */15 * * * * ~/.claude/claude-gc.sh --force 2>/dev/null
```

### Systemd Timer (Linux)

```bash
# Install with systemd
CLAUDE_GC_USE_SYSTEMD=1 bash install.sh

# Or manually:
cp systemd/claude-gc.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-gc.timer

# Check status
systemctl --user status claude-gc.timer
systemctl --user list-timers
```

### LaunchAgent (macOS)

The installer handles this automatically on macOS. The plist is installed at `~/Library/LaunchAgents/com.claude-gc.plist`.

## Uninstall

**One-liner:**

```bash
curl -fsSL https://raw.githubusercontent.com/kojott/claude-gc/main/uninstall.sh | bash
```

**Manual:**

```bash
# Remove cron entry
crontab -l | grep -v claude-gc | crontab -

# Remove script
rm ~/.claude/claude-gc.sh

# Optionally remove logs
rm ~/.claude/claude-gc.log
```

## FAQ

### Will this kill my active Claude Code session?

No. claude-gc only targets processes that have **no controlling terminal** (TTY = `?`). Your active terminal session and all its child processes are protected. It walks the parent chain 3 levels deep for Claude processes and 5 levels deep for MCP processes. Background daemon parents (bun worker-service, node mcp-server) are recognized as legitimate orchestrators and their children are protected.

**Note:** As of v1.2.0, processes older than `--max-age` (default: 4 hours) are force-killed even if they have a living parent, because no legitimate subagent should run that long. Daemons have a separate `--max-daemon-age` (default: 24 hours).

### Why 30 minutes minimum age?

Some Claude Code operations (like complex multi-agent tasks) spawn long-running background processes that are still working. The 30-minute default gives them time to finish. You can lower this with `--min-age` if you want more aggressive cleanup.

### Does it work with tmux/screen?

Yes. Processes running inside tmux or screen have a TTY (the pseudo-terminal from tmux/screen), so they're never targeted. The script also explicitly excludes tmux processes.

### What about MCP servers?

As of v1.1.0, claude-gc actively cleans up orphaned MCP servers (python, uv, node, bun, npm processes matching known MCP patterns). MCP servers that are children of an active Claude session are protected by the parent chain walk (5 levels deep). Orphaned MCP servers (whose parent session has ended) will be cleaned up. Only processes owned by the current user are targeted — MCP servers from other tools (e.g., Cursor) running under different users are never touched.

As of v1.2.0, even protected MCP processes are force-killed after `--max-age` (default: 4h), and daemon processes (worker-service, mcp-server) after `--max-daemon-age` (default: 24h).

### Can I see what it's doing?

```bash
# Preview mode
claude-gc.sh --dry-run --verbose

# Check the log
cat ~/.claude/claude-gc.log
```

## Platform Support

| Platform | Scheduling | Status |
|----------|-----------|--------|
| Linux (x86_64, aarch64) | cron or systemd | Fully supported |
| macOS (Intel, Apple Silicon) | launchd | Fully supported |
| WSL / WSL2 | cron | Supported (uses Linux path) |

## Related

- [Claude Code Issue #20369](https://github.com/anthropics/claude-code/issues/20369) — Subprocesses not cleaned up
- [Claude Code Issue #4953](https://github.com/anthropics/claude-code/issues/4953) — Background processes accumulate
- [Claude Code Issue #11315](https://github.com/anthropics/claude-code/issues/11315) — Memory leak from orphaned processes
- [yowmamasita's cleanup gist](https://gist.github.com/yowmamasita/0dfc5cb809a1e5f3aboref) — Earlier cleanup approach

## License

[MIT](LICENSE)
