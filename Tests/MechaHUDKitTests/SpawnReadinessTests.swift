import XCTest
@testable import MechaHUDKit

/// Stands in for the real filesystem: `isExecutableFile` answers from a fixed set instead of
/// touching disk, so detection tests don't depend on what is actually installed on this Mac.
private final class FakeFileManager: FileManager, @unchecked Sendable {
    let executables: Set<String>
    init(executables: Set<String>) { self.executables = executables }
    override func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
}

final class SpawnReadinessTests: XCTestCase {
    func testBridgeUnreachableWinsOverMissingPrerequisites() {
        let r = SpawnReadiness.check(reachability: .unreachable, tmuxFound: false, mclaudeFound: false)
        XCTAssertFalse(r.canStart)
        XCTAssertEqual(r.problem, "the mechaclaude dashboard is not reachable")
        XCTAssertNotNil(r.fix)
    }

    func testMissingTmuxReportedBeforeMclaude() {
        let r = SpawnReadiness.check(reachability: .connected, tmuxFound: false, mclaudeFound: false)
        XCTAssertFalse(r.canStart)
        XCTAssertEqual(r.problem, "tmux is not installed (mechaclaude spawns detached sessions with it)")
        XCTAssertEqual(r.fix, "brew install tmux")
    }

    func testMissingMclaudeAloneIsReported() {
        let r = SpawnReadiness.check(reachability: .connected, tmuxFound: true, mclaudeFound: false)
        XCTAssertFalse(r.canStart)
        XCTAssertEqual(r.problem, "mclaude is not installed")
    }

    func testEverythingPresentIsReady() {
        let r = SpawnReadiness.check(reachability: .connected, tmuxFound: true, mclaudeFound: true)
        XCTAssertEqual(r, .ready)
        XCTAssertNil(r.problem)
        XCTAssertNil(r.fix)
    }

    func testFindPrefersPATHOverTheFallbackLocations() {
        let fake = FakeFileManager(executables: ["/custom/bin/tmux", "/opt/homebrew/bin/tmux"])
        XCTAssertEqual(SpawnReadiness.findTmux(environment: ["PATH": "/custom/bin"], fileManager: fake), "/custom/bin/tmux")
    }

    func testFindFallsBackToTheKnownHomebrewLocation() {
        let fake = FakeFileManager(executables: ["/opt/homebrew/bin/tmux"])
        XCTAssertEqual(SpawnReadiness.findTmux(environment: ["PATH": "/usr/bin"], fileManager: fake), "/opt/homebrew/bin/tmux")
    }

    func testFindReturnsNilWhenNothingMatches() {
        let fake = FakeFileManager(executables: [])
        XCTAssertNil(SpawnReadiness.findTmux(environment: ["PATH": "/usr/bin"], fileManager: fake))
        XCTAssertNil(SpawnReadiness.findMclaude(environment: ["PATH": "/usr/bin"], fileManager: fake))
    }

    func testFindMclaudeChecksTheHomeDotLocalFallback() {
        let home = ("~/.local/bin/mclaude" as NSString).expandingTildeInPath
        let fake = FakeFileManager(executables: [home])
        XCTAssertEqual(SpawnReadiness.findMclaude(environment: ["PATH": "/usr/bin"], fileManager: fake), home)
    }
}
