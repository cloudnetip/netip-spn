import AppKit
import Foundation
import SwiftUI

@MainActor
final class SPNController: ObservableObject {
    @Published var isConnected = false
    @Published var hasConfig = false
    @Published var statusLine = "Checking…"
    @Published var statusDetail: String?
    @Published var error: String?

    private var pollTimer: Timer?

    init() {
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
        let lines = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        statusLine = isConnected ? "SPN: Connected" : "SPN: Disconnected"
        statusDetail = lines.count > 1 ? String(lines[0]) : nil
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
