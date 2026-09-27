import XCTest
@testable import MechaHUDKit

final class ReconnectHoldTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNeverConnectedDoesNotHold() {
        var h = ReconnectHold()
        h.observe(.connecting, now: t0)
        h.observe(.unreachable, now: t0)
        XCTAssertFalse(h.holding(at: t0))
    }

    func testDropAfterConnectHoldsUntilGrace() {
        var h = ReconnectHold()
        h.observe(.connected, now: t0)
        XCTAssertFalse(h.holding(at: t0))
        h.observe(.connecting, now: t0.addingTimeInterval(1))       // stream ended (redeploy exit)
        h.observe(.unreachable, now: t0.addingTimeInterval(4))      // connection refused while restarting
        XCTAssertTrue(h.holding(at: t0.addingTimeInterval(4)))
        XCTAssertTrue(h.holding(at: t0.addingTimeInterval(1 + ReconnectHold.grace - 0.1)))
        XCTAssertFalse(h.holding(at: t0.addingTimeInterval(1 + ReconnectHold.grace)))
    }

    func testReconnectClearsHold() {
        var h = ReconnectHold()
        h.observe(.connected, now: t0)
        h.observe(.unreachable, now: t0)
        h.observe(.connected, now: t0.addingTimeInterval(2))
        XCTAssertFalse(h.holding(at: t0.addingTimeInterval(2)))
        XCTAssertNil(h.droppedAt)
    }

    func testAuthFailureEndsHold() {
        var h = ReconnectHold()
        h.observe(.connected, now: t0)
        h.observe(.unreachable, now: t0)
        h.observe(.unauthorized, now: t0.addingTimeInterval(2))
        XCTAssertFalse(h.holding(at: t0.addingTimeInterval(2)))
        h.observe(.unreachable, now: t0.addingTimeInterval(3))
        XCTAssertFalse(h.holding(at: t0.addingTimeInterval(3)))
    }

    func testPaneDecision() {
        func pane(_ r: BridgeReachability, holding: Bool = false, settings: Bool = false, endpoint: Bool = true) -> DashboardPane {
            DashboardPane.decide(reachability: r, holding: holding, showingSettings: settings, hasEndpoint: endpoint)
        }
        XCTAssertEqual(pane(.connected), .web)
        XCTAssertEqual(pane(.connected, settings: true), .settings)
        XCTAssertEqual(pane(.connecting), .down)
        XCTAssertEqual(pane(.connecting, holding: true), .webReconnecting)
        XCTAssertEqual(pane(.unreachable, holding: true), .webReconnecting)
        XCTAssertEqual(pane(.unauthorized, holding: true), .down)
        XCTAssertEqual(pane(.unreachable, holding: true, endpoint: false), .down)
    }
}
