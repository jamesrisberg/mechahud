// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MechaHUD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MechaHUDKit", targets: ["MechaHUDKit"]),
        .executable(name: "MechaHUD", targets: ["MechaHUD"]),
        // Installed as Contents/Helpers/mechahud: a distinct product name because MechaHUD and
        // mechahud would collide on a case-insensitive volume.
        .executable(name: "MechaHUDCLI", targets: ["MechaHUDCLI"]),
    ],
    dependencies: [
        // Sibling checkout: ~/dev/hudkit next to ~/dev/mechahud.
        .package(path: "../hudkit"),
    ],
    targets: [
        // Pure core: the fleet feed, bridge requests, settings, the dashboard pane decision.
        // No AppKit UI; everything here is unit-tested.
        .target(
            name: "MechaHUDKit",
            path: "Sources/MechaHUDKit"
        ),
        // The app: menu bar item, MacHUD host, glass panel, dashboard WebView, bridge client.
        .executableTarget(
            name: "MechaHUD",
            dependencies: ["MechaHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/MechaHUD",
            // Bundle files, assembled into the .app by hudkit/scripts/hud-build.sh.
            exclude: ["Resources"]
        ),
        // `mechahud <command> [key=value ...]`: a thin client for the MacHUD control socket.
        .executableTarget(
            name: "MechaHUDCLI",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/MechaHUDCLI"
        ),
        .testTarget(
            name: "MechaHUDKitTests",
            dependencies: ["MechaHUDKit"],
            path: "Tests/MechaHUDKitTests"
        ),
        // Host logic in the app target and the shipped manifest and Info.plist.
        .testTarget(
            name: "MechaHUDTests",
            dependencies: ["MechaHUD", "MechaHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/MechaHUDTests"
        ),
    ]
)
