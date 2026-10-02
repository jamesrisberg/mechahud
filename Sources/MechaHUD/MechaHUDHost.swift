import AppKit
import HUDKit
import MechaHUDKit

/// The window side of the panel, so the host's contract logic is testable without AppKit windows.
@MainActor
public protocol PanelPresenting: AnyObject {
    /// Shows the panel in `mode` (full, compact = strip only, parked = slid off `parking`'s edge).
    /// `transition` carries MacHUD's `panel show` options: a `reason=hover` show must not take
    /// focus; click, summon and the app's own shows activate MechaHUD.
    func present(mode: HUDPanelMode, parking: ParkingSpot, transition: HUDPanelTransition)
    func dismiss()
    func setFrame(_ frame: CGRect)
    /// Selects a session: deep-links the dashboard to it.
    func openSession(_ sessionKey: String)
    /// Debug: renders the panel to a PNG at `path`; `done(nil)` on success, else an error message.
    func snapshot(to path: String, done: @escaping (String?) -> Void)
}

public extension PanelPresenting {
    func snapshot(to path: String, done: @escaping (String?) -> Void) { done("snapshot unsupported") }
}

/// Sends a control request to the bridge; returns the bridge's JSON (`{ack}` / `{status}`).
@MainActor
public protocol BridgeControlling: AnyObject {
    func control(sessionKey: String, body: [String: Any]) async throws -> [String: Any]
}

/// MechaHUD's `HUDPanelHost`: one panel, `dashboard`. The manifest also declares a widget type,
/// `sessions`, which `MechaHUDWidgets` serves; it is not a panel, so the host's states and
/// `panel` commands never include it.
///
/// - `panel show/hide/toggle/frame/mode` drive the `PanelPresenting`; `mode parked` honours
///   and remembers the `edge=`/`peek=` MacHUD passes (HUDKit 0.2).
/// - `state`: badge = sessions waiting on a permission prompt, status = the fleet summary (plus
///   the spawn-readiness problem, once the bridge is up but mechaclaude cannot start a session).
/// - `action open-session id=`, `action approve id=`, `action deny id=`.
/// - `sessions` (registered on the server directly, the `agent-sessions` capability's own verb):
///   `sessionsPayload()`.
/// - `onStateChange` fires when the feed changes the reported state, or an action changes
///   visibility (wire it to `publishState`). Panel verbs don't fire it: `HUDControlRouter`
///   publishes after every `panel` command itself, and UI-initiated changes go through
///   `MechaHUDApp.panel(_:)`, which publishes once.
@MainActor
public final class MechaHUDHost: HUDPanelHost {
    public static let panelID = "dashboard"

    public private(set) var visible = false
    public private(set) var mode: HUDPanelMode = .full
    /// The mode `show` restores after parking.
    public private(set) var restMode: HUDPanelMode = .full
    /// Where `parked` parks: the edge/peek MacHUD last passed, else the nearest edge.
    public private(set) var parking = ParkingSpot(peek: 16)
    public private(set) var feed = SessionFeed()
    public private(set) var reachability: BridgeReachability = .connecting
    /// Set in tests to avoid depending on this machine's tmux/mclaude install; nil (the default)
    /// computes it for real from `reachability`.
    public var spawnReadinessOverride: SpawnReadiness?
    public var spawnReadiness: SpawnReadiness { spawnReadinessOverride ?? SpawnReadiness.current(reachability: reachability) }

    /// Reported by `hello`; the bundle's machud.json when present.
    public var manifest: HUDManifest = HUDManifest.main ?? MechaHUDHost.embeddedManifest

    /// Mirror of `Resources/machud.json` for runs outside the app bundle (`swift run`, tests).
    public static let embeddedManifest = HUDManifest(
        id: "xyz.machud.mechahud", name: "MechaHUD", socket: "mechahud",
        panels: [HUDManifest.Panel(id: panelID, title: "Claude Sessions", symbol: "terminal",
                                   defaultSize: HUDSize(width: 900, height: 640),
                                   compactSize: HUDSize(width: 900, height: 102),
                                   // MacHUD's broker finds a provider by this capability
                                   // (open-session/sessions below).
                                   capabilities: [HUDAgentSessions.capability],
                                   verbs: ["show", "hide", "toggle", "frame", "mode", "open-session", "approve", "deny"],
                                   kind: .windowed),
                 // A desktop widget (HUDKit 0.3): working / waiting / idle counts and sessions.
                 HUDManifest.Panel(id: "sessions", title: "Claude Sessions", symbol: "terminal", kind: .widget,
                                   widget: HUDWidgetSpec(sizes: [.small, .medium], defaultSize: .small,
                                                         multiple: false))])

    public weak var presenter: PanelPresenting?
    public weak var bridge: BridgeControlling?
    public let appSettings: AppSettings
    public var onStateChange: (() -> Void)?
    public var onSettingsChange: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(presenter: PanelPresenting? = nil, bridge: BridgeControlling? = nil, settings: AppSettings = AppSettings()) {
        self.presenter = presenter
        self.bridge = bridge
        self.appSettings = settings
    }

    // MARK: Feed

    /// Updates the fleet view; fires `onStateChange` when the reported state changed.
    public func update(feed: SessionFeed, reachability: BridgeReachability) {
        let before = panelStates
        self.feed = feed
        self.reachability = reachability
        if panelStates != before { onStateChange?() }
    }

    public var badge: String? {
        let n = feed.permissionWaitingCount
        return n > 0 ? String(n) : nil
    }

    public var status: String {
        switch reachability {
        case .connected:
            guard let problem = spawnReadiness.problem else { return feed.summary }
            return "\(feed.summary) — \(problem)"
        case .connecting: return "connecting"
        case .unreachable: return "dashboard not running"
        case .unauthorized: return "dashboard rejected tokens"
        case .noTokens: return "no dashboard tokens"
        }
    }

    // MARK: HUDPanelHost

    public var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    public var panelStates: [HUDPanelState] {
        [HUDPanelState(id: Self.panelID, visible: visible, mode: mode, badge: badge, status: status)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    public func showPanel(_ id: String) throws {
        try showPanel(id, options: [:])
    }

    /// `panel show` with MacHUD's options; only `reason=` matters (the dashboard is not
    /// placed next to the dock button).
    public func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        if mode == .parked { mode = restMode }
        visible = true
        presenter?.present(mode: mode, parking: parking, transition: HUDPanelTransition(options))
    }

    public func hidePanel(_ id: String) throws {
        try check(id)
        visible = false
        presenter?.dismiss()
    }

    public func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 120, frame.height >= 40 else { throw HUDControlError.invalid("frame too small") }
        presenter?.setFrame(frame)
    }

    public func setPanelMode(_ id: String, mode newMode: HUDPanelMode) throws {
        try setPanelMode(id, mode: newMode, options: HUDPanelModeOptions())
    }

    public func setPanelMode(_ id: String, mode newMode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try check(id)
        if newMode == .parked { parking.update(with: options) } else { restMode = newMode }
        mode = newMode
        if newMode == .parked { visible = true }
        if visible { presenter?.present(mode: newMode, parking: parking, transition: HUDPanelTransition()) }
    }

    public func settings() -> [String: Any] { appSettings.snapshot }

    public func updateSettings(_ values: [String: String]) throws {
        do { try appSettings.apply(values) } catch { throw HUDControlError.invalid("\(error)") }
        onSettingsChange?()
    }

    /// The `sessions` socket command (the `agent-sessions` HUDKit capability): every live session
    /// plus whether mechaclaude could start a new one right now. Registered directly on the
    /// server (not through `action`) since the broker addresses every provider the same way.
    public func sessionsPayload() -> [String: Any] {
        let sessions = feed.sessions.map { row -> [String: Any] in
            ["id": row.sessionKey, "title": row.displayName, "cwd": row.cwd ?? "", "state": row.status.label]
        }
        let readiness = spawnReadiness
        var reply: [String: Any] = ["ok": true, "sessions": sessions, "canStart": readiness.canStart]
        if let problem = readiness.problem { reply["problem"] = problem }
        if let fix = readiness.fix { reply["fix"] = fix }
        return reply
    }

    public static let actions = ["open-session", "approve", "deny", "snapshot"]

    public func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        guard Self.actions.contains(name) else {
            done(["ok": false, "error": "unknown action \(name)", "actions": Self.actions])
            return
        }
        if name == "snapshot" {
            let path = args["path"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("mechahud-snapshot.png")
            guard let presenter else { done(["ok": false, "error": "no panel"]); return }
            presenter.snapshot(to: path) { error in
                done(error.map { ["ok": false, "error": $0] } ?? ["ok": true, "path": path])
            }
            return
        }
        guard let key = args["id"] ?? args["session"], !key.isEmpty else {
            done(["ok": false, "error": "id= (a sessionKey) required"])
            return
        }
        guard let row = feed.session(key) ?? feed.sessions.first(where: { $0.sessionId == key || $0.pid.map(String.init) == key }) else {
            done(["ok": false, "error": "no such session \(key)"])
            return
        }
        switch name {
        case "open-session":
            if mode != .full { restMode = .full; mode = .full }
            visible = true
            presenter?.present(mode: .full, parking: parking, transition: HUDPanelTransition())
            presenter?.openSession(row.sessionKey)
            onStateChange?()
            done(["ok": true, "session": row.sessionKey])
        default:
            answer(row, allow: name == "approve", done: done)
        }
    }

    /// Answers a session's permission prompt through the bridge.
    public func answer(_ row: SessionRow, allow: Bool, done: @escaping ([String: Any]) -> Void) {
        guard row.status == .waiting else {
            done(["ok": false, "error": "session \(row.sessionKey) is not waiting on a prompt"])
            return
        }
        guard let bridge else { done(["ok": false, "error": "bridge unavailable"]); return }
        let body = BridgeRequests.approvalBody(for: row.pending, allow: allow)
        Task { @MainActor in
            do {
                let reply = try await bridge.control(sessionKey: row.sessionKey, body: body)
                let ack = reply["ack"] as? [String: Any]
                let status = ack?["status"] as? String ?? reply["status"] as? String ?? "unknown"
                var r: [String: Any] = ["ok": ["applied", "dispatched"].contains(status), "status": status,
                                        "session": row.sessionKey, "sent": body]
                if let ack { r["ack"] = ack.filter { ["status", "action", "applied", "detail", "cid"].contains($0.key) } }
                done(r)
            } catch {
                done(["ok": false, "error": "\(error)", "session": row.sessionKey])
            }
        }
    }

    public func quit() {
        if let onQuit { onQuit() } else { NSApp.terminate(nil) }
    }
}
