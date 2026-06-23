import Cocoa
import Foundation
import AppKit
import UserNotifications

// ── Tripwire Menu Bar App ─────────────────────────────────────
// Shows system health with a COLORED dot (immune to vibrancy).
// Green = OK, Yellow = Warning, Orange = Critical, Red = Emergency.
// Includes sound alerts and persistent popup on escalation.

class TripwireBar: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var menu: NSMenu!

    // Menu items that update dynamically
    private var loadItem: NSMenuItem!
    private var swapItem: NSMenuItem!
    private var ramItem: NSMenuItem!
    private var procItem: NSMenuItem!
    private var phaseItem: NSMenuItem!

    // Popup tracking
    private var lastPhase = "ok"
    private var lastPopupPhase = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Explicit click handling (manual menu show, no auto-menu)
        if let button = statusItem.button {
            button.image = makeDot(color: .systemGray, size: 18)
            button.imagePosition = .imageOnly
            button.image?.isTemplate = false
            button.target = self
            button.action = #selector(statusBarClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        buildMenu()
        // Do NOT set statusItem.menu — we show it manually via statusBarClicked()

        updateMetrics()
        timer = Timer.scheduledTimer(timeInterval: 10.0, target: self,
                                      selector: #selector(updateMetrics),
                                      userInfo: nil, repeats: true)

        // Request notification permission
        requestNotificationPermission()
    }

    // ── Status Bar Click Handler ────────────────────────────

    @objc func statusBarClicked() {
        guard let button = statusItem.button else { return }
        updateMetrics()
        // Show menu on next runloop tick to avoid event-handling conflict
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: button.bounds.height + 4),
                           in: button)
        }
    }

    // ── Build Menu ──────────────────────────────────────────

    func buildMenu() {
        menu = NSMenu()

        phaseItem = NSMenuItem(title: "Phase: checking...", action: nil, keyEquivalent: "")
        phaseItem.isEnabled = false
        menu.addItem(phaseItem)

        menu.addItem(NSMenuItem.separator())

        loadItem = NSMenuItem(title: "Load: --", action: nil, keyEquivalent: "")
        loadItem.isEnabled = false
        menu.addItem(loadItem)

        swapItem = NSMenuItem(title: "Swap: --", action: nil, keyEquivalent: "")
        swapItem.isEnabled = false
        menu.addItem(swapItem)

        ramItem = NSMenuItem(title: "RAM free: --", action: nil, keyEquivalent: "")
        ramItem.isEnabled = false
        menu.addItem(ramItem)

        procItem = NSMenuItem(title: "Procs: --", action: nil, keyEquivalent: "")
        procItem.isEnabled = false
        menu.addItem(procItem)

        menu.addItem(NSMenuItem.separator())

        let recItem = NSMenuItem(title: "📋 Show Recommendations", action: #selector(showRecommendations), keyEquivalent: "r")
        recItem.target = self
        menu.addItem(recItem)

        let diagItem = NSMenuItem(title: "🔍 Run Diagnostic", action: #selector(runDiagnostic), keyEquivalent: "d")
        diagItem.target = self
        menu.addItem(diagItem)

        let popupItem = NSMenuItem(title: "🪟 Show Popup", action: #selector(showPopupNow), keyEquivalent: "p")
        popupItem.target = self
        menu.addItem(popupItem)

        menu.addItem(NSMenuItem.separator())

        let logItem = NSMenuItem(title: "📄 Open Log", action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit TripwireBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // ── Color Dot Image ──────────────────────────────────────

    func makeDot(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = false  // CRITICAL: preserve color in menu bar
        image.lockFocus()
        color.setFill()
        let path = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size - 4, height: size - 4))
        path.fill()
        image.unlockFocus()
        return image
    }

    // ── Metrics Update ───────────────────────────────────────

    @objc func updateMetrics() {
        let load = getLoad()
        let swap = getSwapMB()
        let ramFree = getFreeRamPct()
        let procs = getProcCount()
        let claudeCount = getClaudeCount()
        let phase = detectPhase(load: load, swap: swap, ramFree: ramFree, procs: procs)

        DispatchQueue.main.async {
            // Update menu text
            self.loadItem.title = String(format: "Load: %.1f", load)
            self.swapItem.title = String(format: "Swap: %.0f MB", swap)
            self.ramItem.title = String(format: "RAM free: %d%%", ramFree)
            self.procItem.title = "Procs: \(procs) (Claude: \(claudeCount))"
            self.phaseItem.title = "Phase: \(phase.uppercased())"

            // Update colored dot
            let dotColor = self.phaseColor(phase)
            if let button = self.statusItem.button {
                let img = self.makeDot(color: dotColor, size: 18)
                img.isTemplate = false
                button.image = img
            }

            // Phase escalation → sound + popup
            if phase != self.lastPhase && phase != "ok" {
                self.playAlertSound(for: phase)
                if phase == "critical" || phase == "emergency" {
                    self.showPopup(for: phase, load: load, swap: swap, ramFree: ramFree, procs: procs)
                    self.lastPopupPhase = phase
                }
            }

            self.lastPhase = phase
        }
    }

    // ── Phase to Color ────────────────────────────────────────

    func phaseColor(_ phase: String) -> NSColor {
        switch phase {
        case "emergency": return NSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0)
        case "critical":  return NSColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0)
        case "warning":   return NSColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1.0)
        default:          return NSColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)
        }
    }

    // ── Sound Alerts ──────────────────────────────────────────

    func playAlertSound(for phase: String) {
        switch phase {
        case "emergency":
            NSSound.beep()
            Thread.sleep(forTimeInterval: 0.2)
            NSSound.beep()
            Thread.sleep(forTimeInterval: 0.2)
            NSSound.beep()
        case "critical":
            NSSound.beep()
            Thread.sleep(forTimeInterval: 0.15)
            NSSound.beep()
        case "warning":
            NSSound.beep()
        default:
            break
        }
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("TripwireBar: notification permission granted")
            }
        }
    }

    // ── Granular Kill Panel ──────────────────────────────────

    func showPopup(for phase: String, load: Double, swap: Double, ramFree: Int, procs: Int) {
        playAlertSound(for: phase)
        let procList = getKillableProcesses()
        buildKillPanel(phase: phase, load: load, swap: swap, ramFree: ramFree, procs: procs, processes: procList)
    }

    func getKillableProcesses() -> [[String: Any]] {
        // Use Python brain to get classified processes as JSON
        let script = """
import json, subprocess
procs = []
result = subprocess.run(['ps', 'ax', '-o', 'pid=,pcpu=,rss=,comm='], capture_output=True, text=True, timeout=5)
for line in result.stdout.strip().split('\\n'):
    parts = line.strip().split(None, 3)
    if len(parts) < 4: continue
    try:
        pid, cpu, rss, name = int(parts[0]), float(parts[1]), int(parts[2]), parts[3]
        mem = rss / 1024.0
        if cpu < 2 and mem < 100: continue  # skip tiny processes
        # Classify
        if name.startswith('/System/') or name.startswith('/usr/libexec/'): cat = 'system'
        elif 'Chrome Helper' in name or 'Google Chrome' in name: cat = 'chrome'
        elif 'npm exec' in name or 'mcp' in name.lower(): cat = 'mcp'
        elif name == 'claude' or name.endswith('/claude'): cat = 'claude'
        elif 'node' in name.lower(): cat = 'node'
        elif 'next-server' in name: cat = 'nextjs'
        else: cat = 'other'
        if cat == 'system': continue
        procs.append({'pid': pid, 'name': name[:60], 'cpu': cpu, 'mem': int(mem), 'cat': cat})
    except: pass
procs.sort(key=lambda p: p['cpu'] + p['mem']/100, reverse=True)
print(json.dumps(procs[:30]))
"""
        let task = Process()
        task.launchPath = "/usr/bin/python3"
        task.arguments = ["-c", script]
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch(); task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let jsonStr = String(data: data, encoding: .utf8),
           let jsonData = jsonStr.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            return arr
        }
        return []
    }

    func buildKillPanel(phase: String, load: Double, swap: Double, ramFree: Int, procs: Int, processes: [[String: Any]]) {
        // Activate so the alert shows properly
        NSApp.activate(ignoringOtherApps: true)

        let phaseEmoji = phase == "emergency" ? "💀" : "🔴"
        let panelWidth: CGFloat = 640
        let rowHeight: CGFloat = 22
        let visibleRows = min(processes.count, 14)
        let listHeight = CGFloat(visibleRows) * rowHeight

        // Build scrollable process list as the alert's accessory view
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: listHeight + 20))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: listHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let docView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth - 20, height: CGFloat(processes.count) * rowHeight))
        var checkboxes: [NSButton] = []
        var pids: [Int] = []

        // Column header row
        let hY = CGFloat(processes.count - 1) * rowHeight
        let hKill = NSTextField(labelWithString: "Kill")
        hKill.frame = NSRect(x: 38, y: hY + 6, width: 30, height: 12)
        hKill.font = NSFont.boldSystemFont(ofSize: 9)
        hKill.textColor = .tertiaryLabelColor
        docView.addSubview(hKill)
        let hName = NSTextField(labelWithString: "Process")
        hName.frame = NSRect(x: 88, y: hY + 6, width: 280, height: 12)
        hName.font = NSFont.boldSystemFont(ofSize: 9)
        hName.textColor = .tertiaryLabelColor
        docView.addSubview(hName)
        let hCPU = NSTextField(labelWithString: "CPU")
        hCPU.frame = NSRect(x: 370, y: hY + 6, width: 45, height: 12)
        hCPU.font = NSFont.boldSystemFont(ofSize: 9)
        hCPU.textColor = .tertiaryLabelColor
        hCPU.alignment = .right
        docView.addSubview(hCPU)
        let hRAM = NSTextField(labelWithString: "RAM")
        hRAM.frame = NSRect(x: 425, y: hY + 6, width: 55, height: 12)
        hRAM.font = NSFont.boldSystemFont(ofSize: 9)
        hRAM.textColor = .tertiaryLabelColor
        hRAM.alignment = .right
        docView.addSubview(hRAM)

        for (i, proc) in processes.enumerated() {
            let y = CGFloat(processes.count - 2 - i) * rowHeight + 2
            let pid = proc["pid"] as? Int ?? 0
            let name = proc["name"] as? String ?? "?"
            let cpu = proc["cpu"] as? Double ?? 0
            let mem = proc["mem"] as? Int ?? 0
            let cat = proc["cat"] as? String ?? "other"

            // Per-process Kill button
            let killBtn = NSButton(title: "Kill", target: self, action: #selector(killSingleFromAlert(_:)))
            killBtn.frame = NSRect(x: 34, y: y + 1, width: 44, height: 16)
            killBtn.bezelStyle = .roundRect
            killBtn.font = NSFont.systemFont(ofSize: 9)
            killBtn.tag = pid
            docView.addSubview(killBtn)

            // Checkbox for bulk
            let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            cb.frame = NSRect(x: 4, y: y + 2, width: 16, height: 16)
            cb.state = (cat == "mcp" || (cat == "chrome" && mem > 300) || cpu > 50) ? .on : .off
            docView.addSubview(cb)
            checkboxes.append(cb)
            pids.append(pid)

            // Name
            let shortName = name.count > 52 ? String(name.prefix(49)) + "..." : name
            let nameLabel = NSTextField(labelWithString: shortName)
            nameLabel.frame = NSRect(x: 88, y: y + 3, width: 275, height: 13)
            nameLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            docView.addSubview(nameLabel)

            // CPU
            let cpuLabel = NSTextField(labelWithString: String(format: "%.0f%%", cpu))
            cpuLabel.frame = NSRect(x: 370, y: y + 3, width: 45, height: 13)
            cpuLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: cpu > 30 ? .bold : .regular)
            cpuLabel.alignment = .right
            cpuLabel.textColor = cpu > 50 ? .systemRed : (cpu > 20 ? .systemOrange : .labelColor)
            docView.addSubview(cpuLabel)

            // RAM
            let ramLabel = NSTextField(labelWithString: mem > 999 ? String(format: "%.1fG", Double(mem)/1024.0) : "\(mem)M")
            ramLabel.frame = NSRect(x: 425, y: y + 3, width: 55, height: 13)
            ramLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: mem > 500 ? .bold : .regular)
            ramLabel.alignment = .right
            ramLabel.textColor = mem > 1000 ? .systemRed : (mem > 500 ? .systemOrange : .labelColor)
            docView.addSubview(ramLabel)
        }

        scrollView.documentView = docView
        accessoryView.addSubview(scrollView)

        // Build modal alert — this CANNOT disappear on its own
        let alert = NSAlert()
        alert.messageText = "\(phaseEmoji) Tripwire — \(phase.uppercased())"
        alert.informativeText = "Load: \(String(format: "%.1f", load)) | Swap: \(String(format: "%.0f", swap))MB | RAM free: \(ramFree)% | \(procs) processes\nCheck processes for bulk kill, or click individual Kill buttons."
        alert.alertStyle = .critical
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        alert.accessoryView = accessoryView

        alert.addButton(withTitle: "Dismiss")
        alert.addButton(withTitle: "Kill Checked")
        alert.addButton(withTitle: "Kill Claude + MCP")

        // Store checkboxes + pids for button action
        // (modal alert blocks until dismissed, so no reference needed)

        let response = alert.runModal()

        switch response {
        case .alertSecondButtonReturn:  // Kill Checked
            var killed = 0
            for (i, cb) in checkboxes.enumerated() where cb.state == .on && i < pids.count {
                let task = Process()
                task.launchPath = "/bin/kill"; task.arguments = ["-9", String(pids[i])]
                task.launch(); task.waitUntilExit()
                killed += 1
            }
            if killed == 0 {
                let a = NSAlert(); a.messageText = "No processes checked"; a.runModal()
            }
        case .alertThirdButtonReturn:  // Kill Claude + MCP
            let ckill = Process()
            ckill.launchPath = "/Users/robinsverd/.local/bin/claude-kill"
            ckill.arguments = ["--soft"]
            ckill.launch()
            let mkill = Process()
            mkill.launchPath = "/usr/bin/pkill"
            mkill.arguments = ["-f", "npm exec @"]
            mkill.launch()
        default: break
        }
    }

    @objc func killSingleFromAlert(_ sender: NSButton) {
        let pid = sender.tag
        guard pid > 0 else { return }
        let task = Process()
        task.launchPath = "/bin/kill"
        task.arguments = ["-9", String(pid)]
        task.launch()
        sender.title = "✓ Done"
        sender.isEnabled = false
    }

    // ── Menu Actions ──────────────────────────────────────────

    @objc func showRecommendations() {
        let task = Process()
        task.launchPath = "/Users/robinsverd/.local/bin/tripwire-brain.py"
        task.arguments = ["analyze"]
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Analysis failed"

        let alert = NSAlert()
        alert.messageText = "Tripwire Recommendations"
        alert.informativeText = output
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Dismiss")
        alert.addButton(withTitle: "Kill Claude Sessions")
        alert.addButton(withTitle: "Kill MCP Servers")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let kill = Process()
            kill.launchPath = "/Users/robinsverd/.local/bin/claude-kill"
            kill.arguments = ["--soft"]
            kill.launch()
        } else if response == .alertThirdButtonReturn {
            let kill = Process()
            kill.launchPath = "/usr/bin/pkill"
            kill.arguments = ["-f", "npm exec @"]
            kill.launch()
        }
    }

    @objc func showPopupNow() {
        let load = getLoad()
        let swap = getSwapMB()
        let ramFree = getFreeRamPct()
        let procs = getProcCount()
        let phase = detectPhase(load: load, swap: swap, ramFree: ramFree, procs: procs)
        let procList = getKillableProcesses()
        buildKillPanel(phase: phase, load: load, swap: swap, ramFree: ramFree, procs: procs, processes: procList)
    }

    @objc func runDiagnostic() {
        let task = Process()
        task.launchPath = "/Users/robinsverd/.local/bin/tripwire"
        task.arguments = ["test"]
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "No output"

        let alert = NSAlert()
        alert.messageText = "Tripwire Diagnostic"
        alert.informativeText = output
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/robinsverd/.local/var/tripwire/tripwire.log"))
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // ── Metrics Collectors ────────────────────────────────────

    func getLoad() -> Double {
        var loadavg = [Double](repeating: 0, count: 4)
        var size = MemoryLayout<[Double]>.size
        sysctlbyname("vm.loadavg", &loadavg, &size, nil, 0)
        return loadavg[1]
    }

    func getSwapMB() -> Double {
        let task = Process()
        task.launchPath = "/usr/sbin/sysctl"; task.arguments = ["vm.swapusage"]
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch(); task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let range = output.range(of: "used = "),
           let endRange = output[range.upperBound...].range(of: "M") {
            return Double(String(output[range.upperBound..<endRange.lowerBound])) ?? 0
        }
        return 0
    }

    func getFreeRamPct() -> Int {
        let task = Process()
        task.launchPath = "/usr/bin/vm_stat"
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch(); task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let range = output.range(of: "Pages free:"),
           let endLine = output[range.upperBound...].range(of: "\n") {
            let line = String(output[range.upperBound..<endLine.lowerBound])
            let numStr = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
            if let freePages = Int(numStr) {
                var totalMem: UInt64 = 0
                var size = MemoryLayout<UInt64>.size
                sysctlbyname("hw.memsize", &totalMem, &size, nil, 0)
                return Int(UInt64(freePages) * 16384 * 100 / totalMem)
            }
        }
        return 100
    }

    func getProcCount() -> Int {
        let task = Process()
        task.launchPath = "/bin/ps"; task.arguments = ["ax", "-o", "pid="]
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch(); task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .split(separator: "\n").count
    }

    func getClaudeCount() -> Int {
        let task = Process()
        task.launchPath = "/bin/ps"; task.arguments = ["ax", "-o", "comm="]
        let pipe = Pipe(); task.standardOutput = pipe
        task.launch(); task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .split(separator: "\n")
            .filter { $0 == "claude" || $0.hasSuffix("/claude") }.count
    }

    func detectPhase(load: Double, swap: Double, ramFree: Int, procs: Int) -> String {
        if load >= 100 || swap >= 25600 || ramFree <= 3 { return "emergency" }
        if load >= 50  || swap >= 15360 || ramFree <= 8  { return "critical" }
        if load >= 20  || swap >= 5120  || ramFree <= 15 || procs >= 800 { return "warning" }
        return "ok"
    }
}

// ── Main ──────────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = TripwireBar()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
