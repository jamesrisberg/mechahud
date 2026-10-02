import Foundation
import HUDKit

/// The `--snapshot` launch flag and the isolation switches for running a second instance
/// beside the user's own (live checks, tests); see docs/CONTRACT.md:
///
/// - `MECHAHUD_HOME=<dir>`: base directory for everything MechaHUD writes. Settings and the
///   panel frame go to `<dir>/preferences.plist` instead of the standard UserDefaults.
/// - `MECHAHUD_SOCKET=<name or /abs/path>`: control socket (default `mechahud`); the CLI
///   honours it too.
/// - `MECHAHUD_NO_HOTKEYS`: set to skip registering ⌃⌥M.
/// - `MECHAHUD_DEFAULTS=<suite>`: older switch, a UserDefaults suite for settings; used when
///   `MECHAHUD_HOME` is not set.
enum AppEnvironment {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isolatedHome: String? { nonEmpty("MECHAHUD_HOME") }

    /// Where MechaHUD keeps its files: `MECHAHUD_HOME`, else `~/Library/Application Support/MechaHUD`.
    static var baseDirectory: URL {
        if let home = isolatedHome {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MechaHUD", isDirectory: true)
    }

    /// Settings store. An absolute suite name is a plist path (without the extension), so an
    /// isolated home keeps settings and the panel frame out of the real defaults.
    static var defaults: UserDefaults {
        if isolatedHome != nil {
            try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            if let d = UserDefaults(suiteName: baseDirectory.appendingPathComponent("preferences").path) { return d }
        }
        return nonEmpty("MECHAHUD_DEFAULTS").flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    static var socketPath: String {
        let name = nonEmpty("MECHAHUD_SOCKET") ?? MechaHUDApp.socketName
        return name.hasPrefix("/") ? name : HUDSocket.path(for: name)
    }

    static var hotKeysEnabled: Bool { nonEmpty("MECHAHUD_NO_HOTKEYS") == nil }

    /// `--snapshot <path.png>` on the command line: write a PNG of the panel and quit.
    static var snapshotPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return nil }
        return (args[i + 1] as NSString).expandingTildeInPath
    }

    /// `--snapshot-widgets <dir>` on the command line: write a PNG of each widget size and quit.
    static var widgetSnapshotDirectory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-widgets"), args.indices.contains(i + 1) else { return nil }
        return (args[i + 1] as NSString).expandingTildeInPath
    }

    private static func nonEmpty(_ key: String) -> String? {
        environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}
