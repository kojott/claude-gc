# claude-gc Development Guide

## Structure

- `cleanup.sh` — Main cleanup script (core logic)
- `install.sh` — One-liner installer (download + schedule)
- `uninstall.sh` — Clean removal
- `systemd/` — Systemd service + timer units
- `README.md` — User documentation

## Algorithm

1. Find claude processes with no controlling terminal (TTY = `?` / `??`)
2. Exclude: chroma-mcp, tmux, claude-gc itself
3. Skip processes younger than `--min-age` (default 1800s)
4. Walk parent chain up to 3 levels — protect children of active terminal sessions
5. SIGTERM → wait 2s → SIGKILL survivors
6. Log results to `~/.claude/claude-gc.log`

## Conventions

- Pure bash — no external dependencies beyond coreutils/procps
- Cross-platform: Linux + macOS (handle TTY markers, time formats, memory commands)
- `set -euo pipefail` in all scripts
- Safe for cron: auto-force when no TTY detected
- Self-exclusion: never kill claude-gc itself

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
