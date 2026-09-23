import AppKit
import Foundation
import ServiceManagement
import SwiftUI

private final class AboutActionHandler: NSObject {
    var updateAction: (() -> Void)?

    @objc func performUpdate(_ sender: Any?) {
        updateAction?()
    }
}

@MainActor
final class SPNController: ObservableObject {
    @Published var isConnected = false
    @Published var hasConfig = false
    @Published var statusLine = "Checking…"
    @Published var statusDetail: String?
    @Published var trafficLine: String?
    @Published var error: String?
    @Published var launchAtLogin: Bool = SPNController.readLaunchAtLogin()
    @Published var showStatsInBar: Bool = SPNController.readShowStatsInBar()
    @Published var rxRateText = "0 KB/s"
    @Published var txRateText = "0 KB/s"

    private var pollTimer: Timer?
    private var trafficTimer: Timer?
    private var previousTrafficSample: (iface: String, rx: UInt64, tx: UInt64, at: Date)?
    private var logWindow: NSWindow?
    private var aboutActionHandler: AboutActionHandler?
    private var aboutUpdateVersion: String?
    private var aboutCheckTask: Task<Void, Never>?

    init() {
        applyLaunchAtLogin(launchAtLogin)
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTraffic() }
        }
    }

    func refresh() {
        let configPath = (NSString(string: "~/.cloudnetip/spn.conf").expandingTildeInPath)
        hasConfig = FileManager.default.fileExists(atPath: configPath)

        guard let cli = locateCLI() else {
            isConnected = false
            statusLine = "netip-spn CLI not found"
            statusDetail = "Run: brew install netip/spn/netip-spn"
            resetTrafficStats()
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
            if !showStatsInBar || previousTrafficSample == nil {
                applyStats(cli: cli)
            }
            let lines = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            statusDetail = lines.count > 1 ? String(lines[0]) : nil
        } else {
            statusLine = "SPN: Disconnected"
            statusDetail = nil
            resetTrafficStats()
        }
    }

    private func refreshTraffic() {
        guard showStatsInBar, isConnected, let cli = locateCLI() else { return }
        applyStats(cli: cli)
    }

    private func applyStats(cli: String) {
        let result = run(cli, args: ["stats"])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            trafficLine = nil
            return
        }
        guard (obj["connected"] as? Bool) == true else {
            isConnected = false
            statusLine = "SPN: Disconnected"
            statusDetail = nil
            resetTrafficStats()
            return
        }

        var sinceUnix: Int64 = 0
        if let s = obj["since"] as? Int64 { sinceUnix = s }
        else if let s = obj["since"] as? Int { sinceUnix = Int64(s) }
        else if let s = obj["since"] as? Double { sinceUnix = Int64(s) }

        let iface = obj["iface"] as? String ?? ""
        let rx = readUInt(obj["rx"])
        let tx = readUInt(obj["tx"])
        let now = Date()

        var rxRate: UInt64 = 0
        var txRate: UInt64 = 0
        if let previous = previousTrafficSample, previous.iface == iface {
            let interval = now.timeIntervalSince(previous.at)
            if interval > 0 {
                if rx >= previous.rx {
                    rxRate = UInt64(Double(rx - previous.rx) / interval)
                }
                if tx >= previous.tx {
                    txRate = UInt64(Double(tx - previous.tx) / interval)
                }
            }
        }
        previousTrafficSample = (iface: iface, rx: rx, tx: tx, at: now)
        rxRateText = formatRate(rxRate)
        txRateText = formatRate(txRate)

        if sinceUnix > 0 {
            let elapsed = Int(now.timeIntervalSince1970) - Int(sinceUnix)
            statusLine = "SPN: Connected — " + formatDuration(seconds: elapsed)
        } else {
            statusLine = "SPN: Connected"
        }
        trafficLine = "↑ Sent: \(formatBytes(tx))    ↓ Received: \(formatBytes(rx))"
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

    private func formatRate(_ n: UInt64) -> String {
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var value = Double(n) / 1000.0
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }

        if n == 0 {
            return "0 KB/s"
        }

        let fractionDigits: Int
        if value >= 100 {
            fractionDigits = 0
        } else {
            fractionDigits = 2
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits

        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.*f", fractionDigits, value)
        return "\(number) \(units[unit])"
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
        withPasswordlessHelper(cli: cli) { [weak self] ready in
            guard let self, ready else { return }
            self.runTunnelCommand(cli, args: ["connect"])
        }
    }

    func disconnect() {
        guard let cli = locateCLI() else { return }
        isConnected = false
        statusLine = "SPN: Disconnected"
        statusDetail = nil
        resetTrafficStats()
        withPasswordlessHelper(cli: cli) { [weak self] ready in
            guard let self, ready else {
                self?.refresh()
                return
            }
            self.runTunnelCommand(cli, args: ["disconnect"])
        }
    }

    private func withPasswordlessHelper(cli: String, completion: @escaping (Bool) -> Void) {
        if passwordlessHelperIsActive(cli: cli) {
            completion(true)
            return
        }

        let username = NSUserName()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prompt = "Cloudnetip SPN needs your administrator password once to install its secure networking helper. Future Connect and Disconnect actions will not ask for a password."
        runAsAdministrator(
            cli,
            args: ["_sudoers-install", username, home],
            prompt: prompt
        ) { [weak self] result in
            guard let self else { return }
            if result.exitCode != 0 {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                if !self.wasAuthorizationCancelled(message) {
                    self.presentError(message)
                }
                completion(false)
                return
            }
            guard self.passwordlessHelperIsActive(cli: cli) else {
                self.presentError("Administrator access was granted, but the passwordless helper could not be verified.")
                completion(false)
                return
            }
            completion(true)
        }
    }

    private func passwordlessHelperIsActive(cli: String) -> Bool {
        let result = run(cli, args: ["sudoers", "check"])
        return result.exitCode == 0 && result.stdout.contains("sudoers: enabled")
    }

    private func runTunnelCommand(_ cli: String, args: [String]) {
        runAsync(cli, args: args) { [weak self] result in
            guard let self else { return }
            self.appendConnectionLog(command: args.joined(separator: " "), result: result)
            if result.exitCode != 0 {
                self.presentError(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            self.refresh()
        }
    }

    private func wasAuthorizationCancelled(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("User canceled") ||
        message.localizedCaseInsensitiveContains("(-128)")
    }

    private func resetTrafficStats() {
        previousTrafficSample = nil
        rxRateText = "0 KB/s"
        txRateText = "0 KB/s"
        trafficLine = nil
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
        aboutCheckTask?.cancel()
        aboutUpdateVersion = nil

        let guiVersion = localGUIVersion()
        let alert = NSAlert()
        alert.messageText = "Cloudnetip SPN"
        alert.informativeText = "GUI version: \(guiVersion)\nCLI version: Checking…"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 67))

        let linkView = makeAboutLinkView()
        linkView.frame = NSRect(x: 0, y: 47, width: 260, height: 20)
        accessory.addSubview(linkView)

        let separator = NSBox(frame: NSRect(x: 0, y: 38, width: 260, height: 1))
        separator.boxType = .separator
        accessory.addSubview(separator)

        let updateArea = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 31))
        accessory.addSubview(updateArea)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        let statusLabel = NSTextField(labelWithString: "Checking for updates…")
        statusLabel.alignment = .center

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        updateArea.addSubview(statusRow)

        let updateButton = NSButton(title: "", target: nil, action: nil)
        updateButton.bezelStyle = .rounded
        updateButton.isHidden = true
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateArea.addSubview(updateButton)

        NSLayoutConstraint.activate([
            statusRow.centerXAnchor.constraint(equalTo: updateArea.centerXAnchor),
            statusRow.centerYAnchor.constraint(equalTo: updateArea.centerYAnchor),
            updateButton.centerXAnchor.constraint(equalTo: updateArea.centerXAnchor),
            updateButton.centerYAnchor.constraint(equalTo: updateArea.centerYAnchor),
        ])

        let actionHandler = AboutActionHandler()
        actionHandler.updateAction = { [weak self, weak alert] in
            guard let self, let version = self.aboutUpdateVersion else { return }
            NSApp.abortModal()
            alert?.window.orderOut(nil)
            self.startHomebrewUpdate(targetVersion: version)
        }
        updateButton.target = actionHandler
        updateButton.action = #selector(AboutActionHandler.performUpdate(_:))
        aboutActionHandler = actionHandler

        alert.accessoryView = accessory
        spinner.startAnimation(nil)

        aboutCheckTask = Task { [weak self, weak alert] in
            guard let self else { return }
            let cliTask = Task.detached(priority: .userInitiated) {
                Self.readLocalCLIVersion()
            }

            do {
                let published = try await self.fetchPublishedVersions()
                let cliVersion = await cliTask.value
                guard !Task.isCancelled, alert?.window.isVisible == true else { return }

                alert?.informativeText = "GUI version: \(guiVersion)\nCLI version: \(cliVersion)"
                spinner.stopAnimation(nil)
                spinner.isHidden = true

                guard let homebrew = published.homebrew else {
                    self.aboutUpdateVersion = nil
                    updateButton.isHidden = true
                    statusRow.isHidden = false
                    statusLabel.stringValue = "Unable to check for updates."
                    return
                }

                if guiVersion != homebrew || cliVersion != homebrew {
                    self.aboutUpdateVersion = homebrew
                    statusRow.isHidden = true
                    updateButton.title = "Update to new version \(homebrew)"
                    updateButton.isHidden = false
                } else {
                    self.aboutUpdateVersion = nil
                    updateButton.isHidden = true
                    statusRow.isHidden = false
                    statusLabel.stringValue = "You have the latest version."
                }
            } catch {
                let cliVersion = await cliTask.value
                guard !Task.isCancelled, alert?.window.isVisible == true else { return }

                alert?.informativeText = "GUI version: \(guiVersion)\nCLI version: \(cliVersion)"
                self.aboutUpdateVersion = nil
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                updateButton.isHidden = true
                statusRow.isHidden = false
                statusLabel.stringValue = "Unable to check for updates."
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        aboutCheckTask?.cancel()
        aboutCheckTask = nil
        aboutActionHandler = nil
        aboutUpdateVersion = nil
    }

    private struct PublishedVersions {
        let formula: String
        let cask: String

        var homebrew: String? {
            formula == cask ? formula : nil
        }
    }

    private func localGUIVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private nonisolated static func readLocalCLIVersion() -> String {
        func run(_ path: String, _ args: [String]) -> (String, Int32) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let out = Pipe()
            task.standardOutput = out
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                return ("", -1)
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
        }

        let candidates = [
            "/opt/homebrew/bin/netip-spn",
            "/usr/local/bin/netip-spn",
            "/usr/bin/netip-spn",
        ]

        var cli = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        if cli == nil {
            let result = run("/usr/bin/which", ["netip-spn"])
            let path = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.1 == 0, !path.isEmpty {
                cli = path
            }
        }

        guard let cli else { return "not installed" }
        let result = run(cli, ["version"])
        guard result.1 == 0 else { return "unknown" }
        return result.0.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "netip-spn ", with: "")
    }

    private func fetchPublishedVersions() async throws -> PublishedVersions {
        async let formula = fetchVersion(
            url: URL(string: "https://raw.githubusercontent.com/cloudnetip/homebrew-tap/main/Formula/cloudnetip-spn.rb")!,
            pattern: #"refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz"#
        )
        async let cask = fetchVersion(
            url: URL(string: "https://raw.githubusercontent.com/cloudnetip/homebrew-tap/main/Casks/cloudnetip-spn.rb")!,
            pattern: #"(?m)^\s*version\s+"([0-9]+\.[0-9]+\.[0-9]+)""#
        )
        let versions = try await (formula, cask)
        return PublishedVersions(formula: versions.0, cask: versions.1)
    }

    private func fetchVersion(url: URL, pattern: String) async throws -> String {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("Cloudnetip-SPN/\(localGUIVersion())", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8)
        else {
            throw NSError(domain: "CloudnetipSPN.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "Homebrew metadata could not be downloaded."])
        }

        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let versionRange = Range(match.range(at: 1), in: text)
        else {
            throw NSError(domain: "CloudnetipSPN.Update", code: 3, userInfo: [NSLocalizedDescriptionKey: "Homebrew version could not be parsed."])
        }
        return String(text[versionRange])
    }

    private func makeAboutLinkView() -> NSView {
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
        return field
    }

    private func locateBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func startHomebrewUpdate(targetVersion: String) {
        guard let brew = locateBrew() else {
            presentError("Homebrew was not found. Install Homebrew first, then open About again.")
            return
        }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Cloudnetip SPN", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            presentError("Cannot create update log: \(error.localizedDescription)")
            return
        }

        let logURL = logDir.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            presentError("Cannot open update log at \(logURL.path)")
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = homebrewUpdateScript(
            brew: brew,
            targetVersion: targetVersion,
            currentPID: pid,
            logPath: logURL.path
        )

        let alert = NSAlert()
        alert.messageText = "Updating Cloudnetip SPN"
        alert.informativeText = "Homebrew is installing version \(targetVersion). The app will restart automatically when the CLI and GUI are installed.\n\nLog: \(logURL.path)"
        alert.alertStyle = .informational

        let waitButton = alert.addButton(withTitle: "Updating…")
        waitButton.isEnabled = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        let statusLabel = NSTextField(labelWithString: "Update in progress. Please wait…")
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spinner, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        accessory.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: accessory.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor)
        ])
        alert.accessoryView = accessory
        spinner.startAnimation(nil)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        task.arguments = ["/bin/zsh", "-c", script]
        task.standardOutput = log
        task.standardError = log
        task.terminationHandler = { process in
            Task { @MainActor in
                if process.terminationStatus == 0 {
                    statusLabel.stringValue = "Update complete. Restarting…"
                    return
                }

                spinner.stopAnimation(nil)
                spinner.isHidden = true
                statusLabel.stringValue = "Update failed. See the log for details."
                alert.informativeText = "Homebrew could not install version \(targetVersion).\n\nLog: \(logURL.path)"
                waitButton.title = "OK"
                waitButton.isEnabled = true
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        do {
            try task.run()
            try? log.close()
        } catch {
            try? log.close()
            presentError("Cannot start Homebrew update: \(error.localizedDescription)")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func homebrewUpdateScript(
        brew: String,
        targetVersion: String,
        currentPID: Int32,
        logPath: String
    ) -> String {
        let qBrew = shellQuote(brew)
        let qTarget = shellQuote(targetVersion)
        let qLog = shellQuote(logPath)
        let qApp = shellQuote("/Applications/Cloudnetip SPN.app")
        let formula = "cloudnetip/tap/cloudnetip-spn"

        return """
        set -euo pipefail
        BREW=\(qBrew)
        TARGET=\(qTarget)
        LOG=\(qLog)
        APP=\(qApp)
        FORMULA=\(shellQuote(formula))

        fail_update() {
            message="$1"
            printf '%s\n' "$message" >> "$LOG"
            exit 1
        }

        "$BREW" tap cloudnetip/tap
        "$BREW" update

        TAP="$($BREW --repository cloudnetip/tap)"
        FORMULA_VERSION="$(/usr/bin/sed -nE 's|.*refs/tags/v([0-9]+\\.[0-9]+\\.[0-9]+)\\.tar\\.gz.*|\\1|p' "$TAP/Formula/cloudnetip-spn.rb" | /usr/bin/head -1)"
        CASK_VERSION="$(/usr/bin/sed -nE 's/^[[:space:]]*version "([0-9]+\\.[0-9]+\\.[0-9]+)".*/\\1/p' "$TAP/Casks/cloudnetip-spn.rb" | /usr/bin/head -1)"

        [ "$FORMULA_VERSION" = "$TARGET" ] || fail_update "Homebrew CLI is now $FORMULA_VERSION, expected $TARGET. Open About and try again."
        [ "$CASK_VERSION" = "$TARGET" ] || fail_update "Homebrew GUI is now $CASK_VERSION, expected $TARGET. Open About and try again."

        if "$BREW" list --formula cloudnetip-spn >/dev/null 2>&1; then
            "$BREW" reinstall --formula --no-ask "$FORMULA"
        else
            "$BREW" install --formula --no-ask "$FORMULA"
        fi

        if "$BREW" list --cask cloudnetip-spn >/dev/null 2>&1; then
            "$BREW" reinstall --cask --force --no-ask "$FORMULA"
        else
            "$BREW" install --cask --force --no-ask "$FORMULA"
        fi

        BREW_PREFIX="$("$BREW" --prefix)"
        CLI_BIN="$BREW_PREFIX/bin/netip-spn"
        [ -x "$CLI_BIN" ] || fail_update "CLI verification failed: $CLI_BIN was not installed."
        CLI_VERSION="$("$CLI_BIN" version 2>/dev/null | /usr/bin/sed -nE '1s/^netip-spn[[:space:]]+([^[:space:]]+).*$/\\1/p')"
        GUI_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
        [ "$CLI_VERSION" = "$TARGET" ] || fail_update "CLI verification failed: got $CLI_VERSION, expected $TARGET."
        [ "$GUI_VERSION" = "$TARGET" ] || fail_update "GUI verification failed: got $GUI_VERSION, expected $TARGET."

        /bin/kill \(currentPID) >/dev/null 2>&1 || true
        /bin/sleep 1
        /usr/bin/open -n "$APP"
        """
    }

    func quit() {
        if isConnected {
            disconnect()
        }
        NSApp.terminate(nil)
    }

    func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        applyLaunchAtLogin(launchAtLogin)
    }

    func toggleShowStatsInBar() {
        showStatsInBar.toggle()
        UserDefaults.standard.set(showStatsInBar, forKey: "showStatsInBar")
        previousTrafficSample = nil
        rxRateText = "0 KB/s"
        txRateText = "0 KB/s"
        if showStatsInBar {
            refreshTraffic()
        } else {
            refresh()
        }
    }

    func showLogs() {
        let url = connectionLogURL()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "No WireGuard connection logs yet."

        let window = logWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cloudnetip SPN — WireGuard Logs"
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.string = text

        scrollView.documentView = textView
        window.contentView = scrollView
        if logWindow == nil {
            window.center()
            logWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        textView.scrollToEndOfDocument(nil)
    }

    private static func readShowStatsInBar() -> Bool {
        UserDefaults.standard.bool(forKey: "showStatsInBar")
    }

    private func connectionLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudnetip", isDirectory: true)
            .appendingPathComponent("wireguard.log")
    }

    private func appendConnectionLog(command: String, result: ProcResult) {
        let fm = FileManager.default
        let url = connectionLogURL()
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > 1_000_000 {
                try? fm.removeItem(at: url)
            }

            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            var entry = "[\(timestamp)] netip-spn \(command) — exit \(result.exitCode)\n"
            if !result.stdout.isEmpty {
                entry += result.stdout
                if !result.stdout.hasSuffix("\n") { entry += "\n" }
            }
            if !result.stderr.isEmpty {
                entry += "[stderr]\n" + result.stderr
                if !result.stderr.hasSuffix("\n") { entry += "\n" }
            }
            entry += "\n"

            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
        }
    }

    private static func readLaunchAtLogin() -> Bool {
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

    private func runAsync(_ path: String, args: [String], completion: @escaping (ProcResult) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.terminationHandler = { process in
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let result = ProcResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
            Task { @MainActor in completion(result) }
        }
        do {
            try task.run()
        } catch {
            completion(ProcResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
        }
    }

    private func runAsAdministrator(
        _ path: String,
        args: [String],
        prompt: String,
        completion: @escaping (ProcResult) -> Void
    ) {
        let command = ([path] + args).map(shellQuote).joined(separator: " ")
        let script = """
        on run argv
            do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges
        end run
        """
        runAsync("/usr/bin/osascript", args: ["-e", script, command, prompt], completion: completion)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
