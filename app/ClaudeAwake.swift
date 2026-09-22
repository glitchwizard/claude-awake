// ClaudeAwake — menu bar toggle that keeps a Mac awake with the lid closed
// while a Claude session is actually working, and lets the Mac sleep normally
// the moment you switch it off.
//
// The only thing that overrides a lid-close sleep on macOS is the root-only
// power setting `pmset -a disablesleep`. This app flips it, via a sudoers rule
// scoped to exactly that command, and flips it back.

import AppKit
import ServiceManagement

// MARK: - Shared state (files, so the `claude-awake` CLI sees the same truth)

let stateDir = ("~/.local/state/claude-awake" as NSString).expandingTildeInPath
let armedFlag = stateDir + "/armed"          // auto mode on
let holdFlag = stateDir + "/hold"            // stay awake regardless of sessions
let desktopFlag = stateDir + "/count-desktop" // count the desktop app merely being open
let logPath = ("~/Library/Logs/claude-awake.log" as NSString).expandingTildeInPath

func flag(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func setFlag(_ path: String, _ on: Bool) {
    if on {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
    } else {
        try? FileManager.default.removeItem(atPath: path)
    }
}

extension FileManager {
    func createFile(atPath path: String, contents: Data?) {
        createFile(atPath: path, contents: contents, attributes: nil)
    }
}

func appendLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

// MARK: - Shelling out

/// Runs a command and returns (exitStatus, stdout). Absolute paths only: a GUI
/// app inherits a minimal PATH.
func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - The power switch

enum PowerSwitch {
    /// True when lid-close sleep is currently disabled.
    static var sleepDisabled: Bool {
        let (_, out) = run("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    /// True when the scoped NOPASSWD sudoers rule is in place.
    static var canSwitch: Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).0 == 0
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        let value = on ? "1" : "0"
        let (status, _) = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])
        appendLog(status == 0 ? "disablesleep=\(value)" : "ERROR: pmset failed (status \(status)); is the sudoers rule installed?")
        return status == 0
    }
}

// MARK: - Session detection

struct Detection {
    var labels: [String] = []
    var active: Bool { !labels.isEmpty }
}

enum Sessions {
    /// What counts as a Claude session doing work. The desktop app merely being
    /// open is deliberately excluded by default: it tends to run all day, which
    /// would pin the switch on permanently. Its local Claude Code sessions are
    /// still caught, because those spawn `bg-pty-host`.
    static func detect(countDesktopApp: Bool) -> Detection {
        let (_, out) = run("/bin/ps", ["-axo", "command="])
        var found = Set<String>()
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let isDesktopApp = line.contains("Claude.app") || line.contains("Claude Helper")
            if isDesktopApp {
                if countDesktopApp { found.insert("Claude desktop app (open)") }
                continue
            }
            if line.contains("native-binary/claude") { found.insert("VS Code extension") }
            if line.contains("bg-pty-host") { found.insert("Claude desktop session") }
            if line.contains("@anthropic-ai/claude-code") { found.insert("Claude Code CLI") }
            if let exe = line.split(separator: " ").first {
                let name = (String(exe) as NSString).lastPathComponent
                if name == "claude" || name == "claude.exe" { found.insert("Claude Code CLI") }
            }
        }
        return Detection(labels: found.sorted())
    }
}

// MARK: - Conflict detection

/// Only one poller may own the sleep switch. The CLI refuses to install a
/// LaunchAgent while this app runs; this is the same check from the app's side,
/// so a daemon installed with --force is visible here instead of silently
/// racing us over `pmset`.
enum Conflicts {
    static var daemon: String? {
        let uid = getuid()
        if run("/bin/launchctl", ["print", "gui/\(uid)/com.glitchwizard.claude-awake"]).0 == 0 {
            return "a claude-awake LaunchAgent is loaded"
        }
        let pidFile = stateDir + "/daemon.pid"
        guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        // A pid alone proves nothing: pids are recycled. Confirm it is ours.
        let (status, out) = run("/bin/ps", ["-p", String(pid), "-o", "command="])
        if status == 0 && out.contains("claude-awake") {
            return "a claude-awake daemon is running (pid \(pid))"
        }
        return nil
    }
}

// MARK: - The menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastDetection = Detection()
    private var idlePolls = 0
    private let gracePolls = 4      // ~60s of no sessions before sleep is re-enabled

    private let armedItem = NSMenuItem(title: "Keep awake while Claude runs", action: #selector(toggleArmed), keyEquivalent: "")
    private let holdItem = NSMenuItem(title: "Keep awake until I turn it off", action: #selector(toggleHold), keyEquivalent: "")
    private let desktopItem = NSMenuItem(title: "Count the Claude app just being open", action: #selector(toggleDesktop), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detectedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let conflictLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let setupItem = NSMenuItem(title: "Finish setup: copy the sudo command", action: #selector(copySetupCommand), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.delegate = self
        for item in [armedItem, holdItem, desktopItem] { item.target = self }
        loginItem.target = self
        setupItem.target = self
        statusLine.isEnabled = false
        detectedLine.isEnabled = false
        conflictLine.isEnabled = false

        menu.addItem(statusLine)
        menu.addItem(detectedLine)
        menu.addItem(conflictLine)
        menu.addItem(.separator())
        menu.addItem(armedItem)
        menu.addItem(holdItem)
        menu.addItem(.separator())
        menu.addItem(desktopItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(setupItem)
        menu.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Awake", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        statusItem.menu = menu

        appendLog("menu bar app started")
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting must never leave the Mac unable to sleep.
        if PowerSwitch.sleepDisabled { PowerSwitch.set(false) }
        appendLog("menu bar app quit; sleep re-enabled")
    }

    // MARK: Core loop

    private func tick() {
        let armed = flag(armedFlag)
        let holding = flag(holdFlag)
        lastDetection = Sessions.detect(countDesktopApp: flag(desktopFlag))

        let wantAwake = holding || (armed && lastDetection.active)
        if wantAwake {
            idlePolls = 0
            if !PowerSwitch.sleepDisabled { PowerSwitch.set(true) }
        } else {
            idlePolls += 1
            let settled = !armed || idlePolls >= gracePolls   // switching off is immediate
            if settled && PowerSwitch.sleepDisabled { PowerSwitch.set(false) }
        }
        refresh()
    }

    private func refresh() {
        let armed = flag(armedFlag)
        let holding = flag(holdFlag)
        let preventing = PowerSwitch.sleepDisabled
        let canSwitch = PowerSwitch.canSwitch

        let conflict = Conflicts.daemon

        let symbol: String
        if !canSwitch || conflict != nil { symbol = "exclamationmark.triangle" }
        else if preventing { symbol = "bolt.fill" }
        else if armed || holding { symbol = "bolt" }
        else { symbol = "bolt.slash" }

        let description = preventing ? "Claude Awake: preventing sleep" : "Claude Awake: sleep allowed"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = description

        if let conflict = conflict {
            statusLine.title = "Conflict: " + conflict
        } else if !canSwitch {
            statusLine.title = "Setup not finished — cannot change sleep"
        } else if holding {
            statusLine.title = "Awake: held on until you turn it off"
        } else if preventing {
            statusLine.title = "Awake: lid close will NOT sleep this Mac"
        } else if armed {
            statusLine.title = "Armed: will wake-lock when Claude works"
        } else {
            statusLine.title = "Off: lid close sleeps normally"
        }

        detectedLine.title = lastDetection.active
            ? "Seen now: " + lastDetection.labels.joined(separator: ", ")
            : "Seen now: no Claude sessions"

        if let conflict = conflict {
            conflictLine.title = "Two pollers fight over the switch — run: claude-awake uninstall"
            conflictLine.isHidden = false
            appendLog("WARNING: conflict — " + conflict)
        } else {
            conflictLine.isHidden = true
        }

        armedItem.state = armed ? .on : .off
        holdItem.state = holding ? .on : .off
        desktopItem.state = flag(desktopFlag) ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        setupItem.isHidden = canSwitch
    }

    // MARK: Actions

    @objc private func toggleArmed() {
        setFlag(armedFlag, !flag(armedFlag))
        idlePolls = gracePolls          // turning it off takes effect on this tick
        appendLog("armed=\(flag(armedFlag))")
        tick()
        if flag(armedFlag) && !PowerSwitch.canSwitch { warnSetup() }
    }

    @objc private func toggleHold() {
        setFlag(holdFlag, !flag(holdFlag))
        appendLog("hold=\(flag(holdFlag))")
        tick()
        if flag(holdFlag) && !PowerSwitch.canSwitch { warnSetup() }
    }

    @objc private func toggleDesktop() {
        setFlag(desktopFlag, !flag(desktopFlag))
        tick()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Claude Awake by hand in System Settings, under General → Login Items."
            alert.runModal()
        }
        refresh()
    }

    @objc private func copySetupCommand() {
        let user = NSUserName()
        let command = """
        printf '%s\\n' '\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0' | sudo tee /etc/sudoers.d/claude-awake >/dev/null && sudo chmod 0440 /etc/sudoers.d/claude-awake && sudo visudo -c -f /etc/sudoers.d/claude-awake
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Setup command copied"
        alert.informativeText = "Changing lid-close sleep needs root, so Claude Awake uses a sudo rule limited to that one setting.\n\nPaste the copied command into Terminal and enter your password. Then reopen this menu."
        alert.runModal()
    }

    private func warnSetup() {
        let alert = NSAlert()
        alert.messageText = "Setup is not finished"
        alert.informativeText = "Claude Awake cannot change the sleep setting yet. Use “Finish setup” in the menu to copy the one-time sudo command."
        alert.runModal()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) { appendLog("log opened") }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { tick() }   // never show a stale reading
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)               // menu bar only, no Dock icon
app.run()
