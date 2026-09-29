import Foundation

/// Whether mechaclaude can start a new detached session right now. `spawn.mjs` launches every
/// detached session through `tmux` and the `mclaude` wrapper, and needs the bridge itself to be
/// reachable to accept the request. Surfaced in the `sessions` reply's `canStart`/`problem`/`fix`
/// (the `agent-sessions` HUDKit capability) and mirrored in MechaHUD's own panel and status menu.
/// MechaHUD only detects prerequisites; it never installs anything.
public struct SpawnReadiness: Equatable, Sendable {
    public var canStart: Bool
    public var problem: String?
    public var fix: String?

    public init(canStart: Bool, problem: String? = nil, fix: String? = nil) {
        self.canStart = canStart
        self.problem = problem
        self.fix = fix
    }

    public static let ready = SpawnReadiness(canStart: true)

    /// Pure: `tmuxFound`/`mclaudeFound` are the caller's detection results, so this is testable
    /// without touching the filesystem. The bridge is checked first (a spawn request goes over
    /// its control API), then tmux, then the `mclaude` wrapper.
    public static func check(reachability: BridgeReachability, tmuxFound: Bool, mclaudeFound: Bool) -> SpawnReadiness {
        guard reachability == .connected else {
            return SpawnReadiness(canStart: false, problem: "the mechaclaude dashboard is not reachable",
                                  fix: "run `node webctl.mjs start` in the mechaclaude checkout")
        }
        guard tmuxFound else {
            return SpawnReadiness(canStart: false, problem: "tmux is not installed (mechaclaude spawns detached sessions with it)",
                                  fix: "brew install tmux")
        }
        guard mclaudeFound else {
            return SpawnReadiness(canStart: false, problem: "mclaude is not installed",
                                  fix: "install the mclaude wrapper (see the mechaclaude README)")
        }
        return .ready
    }

    /// Real detection: `tmux`/`mclaude` on `PATH`, else their common install locations (a GUI
    /// app's `PATH` usually lacks Homebrew's). Read at call time, so a fix the user applies
    /// (`brew install tmux`) is picked up on the next `sessions` request without a relaunch.
    public static func current(reachability: BridgeReachability) -> SpawnReadiness {
        check(reachability: reachability, tmuxFound: findTmux() != nil, mclaudeFound: findMclaude() != nil)
    }

    static let tmuxFallbackPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let mclaudeFallbackPaths = [("~/.local/bin/mclaude" as NSString).expandingTildeInPath]

    static func findTmux(environment: [String: String] = ProcessInfo.processInfo.environment,
                         fileManager: FileManager = .default) -> String? {
        find("tmux", fallback: tmuxFallbackPaths, environment: environment, fileManager: fileManager)
    }

    static func findMclaude(environment: [String: String] = ProcessInfo.processInfo.environment,
                            fileManager: FileManager = .default) -> String? {
        find("mclaude", fallback: mclaudeFallbackPaths, environment: environment, fileManager: fileManager)
    }

    private static func find(_ name: String, fallback: [String], environment: [String: String],
                             fileManager: FileManager) -> String? {
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        for candidate in pathCandidates + fallback where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
