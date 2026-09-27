import XCTest
@testable import MechaHUD
import MechaHUDKit

final class DashboardWebViewTests: XCTestCase {
    let ep = BridgeEndpoint(readToken: "READ123", controlToken: "CTRL456")

    func testControlTokenScriptEscapesToken() {
        let js = DashboardWebView.controlTokenScript("a\"b</script>")
        XCTAssertTrue(js.contains(#"localStorage.setItem("mclaude_control_token", "a\"b<\/script>")"#), js)
    }

    func testReadCookieIsHttpOnlyForBridgeHost() throws {
        let c = try XCTUnwrap(DashboardWebView.readCookie(for: ep))
        XCTAssertEqual(c.name, "mclaude_web")
        XCTAssertEqual(c.value, "READ123")
        XCTAssertEqual(c.domain, "127.0.0.1")
        XCTAssertEqual(c.path, "/")
        XCTAssertTrue(c.isHTTPOnly)
    }
}
