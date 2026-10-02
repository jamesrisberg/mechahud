import XCTest
import HUDKit
@testable import MechaHUD
import MechaHUDKit

/// The `sessions` widget type: registered with HUDKit's widget host, fed by the session model
/// the dashboard strip uses, and clicking it opens the dashboard.
@MainActor
final class SessionsWidgetTests: XCTestCase {
    var opened: [String] = []
    var widgets: MechaHUDWidgets!

    override func setUp() async throws {
        opened = []
        widgets = MechaHUDWidgets(manifest: MechaHUDHost.embeddedManifest, bundleURL: URL(fileURLWithPath: "/nonexistent"),
                                  openDashboard: { [unowned self] in self.opened.append("dashboard") },
                                  openSession: { [unowned self] in self.opened.append($0) })
        widgets.host.presentsWindows = false
    }

    private func feed(_ rows: String...) -> SessionFeed {
        var f = SessionFeed()
        f.apply(payload: "{\"type\":\"sessions\",\"sessions\":[\(rows.joined(separator: ","))]}")
        return f
    }

    func testRegistersTheSessionsType() {
        XCTAssertEqual(widgets.host.types, ["sessions"])
        let spec = widgets.host.spec(for: "sessions")
        XCTAssertEqual(spec?.sizes, [.small, .medium])
    }

    func testInstanceLifecycleOverTheWidgetVerb() throws {
        let created = widgets.host.handle(["action": "create", "instance": "s1", "type": "sessions", "frame": "40,40,170,170"])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        XCTAssertEqual(widgets.host.instances.map(\.id), ["s1"])
        let medium = widgets.host.handle(["action": "update", "instance": "s1", "size": "medium"])
        XCTAssertEqual(medium["ok"] as? Bool, true, "\(medium)")
        let large = widgets.host.handle(["action": "update", "instance": "s1", "size": "large"])
        XCTAssertEqual(large["ok"] as? Bool, false, "sessions is small and medium only")
        let second = widgets.host.handle(["action": "create", "instance": "s2", "type": "sessions"])
        XCTAssertEqual(second["ok"] as? Bool, false, "one instance")
        let removed = widgets.host.handle(["action": "remove", "instance": "s1"])
        XCTAssertEqual(removed["removed"] as? String, "s1")
    }

    func testSyncRestoresTheInstanceAfterARelaunch() throws {
        let json = #"[{"instance":"s1","type":"sessions","size":"medium","frame":[24,820,356,170],"layer":"desktop","settings":{}}]"#
        let reply = widgets.host.handle(["action": "sync", "instances": json])
        XCTAssertEqual((reply["instances"] as? [[String: Any]])?.count, 1, "\(reply)")
        XCTAssertEqual((reply["rejected"] as? [Any])?.count, 0)
    }

    func testModelFollowsTheFeed() {
        XCTAssertEqual(widgets.model.summary.unavailable, "Connecting…")
        widgets.model.update(feed: feed(Samples.busyRow, Samples.waitingRow, Samples.idleCodexRow), reachability: .connected, reconnecting: false)
        XCTAssertEqual(widgets.model.summary.working, 1)
        XCTAssertEqual(widgets.model.summary.waiting, 1)
        XCTAssertEqual(widgets.model.summary.idle, 1)
        widgets.model.update(feed: SessionFeed(), reachability: .unreachable, reconnecting: false)
        XCTAssertEqual(widgets.model.summary.unavailable, "Dashboard not running")
    }

    func testClickingTheWidgetOpensTheDashboard() throws {
        _ = widgets.host.handle(["action": "create", "instance": "s1", "type": "sessions"])
        let context = try XCTUnwrap(widgets.host.context(for: "s1"))
        context.openApp()
        XCTAssertEqual(opened, ["dashboard"])
    }

    func testEverySizeRendersToAPNG() throws {
        widgets.model.update(feed: feed(Samples.busyRow, Samples.waitingRow, Samples.idleCodexRow), reachability: .connected, reconnecting: false)
        for size in [HUDWidgetSize.small, .medium] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mechahud-sessions-\(size.rawValue)-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            try widgets.host.writeSnapshot(type: "sessions", size: size, to: url)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "\(size) is a PNG")
        }
    }
}
