import AppKit
import CryptoKit
import Darwin
import Foundation

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var hasConfig = false
    @Published private(set) var inProgress = false
    @Published var lastError: String?

    private var loginTask: Task<Void, Never>?
    private var callbackServer: LoopbackServer?

    static let configPath = "/Library/Application Support/Cloudnetip SPN/spn.conf"

    private static var apiBase: String {
        if let v = ProcessInfo.processInfo.environment["NETIP_API_URL"], !v.isEmpty {
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "https://cloudnetip.com"
    }

    init() { refreshState() }

    func refreshState() {
        let legacy = (NSString(string: "~/.cloudnetip/spn.conf").expandingTildeInPath)
        hasConfig = FileManager.default.fileExists(atPath: Self.configPath) ||
            FileManager.default.fileExists(atPath: legacy)
    }

    func startLogin() {
        guard !inProgress else { return }
        lastError = nil
        inProgress = true

        loginTask?.cancel()
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conf = try await self.runLoopbackFlow()
                guard String(data: conf, encoding: .utf8)?.contains("[Interface]") == true else {
                    throw AuthError.message("Server did not return a WireGuard config.")
                }
                try await Self.saveConfig(conf)
                await MainActor.run {
                    self.hasConfig = true
                    self.inProgress = false
                }
            } catch is CancellationError {
                await MainActor.run { self.inProgress = false }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.inProgress = false
                }
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        callbackServer?.stop()
        callbackServer = nil
        loginTask = nil
        inProgress = false
    }

    func logout(completion: @escaping (Bool) -> Void = { _ in }) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.runPrivilegedConfigCommand(
                    "_config-remove",
                    sourcePath: nil,
                    prompt: "Cloudnetip SPN needs administrator permission to remove the protected VPN configuration."
                )
                await MainActor.run {
                    self.hasConfig = false
                    self.lastError = nil
                    completion(true)
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Sign out failed"
                    alert.informativeText = error.localizedDescription
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    completion(false)
                }
            }
        }
    }

    private func runLoopbackFlow() async throws -> Data {
        let state = Self.randomURLSafe(24)
        let verifier = Self.randomURLSafe(48)
        let challenge = Self.pkceS256(verifier)

        let server = try LoopbackServer.start(expectedState: state)
        await MainActor.run { self.callbackServer = server }
        defer { server.stop() }

        let port = server.port
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        var comp = URLComponents(string: Self.apiBase + "/app/shared/authorize")!
        comp.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "spn"),
        ]
        guard let url = comp.url else { throw AuthError.message("Bad authorize URL") }

        NSWorkspace.shared.open(url)

        let callback = try await server.waitForCallback(timeout: 300)
        if let oauthErr = callback.error {
            throw AuthError.message("Authorization failed: \(oauthErr)")
        }
        guard let code = callback.code else {
            throw AuthError.message("No code in callback.")
        }
        return try await claimConfig(code: code, verifier: verifier, redirectURI: redirectURI)
    }

    private func claimConfig(code: String, verifier: String, redirectURI: String) async throws -> Data {
        var req = URLRequest(url: URL(string: Self.apiBase + "/api/spn/clients/config/claim")!)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.message("claim failed (HTTP \(code)): \(body)")
        }
        return data
    }

    private static func saveConfig(_ data: Data) async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudnetip-spn-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        try await runPrivilegedConfigCommand(
            "_config-install",
            sourcePath: temp.path,
            prompt: "Cloudnetip SPN needs administrator permission to protect the VPN configuration from modification by normal user processes."
        )
        let legacyDir = (NSString(string: "~/.cloudnetip").expandingTildeInPath)
        try? FileManager.default.removeItem(atPath: legacyDir)
    }

    private static func runPrivilegedConfigCommand(
        _ command: String,
        sourcePath: String?,
        prompt: String
    ) async throws {
        guard let resources = Bundle.main.resourceURL else {
            throw AuthError.message("Application resources are unavailable.")
        }
        let helper = resources.appendingPathComponent("WireGuard/helper").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw AuthError.message("Bundled privileged helper is missing.")
        }
        var arguments = [command]
        if let sourcePath { arguments.append(sourcePath) }
        let shellCommand = ([helper] + arguments).map(shellQuote).joined(separator: " ")
        let script = """
        on run argv
            do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges
        end run
        """

        let result = await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script, shellCommand, prompt]
            let out = Pipe(), err = Pipe()
            task.standardOutput = out
            task.standardError = err
            task.terminationHandler = { process in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }
            do {
                try task.run()
            } catch {
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
        guard result.0 == 0 else {
            let message = result.2.isEmpty ? result.1 : result.2
            throw AuthError.message(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func userAgent() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "netip-spn-gui/\(v) (macos)"
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func pkceS256(_ verifier: String) -> String {
        let data = verifier.data(using: .utf8) ?? Data()
        return Data(SHA256.hash(data: data)).base64URLEncoded()
    }

    enum AuthError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }
}

final class LoopbackServer: @unchecked Sendable {
    struct Callback {
        let code: String?
        let state: String?
        let error: String?
    }

    private let listenFD: Int32
    private let expectedState: String
    private var continuation: CheckedContinuation<Callback, Error>?
    private var pendingCallback: Callback?
    private let queue = DispatchQueue(label: "netip.spn.loopback")
    private var done = false
    private var listenerClosed = false

    let port: Int

    static func start(expectedState: String) throws -> LoopbackServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw makeErr("socket(): \(String(cString: strerror(errno)))") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bindOK = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        if bindOK != 0 {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw makeErr("bind(): \(msg)")
        }
        if listen(fd, 4) != 0 {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw makeErr("listen(): \(msg)")
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        if nameOK != 0 {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw makeErr("getsockname(): \(msg)")
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        guard port > 0 else {
            close(fd)
            throw makeErr("kernel returned port 0")
        }

        return LoopbackServer(listenFD: fd, port: port, expectedState: expectedState)
    }

    private init(listenFD: Int32, port: Int, expectedState: String) {
        self.listenFD = listenFD
        self.port = port
        self.expectedState = expectedState
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private static func makeErr(_ msg: String) -> NSError {
        NSError(domain: "LoopbackServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.queue.async {
                guard let self, !self.done else { return }
                self.done = true
                self.closeListenerLocked()
                self.continuation?.resume(throwing: NSError(
                    domain: "LoopbackServer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "timed out waiting for browser callback"]))
                self.continuation = nil
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let pending = self.pendingCallback {
                    self.pendingCallback = nil
                    cont.resume(returning: pending)
                    return
                }
                if self.done {
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
            }
        }
    }

    func stop() {
        queue.async {
            guard !self.done else {
                self.closeListenerLocked()
                return
            }
            self.done = true
            self.closeListenerLocked()
            self.continuation?.resume(throwing: CancellationError())
            self.continuation = nil
            self.pendingCallback = nil
        }
    }

    private func closeListenerLocked() {
        guard !listenerClosed else { return }
        listenerClosed = true
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            var caddr = sockaddr()
            var clen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &caddr, &clen)
            if client < 0 {
                if errno == EBADF || errno == EINVAL { return }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            handleClient(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(fd, &buf, buf.count, 0)
        let request = n > 0
            ? String(bytes: buf[0..<n], encoding: .utf8) ?? ""
            : ""

        guard let parsed = Self.parseRequest(request) else {
            Self.sendResponse(fd, status: "400 Bad Request", body: Self.messageHTML(
                title: "Sign-in request ignored",
                body: "The local callback request was malformed. Return to the active sign-in tab."
            ))
            return
        }

        guard parsed.path == "/callback" else {
            Self.sendResponse(fd, status: "404 Not Found", body: "Not found")
            return
        }

        guard parsed.callback.state == expectedState else {
            Self.sendResponse(fd, status: "200 OK", body: Self.messageHTML(
                title: "Old sign-in request ignored",
                body: "This callback belongs to an earlier sign-in attempt. Continue in the newest Cloudnetip SPN sign-in tab."
            ))
            return
        }

        let body = Self.responseHTML(parsed.callback)
        Self.sendResponse(fd, status: "200 OK", body: body)

        queue.async {
            guard !self.done else { return }
            self.done = true
            self.closeListenerLocked()
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: parsed.callback)
            } else {
                self.pendingCallback = parsed.callback
            }
        }
    }

    private static func sendResponse(_ fd: Int32, status: String, body: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        resp.withCString { ptr in
            _ = send(fd, ptr, strlen(ptr), 0)
        }
    }

    private static func parseRequest(_ request: String) -> (path: String, callback: Callback)? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let rawPath = String(parts[1])
        guard let comp = URLComponents(string: "http://127.0.0.1" + rawPath) else { return nil }
        let q = Dictionary(uniqueKeysWithValues:
            (comp.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return (
            path: comp.path,
            callback: Callback(code: q["code"], state: q["state"], error: q["error"])
        )
    }

    private static func responseHTML(_ cb: Callback) -> String {
        if let error = cb.error {
            return messageHTML(title: "Sign-in failed", body: "Error: \(error)")
        }
        return messageHTML(
            title: "✓ Sign-in received",
            body: "You can close this tab and return to the app."
        )
    }

    private static func messageHTML(title: String, body: String) -> String {
        let safeTitle = htmlEscape(title)
        let safeBody = htmlEscape(body)
        return """
        <!doctype html><meta charset=utf-8><title>\(safeTitle)</title>
        <style>body{font:16px/1.4 -apple-system,system-ui,sans-serif;max-width:520px;margin:80px auto;padding:0 20px;text-align:center}h1{margin-bottom:8px}</style>
        <h1>\(safeTitle)</h1><p>\(safeBody)</p>
        <script>setTimeout(function(){window.close()},1500)</script>
        """
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
