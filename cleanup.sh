#!/usr/bin/env bash
# claude-gc — Automatic cleanup for orphaned Claude Code processes
# https://github.com/kojott/claude-gc
#
# Claude Code spawns child processes (subagents, MCP servers, Task workers)
# that don't get cleaned up when terminals close. Each orphan eats ~220MB RAM.
# This script safely identifies and kills them.
#
# Usage: claude-gc.sh [OPTIONS]
#   --dry-run       Show what would be killed without killing
#   --verbose       Print detailed output
#   --force         Skip interactive confirmation (auto-enabled when no TTY)
#   --min-age SECS  Minimum process age in seconds (default: 1800 = 30min)
#   --log PATH      Log file path (default: ~/.claude/claude-gc.log)
#   --no-log        Disable logging
#   -h, --help      Show this help message
#
# Environment variables:
#   CLAUDE_GC_MIN_AGE   Override default min-age (seconds)
#   CLAUDE_GC_LOG       Override default log path

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

VERSION="1.0.0"
MIN_AGE="${CLAUDE_GC_MIN_AGE:-1800}"
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
  --dry-run       Show what would be killed without killing
  --verbose       Print detailed output
  --force         Skip interactive confirmation
  --min-age SECS  Minimum process age in seconds (default: 1800)
  --log PATH      Log file path (default: ~/.claude/claude-gc.log)
  --no-log        Disable logging
  -h, --help      Show this help message

Environment variables:
  CLAUDE_GC_MIN_AGE   Override default min-age (seconds)
  CLAUDE_GC_LOG       Override default log path

Examples:
  claude-gc.sh --dry-run --verbose    # Preview what would be cleaned
  claude-gc.sh --force                # Clean without confirmation (cron use)
  claude-gc.sh --min-age 900          # Kill processes older than 15 minutes
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --verbose)   VERBOSE=true; shift ;;
        --force)     FORCE=true; shift ;;
        --min-age)   MIN_AGE="$2"; shift 2 ;;
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

verbose "claude-gc v${VERSION} — platform: ${PLATFORM}, min-age: ${MIN_AGE}s"
verbose ""

SELF_PID=$$
NO_TTY="$(no_tty_marker)"

# Step 1: Find claude processes with no controlling terminal
# Exclude: chroma-mcp (persistent vector DB), tmux (session manager), claude-gc itself
declare -a ORPHAN_PIDS=()

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

    ORPHAN_PIDS+=("$pid")
done < <(ps aux 2>/dev/null | grep -i '[c]laude' || true)

if [[ ${#ORPHAN_PIDS[@]} -eq 0 ]]; then
    verbose "No orphaned claude processes found."
    exit 0
fi

verbose "Found ${#ORPHAN_PIDS[@]} candidate processes (no TTY, claude-related)"

# Step 2: Get active terminal claude sessions (have a TTY like pts/*)
declare -a ACTIVE_PIDS=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $2}')
    tty=$(echo "$line" | awk '{print $7}')
    [[ "$tty" == "$NO_TTY" ]] && continue
    ACTIVE_PIDS+=("$pid")
done < <(ps aux 2>/dev/null | grep -i '[c]laude' || true)

verbose "Found ${#ACTIVE_PIDS[@]} active terminal claude sessions"

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
        ((depth++))
    done
    return 1
}

declare -a KILL_PIDS=()

for pid in "${ORPHAN_PIDS[@]}"; do
    # Skip processes younger than min-age
    elapsed=$(get_elapsed_seconds "$pid")
    if [[ -n "$elapsed" && "$elapsed" -lt "$MIN_AGE" ]]; then
        verbose "  SKIP pid=$pid age=${elapsed}s (younger than ${MIN_AGE}s)"
        continue
    fi

    # Skip if child of an active terminal session (walk parent chain)
    if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]] && is_child_of_active "$pid"; then
        verbose "  SKIP pid=$pid (child of active terminal session)"
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

if [[ ${#KILL_PIDS[@]} -eq 0 ]]; then
    verbose "No orphaned processes to clean up after filtering."
    exit 0
fi

# Step 4: Confirm or kill
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
    echo "[DRY RUN] Would kill $KILL_COUNT process(es). Use without --dry-run to clean up."
    log_msg "DRY RUN | Would kill $KILL_COUNT orphaned processes (~${TOTAL_MB}MB)"
    exit 0
fi

if [[ "$FORCE" != true ]]; then
    echo ""
    read -rp "Kill $KILL_COUNT orphaned process(es)? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Step 5: Kill — SIGTERM first, then SIGKILL
MEM_BEFORE=$(get_used_memory_mb)

kill "${KILL_PIDS[@]}" 2>/dev/null || true
sleep 2

# Check which ones survived, SIGKILL those
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

echo "Killed $KILL_COUNT orphaned process(es) | Freed ~${FREED}MB RAM"
log_msg "Killed $KILL_COUNT orphaned processes | Freed ~${FREED}MB RAM"
