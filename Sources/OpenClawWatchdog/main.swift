import AppKit
import Foundation

// MARK: - Security Hardening

/// Validates file permissions are secure
func validatePermissions(path: String, requiredMode: mode_t) -> Bool {
    var stat_info = stat()
    guard stat(path, &stat_info) == 0 else { return false }
    return (stat_info.st_mode & 0o777) <= requiredMode
}

/// Sanitizes input to prevent injection attacks
func sanitize(_ input: String) -> String {
    // Remove shell metacharacters
    let dangerous = CharacterSet(charactersIn: ";|&`$(){}[]<>\\\"'")
    return input.unicodeScalars.filter { !dangerous.contains($0) }.map { String($0) }.joined()
}

/// Verifies the watchdog script hasn't been tampered with
func verifyScriptIntegrity(scriptPath: String, expectedHash: String?) -> Bool {
    guard let data = FileManager.default.contents(atPath: scriptPath) else { return false }
    
    // If no expected hash, just verify file exists and is executable
    guard let hash = expectedHash else {
        return FileManager.default.isExecutableFile(atPath: scriptPath)
    }
    
    // Calculate SHA256
    let computed = data.sha256()
    return computed == hash
}

// MARK: - Data Extension for SHA256

extension Data {
    func sha256() -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

import CommonCrypto

// MARK: - Watchdog Status

enum WatchdogHealth: String {
    case healthy = "healthy"
    case warning = "warning"
    case critical = "critical"
    case unknown = "unknown"
}

struct WatchdogStatus {
    var health: WatchdogHealth = .unknown
    var gatewayRunning: Bool = false
    var gatewayHealthy: Bool = false
    var memoryMB: Int = 0
    var diskPercent: Int = 0
    var lastCheck: Date = Date()
    var message: String = "Initializing..."
}

// MARK: - Status Monitor

class StatusMonitor {
    private let metricsPath = NSString("~/.openclaw/watchdog/metrics.json").expandingTildeInPath
    private let statePath = NSString("~/.openclaw/watchdog/state.json").expandingTildeInPath
    private let logPath = NSString("~/.openclaw/watchdog/watchdog.log").expandingTildeInPath
    
    var currentStatus = WatchdogStatus()
    
    func refresh() {
        // Read metrics file
        if let data = FileManager.default.contents(atPath: metricsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            if let gateway = json["gateway"] as? [String: Any] {
                currentStatus.memoryMB = gateway["memory_mb"] as? Int ?? 0
            }
            
            if let system = json["system"] as? [String: Any] {
                currentStatus.diskPercent = system["disk_percent"] as? Int ?? 0
            }
            
            if let health = json["health"] as? [String: Any] {
                currentStatus.gatewayRunning = health["gateway_running"] as? Bool ?? false
                currentStatus.gatewayHealthy = health["gateway_healthy"] as? Bool ?? false
            }
            
            currentStatus.lastCheck = Date()
            
            // Determine overall health
            if !currentStatus.gatewayRunning {
                currentStatus.health = .critical
                currentStatus.message = "Gateway not running!"
            } else if !currentStatus.gatewayHealthy {
                currentStatus.health = .warning
                currentStatus.message = "Gateway unhealthy"
            } else if currentStatus.memoryMB > 500 {
                currentStatus.health = .warning
                currentStatus.message = "High memory: \(currentStatus.memoryMB)MB"
            } else if currentStatus.diskPercent > 80 {
                currentStatus.health = .warning
                currentStatus.message = "Disk \(currentStatus.diskPercent)% full"
            } else {
                currentStatus.health = .healthy
                currentStatus.message = "All systems nominal"
            }
        } else {
            currentStatus.health = .unknown
            currentStatus.message = "Cannot read metrics"
        }
    }
    
    func getRecentLogs(lines: Int = 20) -> String {
        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return "No logs available"
        }
        
        let allLines = content.components(separatedBy: .newlines)
        let recent = allLines.suffix(lines)
        return recent.joined(separator: "\n")
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor = StatusMonitor()
    private var refreshTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Use SF Symbol for bulldog-like icon (dog face)
            if let image = NSImage(systemSymbolName: "dog.fill", accessibilityDescription: "Watchdog") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🐕"
            }
        }
        
        // Build menu
        updateMenu()
        
        // Start refresh timer (every 30 seconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        
        // Initial refresh
        refresh()
    }
    
    func refresh() {
        monitor.refresh()
        updateMenu()
        updateIcon()
    }
    
    func updateIcon() {
        guard let button = statusItem.button else { return }
        
        // Color the icon based on health
        let symbolConfig: NSImage.SymbolConfiguration
        switch monitor.currentStatus.health {
        case .healthy:
            symbolConfig = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        case .warning:
            symbolConfig = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        case .critical:
            symbolConfig = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        case .unknown:
            symbolConfig = NSImage.SymbolConfiguration(paletteColors: [.systemGray])
        }
        
        if let image = NSImage(systemSymbolName: "dog.fill", accessibilityDescription: "Watchdog")?.withSymbolConfiguration(symbolConfig) {
            button.image = image
        }
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        // Status header
        let statusEmoji: String
        switch monitor.currentStatus.health {
        case .healthy: statusEmoji = "✅"
        case .warning: statusEmoji = "⚠️"
        case .critical: statusEmoji = "🚨"
        case .unknown: statusEmoji = "❓"
        }
        
        let headerItem = NSMenuItem(title: "\(statusEmoji) \(monitor.currentStatus.message)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Stats
        let gatewayItem = NSMenuItem(
            title: "Gateway: \(monitor.currentStatus.gatewayRunning ? "Running" : "Stopped") \(monitor.currentStatus.gatewayHealthy ? "✓" : "✗")",
            action: nil,
            keyEquivalent: ""
        )
        gatewayItem.isEnabled = false
        menu.addItem(gatewayItem)
        
        let memoryItem = NSMenuItem(title: "Memory: \(monitor.currentStatus.memoryMB) MB", action: nil, keyEquivalent: "")
        memoryItem.isEnabled = false
        menu.addItem(memoryItem)
        
        let diskItem = NSMenuItem(title: "Disk: \(monitor.currentStatus.diskPercent)%", action: nil, keyEquivalent: "")
        diskItem.isEnabled = false
        menu.addItem(diskItem)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let lastCheckItem = NSMenuItem(title: "Last check: \(timeFormatter.string(from: monitor.currentStatus.lastCheck))", action: nil, keyEquivalent: "")
        lastCheckItem.isEnabled = false
        menu.addItem(lastCheckItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Actions
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "View Logs...", action: #selector(viewLogs), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Open Dashboard...", action: #selector(openDashboard), keyEquivalent: "d"))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Restart Gateway", action: #selector(restartGateway), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Quit Watchdog", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    @objc func refreshNow() {
        refresh()
    }
    
    @objc func viewLogs() {
        let logs = monitor.getRecentLogs(lines: 50)
        
        let alert = NSAlert()
        alert.messageText = "Watchdog Logs"
        alert.informativeText = logs
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open in Console")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let logPath = NSString("~/.openclaw/watchdog/watchdog.log").expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }
    
    @objc func openDashboard() {
        if let url = URL(string: "http://127.0.0.1:18789") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func restartGateway() {
        let alert = NSAlert()
        alert.messageText = "Restart Gateway?"
        alert.informativeText = "This will restart the OpenClaw gateway. Active sessions may be interrupted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Send graceful restart signal
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", "pkill -SIGUSR1 -f 'openclaw-gateway'"]
            try? task.run()
        }
    }
    
    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only, no dock icon
app.run()
