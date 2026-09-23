import AppKit
import Combine
import CoreText
import SwiftUI

@main
struct CloudnetipSPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let controller = SPNController()
            let auth = AuthService()
            self.statusBarController = StatusBarController(controller: controller, auth: auth)
        }
    }
}

@MainActor
private final class StatusBarController: NSObject, NSMenuDelegate {
    private let controller: SPNController
    private let auth: AuthService
    private let statusItem: NSStatusItem
    private let contentView = StatusBarContentView()
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(controller: SPNController, auth: AuthService) {
        self.controller = controller
        self.auth = auth
        self.statusItem = NSStatusBar.system.statusItem(withLength: StatusBarContentView.iconOnlyWidth)
        super.init()

        statusItem.autosaveName = "CloudnetipSPN"
        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.toolTip = "Cloudnetip SPN"
            button.setAccessibilityLabel("Cloudnetip SPN")

            contentView.frame = button.bounds
            contentView.autoresizingMask = [.width, .height]
            button.addSubview(contentView)
        }

        observeStatusChanges()
        updateStatusItem()
    }

    private func observeStatusChanges() {
        controller.$isConnected
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        controller.$showStatsInBar
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        controller.$txRateText
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        controller.$rxRateText
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        let showStats = controller.isConnected && controller.showStatsInBar
        statusItem.length = StatusBarContentView.preferredWidth(
            showStats: showStats,
            txRate: controller.txRateText,
            rxRate: controller.rxRateText
        )
        contentView.update(
            isConnected: controller.isConnected,
            showStats: showStats,
            txRate: controller.txRateText,
            rxRate: controller.rxRateText
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error = controller.error, !error.isEmpty {
            addDisabled("⚠︎ \(error)")
            menu.addItem(.separator())
        }

        addDisabled(controller.statusLine)
        if let detail = controller.statusDetail, !detail.isEmpty {
            addDisabled(detail)
        }
        if let traffic = controller.trafficLine, !traffic.isEmpty {
            addDisabled(traffic)
        }
        menu.addItem(.separator())

        if controller.isConnected {
            addAction("Disconnect", action: #selector(disconnect), key: "d")
        } else {
            addAction("Connect", action: #selector(connect), key: "c", enabled: controller.hasConfig)
        }

        menu.addItem(.separator())

        if !auth.hasConfig {
            addAction(
                auth.inProgress ? "Signing in…" : "Sign in…",
                action: #selector(signIn),
                enabled: !auth.inProgress
            )
        }

        addAction("Choose config…", action: #selector(chooseConfig))
        if controller.hasConfig {
            addAction("Reveal config in Finder", action: #selector(revealConfig))
        }

        menu.addItem(.separator())

        let launch = addAction("Launch at login", action: #selector(toggleLaunchAtLogin))
        launch.state = controller.launchAtLogin ? .on : .off

        let stats = addAction("Show stats in bar", action: #selector(toggleShowStats))
        stats.state = controller.showStatsInBar ? .on : .off

        addAction("Show logs", action: #selector(showLogs))

        if auth.hasConfig {
            addAction("Sign out", action: #selector(signOut))
        }

        menu.addItem(.separator())
        addAction("About Cloudnetip SPN", action: #selector(showAbout))
        addAction("Quit Cloudnetip SPN", action: #selector(quit), key: "q")
    }

    @discardableResult
    private func addAction(
        _ title: String,
        action: Selector,
        key: String = "",
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func connect() { controller.connect() }
    @objc private func disconnect() { controller.disconnect() }
    @objc private func signIn() { AuthFlowPresenter.start(auth: auth, controller: controller) }
    @objc private func chooseConfig() { controller.chooseConfig() }
    @objc private func revealConfig() { controller.revealConfig() }
    @objc private func toggleLaunchAtLogin() { controller.toggleLaunchAtLogin() }
    @objc private func toggleShowStats() { controller.toggleShowStatsInBar() }
    @objc private func showLogs() { controller.showLogs() }
    @objc private func showAbout() { controller.showAbout() }
    @objc private func quit() { controller.quit() }

    @objc private func signOut() {
        auth.logout()
        controller.refresh()
    }
}

@MainActor
private final class StatusBarContentView: NSView {
    static let itemHeight: CGFloat = 22
    static let iconSize: CGFloat = 18
    static let iconOnlyWidth: CGFloat = iconSize

    private static let iconTextGap: CGFloat = 0.0
    private static let textX = iconSize + iconTextGap

    private static let trailingSafety: CGFloat = 4.0

    private static let rateFont: NSFont = {
        let base = NSFont.menuBarFont(ofSize: 9.0)
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: 9.0)
            ?? NSFont.systemFont(ofSize: 9.0, weight: .regular)
    }()

    private static func measuredRateWidth(_ value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: rateFont]).width)
    }

    private static let rateTextWidth: CGFloat = {
        let localeSeparator = Locale.current.decimalSeparator ?? "."
        let separators = Array(Set([localeSeparator, ".", ","]))
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]

        var samples = ["888 KB/s"]
        for separator in separators {
            samples += units.map { "88\(separator)88 \($0)" }
        }

        return (samples.map(measuredRateWidth).max() ?? 0) + 1.0
    }()

    private let iconView = NSImageView()
    private let txLabel = NSTextField(labelWithString: "0 KB/s")
    private let rxLabel = NSTextField(labelWithString: "0 KB/s")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        iconView.image = Self.loadIcon()
        addSubview(iconView)

        configureRateLabel(txLabel)
        configureRateLabel(rxLabel)
        addSubview(txLabel)
        addSubview(rxLabel)
    }

    required init?(coder: NSCoder) { nil }

    static func preferredWidth(showStats: Bool, txRate: String, rxRate: String) -> CGFloat {
        guard showStats else { return iconOnlyWidth }
        return textX + rateTextWidth + trailingSafety
    }

    func update(isConnected: Bool, showStats: Bool, txRate: String, rxRate: String) {
        iconView.alphaValue = isConnected ? 1.0 : 0.35
        txLabel.stringValue = txRate
        rxLabel.stringValue = rxRate
        txLabel.isHidden = !showStats
        rxLabel.isHidden = !showStats
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height > 0 ? bounds.height : Self.itemHeight
        iconView.frame = NSRect(
            x: 0,
            y: floor((height - Self.iconSize) / 2),
            width: Self.iconSize,
            height: Self.iconSize
        )

        let rowHeight: CGFloat = 10
        let bottomY: CGFloat = 2
        let topY: CGFloat = bottomY + 9
        let textFrameWidth = max(0, bounds.width - Self.textX)
        rxLabel.frame = NSRect(x: Self.textX, y: bottomY, width: textFrameWidth, height: rowHeight)
        txLabel.frame = NSRect(x: Self.textX, y: topY, width: textFrameWidth, height: rowHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        iconView.contentTintColor = .labelColor
        txLabel.textColor = .labelColor
        rxLabel.textColor = .labelColor
    }

    private func configureRateLabel(_ label: NSTextField) {
        label.font = Self.rateFont
        label.textColor = .labelColor
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isBezeled = false
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.cell?.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private static func loadIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: iconSize, height: iconSize)
            image.isTemplate = true
            return image
        }
        let image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
