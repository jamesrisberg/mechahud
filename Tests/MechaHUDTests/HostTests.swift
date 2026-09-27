import XCTest
import HUDKit
@testable import MechaHUD
import MechaHUDKit

@MainActor
final class FakePresenter: PanelPresenting {
    var log: [String] = []
    /// Where each `present(mode: .parked)` was asked to park.
    var parkedAt: [ParkingSpot] = []
    /// The `reason=` of each present.
    var reasons: [HUDPanelTransition.Reason?] = []
    func present(mode: HUDPanelMode, parking: ParkingSpot, transition: HUDPanelTransition) {
        reasons.append(transition.reason)
        log.append("present \(mode.rawValue)")
        if mode == .parked { parkedAt.append(parking) }
    }
    func dismiss() { log.append("dismiss") }
    func setFrame(_ frame: CGRect) { log.append("frame \(Int(frame.width))x\(Int(frame.height))") }
    func openSession(_ sessionKey: String) { log.append("open \(sessionKey)") }
}

@MainActor
final class FakeBridge: BridgeControlling {
    var sent: [(String, [String: Any])] = []
    var reply: [String: Any] = ["ack": ["status": "applied", "action": "choose"]]
    func control(sessionKey: String, body: [String: Any]) async throws -> [String: Any] {
        sent.append((sessionKey, body))
        return reply
    }
}

@MainActor
final class HostTests: XCTestCase {
    var presenter: FakePresenter!
    var bridge: FakeBridge!
    var host: MechaHUDHost!
    var stateChanges = 0

    override func setUp() async throws {
        presenter = FakePresenter()
        bridge = FakeBridge()
        let defaults = UserDefaults(suiteName: "mechahud-host-\(UUID().uuidString)")!
        host = MechaHUDHost(presenter: presenter, bridge: bridge, settings: AppSettings(defaults: defaults))
        host.manifest = MechaHUDHost.embeddedManifest
        stateChanges = 0
        host.onStateChange = { [unowned self] in self.stateChanges += 1 }
    }

    private func feed(_ rows: String...) -> SessionFeed {
        var f = SessionFeed()
        f.apply(payload: "{\"type\":\"sessions\",\"sessions\":[\(rows.joined(separator: ","))]}")
        return f
    }

    private func run(_ verb: String, _ args: [String: String] = [:]) async -> [String: Any] {
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-mechahud-test.sock"), manifest: host.manifest)
        return await withCheckedContinuation { c in router.handle(verb, args: args) { c.resume(returning: $0) } }
    }

    func testStateReportsBadgeAsPermissionWaitingCount() {
        host.update(feed: feed(Samples.busyRow, Samples.waitingRow, Samples.questionRow), reachability: .connected)
        let s = host.panelStates[0]
        XCTAssertEqual(s.id, "dashboard")
        XCTAssertEqual(s.badge, "1")
        XCTAssertEqual(s.status, "1 working · 2 waiting")
        XCTAssertEqual(stateChanges, 1)

        host.update(feed: feed(Samples.busyRow, Samples.waitingRow, Samples.questionRow), reachability: .connected)
        XCTAssertEqual(stateChanges, 1, "an identical feed does not publish")

        host.update(feed: feed(Samples.busyRow), reachability: .connected)
        XCTAssertNil(host.panelStates[0].badge, "no badge when nothing waits on permission")
        XCTAssertEqual(stateChanges, 2)

        host.update(feed: SessionFeed(), reachability: .unreachable)
        XCTAssertEqual(host.panelStates[0].status, "dashboard not running")
    }

    func testShowHideToggleAndModes() throws {
        try host.showPanel("dashboard")
        XCTAssertTrue(host.visible)
        try host.setPanelMode("dashboard", mode: .compact)
        try host.togglePanel("dashboard")
        XCTAssertFalse(host.visible)
        try host.setPanelMode("dashboard", mode: .full)   // hidden: recorded, not presented
        try host.togglePanel("dashboard")
        try host.setPanelMode("dashboard", mode: .parked)
        XCTAssertTrue(host.visible, "a parked panel is on screen as a peek")
        try host.showPanel("dashboard")
        XCTAssertEqual(host.mode, .full, "show unparks to the last rest mode")
        XCTAssertEqual(presenter.log, ["present full", "present compact", "dismiss", "present full", "present parked", "present full"])
        XCTAssertEqual(stateChanges, 0, "panel verbs are published by the router (or the app's UI path), not twice")
        XCTAssertThrowsError(try host.showPanel("nope"))
    }

    func testShowPassesTheReasonSoHoverShowsDoNotTakeFocus() throws {
        try host.showPanel("dashboard", options: ["reason": "hover"])
        try host.hidePanel("dashboard")
        try host.showPanel("dashboard", options: ["reason": "click", "from": "top"])
        try host.togglePanel("dashboard", options: ["reason": "summon"])
        try host.togglePanel("dashboard", options: ["reason": "summon"])
        try host.showPanel("dashboard")
        XCTAssertEqual(presenter.reasons, [.hover, .click, .summon, nil])
    }

    func testParkedWithEdgeAndPeekParksThereAndIsRemembered() async {
        _ = await run("panel", ["show": "1", "id": "dashboard"])
        XCTAssertEqual(presenter.parkedAt, [])

        let parked = await run("panel", ["mode": "parked", "id": "dashboard", "edge": "right", "peek": "24"])
        XCTAssertEqual(parked["ok"] as? Bool, true)
        XCTAssertEqual(parked["mode"] as? String, "parked")
        XCTAssertEqual(presenter.parkedAt.last, ParkingSpot(edge: .right, peek: 24))

        let full = await run("panel", ["mode": "full", "id": "dashboard"])
        XCTAssertEqual(full["mode"] as? String, "full")
        XCTAssertEqual(presenter.log.last, "present full", "full returns to the rest frame")

        // A bare parked (the menu, a hotkey, or MacHUD without a slot) reuses the last edge and peek.
        _ = await run("panel", ["mode": "parked", "id": "dashboard"])
        try? host.setPanelMode("dashboard", mode: .parked)
        XCTAssertEqual(presenter.parkedAt.suffix(2), [ParkingSpot(edge: .right, peek: 24), ParkingSpot(edge: .right, peek: 24)])

        // A new edge alone keeps the last peek.
        _ = await run("panel", ["mode": "parked", "id": "dashboard", "edge": "top"])
        XCTAssertEqual(presenter.parkedAt.last, ParkingSpot(edge: .top, peek: 24))

        let bad = await run("panel", ["mode": "parked", "id": "dashboard", "edge": "diagonal"])
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertEqual(host.parking, ParkingSpot(edge: .top, peek: 24), "a rejected edge changes nothing")
    }

    func testParkingWithoutAnEdgeUsesTheNearestEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rest = CGRect(x: 1000, y: 300, width: 400, height: 300)
        XCTAssertEqual(host.parking.edge(for: rest, in: screen), .right)
        var spot = host.parking
        spot.update(with: HUDPanelModeOptions(edge: .bottom, peek: 10))
        XCTAssertEqual(spot.offScreenFrame(for: rest, in: screen), CGRect(x: 1000, y: -290, width: 400, height: 300))
    }

    func testRouterPanelVerbsAndHello() async {
        let hello = await run("hello")
        XCTAssertEqual(hello["app"] as? String, "xyz.machud.mechahud")
        XCTAssertEqual((hello["panels"] as? [[String: Any]])?.first?["id"] as? String, "dashboard")

        let shown = await run("panel", ["show": "1", "id": "dashboard"])
        XCTAssertEqual(shown["ok"] as? Bool, true)
        XCTAssertEqual(shown["visible"] as? Bool, true)

        let compact = await run("panel", ["mode": "compact", "id": "dashboard"])
        XCTAssertEqual(compact["mode"] as? String, "compact")

        let framed = await run("panel", ["frame": "1", "id": "dashboard", "x": "10", "y": "20", "w": "800", "h": "500"])
        XCTAssertEqual(framed["ok"] as? Bool, true)
        XCTAssertEqual(presenter.log.last, "frame 800x500")

        host.update(feed: feed(Samples.waitingRow), reachability: .connected)
        let state = await run("state")
        let panel = (state["panels"] as? [[String: Any]])?.first
        XCTAssertEqual(panel?["badge"] as? String, "1")
        XCTAssertEqual(panel?["mode"] as? String, "compact")
    }

    func testApproveAndDenySendChooseThroughBridge() async {
        host.update(feed: feed(Samples.waitingRow), reachability: .connected)
        let approved = await run("action", ["name": "approve", "id": "claude:5151"])
        XCTAssertEqual(approved["ok"] as? Bool, true)
        XCTAssertEqual(approved["status"] as? String, "applied")
        let denied = await run("action", ["name": "deny", "id": "claude:5151"])
        XCTAssertEqual(denied["ok"] as? Bool, true)
        XCTAssertEqual(bridge.sent.map(\.0), ["claude:5151", "claude:5151"])
        XCTAssertEqual(bridge.sent[0].1 as NSDictionary, ["action": "choose", "index": 0])
        XCTAssertEqual(bridge.sent[1].1 as NSDictionary, ["action": "choose", "index": 2])
    }

    func testApproveRefusesSessionsThatAreNotWaiting() async {
        host.update(feed: feed(Samples.busyRow), reachability: .connected)
        let r = await run("action", ["name": "approve", "id": "claude:4242"])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue(bridge.sent.isEmpty)
        let missing = await run("action", ["name": "deny", "id": "claude:1"])
        XCTAssertEqual(missing["ok"] as? Bool, false)
        let unknown = await run("action", ["name": "explode", "id": "claude:4242"])
        XCTAssertEqual(unknown["ok"] as? Bool, false)
    }

    func testAckErrorIsNotOK() async {
        bridge.reply = ["ack": ["status": "noop"]]
        host.update(feed: feed(Samples.waitingRow), reachability: .connected)
        let r = await run("action", ["name": "approve", "id": "claude:5151"])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(r["status"] as? String, "noop")
    }

    func testOpenSessionShowsFullAndDeepLinks() async {
        try? host.setPanelMode("dashboard", mode: .compact)
        host.update(feed: feed(Samples.busyRow), reachability: .connected)
        let r = await run("action", ["name": "open-session", "id": "claude:4242"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(host.mode, .full)
        XCTAssertTrue(host.visible)
        XCTAssertEqual(presenter.log.suffix(2), ["present full", "open claude:4242"])
        // a sessionId also resolves
        let bySid = await run("action", ["name": "open-session", "id": "0b9d7c1e-1111-4a4a-9c9c-2f2f2f2f2f2f"])
        XCTAssertEqual(bySid["session"] as? String, "claude:4242")
    }

    func testSettingsGetSet() async {
        let set = await run("settings", ["set": "1", "mechaclaudePath": "/tmp/mc"])
        XCTAssertEqual(set["ok"] as? Bool, true)
        let get = await run("settings", ["key": "mechaclaudePath"])
        XCTAssertEqual(get["value"] as? String, "/tmp/mc")
        let bad = await run("settings", ["set": "1", "bogus": "x"])
        XCTAssertEqual(bad["ok"] as? Bool, false)
    }

    func testBundledManifestMatchesEmbeddedCopy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MechaHUD/Resources/machud.json")
        let manifest = try HUDManifest.decode(Data(contentsOf: url))
        XCTAssertEqual(manifest, MechaHUDHost.embeddedManifest)
        XCTAssertEqual(manifest.socketPath, HUDSocket.path(for: "mechahud"))
    }

    func testDashboardPanelIsWindowed() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MechaHUD/Resources/machud.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let panel = (raw?["panels"] as? [[String: Any]])?.first
        XCTAssertEqual(panel?["kind"] as? String, "windowed", "the manifest states the kind explicitly")
        XCTAssertEqual(MechaHUDHost.embeddedManifest.panel(id: "dashboard")?.kind, .windowed)
        let hello = await run("hello")
        let panels = hello["panels"] as? [[String: Any]]
        XCTAssertEqual(panels?.first?["kind"] as? String, "windowed")
    }

    func testPanelFramePersistsAcrossSettingsInstances() async {
        let suite = "mechahud-frame-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AppSettings(defaults: defaults).panelFrame)
        let frame = CGRect(x: 120.5, y: 80, width: 900, height: 640)
        AppSettings(defaults: defaults).panelFrame = frame
        XCTAssertEqual(AppSettings(defaults: defaults).panelFrame, frame)
        XCTAssertEqual(AppSettings(defaults: defaults).snapshot["panelFrame"] as? [Double], [120.5, 80, 900, 640])
        defaults.set("{{0, 0}, {0, 0}}", forKey: AppSettings.panelFrameKey)
        XCTAssertNil(AppSettings(defaults: defaults).panelFrame, "a degenerate frame is ignored")
        AppSettings(defaults: defaults).panelFrame = nil
        XCTAssertNil(defaults.string(forKey: AppSettings.panelFrameKey))
    }
}
