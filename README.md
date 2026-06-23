# Tripwire — macOS System Overload Protection

Prevents macOS crashes by monitoring system health and taking escalating action before the kernel panic hits.

## The Problem

Running multiple AI coding agents (Claude Code, Codex) simultaneously on macOS causes:
- Memory leaks accumulating over days → 33GB+ swap
- Boot storms: 1000+ processes starting at once after reboot
- macOS Jetsam (memory killer) or thermal panics

## Components

| Tool | What |
|------|------|
| `tripwire.sh` | Monitoring daemon — checks load/swap/RAM every 30s, escalates in 3 phases |
| `tripwire-brain.py` | AI-powered analysis engine with SQLite learning, process classification, recommendations |
| `TripwireBar.swift` | macOS menu bar app with colored status dot, sound alerts, popup dialogs |
| `boot-shield.sh` | Suppresses Spotlight indexing for 5-10 min after boot to prevent indexing storms |
| `claude-kill` | Emergency kill switch for Claude Code processes |
| `tripwire` | CLI control tool |

## Installation

```bash
# Install scripts
cp tripwire.sh ~/.local/bin/
cp tripwire-brain.py ~/.local/bin/
cp tripwire ~/.local/bin/
cp TripwireBar.swift ~/.local/bin/
cp boot-shield.sh ~/.local/bin/
cp claude-kill ~/.local/bin/
chmod +x ~/.local/bin/tripwire*

# Compile menu bar app
swiftc ~/.local/bin/TripwireBar.swift -o ~/.local/bin/TripwireBar -framework Cocoa -framework Foundation -framework UserNotifications

# Install launch agents
cp com.thrivbe.tripwire.plist ~/Library/LaunchAgents/
cp com.thrivbe.boot-shield.plist ~/Library/LaunchAgents/

# Start
launchctl load ~/Library/LaunchAgents/com.thrivbe.tripwire.plist
launchctl load ~/Library/LaunchAgents/com.thrivbe.boot-shield.plist
~/.local/bin/TripwireBar &
```

## Escalation Ladder

| Phase | Trigger | Action |
|-------|---------|--------|
| ⚠️ Warning | load>20, swap>5GB, RAM<15% | Notification + log |
| 🔴 Critical | load>50, swap>15GB, RAM<8% | Popup with recommendations, kill Spotlight |
| 💀 Emergency | load>100, swap>25GB, RAM<3% | Kill Claude sessions + MCP servers, suggest reboot |

## Commands

```bash
tripwire status          # check daemon status
tripwire test            # one-shot diagnostic
tripwire log             # watch live log
claude-kill --soft       # graceful Claude shutdown
claude-kill --count      # count Claude processes
python3 tripwire-brain.py analyze   # recommendations
python3 tripwire-brain.py history   # learning history
```

## Learning System

The brain builds a SQLite database at `~/.local/var/tripwire/brain.db` that:
1. Records every process's CPU/RAM during overload events
2. Tracks which processes were killed and whether it helped
3. Builds personalized "safe to kill" scores over time
4. Generates contextual recommendations based on current system state

## Architecture

```
tripwire (launchd daemon)  ← runs every 30s
  ├── collects: load, swap, RAM, process count
  ├── calls: tripwire-brain.py (analysis + learning)
  └── escalates: notification → popup → process kill

TripwireBar (menu bar app) ← runs continuously
  ├── colored dot: 🟢🟡🔴💀
  ├── dropdown: metrics + recommendations button
  └── auto-popup on critical/emergency with sound

boot-shield (login agent)  ← runs once at login
  └── suppresses Spotlight for 5-10 min
```
