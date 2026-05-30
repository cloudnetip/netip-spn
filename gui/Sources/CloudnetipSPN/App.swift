import SwiftUI

@main
struct CloudnetipSPNApp: App {
    @StateObject private var controller = SPNController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.isConnected ? "cloud.fill" : "cloud")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var controller: SPNController

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

        Button("About Cloudnetip SPN") { controller.showAbout() }
        Button("Quit Cloudnetip SPN") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
