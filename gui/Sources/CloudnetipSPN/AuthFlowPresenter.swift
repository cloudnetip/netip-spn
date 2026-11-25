import AppKit
import Foundation

// Connect immediately after the browser sign-in has saved the configuration.
// Only show an alert if sign-in fails.
@MainActor
enum AuthFlowPresenter {
    static func start(auth: AuthService, controller: SPNController) {
        auth.startLogin { success in
            if success {
                controller.refresh()
                controller.connect()
            } else if let err = auth.lastError {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Sign-in failed"
                a.informativeText = err
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
        }
    }
}
