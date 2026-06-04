import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class SPNController: ObservableObject {
    @Published var isConnected = false
    @Published var hasConfig = false
    @Published var statusLine = "Checking…"
    @Published var statusDetail: String?
    @Published var trafficLine: String?
    @Published var error: String?
    @Published var launchAtLogin: Bool = SPNController.readLaunchAtLogin()

    private var pollTimer: Timer?

    init() {
        applyLaunchAtLogin(launchAtLogin)
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let configPath = (NSString(string: "~/.cloudnetip/spn.conf").expandingTildeInPath)
        hasConfig = FileManager.default.fileExists(atPath: configPath)

        guard let cli = locateCLI() else {
            isConnected = false
            statusLine = "netip-spn CLI not found"
            statusDetail = "Run: brew install netip/spn/netip-spn"
            trafficLine = nil
            error = nil
            return
        }
        let result = run(cli, args: ["status"])
        if result.exitCode != 0 {
            error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        error = nil
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        isConnected = out.contains("connected") && !out.contains("disconnected")

        if isConnected {
            applyStats(cli: cli)
            let lines = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            statusDetail = lines.count > 1 ? String(lines[0]) : nil
        } else {
            statusLine = "SPN: Disconnected"
            statusDetail = nil
            trafficLine = nil
        }
    }

    private func applyStats(cli: String) {
        let result = run(cli, args: ["stats"])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["connected"] as? Bool) == true
        else {
            statusLine = "SPN: Connected"
            trafficLine = nil
            return
        }

        var sinceUnix: Int64 = 0
        if let s = obj["since"] as? Int64 { sinceUnix = s }
        else if let s = obj["since"] as? Int { sinceUnix = Int64(s) }
        else if let s = obj["since"] as? Double { sinceUnix = Int64(s) }

        let rx = readUInt(obj["rx"])
        let tx = readUInt(obj["tx"])

        if sinceUnix > 0 {
            let elapsed = Int(Date().timeIntervalSince1970) - Int(sinceUnix)
            statusLine = "SPN: Connected — " + formatDuration(seconds: elapsed)
        } else {
            statusLine = "SPN: Connected"
        }
        trafficLine = "↓ Received: \(formatBytes(rx))    ↑ Sent: \(formatBytes(tx))"
    }

    private func readUInt(_ v: Any?) -> UInt64 {
        if let n = v as? UInt64 { return n }
        if let n = v as? Int64 { return UInt64(max(0, n)) }
        if let n = v as? Int { return UInt64(max(0, n)) }
        if let n = v as? Double { return UInt64(max(0, n)) }
        return 0
    }

    private func formatDuration(seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return String(format: "%ds", sec)
    }

    private func formatBytes(_ n: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(n)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) \(units[unit])" }
        return String(format: "%.1f %@", value, units[unit])
    }

    func connect() {
        guard hasConfig, let cli = locateCLI() else { return }
        runInTerminal(cli, args: ["connect"])
    }

    func disconnect() {
        guard let cli = locateCLI() else { return }
        runInTerminal(cli, args: ["disconnect"])
    }

    func chooseConfig() {
        let panel = NSOpenPanel()
        panel.title = "Select SPN config"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let cli = locateCLI() else { return }
        let result = run(cli, args: ["config", url.path])
        if result.exitCode != 0 {
            presentError(result.stderr.isEmpty ? result.stdout : result.stderr)
            return
        }
        refresh()
    }

    func revealConfig() {
        let path = (NSString(string: "~/.cloudnetip/spn.conf").expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func showAbout() {
        let cliVersion: String = {
            guard let cli = locateCLI() else { return "not installed" }
            let result = run(cli, args: ["version"])
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "netip-spn ", with: "")
        }()
        let guiVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        let alert = NSAlert()
        alert.messageText = "Cloudnetip SPN"
        alert.informativeText = "GUI version: \(guiVersion)\nCLI version: \(cliVersion)"

        let linkText = "https://cloudnetip.com"
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let link = NSMutableAttributedString(string: linkText)
        link.addAttributes([
            .link: URL(string: linkText)!,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: para,
        ], range: NSRange(location: 0, length: link.length))

        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.textContainerInset = .zero
        field.alignment = .center
        field.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        field.textStorage?.setAttributedString(link)
        alert.accessoryView = field

        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func quit() {
        if isConnected, let cli = locateCLI() {
            runInTerminal(cli, args: ["disconnect"])
        }
        NSApp.terminate(nil)
    }

    func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        applyLaunchAtLogin(launchAtLogin)
    }

    private static func readLaunchAtLogin() -> Bool {
        // Default: on. The first launch flips the switch on; subsequent launches
        // honour what the user toggled.
        let key = "launchAtLogin"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            // Surface as a non-blocking error on the menu.
            self.error = "Login item: \(error.localizedDescription)"
        }
    }

    private func locateCLI() -> String? {
        let candidates = [
            "/opt/homebrew/bin/netip-spn",
            "/usr/local/bin/netip-spn",
            "/usr/bin/netip-spn",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = run("/usr/bin/which", args: ["netip-spn"])
        let trimmed = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return which.exitCode == 0 && !trimmed.isEmpty ? trimmed : nil
    }

    private struct ProcResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func run(_ path: String, args: [String]) -> ProcResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ProcResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcResult(stdout: out, stderr: err, exitCode: task.terminationStatus)
    }

    // sudo prompts must be interactive, so connect/disconnect launch Terminal.app.
    private func runInTerminal(_ path: String, args: [String]) {
        let cmd = ([path] + args).map { "'\($0)'" }.joined(separator: " ")
        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd); echo; echo Press any key to close.; read -n 1; exit"
        end tell
        """
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        try? osa.run()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "netip-spn"
        alert.informativeText = message.isEmpty ? "Unknown error" : message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
