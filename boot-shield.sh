#!/bin/bash
# boot-shield — runs at login to suppress the boot storm
# Disables Spotlight temporarily, logs boot state, re-enables after delay

LOG="$HOME/.local/var/tripwire/boot-shield.log"
GRACE=300  # 5 minutes

mkdir -p "$(dirname "$LOG")"

echo "[$(date)] Boot-shield: system booted, starting grace period (${GRACE}s)" >> "$LOG"

# Immediately suppress Spotlight to prevent indexing storm
echo "[$(date)] Boot-shield: disabling Spotlight temporarily" >> "$LOG"
mdutil -a -i off 2>/dev/null

# Log what we're dealing with
echo "[$(date)] Boot-shield: $(ps ax -o pid= | wc -l | tr -d ' ') processes at boot" >> "$LOG"
echo "[$(date)] Boot-shield: $(ps ax -o comm= | grep -c '^claude$' || echo 0) Claude processes at boot" >> "$LOG"

# Wait for the grace period
sleep "$GRACE"

# Check if system has stabilized
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' | tr -d '{}')
load_int=${load%.*}

if [ "$load_int" -lt 30 ]; then
    echo "[$(date)] Boot-shield: load is ${load} — stable, re-enabling Spotlight" >> "$LOG"
    mdutil -a -i on 2>/dev/null
else
    echo "[$(date)] Boot-shield: load is ${load} — still high, keeping Spotlight off" >> "$LOG"
    # Wait another 5 min and try again
    sleep 300
    load2=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' | tr -d '{}')
    if [ "${load2%.*}" -lt 30 ]; then
        echo "[$(date)] Boot-shield: load dropped to ${load2} — re-enabling Spotlight" >> "$LOG"
        mdutil -a -i on 2>/dev/null
    else
        echo "[$(date)] Boot-shield: load still ${load2} — leaving Spotlight off (re-enable manually: mdutil -a -i on)" >> "$LOG"
    fi
fi
