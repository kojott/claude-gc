#!/usr/bin/env bash
# claude-gc — Automatic cleanup for orphaned Claude Code processes
# https://github.com/kojott/claude-gc
#
# Claude Code spawns child processes (subagents, MCP servers, Task workers)
# that don't get cleaned up when terminals close. Each orphan eats ~220MB RAM.
# This script safely identifies and kills them.
#
# Usage: claude-gc.sh [OPTIONS]
#   --dry-run            Show what would be killed without killing
#   --verbose            Print detailed output
#   --force              Skip interactive confirmation (auto-enabled when no TTY)
#   --min-age SECS       Minimum process age in seconds (default: 1800 = 30min)
#   --max-age SECS       Force-kill even protected processes older than this (default: 14400 = 4h)
#   --max-daemon-age SECS  Force-kill daemon processes older than this (default: 86400 = 24h)
#   --log PATH           Log file path (default: ~/.claude/claude-gc.log)
#   --no-log             Disable logging
#   -h, --help           Show this help message
#
# Environment variables:
#   CLAUDE_GC_MIN_AGE        Override default min-age (seconds)
#   CLAUDE_GC_MAX_AGE        Override default max-age (seconds)
#   CLAUDE_GC_MAX_DAEMON_AGE Override default max-daemon-age (seconds)
#   CLAUDE_GC_LOG            Override default log path

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

VERSION="1.2.0"
MIN_AGE="${CLAUDE_GC_MIN_AGE:-1800}"
MAX_AGE="${CLAUDE_GC_MAX_AGE:-14400}"
MAX_DAEMON_AGE="${CLAUDE_GC_MAX_DAEMON_AGE:-86400}"
LOG_FILE="${CLAUDE_GC_LOG:-${HOME}/.claude/claude-gc.log}"
LOG_ENABLED=true
DRY_RUN=false
VERBOSE=false
FORCE=false
PARENT_DEPTH=3

# Auto-force when no TTY (cron, systemd, pipe)
if [[ ! -t 1 ]]; then
    FORCE=true
fi

# ── Platform detection ───────────────────────────────────────────────────────

OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       PLATFORM="linux" ;; # Best-effort fallback
esac

# ── Argument parsing ────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
claude-gc — Automatic cleanup for orphaned Claude Code processes

Usage: claude-gc.sh [OPTIONS]

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

Environment variables:
  CLAUDE_GC_MIN_AGE        Override default min-age (seconds)
  CLAUDE_GC_MAX_AGE        Override default max-age (seconds)
  CLAUDE_GC_MAX_DAEMON_AGE Override default max-daemon-age (seconds)
  CLAUDE_GC_LOG            Override default log path

Examples:
  claude-gc.sh --dry-run --verbose       # Preview what would be cleaned
  claude-gc.sh --force                   # Clean without confirmation (cron use)
  claude-gc.sh --min-age 900             # Kill processes older than 15 minutes
  claude-gc.sh --max-age 3600            # Force-kill protected processes after 1 hour
  claude-gc.sh --max-daemon-age 43200    # Force-kill daemons after 12 hours
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --verbose)   VERBOSE=true; shift ;;
        --force)     FORCE=true; shift ;;
        --min-age)   MIN_AGE="$2"; shift 2 ;;
        --max-age)   MAX_AGE="$2"; shift 2 ;;
        --max-daemon-age) MAX_DAEMON_AGE="$2"; shift 2 ;;
        --log)       LOG_FILE="$2"; shift 2 ;;
        --no-log)    LOG_ENABLED=false; shift ;;
        -h|--help)   usage ;;
        *)           echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helper functions ─────────────────────────────────────────────────────────

log_msg() {
    local msg="$1"
    if [[ "$LOG_ENABLED" == true ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        [[ -d "$log_dir" ]] || mkdir -p "$log_dir"
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $msg" >> "$LOG_FILE"
    fi
}

verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$1"
    fi
}

# Get process elapsed time in seconds (cross-platform)
get_elapsed_seconds() {
    local pid="$1"
    if [[ "$PLATFORM" == "linux" ]]; then
        # Linux: etimes gives elapsed time in seconds directly
        ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' '
    else
        # macOS: etime gives elapsed time as [[DD-]HH:]MM:SS
        local etime
        etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z "$etime" ]] && return

        local days=0 hours=0 mins=0 secs=0
        # Format: DD-HH:MM:SS or HH:MM:SS or MM:SS
        if [[ "$etime" == *-* ]]; then
            days="${etime%%-*}"
            etime="${etime#*-}"
        fi
        # Count colons to determine format
        local colons
        colons=$(echo "$etime" | tr -cd ':' | wc -c)
        if [[ "$colons" -eq 2 ]]; then
            IFS=: read -r hours mins secs <<< "$etime"
        else
            IFS=: read -r mins secs <<< "$etime"
        fi
        # Strip leading zeros to avoid octal interpretation
        days=$((10#$days)) hours=$((10#$hours)) mins=$((10#$mins)) secs=$((10#$secs))
        echo $(( days*86400 + hours*3600 + mins*60 + secs ))
    fi
}

# Get memory usage (cross-platform)
get_used_memory_mb() {
    if [[ "$PLATFORM" == "linux" ]]; then
        free -m 2>/dev/null | awk '/Mem:/ {print $3}'
    else
        # macOS: use vm_stat
        local page_size
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        local pages_active pages_wired
        pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
        pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$4); print $4}')
        if [[ -n "$pages_active" && -n "$pages_wired" ]]; then
            echo $(( (pages_active + pages_wired) * page_size / 1048576 ))
        else
            echo "0"
        fi
    fi
}

# TTY marker for "no terminal" differs by platform
no_tty_marker() {
    if [[ "$PLATFORM" == "linux" ]]; then
        echo '?'
    else
        echo '??'
    fi
}

# ── Main logic ───────────────────────────────────────────────────────────────

verbose "claude-gc v${VERSION} — platform: ${PLATFORM}, min-age: ${MIN_AGE}s, max-age: ${MAX_AGE}s, max-daemon-age: ${MAX_DAEMON_AGE}s"
verbose ""

SELF_PID=$$
NO_TTY="$(no_tty_marker)"

# Step 1: Find claude processes with no controlling terminal
# Exclude: chroma-mcp (persistent vector DB), tmux (session manager), claude-gc itself
# Daemon processes (worker-service, mcp-server) are tracked separately for --max-daemon-age
declare -a ORPHAN_PIDS=()
declare -a DAEMON_PIDS=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $2}')
    tty=$(echo "$line" | awk '{print $7}')
    cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')

    # Skip if has a TTY
    [[ "$tty" != "$NO_TTY" ]] && continue

    # Skip excluded processes
    [[ "$cmd" == *chroma* ]] && continue
    [[ "$cmd" == *tmux* ]] && continue
    [[ "$cmd" == *claude-gc* ]] && continue

    # Skip self
    [[ "$pid" -eq "$SELF_PID" ]] && continue

    # Track daemons separately (subject to --max-daemon-age instead of --max-age)
    if [[ "$cmd" == *worker-service* ]] || [[ "$cmd" == *mcp-server* ]]; then
        DAEMON_PIDS+=("$pid")
        continue
    fi

    ORPHAN_PIDS+=("$pid")
done < <(ps aux 2>/dev/null | grep -i '[c]laude' || true)

if [[ ${#ORPHAN_PIDS[@]} -eq 0 ]]; then
    verbose "No orphaned claude processes found."
fi

verbose "Found ${#ORPHAN_PIDS[@]} candidate processes (no TTY, claude-related) + ${#DAEMON_PIDS[@]} daemon(s)"

# Step 2: Get active claude sessions — both terminal AND known daemon parents
# Include terminal sessions (pts/*) and background orchestrators (bun worker-service,
# node mcp-server) that legitimately spawn claude subagents
declare -a ACTIVE_PIDS=()

# Terminal claude sessions
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $2}')
    tty=$(echo "$line" | awk '{print $7}')
    [[ "$tty" == "$NO_TTY" ]] && continue
    ACTIVE_PIDS+=("$pid")
done < <(ps aux 2>/dev/null | grep -i '[c]laude' || true)

# Background daemon parents that legitimately own claude subagents
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $2}')
    ACTIVE_PIDS+=("$pid")
done < <(ps aux 2>/dev/null | grep -E 'bun.*worker-service|node.*mcp-server' | grep -v grep || true)

verbose "Found ${#ACTIVE_PIDS[@]} active claude sessions/daemons"

# Step 3: Filter — skip young processes and children of active sessions
is_child_of_active() {
    local check_pid="$1"
    local depth=0
    local current_pid="$check_pid"

    while [[ $depth -lt $PARENT_DEPTH ]]; do
        local parent
        parent=$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')
        [[ -z "$parent" || "$parent" == "0" || "$parent" == "1" ]] && return 1

        for active_pid in "${ACTIVE_PIDS[@]}"; do
            if [[ "$parent" == "$active_pid" ]]; then
                return 0
            fi
        done

        current_pid="$parent"
        (( depth++ )) || true
    done
    return 1
}

declare -a KILL_PIDS=()
MAX_AGE_KILLS=0

for pid in "${ORPHAN_PIDS[@]}"; do
    # Skip processes younger than min-age
    elapsed=$(get_elapsed_seconds "$pid")
    if [[ -n "$elapsed" && "$elapsed" -lt "$MIN_AGE" ]]; then
        verbose "  SKIP pid=$pid age=${elapsed}s (younger than ${MIN_AGE}s)"
        continue
    fi

    # Force-kill if older than max-age, regardless of parent chain
    if [[ -n "$elapsed" && "$elapsed" -ge "$MAX_AGE" ]]; then
        cmd_info=$(ps -o args= -p "$pid" 2>/dev/null || true)
        cmd_info="${cmd_info:0:80}"
        mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        mem_mb=$(( ${mem_rss:-0} / 1024 ))
        verbose "  FORCE-KILL pid=$pid age=${elapsed}s (exceeds max-age ${MAX_AGE}s) mem=${mem_mb}MB cmd=${cmd_info}"
        KILL_PIDS+=("$pid")
        (( MAX_AGE_KILLS++ )) || true
        continue
    fi

    # Skip if child of an active terminal session (walk parent chain)
    if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]] && is_child_of_active "$pid"; then
        verbose "  SKIP pid=$pid age=${elapsed:-?}s (child of active session)"
        continue
    fi

    # Get process info for display
    cmd_info=$(ps -o args= -p "$pid" 2>/dev/null || true)
    cmd_info="${cmd_info:0:80}"
    mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    mem_rss=${mem_rss:-0}
    mem_mb=$(( mem_rss / 1024 ))

    verbose "  KILL pid=$pid age=${elapsed:-?}s mem=${mem_mb}MB cmd=${cmd_info}"
    KILL_PIDS+=("$pid")
done

# Check daemon processes against --max-daemon-age
DAEMON_KILLS=0
for pid in "${DAEMON_PIDS[@]}"; do
    elapsed=$(get_elapsed_seconds "$pid")
    if [[ -n "$elapsed" && "$elapsed" -ge "$MAX_DAEMON_AGE" ]]; then
        cmd_info=$(ps -o args= -p "$pid" 2>/dev/null || true)
        cmd_info="${cmd_info:0:80}"
        mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        mem_mb=$(( ${mem_rss:-0} / 1024 ))
        verbose "  FORCE-KILL DAEMON pid=$pid age=${elapsed}s (exceeds max-daemon-age ${MAX_DAEMON_AGE}s) mem=${mem_mb}MB cmd=${cmd_info}"
        KILL_PIDS+=("$pid")
        (( DAEMON_KILLS++ )) || true
    else
        verbose "  SKIP DAEMON pid=$pid age=${elapsed:-?}s (within max-daemon-age ${MAX_DAEMON_AGE}s)"
    fi
done

if [[ ${#KILL_PIDS[@]} -eq 0 ]]; then
    verbose "No orphaned Claude processes to clean up after filtering."
fi

# Step 4+5: Kill orphaned Claude processes (if any)
if [[ ${#KILL_PIDS[@]} -gt 0 ]]; then
    KILL_COUNT=${#KILL_PIDS[@]}

    # Calculate total memory of targets
    TOTAL_RSS=0
    for pid in "${KILL_PIDS[@]}"; do
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        TOTAL_RSS=$(( TOTAL_RSS + ${rss:-0} ))
    done
    TOTAL_MB=$(( TOTAL_RSS / 1024 ))

    echo "Found $KILL_COUNT orphaned Claude process(es) using ~${TOTAL_MB}MB RAM"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would kill $KILL_COUNT Claude process(es)."
        log_msg "DRY RUN | Would kill $KILL_COUNT orphaned processes (~${TOTAL_MB}MB)"
    elif [[ "$FORCE" != true ]]; then
        echo ""
        read -rp "Kill $KILL_COUNT orphaned process(es)? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    if [[ "$DRY_RUN" != true ]]; then
        MEM_BEFORE=$(get_used_memory_mb)
        kill "${KILL_PIDS[@]}" 2>/dev/null || true
        sleep 2

        declare -a SURVIVORS=()
        for pid in "${KILL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                SURVIVORS+=("$pid")
            fi
        done

        if [[ ${#SURVIVORS[@]} -gt 0 ]]; then
            verbose "  ${#SURVIVORS[@]} process(es) survived SIGTERM, sending SIGKILL..."
            kill -9 "${SURVIVORS[@]}" 2>/dev/null || true
            sleep 1
        fi

        MEM_AFTER=$(get_used_memory_mb)
        FREED=$(( MEM_BEFORE - MEM_AFTER ))
        [[ "$FREED" -lt 0 ]] && FREED=0

        local override_info=""
        [[ $MAX_AGE_KILLS -gt 0 ]] && override_info=" ($MAX_AGE_KILLS max-age override(s))"
        [[ $DAEMON_KILLS -gt 0 ]] && override_info="${override_info} ($DAEMON_KILLS daemon(s))"
        echo "Killed $KILL_COUNT orphaned Claude process(es)${override_info} | Freed ~${FREED}MB RAM"
        log_msg "Killed $KILL_COUNT orphaned Claude processes${override_info} | Freed ~${FREED}MB RAM"
    fi
fi

# ── Step 6: Kill orphaned MCP child processes (python, uv, node, bun) ────────
# These are spawned by Claude sessions but not matched by 'claude' grep.
# Strategy: find processes whose parent is PID 1 (reparented orphans) or whose
# ancestor claude process no longer exists, that match known MCP patterns.

verbose ""
verbose "── Scanning for orphaned MCP child processes ──"

# Collect all living claude PIDs (both terminal and background)
declare -a ALL_CLAUDE_PIDS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ALL_CLAUDE_PIDS+=("$(echo "$line" | awk '{print $2}')")
done < <(ps aux 2>/dev/null | grep -i '[c]laude' | grep -v claude-gc || true)

# MCP process patterns - commands that indicate a Claude MCP server
# Matches: uv tool run/uvx with mcp, python running mcp servers, npm exec mcp,
# bun running claude plugins, node running mcp
MCP_PATTERNS=(
    'uv.*tool.*mcp'
    'uv.*uvx.*mcp'
    'uvx.*mcp'
    'python.*mcp'
    'python.*chroma'
    'node.*mcp'
    'node.*playwright-mcp'
    'npm.*exec.*mcp'
    'bun.*claude.*plugin'
    'bun.*worker-service'
)

# Build a single grep pattern
MCP_GREP_PATTERN=$(IFS='|'; echo "${MCP_PATTERNS[*]}")

declare -a MCP_KILL_PIDS=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $2}')
    tty=$(echo "$line" | awk '{print $7}')

    # Only target processes without a TTY
    [[ "$tty" != "$NO_TTY" ]] && continue

    # Skip self
    [[ "$pid" -eq "$SELF_PID" ]] && continue

    # Check if this is a daemon orchestrator
    cmd_check=$(ps -o args= -p "$pid" 2>/dev/null || true)
    is_daemon=false
    if [[ "$cmd_check" == *worker-service* ]] || [[ "$cmd_check" == *mcp-server* ]]; then
        is_daemon=true
    fi

    # Skip processes younger than min-age
    elapsed=$(get_elapsed_seconds "$pid")
    if [[ -n "$elapsed" && "$elapsed" -lt "$MIN_AGE" ]]; then
        verbose "  SKIP MCP pid=$pid age=${elapsed}s (too young)"
        continue
    fi

    # Daemon orchestrators: only kill if exceeding max-daemon-age
    if [[ "$is_daemon" == true ]]; then
        if [[ -n "$elapsed" && "$elapsed" -ge "$MAX_DAEMON_AGE" ]]; then
            cmd_info="${cmd_check:0:80}"
            mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
            mem_mb=$(( ${mem_rss:-0} / 1024 ))
            verbose "  FORCE-KILL MCP DAEMON pid=$pid age=${elapsed}s (exceeds max-daemon-age ${MAX_DAEMON_AGE}s) mem=${mem_mb}MB cmd=${cmd_info}"
            MCP_KILL_PIDS+=("$pid")
        else
            verbose "  SKIP MCP pid=$pid (${is_daemon:+daemon }within max-daemon-age ${MAX_DAEMON_AGE}s)"
        fi
        continue
    fi

    # Force-kill non-daemon MCP processes older than max-age, regardless of ancestry
    if [[ -n "$elapsed" && "$elapsed" -ge "$MAX_AGE" ]]; then
        cmd_info="${cmd_check:0:80}"
        mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        mem_mb=$(( ${mem_rss:-0} / 1024 ))
        verbose "  FORCE-KILL MCP pid=$pid age=${elapsed}s (exceeds max-age ${MAX_AGE}s) mem=${mem_mb}MB cmd=${cmd_info}"
        MCP_KILL_PIDS+=("$pid")
        continue
    fi

    # Check if any living claude process is an ancestor
    has_claude_ancestor=false
    current_pid="$pid"
    depth=0
    while [[ $depth -lt 5 ]]; do
        parent=$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')
        [[ -z "$parent" || "$parent" == "0" || "$parent" == "1" ]] && break

        for cpid in "${ALL_CLAUDE_PIDS[@]}"; do
            if [[ "$parent" == "$cpid" ]]; then
                has_claude_ancestor=true
                break 2
            fi
        done

        current_pid="$parent"
        (( depth++ )) || true
    done

    # Also check if any active terminal session is an ancestor
    if [[ "$has_claude_ancestor" == false && ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
        if is_child_of_active "$pid"; then
            has_claude_ancestor=true
        fi
    fi

    if [[ "$has_claude_ancestor" == false ]]; then
        cmd_info="${cmd_check:0:80}"
        mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        mem_mb=$(( ${mem_rss:-0} / 1024 ))

        verbose "  KILL MCP pid=$pid age=${elapsed:-?}s mem=${mem_mb}MB cmd=${cmd_info}"
        MCP_KILL_PIDS+=("$pid")
    else
        verbose "  SKIP MCP pid=$pid age=${elapsed:-?}s (has living claude ancestor)"
    fi
# Only match processes owned by current user (avoid killing Cursor/other tools' MCP servers)
done < <(ps aux 2>/dev/null | awk -v user="$(whoami)" '$1 == user' | grep -iE "$MCP_GREP_PATTERN" | grep -v grep | grep -v claude-gc || true)

if [[ ${#MCP_KILL_PIDS[@]} -gt 0 ]]; then
    MCP_KILL_COUNT=${#MCP_KILL_PIDS[@]}

    MCP_TOTAL_RSS=0
    for pid in "${MCP_KILL_PIDS[@]}"; do
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        MCP_TOTAL_RSS=$(( MCP_TOTAL_RSS + ${rss:-0} ))
    done
    MCP_TOTAL_MB=$(( MCP_TOTAL_RSS / 1024 ))

    echo "Found $MCP_KILL_COUNT orphaned MCP process(es) using ~${MCP_TOTAL_MB}MB RAM"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would kill $MCP_KILL_COUNT MCP process(es)."
        log_msg "DRY RUN | Would kill $MCP_KILL_COUNT orphaned MCP processes (~${MCP_TOTAL_MB}MB)"
    else
        MEM_BEFORE_MCP=$(get_used_memory_mb)

        kill "${MCP_KILL_PIDS[@]}" 2>/dev/null || true
        sleep 2

        # SIGKILL survivors
        for pid in "${MCP_KILL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        done

        MEM_AFTER_MCP=$(get_used_memory_mb)
        MCP_FREED=$(( MEM_BEFORE_MCP - MEM_AFTER_MCP ))
        [[ "$MCP_FREED" -lt 0 ]] && MCP_FREED=0

        echo "Killed $MCP_KILL_COUNT orphaned MCP process(es) | Freed ~${MCP_FREED}MB RAM"
        log_msg "Killed $MCP_KILL_COUNT orphaned MCP processes (~${MCP_TOTAL_MB}MB) | Freed ~${MCP_FREED}MB RAM"
    fi
else
    verbose "No orphaned MCP processes found."
fi
