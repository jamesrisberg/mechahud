import XCTest
@testable import MechaHUDKit

final class BridgeRequestTests: XCTestCase {
    let ep = BridgeEndpoint(readToken: "READ123", controlToken: "CTRL456")

    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testOriginMatchesHostAndPort() {
        XCTAssertEqual(ep.origin, "http://127.0.0.1:7616")
        XCTAssertEqual(BridgeEndpoint(baseURL: URL(string: "http://localhost")!, readToken: "r", controlToken: "c").origin, "http://localhost")
    }

    func testControlRequestHeadersAndBody() {
        let r = BridgeRequests.control(ep, sessionKey: "claude:5151", body: ["action": "choose", "index": 0])
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:7616/api/control")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), "mclaude_web=READ123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Control-Token"), "CTRL456")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:7616")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(r.httpShouldHandleCookies)
        let b = body(r)
        XCTAssertEqual(b["sessionKey"] as? String, "claude:5151")
        XCTAssertEqual(b["action"] as? String, "choose")
        XCTAssertEqual(b["index"] as? Int, 0)
    }

    func testWaitForOutcomeQuery() {
        let r = BridgeRequests.control(ep, sessionKey: "k", body: ["action": "interrupt"], waitForOutcome: true)
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:7616/api/control?wait=outcome")
    }

    func testEventsRequestIsCookieOnlyAndUncompressed() {
        let r = BridgeRequests.events(ep)
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:7616/events")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), "mclaude_web=READ123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertNil(r.value(forHTTPHeaderField: "X-Control-Token"), "reads never carry the control token")
        XCTAssertNil(r.value(forHTTPHeaderField: "Origin"))
    }

    func testDashboardDeepLink() {
        XCTAssertEqual(ep.dashboardURL().absoluteString, "http://127.0.0.1:7616/")
        XCTAssertEqual(ep.dashboardURL(sessionKey: "claude:42").absoluteString, "http://127.0.0.1:7616/?key=claude:42")
    }

    func testApprovalBodyPicksYesAndNoOptions() {
        let pending = PendingBlock(kind: "permission", tool: "Bash", options: [
            PendingOption(value: "yes", label: "Yes"),
            PendingOption(value: "yes-dont-ask-again", label: "Yes, and don't ask again"),
            PendingOption(value: "no", label: "No"),
        ])
        XCTAssertEqual(BridgeRequests.approvalBody(for: pending, allow: true) as NSDictionary, ["action": "choose", "index": 0])
        XCTAssertEqual(BridgeRequests.approvalBody(for: pending, allow: false) as NSDictionary, ["action": "choose", "index": 2])
    }

    func testApprovalBodyFallsBackToFirstOptionAndCancel() {
        let pending = PendingBlock(kind: "permission", options: [PendingOption(value: "accept", label: "Accept")])
        XCTAssertEqual(BridgeRequests.approvalBody(for: pending, allow: true) as NSDictionary, ["action": "choose", "index": 0])
        XCTAssertEqual(BridgeRequests.approvalBody(for: pending, allow: false) as NSDictionary, ["action": "choose", "cancel": true])
        XCTAssertEqual(BridgeRequests.approvalBody(for: nil, allow: false) as NSDictionary, ["action": "choose", "cancel": true])
    }

    func testTokenFileAndOverrides() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("web-tokens.json")
        try Data(#"{"readToken":"R","controlToken":"C","pid":1,"startedAt":2}"#.utf8).write(to: file)

        let defaults = UserDefaults(suiteName: "mechahud-test-\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        s.tokenFile = file
        XCTAssertEqual(s.endpoint(), BridgeEndpoint(readToken: "R", controlToken: "C"))
        try s.apply(["controlToken": "MANUAL", "dashboardURL": "http://localhost:9000"])
        XCTAssertEqual(s.endpoint(), BridgeEndpoint(baseURL: URL(string: "http://localhost:9000")!, readToken: "R", controlToken: "MANUAL"))
        XCTAssertThrowsError(try s.apply(["nope": "1"]))
        XCTAssertThrowsError(try s.apply(["dashboardURL": "not a url"]))
        s.tokenFile = dir.appendingPathComponent("missing.json")
        s.controlTokenOverride = ""
        XCTAssertNil(s.endpoint(), "no read token anywhere")
    }

    func testStateDirectoryHonoursMCLAUDE_STATE_DIR() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(WebTokens.stateDirectory(environment: ["MCLAUDE_STATE_DIR": dir.path]), dir)
        XCTAssertEqual(WebTokens.defaultURL(environment: ["MCLAUDE_STATE_DIR": dir.path]),
                       dir.appendingPathComponent("web-tokens.json"))
    }

    func testStateDirectoryFallsBackToTheRealStateTapsWithoutTheOverride() {
        let realTaps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/state-taps")
        XCTAssertEqual(WebTokens.stateDirectory(environment: [:]), realTaps)
        XCTAssertEqual(WebTokens.defaultURL(environment: [:]), realTaps.appendingPathComponent("web-tokens.json"))
        XCTAssertEqual(WebTokens.stateDirectory(environment: ["MCLAUDE_STATE_DIR": ""]), realTaps,
                       "an empty override is not a real path")
    }

    func testLoadReadsFromAnIsolatedStateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"readToken":"R","controlToken":"C"}"#.utf8).write(to: dir.appendingPathComponent("web-tokens.json"))
        let isolated = WebTokens.defaultURL(environment: ["MCLAUDE_STATE_DIR": dir.path])
        XCTAssertEqual(WebTokens.load(from: isolated), WebTokens(readToken: "R", controlToken: "C"))
    }
}
