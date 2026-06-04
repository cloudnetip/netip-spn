import AppKit
import Combine
import Foundation

// AuthFlowPresenter starts the auth flow and pops a single result NSAlert
// when it finishes — no codes to copy, no manual steps. The browser handles
// everything and redirects back to our loopback listener.
@MainActor
enum AuthFlowPresenter {
    private static var observers: Set<AnyCancellable> = []

    static func start(auth: AuthService, controller: SPNController) {
        observers.removeAll()
        auth.startLogin()

        let watcher = auth.$inProgress
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .first()
            .sink { _ in
                observers.removeAll()
                if auth.hasConfig {
                    controller.refresh()
                    let done = NSAlert()
                    done.messageText = "✓ Configured"
                    done.informativeText = "Successful handshake with Cloudnetip SPN. You can now connect."
                    NSApp.activate(ignoringOtherApps: true)
                    done.runModal()
                } else if let err = auth.lastError {
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "Sign-in failed"
                    a.informativeText = err
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
            }
        observers.insert(AnyCancellable(watcher))
    }
}
