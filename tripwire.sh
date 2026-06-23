#!/bin/bash
# tripwire — system overload early-warning and intervention system
# Monitors key metrics and takes escalating action before macOS crashes.
# Run via launchd: ~/Library/LaunchAgents/com.thrivbe.tripwire.plist

set -e

# ── Configuration ──────────────────────────────────────────────
LOG_DIR="${HOME}/.local/var/tripwire"
LOG_FILE="${LOG_DIR}/tripwire.log"
STATE_FILE="${LOG_DIR}/state.json"
INTERVAL="${TRIPWIRE_INTERVAL:-30}"  # seconds between checks
COOLDOWN_ESCALATE=300                # 5 min between escalations
COOLDOWN_ACTION=120                  # 2 min between same-phase actions
BOOT_GRACE_PERIOD=300                # 5 min after boot, only warn

# Thresholds
WARN_LOAD=20
WARN_SWAP_MB=5120       # 5 GB
WARN_FREE_RAM_PCT=15
WARN_PROC_COUNT=800

CRIT_LOAD=50
CRIT_SWAP_MB=15360      # 15 GB
CRIT_FREE_RAM_PCT=8
CRIT_FSEVENTS_CPU=80    # fseventsd CPU% — indexing storm

EMERG_LOAD=100
EMERG_SWAP_MB=25600     # 25 GB
EMERG_FREE_RAM_PCT=3
EMERG_TEMP_C=85         # CPU temperature (if available)

# ── Setup ──────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

notify() {
    local title="$1" body="$2"
    osascript -e "display notification \"$body\" with title \"Tripwire: $title\" sound name \"Ping\"" 2>/dev/null || true
}

# ── Metrics collection ─────────────────────────────────────────
get_load() {
    sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' | tr -d '{}' || echo "999"
}

get_swap_mb() {
    # vm.swapusage: total = 2048.00M  used = 512.00M  free = 1536.00M
    sysctl vm.swapusage 2>/dev/null | grep -o 'used = [0-9.]*M' | grep -o '[0-9.]*' || echo "0"
}

get_free_ram_pct() {
    local free=$(vm_stat 2>/dev/null | awk '/Pages free:/ {gsub(/\./, ""); print $NF}')
    local total=$(sysctl -n hw.memsize 2>/dev/null)
    if [ -n "$free" ] && [ -n "$total" ]; then
        # pages are 16384 bytes on Apple Silicon
        local free_bytes=$((free * 16384))
        echo $((free_bytes * 100 / total))
    else
        echo "100"
    fi
}

get_proc_count() {
    ps ax -o pid= 2>/dev/null | wc -l | tr -d ' '
}

get_fsevents_cpu() {
    # Check if fseventsd is burning CPU (indexing storm indicator)
    ps ax -o pcpu=,comm= 2>/dev/null | awk '$2 == "fseventsd" {sum+=$1} END {printf "%.0f", sum}'
}

get_mds_cpu() {
    # Spotlight indexing CPU
    ps ax -o pcpu=,comm= 2>/dev/null | awk '$2 ~ /^(mds|mdsync|mds_stores|mdworker)/ {sum+=$1} END {printf "%.0f", sum}'
}

get_cpu_temp() {
    # Try to get CPU temperature (requires sudo on some Macs)
    sudo powermetrics --samplers smc -i 1 -n 1 2>/dev/null | grep -i "CPU die" | grep -o '[0-9.]*' | head -1 || echo "0"
}

claude_session_count() {
    ps ax -o comm= 2>/dev/null | grep -c '^claude$' || echo "0"
}

# ── Phase detection ────────────────────────────────────────────
detect_phase() {
    local load="$1" swap="$2" free_ram="$3" procs="$4" fsevents="$5"

    if [ "${load%.*}" -ge "$EMERG_LOAD" ] || \
       [ "${swap%.*}" -ge "$EMERG_SWAP_MB" ] || \
       [ "$free_ram" -le "$EMERG_FREE_RAM_PCT" ]; then
        echo "emergency"
        return
    fi

    if [ "${load%.*}" -ge "$CRIT_LOAD" ] || \
       [ "${swap%.*}" -ge "$CRIT_SWAP_MB" ] || \
       [ "$free_ram" -le "$CRIT_FREE_RAM_PCT" ] || \
       [ "${fsevents%.*}" -ge "$CRIT_FSEVENTS_CPU" ]; then
        echo "critical"
        return
    fi

    if [ "${load%.*}" -ge "$WARN_LOAD" ] || \
       [ "${swap%.*}" -ge "$WARN_SWAP_MB" ] || \
       [ "$free_ram" -le "$WARN_FREE_RAM_PCT" ] || \
       [ "$procs" -ge "$WARN_PROC_COUNT" ]; then
        echo "warning"
        return
    fi

    echo "ok"
}

# ── Actions ────────────────────────────────────────────────────
action_warning() {
    local load="$1" swap="$2" free_ram="$3" procs="$4"
    log "⚠️  WARNING — load=$load swap=${swap}MB free_ram=${free_ram}% procs=$procs"
    notify "⚠️ Warning" "Load: $load | Swap: ${swap}MB | Free RAM: ${free_ram}% | Procs: $procs"
    
    # Record for learning & show recommendations every 10 min
    if [ $((now - last_action)) -ge 600 ]; then
        python3 "$HOME/.local/bin/tripwire-brain.py" snapshot warning 2>/dev/null &
    fi
}

action_critical() {
    local load="$1" swap="$2" free_ram="$3" fsevents="$4" mds="$5"
    log "🔴 CRITICAL — load=$load swap=${swap}MB free_ram=${free_ram}% fsevents_cpu=${fsevents}% mds_cpu=${mds}%"

    # Kill Spotlight indexing if it's the culprit
    if [ "${fsevents%.*}" -ge "$CRIT_FSEVENTS_CPU" ] || [ "${mds%.*}" -ge 50 ]; then
        log "  → Disabling Spotlight indexing (indexing storm detected)"
        mdutil -a -i off 2>/dev/null || true
    fi

    # Run the brain: analyze + show popup with recommendations
    log "  → Running tripwire-brain analysis..."
    python3 "$HOME/.local/bin/tripwire-brain.py" snapshot critical 2>/dev/null &
    
    # Show popup dialog with actionable recommendations
    python3 "$HOME/.local/bin/tripwire-brain.py" popup 2>/dev/null &

    # Also send a notification
    notify "🔴 Critical — Recommendations" "Popup opening with actions you can take. Load: $load | RAM: ${free_ram}%"
}

action_emergency() {
    local load="$1" swap="$2" free_ram="$3" claude_count="$4"
    log "💀 EMERGENCY — load=$load swap=${swap}MB free_ram=${free_ram}% claude_sessions=$claude_count"

    # Run brain snapshot before we kill things
    python3 "$HOME/.local/bin/tripwire-brain.py" snapshot emergency 2>/dev/null &

    # Show urgent popup first
    python3 "$HOME/.local/bin/tripwire-brain.py" popup 2>/dev/null &
    sleep 1  # Give popup time to appear

    # Graceful: send SIGTERM to Claude processes first
    log "  → Sending SIGTERM to all Claude processes"
    pkill -TERM -f '/Users/robinsverd/.local/bin/claude' 2>/dev/null || true
    sleep 3

    # If still alive, force kill
    local remaining=$(claude_session_count)
    if [ "$remaining" -gt 0 ]; then
        log "  → Force killing $remaining remaining Claude processes"
        pkill -KILL -f '/Users/robinsverd/.local/bin/claude' 2>/dev/null || true
    fi

    # Also kill stuck MCP servers (npm exec processes)
    log "  → Killing MCP server processes"
    pkill -TERM -f 'npm exec @' 2>/dev/null || true

    log "  → Emergency actions complete. System should stabilize shortly."
    notify "💀 Emergency actions taken" "Claude sessions killed. Monitor system — reboot if still sluggish."
}

# ── State management ───────────────────────────────────────────
read_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo '{"last_phase":"ok","last_escalation":0,"last_action_ok":0,"last_action_warning":0,"last_action_critical":0,"last_action_emergency":0,"boot_time":'$(date +%s)'}'
    fi
}

write_state() {
    echo "$1" > "$STATE_FILE"
}

# ── Boot grace period check ────────────────────────────────────
in_grace_period() {
    local boot_time="$1" now="$2"
    [ $((now - boot_time)) -lt "$BOOT_GRACE_PERIOD" ]
}

# ── Main loop ──────────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "🛡️  Tripwire started (interval=${INTERVAL}s)"
log "   Warn:  load>${WARN_LOAD} | swap>${WARN_SWAP_MB}MB | ram<${WARN_FREE_RAM_PCT}% | procs>${WARN_PROC_COUNT}"
log "   Crit:  load>${CRIT_LOAD} | swap>${CRIT_SWAP_MB}MB | ram<${CRIT_FREE_RAM_PCT}% | fsevents>${CRIT_FSEVENTS_CPU}%"
log "   Emerg: load>${EMERG_LOAD} | swap>${EMERG_SWAP_MB}MB | ram<${EMERG_FREE_RAM_PCT}%"
log "   Grace period: ${BOOT_GRACE_PERIOD}s after boot"

while true; do
    state=$(read_state)
    now=$(date +%s)

    # Collect metrics
    load=$(get_load)
    swap=$(get_swap_mb)
    free_ram=$(get_free_ram_pct)
    procs=$(get_proc_count)
    fsevents=$(get_fsevents_cpu)
    mds=$(get_mds_cpu)
    claude_count=$(claude_session_count)
    phase=$(detect_phase "$load" "$swap" "$free_ram" "$procs" "$fsevents")

    boot_time=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('boot_time',0))" 2>/dev/null || echo "0")
    last_phase=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_phase','ok'))" 2>/dev/null || echo "ok")
    last_escalation=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_escalation',0))" 2>/dev/null || echo "0")
    last_action=$(echo "$state" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('last_action_${phase}',0))" 2>/dev/null || echo "0")

    # Only log state changes to avoid noise
    if [ "$phase" != "$last_phase" ] || [ "$phase" != "ok" ]; then
        log "[$(printf '%-6s' $phase)] load=${load} swap=${swap}MB free_ram=${free_ram}% procs=${procs} fsevents=${fsevents}% mds=${mds}% claude=${claude_count}"
    fi

    # Act only if phase changed OR enough cooldown passed for this phase
    if [ "$phase" != "ok" ]; then
        # Check boot grace period — only warn during grace
        if in_grace_period "$boot_time" "$now"; then
            if [ "$phase" != "$last_phase" ]; then
                grace_remaining=$((BOOT_GRACE_PERIOD - (now - boot_time)))
                log "  🕐 Boot grace period active (${grace_remaining}s remaining) — suppressing ${phase} actions"
                notify "🕐 Boot grace" "System stabilizing (${grace_remaining}s remaining). Phase ${phase} suppressed."
            fi
        elif [ "$phase" != "$last_phase" ] || [ $((now - last_escalation)) -ge "$COOLDOWN_ESCALATE" ] || \
             ([ $((now - last_action)) -ge "$COOLDOWN_ACTION" ] && [ "$phase" != "ok" ]); then

            case "$phase" in
                warning)
                    action_warning "$load" "$swap" "$free_ram" "$procs"
                    ;;
                critical)
                    action_critical "$load" "$swap" "$free_ram" "$fsevents" "$mds"
                    ;;
                emergency)
                    action_emergency "$load" "$swap" "$free_ram" "$claude_count"
                    ;;
            esac

            last_escalation=$now
            last_action=$now
        fi
    fi

    # Persist state
    new_state=$(echo "$state" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d['last_phase'] = '$phase'
d['last_escalation'] = $last_escalation
d['last_action_${phase}'] = $last_action
d['last_check'] = $now
print(json.dumps(d))
" 2>/dev/null)
    write_state "$new_state"

    sleep "$INTERVAL"
done
