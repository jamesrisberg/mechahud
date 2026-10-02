import XCTest
@testable import MechaHUDKit

final class SessionsWidgetSummaryTests: XCTestCase {
    private func row(_ key: String, _ status: String, name: String? = nil, cwd: String? = nil) -> SessionRow {
        SessionRow(sessionKey: key, cwd: cwd, status: status, customName: name)
    }

    private func summary(_ rows: [SessionRow], _ reachability: BridgeReachability = .connected,
                         reconnecting: Bool = false, limit: Int = 4) -> SessionsWidgetSummary {
        SessionsWidgetSummary(feed: SessionFeed(sessions: rows), reachability: reachability,
                              reconnecting: reconnecting, rowLimit: limit)
    }

    func testCountsWorkingIdleAndWaiting() {
        let s = summary([row("a", "busy"), row("b", "running"), row("c", "idle"), row("d", "waiting"),
                         row("e", "connecting"), row("f", "closed")])
        XCTAssertEqual(s.working, 2)
        XCTAssertEqual(s.idle, 1)
        XCTAssertEqual(s.waiting, 1)
        XCTAssertNil(s.unavailable)
        XCTAssertFalse(s.isEmpty)
    }

    func testRowsListWaitingFirstThenWorkingThenTheRestKeepingFeedOrder() {
        let s = summary([row("i1", "idle", name: "i1"), row("w1", "busy", name: "w1"), row("p1", "waiting", name: "p1"),
                         row("w2", "busy", name: "w2"), row("p2", "waiting", name: "p2")], limit: 10)
        XCTAssertEqual(s.rows.map(\.name), ["p1", "p2", "w1", "w2", "i1"])
        XCTAssertEqual(s.rows.map(\.status), [.waiting, .waiting, .working, .working, .idle])
    }

    func testRowLimitCountsTheSessionsLeftOut() {
        let rows = (1...7).map { row("s\($0)", "idle", name: "s\($0)") }
        let s = summary(rows, limit: 4)
        XCTAssertEqual(s.rows.count, 4)
        XCTAssertEqual(s.more, 3)
        XCTAssertEqual(summary(Array(rows.prefix(4)), limit: 4).more, 0)
    }

    func testRowNameIsTheDisplayName() {
        let s = summary([row("claude:1", "idle", cwd: "/Users/me/dev/machud")])
        XCTAssertEqual(s.rows.first?.name, "machud")
        XCTAssertEqual(s.rows.first?.sessionKey, "claude:1")
    }

    func testEmptyFleet() {
        let s = summary([])
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.working + s.idle + s.waiting, 0)
        XCTAssertTrue(s.rows.isEmpty)
    }

    func testUnavailableWhenTheBridgeIsNotConnected() {
        XCTAssertEqual(summary([row("a", "busy")], .connecting).unavailable, "Connecting…")
        XCTAssertEqual(summary([], .unreachable).unavailable, "Dashboard not running")
        XCTAssertEqual(summary([], .unauthorized).unavailable, "Dashboard rejected tokens")
        XCTAssertEqual(summary([], .noTokens).unavailable, "No dashboard tokens")
    }

    func testReconnectingHoldWinsOverStaleCounts() {
        XCTAssertEqual(summary([row("a", "busy")], .unreachable, reconnecting: true).unavailable, "Reconnecting…")
    }

    func testUnavailableShowsNoRows() {
        let s = summary([row("a", "busy")], .unreachable)
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertEqual(s.working, 0, "a dead bridge's last feed is not shown as live sessions")
    }
}
