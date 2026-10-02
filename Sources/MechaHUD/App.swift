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
    private var widgets: MechaHUDWidgets!
    private var statusItem: NSStatusItem!
    /// Disabled line (with its separator) shown only while `MechaHUDHost.spawnReadiness` has a
    /// problem: mirrors the `sessions` reply's `problem`/`fix` where the user actually looks.
    private var spawnProblemItem: NSMenuItem!
    private var spawnProblemSeparator: NSMenuItem!

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
        // The `sessions` widget type; its model is fed from the bridge client below.
        widgets = MechaHUDWidgets(
            manifest: HUDManifest.main ?? MechaHUDHost.embeddedManifest,
            openDashboard: { [weak self] in self?.changePanel { try $0.showPanel(MechaHUDHost.panelID) } },
            openSession: { [weak self] key in self?.host.performAction("open-session", args: ["id": key]) { _ in } })
        // `--snapshot-widgets` needs neither the bridge (it would read the token file) nor a socket.
        if let directory = AppEnvironment.widgetSnapshotDirectory {
            snapshotWidgets(to: directory)
            return
        }
        // A `--snapshot` run draws the panel from made-up sessions: its bridge is offline, so it
        // reads no token, and it has no socket, hotkey, menu bar item or stream.
        let snapshotting = AppEnvironment.snapshotPath != nil
        bridge = BridgeClient(settings: settings, offline: snapshotting)
        if snapshotting { bridge.showSample(feed: SessionsWidgetSample.feed, reachability: .connected) }
        panel = PanelController(bridge: bridge, settings: settings)
        host = MechaHUDHost(presenter: panel, bridge: bridge, settings: settings)
        host.manifest = HUDManifest.main ?? MechaHUDHost.embeddedManifest

        server = HUDSocketServer(path: AppEnvironment.socketPath, label: "xyz.machud.mechahud.socket")
        router = HUDControlRouter(host: host, server: server, manifest: host.manifest)
        router.install()
        // Set before the socket starts: MacHUD sends `widget sync` as soon as it connects.
        router.widgetHost = widgets.host
        // The `agent-sessions` capability's own verb (not `action`, so MacHUD's broker can ask
        // every provider the same way regardless of its app-specific action names).
        server.register("sessions") { [weak host] _, done in done(host?.sessionsPayload() ?? ["ok": false, "error": "no host"]) }
        if !snapshotting, !server.start() { NSLog("MechaHUD: could not start socket at %@", server.path) }

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
            self.widgets.model.update(feed: self.bridge.feed, reachability: self.bridge.reachability,
                                      reconnecting: self.bridge.holdingDashboard)
        }
        panel.onUserMode = { [weak self] mode in self?.changePanel { try $0.setPanelMode(MechaHUDHost.panelID, mode: mode) } }
        panel.onUserHide = { [weak self] in self?.changePanel { try $0.hidePanel(MechaHUDHost.panelID) } }

        if AppEnvironment.hotKeysEnabled, !snapshotting {
            HUDHotKeyCenter.shared.register(Self.hotKey) { [weak self] in
                self?.changePanel { try $0.togglePanel(MechaHUDHost.panelID) }
            }
        }
        if !snapshotting {
            setUpStatusItem()
            // While MacHUD runs, its menu hosts this one and the icon hides (HUDKit menu bar consolidation).
            router.menuProvider = { [weak self] in self?.statusItem?.menu }
            // menuBar.consumed lives with the other settings (AppEnvironment.defaults), so MECHAHUD_HOME isolates it.
            HUDStatusItemPolicy.attach(statusItem, appID: host.manifest.id, store: .defaults(AppEnvironment.defaults))
            bridge.start()
        }
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

    /// `--snapshot-widgets <dir>`: render the `sessions` widget at every size, with sample sessions
    /// and with the dashboard down, to `<dir>/sessions-<size>[-down].png`, then quit. Starts no
    /// socket, bridge or hotkey, so it reads nothing from mechaclaude.
    private func snapshotWidgets(to directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (suffix, feed, reachability) in [("", SessionsWidgetSample.feed, BridgeReachability.connected),
                                                 ("-empty", SessionFeed(), .connected),
                                                 ("-down", SessionFeed(), .unreachable)] {
                widgets.model.update(feed: feed, reachability: reachability, reconnecting: false)
                for size in [HUDWidgetSize.small, .medium] {
                    let file = url.appendingPathComponent("sessions-\(size.rawValue)\(suffix).png")
                    try widgets.host.writeSnapshot(type: MechaHUDWidgets.sessionsType, size: size, to: file)
                    print(file.path)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("MechaHUD: widget snapshot failed: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
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
        spawnProblemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        spawnProblemItem.isEnabled = false
        spawnProblemItem.isHidden = true
        spawnProblemSeparator = .separator()
        spawnProblemSeparator.isHidden = true
        menu.addItem(spawnProblemItem)
        menu.addItem(spawnProblemSeparator)
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
        let readiness = host?.spawnReadiness
        panel?.ui.spawnReadiness = readiness ?? .ready
        if let problem = readiness?.problem {
            spawnProblemItem?.title = readiness?.fix.map { "\(problem) — \($0)" } ?? problem
            spawnProblemItem?.isHidden = false
            spawnProblemSeparator?.isHidden = false
        } else {
            spawnProblemItem?.isHidden = true
            spawnProblemSeparator?.isHidden = true
        }
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
