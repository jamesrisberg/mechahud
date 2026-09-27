import XCTest
@testable import MechaHUDKit

final class SSEParserTests: XCTestCase {
    func testPreambleYieldsOnlyDataPayloads() {
        var p = SSEParser()
        let payloads = Samples.connectPreamble.compactMap { p.feed($0) }
        XCTAssertEqual(payloads.count, 4)
        XCTAssertEqual(payloads.first, #"{"type":"sessions","sessions":[]}"#)
        XCTAssertEqual(p.retryMilliseconds, 3000)
    }

    func testMultiLineDataJoinsAndCRLFIsStripped() {
        var p = SSEParser()
        XCTAssertNil(p.feed("id: abc:0:7\r"))
        XCTAssertNil(p.feed("data: {\"a\":\r"))
        XCTAssertNil(p.feed("data:1}"))
        XCTAssertEqual(p.feed("\r"), "{\"a\":\n1}")
        XCTAssertEqual(p.lastEventID, "abc:0:7")
        XCTAssertNil(p.feed(""), "a blank line with no data is not an event")
    }
}

final class SessionFeedTests: XCTestCase {
    private func feed(_ lines: [String], into f: inout SessionFeed) -> [FeedChange] {
        lines.compactMap { f.feed(line: $0) }
    }

    func testConnectPreambleEstablishesEmptySnapshot() {
        var f = SessionFeed()
        let changes = feed(Samples.connectPreamble, into: &f)
        XCTAssertEqual(changes, [.sessionsChanged, .ignored, .ignored, .heartbeat])
        XCTAssertTrue(f.hasSnapshot)
        XCTAssertEqual(f.sessions, [])
        XCTAssertEqual(f.lastHeartbeat, 1790396772664)
        XCTAssertEqual(f.summary, "no sessions")
    }

    func testFullSessionsFrameParsesRows() {
        var f = SessionFeed()
        XCTAssertEqual(f.apply(payload: "data: {\"type\":\"sessions\",\"sessions\":[\(Samples.busyRow),\(Samples.waitingRow),\(Samples.idleCodexRow)]}"), .sessionsChanged)
        XCTAssertEqual(f.sessions.map(\.sessionKey), ["claude:4242", "claude:5151", "codex:thread-abc"])

        let busy = f.sessions[0]
        XCTAssertEqual(busy.status, .working)
        XCTAssertEqual(busy.displayName, "Build MechaHUD")
        XCTAssertEqual(busy.pid, 4242)
        XCTAssertEqual(busy.pctUntilCompact, 91)
        XCTAssertNil(busy.pending)

        let waiting = f.sessions[1]
        XCTAssertEqual(waiting.displayName, "machud fixes", "customName outranks the title")
        XCTAssertTrue(waiting.isWaitingOnPermission)
        XCTAssertEqual(waiting.pending?.tool, "Bash")
        XCTAssertEqual(waiting.pending?.options.map(\.value), ["yes", "yes-dont-ask-again", "no"])

        let codex = f.sessions[2]
        XCTAssertNil(codex.pid)
        XCTAssertEqual(codex.displayName, "archibald", "falls back to the cwd's basename")
        XCTAssertEqual(codex.status, .idle)

        XCTAssertEqual(f.summary, "1 working · 1 waiting · 1 idle")
        XCTAssertEqual(f.permissionWaitingCount, 1)
    }

    func testDeltaUpsertsInPlaceAppendsAndRemoves() {
        var f = SessionFeed()
        f.apply(payload: "{\"type\":\"sessions\",\"sessions\":[\(Samples.busyRow),\(Samples.idleCodexRow)]}")
        // claude:4242 flips to waiting on a permission prompt; a question session appears.
        let flipped = Samples.waitingRow.replacingOccurrences(of: "5151", with: "4242")
        XCTAssertEqual(f.apply(payload: "{\"type\":\"sessions_delta\",\"upsert\":[\(flipped),\(Samples.questionRow)]}"), .sessionsChanged)
        XCTAssertEqual(f.sessions.map(\.sessionKey), ["claude:4242", "codex:thread-abc", "claude:6161"])
        XCTAssertEqual(f.sessions[0].status, .waiting)
        XCTAssertEqual(f.waitingCount, 2)
        XCTAssertEqual(f.permissionWaitingCount, 1, "a question is waiting but not a permission prompt")

        XCTAssertEqual(f.apply(payload: #"{"type":"sessions_delta","remove":["codex:thread-abc","claude:99"]}"#), .sessionsChanged)
        XCTAssertEqual(f.sessions.map(\.sessionKey), ["claude:4242", "claude:6161"])
        XCTAssertEqual(f.apply(payload: #"{"type":"sessions_delta"}"#), .ignored)
    }

    func testSessionRemovedBySessionKeyOrPid() {
        var f = SessionFeed()
        f.apply(payload: "{\"type\":\"sessions\",\"sessions\":[\(Samples.busyRow),\(Samples.waitingRow)]}")
        XCTAssertEqual(f.apply(payload: #"{"type":"session_removed","pid":4242,"sessionKey":"claude:4242"}"#), .sessionsChanged)
        XCTAssertEqual(f.apply(payload: #"{"type":"session_removed","pid":5151}"#), .sessionsChanged)
        XCTAssertEqual(f.sessions, [])
        XCTAssertEqual(f.apply(payload: #"{"type":"session_removed","pid":1}"#), .ignored)
    }

    func testControlFramesAndGarbage() {
        var f = SessionFeed()
        XCTAssertEqual(f.apply(payload: #"{"type":"gap","reason":"backpressure"}"#), .gap)
        XCTAssertEqual(f.apply(payload: #"{"type":"spawn_failed","tag":"t1","cwd":"/x","error":"tmux not found"}"#), .spawnFailed("/x: tmux not found"))
        XCTAssertEqual(f.apply(payload: #"{"type":"usage_alert"}"#), .ignored)
        XCTAssertEqual(f.apply(payload: "not json"), .malformed)
        XCTAssertEqual(f.apply(payload: #"{"no":"type"}"#), .malformed)
    }

    func testRowWithoutSessionKeyIsSkipped() {
        var f = SessionFeed()
        f.apply(payload: #"{"type":"sessions","sessions":[{"pid":1,"status":"idle"},{"sessionKey":"claude:2"}]}"#)
        XCTAssertEqual(f.sessions.map(\.sessionKey), ["claude:2"])
        XCTAssertEqual(f.sessions[0].status, .connecting, "a row with no status reads as connecting")
    }

    func testNumericOptionValuesAreStringified() {
        let row = SessionRow(json: try! JSONSerialization.jsonObject(with: Data(#"{"sessionKey":"k","status":"waiting","pending":{"kind":"permission","options":[{"value":1,"label":"One"},{"value":"x"}]}}"#.utf8)))
        XCTAssertEqual(row?.pending?.options, [PendingOption(value: "1", label: "One"), PendingOption(value: "x", label: "x")])
    }

    func testStatusMapping() {
        XCTAssertEqual(SessionStatus("busy"), .working)
        XCTAssertEqual(SessionStatus("waiting"), .waiting)
        XCTAssertEqual(SessionStatus("idle"), .idle)
        XCTAssertEqual(SessionStatus("parked"), .other("parked"))
        XCTAssertEqual(SessionStatus("parked").label, "parked")
    }
}
