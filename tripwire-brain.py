#!/usr/bin/env python3
"""
tripwire-brain — intelligent process analysis and recommendation engine.
Learns which processes are safe to kill, builds personal profiles,
and generates actionable recommendations when the system is overloaded.
"""

import json
import os
import sqlite3
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path.home()
TRIPWIRE_DIR = HOME / ".local/var/tripwire"
DB_PATH = TRIPWIRE_DIR / "brain.db"
STATE_PATH = TRIPWIRE_DIR / "state.json"

# ── Process Safety Classification ──────────────────────────────

# These processes are the backbone — never suggest killing them
SYSTEM_CRITICAL = {
    "kernel_task", "launchd", "WindowServer", "loginwindow",
    "coreaudiod", "bluetoothd", "airportd", "configd",
    "syslogd", "securityd", "trustd", "cfprefsd",
    "distnoted", "notifyd", "logd", "UserEventAgent",
    "systemstats", "powerd", "thermald", "opendirectoryd",
    "AppleIDAuthAgent", "kextd", "diskarbitrationd",
}

# User-critical — keep these alive
USER_CRITICAL = {
    "cmux", "Ghostty", "Terminal", "iTerm2", "Finder",
    "SystemUIServer", "Dock", "ControlCenter", "NotificationCenter",
    "Spotlight", "TextInputMenuAgent", "OSDUIHelper",
    "coreautha", "secd", "keychain",
}

# Always safe to suggest closing if they're heavy
SAFE_TO_KILL = {
    "Google Chrome Helper (Renderer)", "Google Chrome Helper",
    "Google Chrome", "Beeper Desktop", "Beeper Helper (Renderer)",
    "Microsoft Teams", "Slack", "Discord", "Spotify",
    "zoom.us", "WhatsApp", "Telegram Desktop",
    "Xcode", "Simulator", "Android Studio",
    "Docker Desktop", "Docker",
}

# Medium — ask before killing, but candidates when in trouble
ASK_BEFORE_KILL = {
    "claude", "codex", "node", "npm exec",
    "next-server", "python", "uv",
    "Cursor", "Visual Studio Code", "Code",
}

# Auto-kill on sight when overloaded (stuck/zombie processes)
AUTO_KILL_ON_SIGHT = {
    "npm exec @calcom/cal-mcp",
    "npm exec @stripe/mcp",
    # Any npm exec with > 30% CPU gets flagged
}

def classify_process(name, cpu_pct, mem_mb):
    """Classify a process into a safety category."""
    name_clean = name.strip()

    # Check exact matches
    if name_clean in SYSTEM_CRITICAL:
        return "system"
    if name_clean in USER_CRITICAL:
        return "user-critical"
    if name_clean in SAFE_TO_KILL:
        return "safe-to-kill"
    if name_clean in ASK_BEFORE_KILL:
        return "ask-first"

    # Pattern matching
    if name_clean.startswith("/System/"):
        return "system"
    if name_clean.startswith("/usr/libexec/"):
        return "system"
    if "Chrome" in name_clean or "chrome" in name_clean:
        return "safe-to-kill"
    if "npm exec" in name_clean:
        return "safe-to-kill" if cpu_pct > 30 else "ask-first"
    if name_clean.endswith("mcp") or "mcp-server" in name_clean:
        return "safe-to-kill" if cpu_pct > 30 else "ask-first"
    if "node" in name_clean.lower():
        return "ask-first"

    return "unknown"


def get_processes():
    """Get all processes with CPU and memory, classified."""
    try:
        result = subprocess.run(
            ["ps", "ax", "-o", "pid=,pcpu=,rss=,comm="],
            capture_output=True, text=True, timeout=5
        )
    except subprocess.TimeoutExpired:
        return []

    processes = []
    for line in result.stdout.strip().split("\n"):
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            cpu = float(parts[1])
            rss_kb = int(parts[2])
            name = parts[3]
            mem_mb = rss_kb / 1024
        except (ValueError, IndexError):
            continue

        category = classify_process(name, cpu, mem_mb)
        processes.append({
            "pid": pid,
            "name": name,
            "cpu_pct": cpu,
            "mem_mb": mem_mb,
            "category": category,
        })

    return processes


# ── SQLite Learning Database ───────────────────────────────────

def init_db():
    """Initialize the learning database."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    c = conn.cursor()

    c.execute("""
        CREATE TABLE IF NOT EXISTS process_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            pid INTEGER NOT NULL,
            name TEXT NOT NULL,
            cpu_pct REAL,
            mem_mb REAL,
            category TEXT,
            phase TEXT,
            load_avg REAL,
            swap_mb REAL,
            free_ram_pct INTEGER
        )
    """)

    c.execute("""
        CREATE TABLE IF NOT EXISTS kill_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            pid INTEGER NOT NULL,
            name TEXT NOT NULL,
            reason TEXT,
            load_before REAL,
            load_after REAL,
            was_helpful INTEGER  -- 1=yes, 0=no, NULL=unknown
        )
    """)

    c.execute("""
        CREATE TABLE IF NOT EXISTS session_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            event_type TEXT NOT NULL,  -- 'crash', 'reboot', 'tripwire_escalation', 'manual_kill'
            phase TEXT,
            load_avg REAL,
            swap_mb REAL,
            free_ram_pct INTEGER,
            proc_count INTEGER,
            note TEXT
        )
    """)

    c.execute("""
        CREATE TABLE IF NOT EXISTS process_scores (
            name TEXT PRIMARY KEY,
            kill_score REAL DEFAULT 0.0,    -- -1 to 1: negative = harmful to kill, positive = good to kill
            times_killed INTEGER DEFAULT 0,
            times_helpful INTEGER DEFAULT 0,
            times_not_helpful INTEGER DEFAULT 0,
            avg_cpu_when_overloaded REAL,
            avg_mem_when_overloaded REAL,
            last_seen REAL,
            last_killed REAL
        )
    """)

    conn.commit()
    return conn


def record_snapshot(conn, phase, load, swap, free_ram):
    """Record current process state into the database for learning."""
    procs = get_processes()
    now = time.time()

    c = conn.cursor()
    for p in procs:
        if p["cpu_pct"] < 1.0 and p["mem_mb"] < 50:
            continue  # skip trivial processes to save space
        c.execute(
            """INSERT INTO process_history 
               (timestamp, pid, name, cpu_pct, mem_mb, category, phase, load_avg, swap_mb, free_ram_pct)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (now, p["pid"], p["name"], p["cpu_pct"], p["mem_mb"],
             p["category"], phase, load, swap, free_ram)
        )

    # Update process scores
    for p in procs:
        if p["cpu_pct"] >= 5 or p["mem_mb"] >= 200:
            c.execute(
                """INSERT INTO process_scores (name, avg_cpu_when_overloaded, avg_mem_when_overloaded, last_seen)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(name) DO UPDATE SET
                   avg_cpu_when_overloaded = (avg_cpu_when_overloaded * 0.7 + ? * 0.3),
                   avg_mem_when_overloaded = (avg_mem_when_overloaded * 0.7 + ? * 0.3),
                   last_seen = ?""",
                (p["name"], p["cpu_pct"], p["mem_mb"], now,
                 p["cpu_pct"], p["mem_mb"], now)
            )

    conn.commit()


def record_kill(conn, pid, name, reason, load_before):
    """Record that a process was killed."""
    c = conn.cursor()
    c.execute(
        """INSERT INTO kill_events (timestamp, pid, name, reason, load_before, was_helpful)
           VALUES (?, ?, ?, ?, ?, NULL)""",
        (time.time(), pid, name, reason, load_before)
    )

    c.execute(
        """INSERT INTO process_scores (name, times_killed, last_killed)
           VALUES (?, 1, ?)
           ON CONFLICT(name) DO UPDATE SET
           times_killed = times_killed + 1,
           last_killed = ?""",
        (name, time.time(), time.time())
    )
    conn.commit()


def record_session_event(conn, event_type, phase, load, swap, free_ram, procs, note=""):
    """Record a session event (crash, reboot, escalation)."""
    c = conn.cursor()
    c.execute(
        """INSERT INTO session_events 
           (timestamp, event_type, phase, load_avg, swap_mb, free_ram_pct, proc_count, note)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (time.time(), event_type, phase, load, swap, free_ram, procs, note)
    )
    conn.commit()


# ── Recommendation Engine ──────────────────────────────────────

def get_recommendations(phase="critical"):
    """Generate actionable recommendations based on current state and history."""
    procs = get_processes()
    conn = init_db()

    recommendations = []
    total_freed_ram = 0
    total_freed_cpu = 0

    # Sort by impact (CPU + RAM combined)
    by_impact = sorted(procs, key=lambda p: p["cpu_pct"] + p["mem_mb"] / 100, reverse=True)

    # Group processes for recommendations
    chrome_tabs = [p for p in by_impact if "Chrome Helper (Renderer)" in p["name"]]
    mcp_servers = [p for p in by_impact if "npm exec" in p["name"] or "mcp" in p["name"].lower()]
    heavy_apps = [p for p in by_impact if p["category"] == "safe-to-kill" and p["mem_mb"] > 200]
    stuck_procs = [p for p in by_impact if p["cpu_pct"] > 50 and p["category"] != "system"]
    top_hogs = [p for p in by_impact if (p["cpu_pct"] > 20 or p["mem_mb"] > 500) and p["category"] not in ("system", "user-critical")]

    # ── Recommendation 1: Chrome tabs ──
    if len(chrome_tabs) > 20:
        chrome_ram = sum(p["mem_mb"] for p in chrome_tabs)
        recommendations.append({
            "id": "chrome_tabs",
            "title": f"Close unused Chrome tabs",
            "detail": f"{len(chrome_tabs)} tabs using {chrome_ram:.0f} MB RAM. Consider closing tabs you don't need.",
            "impact": f"~{chrome_ram * 0.5:.0f} MB",
            "action": "manual",
            "command": None,
            "danger": "low",
        })

    # ── Recommendation 2: Stuck MCP servers ──
    if stuck_procs:
        stuck_info = []
        kill_pids = []
        for p in stuck_procs[:5]:
            stuck_info.append(f"{p['name'][:40]} ({p['cpu_pct']:.0f}% CPU)")
            kill_pids.append(str(p["pid"]))
        recommendations.append({
            "id": "stuck_procs",
            "title": f"Kill {len(stuck_procs)} stuck process(es)",
            "detail": " | ".join(stuck_info),
            "impact": f"~{sum(p['cpu_pct'] for p in stuck_procs):.0f}% CPU freed",
            "action": "kill",
            "command": f"kill -9 {' '.join(kill_pids)}",
            "danger": "medium",
        })

    # ── Recommendation 3: Heavy MCP servers in bulk ──
    if mcp_servers:
        mcp_ram = sum(p["mem_mb"] for p in mcp_servers)
        if mcp_ram > 1000:
            recommendations.append({
                "id": "mcp_servers",
                "title": f"Restart MCP servers ({len(mcp_servers)})",
                "detail": f"MCP servers using {mcp_ram:.0f} MB. These auto-respawn so safe to kill.",
                "impact": f"~{mcp_ram * 0.7:.0f} MB",
                "action": "kill_all_mcp",
                "command": "pkill -f 'npm exec @'",
                "danger": "low",
            })

    # ── Recommendation 4: Heavy apps ──
    if heavy_apps:
        for p in heavy_apps[:3]:
            recommendations.append({
                "id": f"app_{p['pid']}",
                "title": f"Close {p['name'][:40]}",
                "detail": f"Using {p['mem_mb']:.0f} MB RAM, {p['cpu_pct']:.0f}% CPU",
                "impact": f"~{p['mem_mb']:.0f} MB",
                "action": "manual",
                "command": None,
                "danger": "low",
            })

    # ── Recommendation 5: Top CPU hogs warning ──
    if top_hogs:
        hog_list = "\n".join(
            f"  • {p['name'][:50]} — {p['cpu_pct']:.0f}% CPU, {p['mem_mb']:.0f} MB"
            for p in top_hogs[:8]
        )
        recommendations.append({
            "id": "top_hogs",
            "title": "Top resource consumers right now",
            "detail": hog_list,
            "impact": "informational",
            "action": "info",
            "command": None,
            "danger": "none",
        })

    # ── Recommendation 6: Reboot suggestion (emergency only) ──
    if phase == "emergency":
        # Check session history for recent reboots
        c = conn.cursor()
        c.execute(
            "SELECT COUNT(*) FROM session_events WHERE event_type='crash' AND timestamp > ?",
            (time.time() - 86400,)  # last 24h
        )
        recent_crashes = c.fetchone()[0]

        if recent_crashes > 0:
            note = f"({recent_crashes} crash(es) in the last 24h)"
        else:
            note = ""

        recommendations.insert(0, {
            "id": "reboot",
            "title": "🔄 Reboot your Mac",
            "detail": f"System critically overloaded. A reboot will clear swap and stop all runaway processes. {note}",
            "impact": "Full reset — 33 GB swap cleared",
            "action": "reboot",
            "command": "sudo shutdown -r now",
            "danger": "high",
        })

    conn.close()
    return recommendations


# ── Popup Dialog ───────────────────────────────────────────────

def show_popup(phase, load, swap, free_ram, procs, recommendations):
    """Show an actionable popup dialog using osascript."""
    rec_text = ""
    for i, r in enumerate(recommendations[:6], 1):
        danger_icon = {"low": "🟢", "medium": "🟡", "high": "🔴", "none": "ℹ️"}.get(r["danger"], "⚪")
        rec_text += f"{danger_icon} {r['title']}\n"
        rec_text += f"   {r['detail'][:120]}\n"
        if r.get("impact") and r["impact"] != "informational":
            rec_text += f"   Impact: {r['impact']}\n"
        rec_text += "\n"

    # Escape for AppleScript
    msg = (f"TRIPWIRE: {phase.upper()}\n"
           f"Load: {load:.1f} | Swap: {swap:.0f}MB | RAM free: {free_ram}%\n"
           f"Processes: {procs}\n\n"
           f"── RECOMMENDED ACTIONS ──\n\n{rec_text}\n"
           f"Open Terminal and run: claude-kill --soft")

    msg_escaped = msg.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

    apple_script = f'''
    display dialog "{msg_escaped}" \
        with title "Tripwire — System Overload" \
        buttons {{"Dismiss", "Run Diagnostic", "Kill Claude Sessions"}} \
        default button "Dismiss" \
        with icon caution
    '''

    try:
        result = subprocess.run(
            ["osascript", "-e", apple_script],
            capture_output=True, text=True, timeout=10
        )
        choice = result.stdout.strip()
        if "Kill Claude" in choice:
            subprocess.run(["pkill", "-TERM", "-f", f"{HOME}/.local/bin/claude"])
            return "killed_claude"
        elif "Diagnostic" in choice:
            return "diagnostic"
    except Exception:
        pass

    return "dismissed"


# ── Recent Crash Detection ─────────────────────────────────────

def detect_recent_crash(conn):
    """Check if we just restarted — detect a crash/reboot event."""
    c = conn.cursor()
    c.execute(
        "SELECT timestamp, event_type FROM session_events ORDER BY timestamp DESC LIMIT 1"
    )
    last = c.fetchone()

    # Check if system uptime is very recent
    try:
        result = subprocess.run(["sysctl", "-n", "kern.boottime"],
                                capture_output=True, text=True)
        # kern.boottime: { sec = 1234567890, usec = 0 } ...
        import re
        match = re.search(r'sec\s*=\s*(\d+)', result.stdout)
        if match:
            boot_time = int(match.group(1))
            now = int(time.time())
            uptime = now - boot_time
            if uptime < 600:  # booted in last 10 min
                if not last or (now - last[0]) > 600:
                    record_session_event(conn, "reboot", "unknown", 0, 0, 0, 0,
                                         f"System booted, uptime {uptime}s")
    except Exception:
        pass


# ── CLI Interface ──────────────────────────────────────────────

def cmd_analyze():
    """Run full analysis and print recommendations."""
    load = float(subprocess.run(
        ["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True
    ).stdout.strip().split()[1].strip("{}"))

    swap_raw = subprocess.run(
        ["sysctl", "vm.swapusage"], capture_output=True, text=True
    ).stdout
    import re
    swap_match = re.search(r'used\s*=\s*([\d.]+)M', swap_raw)
    swap = float(swap_match.group(1)) if swap_match else 0

    # RAM
    vmstat = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    free_match = re.search(r'Pages free:\s+(\d+)', vmstat)
    total_mem = int(subprocess.run(
        ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True
    ).stdout.strip())
    free_ram = int(free_match.group(1)) * 16384 * 100 // total_mem if free_match else 100

    procs = len(subprocess.run(
        ["ps", "ax", "-o", "pid="], capture_output=True, text=True
    ).stdout.strip().split("\n"))

    # Phase
    if load >= 100 or swap >= 25600 or free_ram <= 3:
        phase = "emergency"
    elif load >= 50 or swap >= 15360 or free_ram <= 8:
        phase = "critical"
    elif load >= 20 or swap >= 5120 or free_ram <= 15 or procs >= 800:
        phase = "warning"
    else:
        phase = "ok"

    print(f"Phase: {phase.upper()}")
    print(f"Load: {load:.1f} | Swap: {swap:.0f}MB | RAM free: {free_ram}% | Procs: {procs}")
    print()

    recs = get_recommendations(phase)
    if not recs:
        print("✅ System looks healthy. No recommendations needed.")
        return

    print(f"── {len(recs)} RECOMMENDATIONS ──")
    for r in recs:
        danger_icon = {"low": "🟢", "medium": "🟡", "high": "🔴", "none": "ℹ️"}.get(r["danger"], "⚪")
        print(f"\n{danger_icon} {r['title']}")
        print(f"   {r['detail']}")
        if r.get("impact") and r["impact"] != "informational":
            print(f"   Impact: {r['impact']}")
        if r.get("command"):
            print(f"   Run: {r['command']}")


def cmd_popup():
    """Show the popup dialog."""
    load = float(subprocess.run(
        ["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True
    ).stdout.strip().split()[1].strip("{}"))

    swap_raw = subprocess.run(
        ["sysctl", "vm.swapusage"], capture_output=True, text=True
    ).stdout
    import re
    swap_match = re.search(r'used\s*=\s*([\d.]+)M', swap_raw)
    swap = float(swap_match.group(1)) if swap_match else 0

    vmstat = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    free_match = re.search(r'Pages free:\s+(\d+)', vmstat)
    total_mem = int(subprocess.run(
        ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True
    ).stdout.strip())
    free_ram = int(free_match.group(1)) * 16384 * 100 // total_mem if free_match else 100

    procs = len(subprocess.run(
        ["ps", "ax", "-o", "pid="], capture_output=True, text=True
    ).stdout.strip().split("\n"))

    if load >= 100 or swap >= 25600 or free_ram <= 3:
        phase = "emergency"
    elif load >= 50 or swap >= 15360 or free_ram <= 8:
        phase = "critical"
    elif load >= 20 or swap >= 5120 or free_ram <= 15 or procs >= 800:
        phase = "warning"
    else:
        phase = "ok"

    recs = get_recommendations(phase)
    show_popup(phase, load, swap, free_ram, procs, recs)


def cmd_record_snapshot():
    """Called by tripwire daemon to record a snapshot for learning."""
    conn = init_db()

    load = float(subprocess.run(
        ["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True
    ).stdout.strip().split()[1].strip("{}"))

    swap_raw = subprocess.run(
        ["sysctl", "vm.swapusage"], capture_output=True, text=True
    ).stdout
    import re
    swap_match = re.search(r'used\s*=\s*([\d.]+)M', swap_raw)
    swap = float(swap_match.group(1)) if swap_match else 0

    vmstat = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    free_match = re.search(r'Pages free:\s+(\d+)', vmstat)
    total_mem = int(subprocess.run(
        ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True
    ).stdout.strip())
    free_ram = int(free_match.group(1)) * 16384 * 100 // total_mem if free_match else 100

    phase = sys.argv[2] if len(sys.argv) > 2 else "ok"

    detect_recent_crash(conn)
    record_snapshot(conn, phase, load, swap, free_ram)

    # If in critical/emergency, also record escalation event
    if phase in ("critical", "emergency"):
        procs = len(subprocess.run(
            ["ps", "ax", "-o", "pid="], capture_output=True, text=True
        ).stdout.strip().split("\n"))
        record_session_event(conn, "tripwire_escalation", phase, load, swap, free_ram, procs)

    conn.close()
    print(f"Snapshot recorded — phase={phase} load={load:.1f}")


def cmd_kill_feedback(pid, name, was_helpful):
    """Record feedback after killing a process."""
    conn = init_db()
    c = conn.cursor()
    helpful = 1 if was_helpful.lower() in ("yes", "1", "true") else 0
    c.execute(
        "UPDATE kill_events SET was_helpful = ? WHERE pid = ? ORDER BY timestamp DESC LIMIT 1",
        (helpful, int(pid))
    )

    # Update score
    delta = 0.1 if helpful else -0.1
    c.execute(
        """INSERT INTO process_scores (name, kill_score, times_helpful, times_not_helpful)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(name) DO UPDATE SET
           kill_score = kill_score + ?,
           times_helpful = times_helpful + ?,
           times_not_helpful = times_not_helpful + ?""",
        (name, delta, 1 if helpful else 0, 0 if helpful else 1,
         delta, 1 if helpful else 0, 0 if helpful else 1)
    )
    conn.commit()
    conn.close()
    print(f"Feedback recorded for {name} (PID {pid}): helpful={helpful}")


def cmd_history():
    """Show learning history."""
    conn = init_db()
    c = conn.cursor()

    print("── SESSION EVENTS (last 10) ──")
    c.execute("SELECT timestamp, event_type, phase, load_avg, swap_mb, free_ram_pct, proc_count, note FROM session_events ORDER BY timestamp DESC LIMIT 10")
    for row in c.fetchall():
        ts = datetime.fromtimestamp(row[0]).strftime("%Y-%m-%d %H:%M")
        print(f"  {ts}  {row[1]:20s}  {row[2]:10s}  load={row[3]:.1f}  swap={row[4]:.0f}MB  ram={row[5]}%  procs={row[6]}  {row[7]}")

    print()
    print("── PROCESS SCORES (top positive = best to kill) ──")
    c.execute("SELECT name, kill_score, times_killed, times_helpful, avg_cpu_when_overloaded, avg_mem_when_overloaded FROM process_scores WHERE times_killed > 0 ORDER BY kill_score DESC LIMIT 15")
    for row in c.fetchall():
        print(f"  {row[0][:45]:45s}  score={row[1]:.2f}  killed={row[2]}x  helpful={row[3]}x  avg_cpu={row[4]:.0f}%  avg_mem={row[5]:.0f}MB")

    conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: tripwire-brain {analyze|popup|snapshot|kill-feedback|history}")
        print("  analyze        — show recommendations for current system state")
        print("  popup          — show interactive popup dialog")
        print("  snapshot       — record current state for learning (called by daemon)")
        print("  kill-feedback  — record whether killing a process helped")
        print("  history        — show learning database history")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "analyze":
        cmd_analyze()
    elif cmd == "popup":
        cmd_popup()
    elif cmd == "snapshot":
        cmd_record_snapshot()
    elif cmd == "kill-feedback":
        if len(sys.argv) < 4:
            print("Usage: tripwire-brain kill-feedback <pid> <name> <was_helpful>")
            sys.exit(1)
        cmd_kill_feedback(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "history":
        cmd_history()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
