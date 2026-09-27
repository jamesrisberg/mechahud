import AppKit
import HUDKit
import MechaHUDKit

/// Menu bar app (no Dock icon): the glass panel, the MacHUD socket, the ⌃⌥M hotkey.
@MainActor
public final class MechaHUDApp: NSObject, NSApplicationDelegate {
    public nonisolated static let socketName = "mechahud"
    public static let hotKey = HUDHotKey(key: "m", modifiers: ["control", "option"])

    private let settings = AppSettings(defaults: AppEnvironment.defaults)
    private var bridge: BridgeClient!
    private var host: MechaHUDHost!
    private var panel: PanelController!
    private var server: HUDSocketServer!
    private var router: HUDControlRouter!
    private var statusItem: NSStatusItem!

    public static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "ctl" {
            exit(HUDSocketClient.runCLI(path: AppEnvironment.socketPath, arguments: Array(args.dropFirst(2)), appName: "MechaHUD"))
        }
        let app = NSApplication.shared
        let delegate = MechaHUDApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        HUDEditMenu.install(appName: "MechaHUD")
        bridge = BridgeClient(settings: settings)
        panel = PanelController(bridge: bridge, settings: settings)
        host = MechaHUDHost(presenter: panel, bridge: bridge, settings: settings)
        host.manifest = HUDManifest.main ?? MechaHUDHost.embeddedManifest

        server = HUDSocketServer(path: AppEnvironment.socketPath, label: "xyz.machud.mechahud.socket")
        router = HUDControlRouter(host: host, server: server, manifest: host.manifest)
        router.install()
        // A `--snapshot` run leaves the socket and the hotkey to a running MechaHUD.
        if AppEnvironment.snapshotPath == nil, !server.start() { NSLog("MechaHUD: could not start socket at %@", server.path) }

        host.onStateChange = { [weak self] in
            self?.router.publishState()
            self?.refreshStatusItem()
        }
        host.onSettingsChange = { [weak self] in
            self?.panel.ui.reloadID += 1
            self?.bridge.reconnect()
        }
        bridge.onChange = { [weak self] in
            guard let self else { return }
            self.host.update(feed: self.bridge.feed, reachability: self.bridge.reachability)
        }
        panel.onUserMode = { [weak self] mode in self?.changePanel { try $0.setPanelMode(MechaHUDHost.panelID, mode: mode) } }
        panel.onUserHide = { [weak self] in self?.changePanel { try $0.hidePanel(MechaHUDHost.panelID) } }

        if AppEnvironment.hotKeysEnabled, AppEnvironment.snapshotPath == nil {
            HUDHotKeyCenter.shared.register(Self.hotKey) { [weak self] in
                self?.changePanel { try $0.togglePanel(MechaHUDHost.panelID) }
            }
        }
        setUpStatusItem()
        // While MacHUD runs, its menu hosts this one and the icon hides (HUDKit menu bar consolidation).
        router.menuProvider = { [weak self] in self?.statusItem?.menu }
        // menuBar.consumed lives with the other settings (AppEnvironment.defaults), so MECHAHUD_HOME isolates it.
        HUDStatusItemPolicy.attach(statusItem, appID: host.manifest.id, store: .defaults(AppEnvironment.defaults))
        bridge.start()
        changePanel { try $0.showPanel(MechaHUDHost.panelID) }
        if let path = AppEnvironment.snapshotPath { snapshot(to: path) }
    }

    /// `--snapshot <path.png>`: the panel is shown at launch; once it settles, write a PNG of it
    /// (the same rendering as `action name=snapshot`) and quit. For docs and UI checks without
    /// Screen Recording permission.
    private func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.panel.snapshot(to: path) { error in
                if let error {
                    FileHandle.standardError.write(Data("MechaHUD: snapshot failed: \(error)\n".utf8))
                } else {
                    print(path)
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// A panel change from the app's own UI (hotkey, menu, strip buttons): apply it, then
    /// publish once. Socket `panel` commands are published by the router instead.
    private func changePanel(_ change: (MechaHUDHost) throws -> Void) {
        try? change(host)
        router.publishState()
        refreshStatusItem()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        bridge?.stop()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "terminal", accessibilityDescription: "MechaHUD")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.addItem(item("Show MechaHUD", #selector(showPanel)))
        menu.addItem(item("Show/Hide Panel (\(Self.hotKey.display))", #selector(togglePanel)))
        menu.addItem(item("Compact", #selector(compactMode)))
        menu.addItem(item("Full", #selector(fullMode)))
        menu.addItem(item("Park", #selector(parkMode)))
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard in Browser", #selector(openInBrowser)))
        menu.addItem(item("Start Dashboard (webctl start)", #selector(startDashboard)))
        menu.addItem(item("Reconnect", #selector(reconnect)))
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit MechaHUD", #selector(quit), key: "q"))
        statusItem.menu = menu
        refreshStatusItem()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func refreshStatusItem() {
        statusItem?.button?.title = host?.badge.map { " \($0)" } ?? ""
        statusItem?.button?.toolTip = "MechaHUD: \(host?.status ?? "")"
    }

    /// Summons the panel at its last frame, in its last shown mode.
    @objc private func showPanel() { changePanel { try $0.showPanel(MechaHUDHost.panelID) } }
    @objc private func togglePanel() { changePanel { try $0.togglePanel(MechaHUDHost.panelID) } }
    @objc private func compactMode() { show(.compact) }
    @objc private func fullMode() { show(.full) }
    @objc private func parkMode() { changePanel { try $0.setPanelMode(MechaHUDHost.panelID, mode: .parked) } }

    private func show(_ mode: HUDPanelMode) {
        changePanel {
            try $0.setPanelMode(MechaHUDHost.panelID, mode: mode)
            try $0.showPanel(MechaHUDHost.panelID)
        }
    }
    @objc private func openInBrowser() { NSWorkspace.shared.open(settings.dashboardURL) }
    @objc private func startDashboard() { bridge.startDashboard(); fullMode() }
    @objc private func reconnect() { bridge.reconnect() }
    @objc private func showSettings() { panel.ui.showingSettings = true; fullMode() }
    @objc private func quit() { NSApp.terminate(nil) }
}
