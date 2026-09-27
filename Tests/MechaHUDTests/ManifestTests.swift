import Foundation
import HUDKit
import XCTest
@testable import MechaHUD

/// The shipped machud.json and Info.plist are what MacHUD and hud-build.sh read without
/// launching MechaHUD; keep them valid and in step with the conventions.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MechaHUD/Resources")
    }

    @MainActor
    func testManifestFollowsTheConventions() throws {
        let manifest = try HUDManifest.decode(Data(contentsOf: resources.appendingPathComponent(HUDManifest.fileName)))
        XCTAssertEqual(manifest.id, "xyz.machud.mechahud")
        XCTAssertEqual(manifest.socket, "mechahud", "socket name = CLI name = repo name")
        XCTAssertNotNil(manifest.panel(id: MechaHUDHost.panelID))
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "xyz.machud.mechahud")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "MechaHUD")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}
