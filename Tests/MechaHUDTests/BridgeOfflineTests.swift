import XCTest
@testable import MechaHUD
import MechaHUDKit

/// A `--snapshot` run uses an offline bridge: it must not read the token file or the token
/// settings, open the stream or send a control request.
@MainActor
final class BridgeOfflineTests: XCTestCase {
    private var directory: URL!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mechahud-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tokens = directory.appendingPathComponent("web-tokens.json")
        try JSONEncoder().encode(WebTokens(readToken: "read-secret", controlToken: "control-secret")).write(to: tokens)
        let defaults = UserDefaults(suiteName: "mechahud-offline-\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        settings.tokenFile = tokens
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOnlineClientReadsTheTokenFile() {
        XCTAssertEqual(BridgeClient(settings: settings).endpoint?.readToken, "read-secret")
    }

    func testOfflineClientReadsNoToken() async {
        let bridge = BridgeClient(settings: settings, offline: true)
        XCTAssertNil(bridge.endpoint)
        bridge.reconnect()
        XCTAssertNil(bridge.endpoint, "reconnect re-reads tokens on an online client")
        bridge.start()
        XCTAssertEqual(bridge.reachability, .connecting, "no stream was opened")
        do {
            _ = try await bridge.control(sessionKey: "claude:1", body: [:])
            XCTFail("an offline client sends no control request")
        } catch BridgeError.noTokens {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOfflineClientShowsSampleSessionsOnly() {
        let online = BridgeClient(settings: settings)
        online.showSample(feed: SessionsWidgetSample.feed, reachability: .connected)
        XCTAssertTrue(online.feed.sessions.isEmpty, "samples go to an offline client only")
        let offline = BridgeClient(settings: settings, offline: true)
        offline.showSample(feed: SessionsWidgetSample.feed, reachability: .connected)
        XCTAssertEqual(offline.feed.sessions.count, SessionsWidgetSample.feed.sessions.count)
        XCTAssertEqual(offline.reachability, .connected)
    }
}
