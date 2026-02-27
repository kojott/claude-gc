# Design: --max-age and --max-daemon-age (v1.2.0)

## Problem

claude-gc never kills subagents that have a living parent session, even if they've been running for hours/days. The `is_child_of_active()` parent chain walk provides absolute protection. This causes unbounded accumulation of stale Task subagents (documented case: 143 orphaned subagents consuming all RAM).

## Solution

Add `--max-age` flag that overrides parent chain protection for processes exceeding the age limit. Separate `--max-daemon-age` for long-lived daemon processes.

## Parameters

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--max-age SECS` | `CLAUDE_GC_MAX_AGE` | `14400` (4h) | Kill processes older than this, even with living parent |
| `--max-daemon-age SECS` | `CLAUDE_GC_MAX_DAEMON_AGE` | `86400` (24h) | Kill daemon processes (worker-service, mcp-server) older than this |

## Logic

### Phase 1 (Claude processes)

```
for each candidate (no TTY, not excluded):
  if age < MIN_AGE → SKIP
  if is_daemon AND age > MAX_DAEMON_AGE → KILL (force)
  if is_daemon → SKIP
  if age > MAX_AGE → KILL (force, override parent protection)
  if is_child_of_active() → SKIP
  else → KILL
```

### Phase 2 (MCP processes)

Same pattern — MAX_AGE overrides ancestor check.

## Files Changed

1. `cleanup.sh` — new vars, arg parsing, override logic in both phases
2. `install.sh` — env var support for new flags
3. `systemd/claude-gc.service` — optionally pass --max-age
4. `README.md` — document new flags

## Rationale

- Anthropic data: 99.9th percentile task turn is < 45 minutes
- Subagents running 4+ hours are almost certainly orphaned
- Daemons (worker-service, mcp-server) are intentionally long-lived, so they get a separate 24h limit
- Conservative defaults (4h/24h) minimize false kills
