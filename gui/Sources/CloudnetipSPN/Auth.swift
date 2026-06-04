import AppKit
import CryptoKit
import Darwin
import Foundation

// OAuth 2.0 authorization-code flow with PKCE (RFC 7636) over a loopback
// redirect (RFC 8252). The server's claim endpoint returns a wg-quick config
// directly — no Bearer token is ever issued, so there's nothing to persist
// beyond ~/.cloudnetip/spn.conf itself.
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var hasConfig = false
    @Published private(set) var inProgress = false
    @Published var lastError: String?

    private var loginTask: Task<Void, Never>?
    private var callbackServer: LoopbackServer?

    static let configPath: String = (NSString(string: "~/.cloudnetip/spn.conf").expandingTildeInPath)
    static let wgConfigPath: String = (NSString(string: "~/.cloudnetip/wg-netip.conf").expandingTildeInPath)

    private static var apiBase: String {
        if let v = ProcessInfo.processInfo.environment["NETIP_API_URL"], !v.isEmpty {
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "https://cloudnetip.com"
    }

    init() { refreshState() }

    func refreshState() {
        hasConfig = FileManager.default.fileExists(atPath: Self.configPath)
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
                try Self.saveConfig(conf)
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

    func logout() {
        try? FileManager.default.removeItem(atPath: Self.configPath)
        try? FileManager.default.removeItem(atPath: Self.wgConfigPath)
        hasConfig = false
    }

    // MARK: - Flow

    private func runLoopbackFlow() async throws -> Data {
        let server = try LoopbackServer.start()
        await MainActor.run { self.callbackServer = server }
        defer { server.stop() }

        let port = server.port
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let state = Self.randomURLSafe(24)
        let verifier = Self.randomURLSafe(48)
        let challenge = Self.pkceS256(verifier)

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
        guard callback.state == state else {
            throw AuthError.message("State mismatch — possible CSRF, ignored.")
        }
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

    private static func saveConfig(_ data: Data) throws {
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: URL(fileURLWithPath: configPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
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

// MARK: - Loopback HTTP server

// Minimal HTTP/1.1 server bound to 127.0.0.1:0 via POSIX sockets. We use
// raw BSD sockets (not NWListener) because NWListener.port is populated
// asynchronously after start() and a polling loop occasionally returned 0
// in release builds — so the redirect_uri shipped a port=0 URL.
final class LoopbackServer: @unchecked Sendable {
    struct Callback {
        let code: String?
        let state: String?
        let error: String?
    }

    private let listenFD: Int32
    private var continuation: CheckedContinuation<Callback, Error>?
    private let queue = DispatchQueue(label: "netip.spn.loopback")
    private var done = false

    let port: Int

    static func start() throws -> LoopbackServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw makeErr("socket(): \(String(cString: strerror(errno)))") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                  // kernel picks
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

        return LoopbackServer(listenFD: fd, port: port)
    }

    private init(listenFD: Int32, port: Int) {
        self.listenFD = listenFD
        self.port = port
        // accept() blocks, so run it on a dedicated background thread —
        // not on `queue`, which we keep free for state synchronization.
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
                self.continuation?.resume(throwing: NSError(
                    domain: "LoopbackServer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "timed out waiting for browser callback"]))
                self.continuation = nil
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if self.done { return }
                self.continuation = cont
            }
        }
    }

    func stop() {
        queue.async {
            guard !self.done else { return }
            self.done = true
            close(self.listenFD)
        }
    }

    private func acceptLoop() {
        while !done {
            var caddr = sockaddr()
            var clen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &caddr, &clen)
            if client < 0 {
                if done { return }
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
        let cb = Self.parseCallback(request)
        let body = Self.responseHTML(cb)
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        resp.withCString { ptr in
            _ = send(fd, ptr, strlen(ptr), 0)
        }
        queue.async {
            guard !self.done else { return }
            self.done = true
            self.continuation?.resume(returning: cb)
            self.continuation = nil
            close(self.listenFD)
        }
    }

    private static func parseCallback(_ request: String) -> Callback {
        guard let firstLine = request.split(separator: "\r\n").first else {
            return Callback(code: nil, state: nil, error: "bad request")
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return Callback(code: nil, state: nil, error: "bad request")
        }
        let path = String(parts[1])
        guard let comp = URLComponents(string: "http://127.0.0.1" + path) else {
            return Callback(code: nil, state: nil, error: "bad path")
        }
        let q = Dictionary(uniqueKeysWithValues:
            (comp.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return Callback(code: q["code"], state: q["state"], error: q["error"])
    }

    private static func responseHTML(_ cb: Callback) -> String {
        let ok = cb.error == nil && cb.code != nil
        let title = ok ? "✓ Configured" : "Sign-in failed"
        let body = ok
            ? "You can close this tab and return to the app."
            : "Error: \(cb.error ?? "unknown")"
        return """
        <!doctype html><meta charset=utf-8><title>\(title)</title>
        <style>body{font:16px/1.4 -apple-system,system-ui,sans-serif;max-width:520px;margin:80px auto;padding:0 20px;text-align:center}h1{margin-bottom:8px}</style>
        <h1>\(title)</h1><p>\(body)</p>
        <script>setTimeout(function(){window.close()},1500)</script>
        """
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
