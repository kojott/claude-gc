# claude-gc Development Guide

## Structure

- `cleanup.sh` — Main cleanup script (core logic)
- `install.sh` — One-liner installer (download + schedule)
- `uninstall.sh` — Clean removal
- `systemd/` — Systemd service + timer units
- `README.md` — User documentation

## Algorithm

### Phase 1: Orphaned Claude processes
1. Find claude processes with no controlling terminal (TTY = `?` / `??`)
2. Exclude: chroma-mcp, tmux, worker-service, mcp-server, claude-gc itself
3. Collect active sessions: terminal claude sessions + background daemons (bun worker-service, node mcp-server)
4. Skip processes younger than `--min-age` (default 1800s)
5. Walk parent chain up to 3 levels — protect children of active sessions/daemons
6. SIGTERM → wait 2s → SIGKILL survivors

### Phase 2: Orphaned MCP server processes
7. Scan for known MCP patterns (python/uv/node/bun/npm with mcp-related args)
8. Filter by current user only (never touch other users' processes)
9. Exclude worker-service and mcp-server daemons
10. Walk parent chain up to 5 levels — protect processes with living claude ancestor
11. Same SIGTERM → SIGKILL flow
12. Log results to `~/.claude/claude-gc.log`

## Conventions

- Pure bash — no external dependencies beyond coreutils/procps
- Cross-platform: Linux + macOS (handle TTY markers, time formats, memory commands)
- `set -euo pipefail` in all scripts — use `|| true` for arithmetic that can return 0
- Safe for cron: auto-force when no TTY detected
- Self-exclusion: never kill claude-gc itself
- User-scoped: only target processes owned by current user
- Daemon-aware: recognize worker-service/mcp-server as legitimate background parents

## Security Model

- All inputs (env vars, CLI flags) are trusted — the tool runs in the user's own environment
- No untrusted user input is processed at any point
- Security review (2026-02-16): **0 vulnerabilities found** — 5 candidates analyzed, all filtered as false positives (relied on attacker-controlled env vars, which is out of scope)

## Testing

```bash
# Preview what would be cleaned
bash cleanup.sh --dry-run --verbose

# Show usage
bash cleanup.sh --help

# Clean orphans (interactive confirmation)
bash cleanup.sh --verbose

# Clean orphans (no confirmation, like cron would)
bash cleanup.sh --force --verbose

# Test with shorter min-age
bash cleanup.sh --dry-run --verbose --min-age 60

# Test installer locally
bash install.sh

# Test uninstaller
bash uninstall.sh
```
