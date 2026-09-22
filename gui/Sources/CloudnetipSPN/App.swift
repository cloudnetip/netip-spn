import AppKit
import SwiftUI

@main
struct CloudnetipSPNApp: App {
    @StateObject private var controller = SPNController()
    @StateObject private var auth = AuthService()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, auth: auth)
        } label: {
            MenuBarIcon(isConnected: controller.isConnected)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    var isConnected: Bool

    private static let baseImage: NSImage? = {
        guard
            let url = Bundle.main.url(
                forResource: "MenuBarIconTemplate",
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private static let fadedImage: NSImage? = {
        guard let base = baseImage else { return nil }
        let size = base.size
        let faded = NSImage(size: size)
        faded.lockFocus()
        base.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.35
        )
        faded.unlockFocus()
        faded.size = size
        faded.isTemplate = true
        return faded
    }()

    var body: some View {
        if let image = isConnected ? Self.baseImage : Self.fadedImage {
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            Image(systemName: "cloud")
                .opacity(isConnected ? 1.0 : 0.35)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: SPNController
    @ObservedObject var auth: AuthService

    var body: some View {
        if let err = controller.error {
            Text("⚠︎ \(err)").font(.system(size: 12))
            Divider()
        }

        Text(controller.statusLine).font(.system(size: 12, weight: .semibold))
        if let detail = controller.statusDetail {
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let traffic = controller.trafficLine {
            Text(traffic).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Divider()

        if controller.isConnected {
            Button("Disconnect") { controller.disconnect() }
                .keyboardShortcut("d")
        } else {
            Button("Connect") { controller.connect() }
                .keyboardShortcut("c")
                .disabled(!controller.hasConfig)
        }

        Divider()

        if !auth.hasConfig {
            Button(auth.inProgress ? "Signing in…" : "Sign in…") {
                AuthFlowPresenter.start(auth: auth, controller: controller)
            }
            .disabled(auth.inProgress)
        }

        Button("Choose config…") { controller.chooseConfig() }
        if controller.hasConfig {
            Button("Reveal config in Finder") { controller.revealConfig() }
        }

        Divider()

        Toggle("Launch at login", isOn: Binding(
            get: { controller.launchAtLogin },
            set: { _ in controller.toggleLaunchAtLogin() }
        ))

        Button("Refresh") { controller.refresh() }
            .keyboardShortcut("r")

        Divider()

        if auth.hasConfig {
            Button("Sign out") {
                auth.logout()
                controller.refresh()
            }
        }

        Button("About Cloudnetip SPN") { controller.showAbout() }
        Button("Quit Cloudnetip SPN") { controller.quit() }
            .keyboardShortcut("q")
    }
}
