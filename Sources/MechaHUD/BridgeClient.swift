import Foundation
import Combine
import MechaHUDKit

public enum BridgeError: Error, CustomStringConvertible {
    case noTokens
    case noControlToken
    case http(Int, String)

    public var description: String {
        switch self {
        case .noTokens: return "no dashboard read token (Settings, or start the dashboard)"
        case .noControlToken: return "no control token (Settings)"
        case .http(let code, let status): return "HTTP \(code): \(status)"
        }
    }
}

/// Talks to the mechaclaude bridge: keeps the fleet SSE stream (`GET /events`) open with
/// reconnects, sends control requests, and can start the dashboard with `node webctl.mjs start`.
@MainActor
public final class BridgeClient: ObservableObject, BridgeControlling {
    @Published public private(set) var feed = SessionFeed()
    @Published public private(set) var reachability: BridgeReachability = .connecting
    @Published public private(set) var endpoint: BridgeEndpoint?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isStartingDashboard = false
    @Published public private(set) var startOutput: String?
    /// True while a stream that was connected has dropped and the grace has not run out (a
    /// dashboard Redeploy restarting the bridge): the panel keeps the WebView and says "reconnecting".
    @Published public private(set) var holdingDashboard = false
    /// Per-session delivery state of the last Allow/Deny ("sending", "applied", an error...).
    @Published public var delivery: [String: String] = [:]

    /// Fires after every feed or reachability change.
    public var onChange: (() -> Void)?

    public let settings: AppSettings
    /// An offline client never reads the token file or the token settings, never opens the
    /// stream and sends no control request: a `--snapshot` run uses one so it touches no
    /// secret and talks to no dashboard.
    public let offline: Bool
    private let session: URLSession
    private var loop: Task<Void, Never>?
    /// SSE framing state for the current connection. Kept apart from `feed` so buffering a
    /// `data:` line never republishes the feed.
    private var parser = SSEParser()
    private var hold = ReconnectHold()
    private var holdExpiry: Task<Void, Never>?

    public init(settings: AppSettings, offline: Bool = false) {
        self.settings = settings
        self.offline = offline
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 60 * 60 * 24 * 365
        session = URLSession(configuration: config)
        endpoint = offline ? nil : settings.endpoint()
    }

    /// Offline only: shows made-up sessions in the panel (for `--snapshot`).
    func showSample(feed sample: SessionFeed, reachability sampled: BridgeReachability) {
        guard offline else { return }
        feed = sample
        reachability = sampled
    }

    // MARK: Stream

    public func start() {
        guard !offline, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.connectOnce()
                if Task.isCancelled { return }
                let ms = self.parser.retryMilliseconds ?? 3000
                try? await Task.sleep(nanoseconds: UInt64(max(ms, 1000)) * 1_000_000)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Drop the stream and connect again (settings changed, tokens rotated, dashboard started).
    public func reconnect() {
        stop()
        hold.reset()
        refreshHold()
        endpoint = offline ? nil : settings.endpoint()
        start()
    }

    private func set(_ r: BridgeReachability, error: String? = nil) {
        let changed = r != reachability || error != lastError
        reachability = r
        lastError = error
        hold.observe(r, now: Date())
        refreshHold()
        if r != .connected, !feed.sessions.isEmpty { feed.reset() }
        if changed { onChange?() }
    }

    /// Publishes `holdingDashboard` and, while holding, re-checks it when the grace runs out.
    private func refreshHold() {
        let now = Date()
        let holding = hold.holding(at: now)
        if holding != holdingDashboard { holdingDashboard = holding }
        holdExpiry?.cancel()
        holdExpiry = nil
        guard holding, let droppedAt = hold.droppedAt else { return }
        let remaining = ReconnectHold.grace - now.timeIntervalSince(droppedAt)
        holdExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(remaining, 0) * 1_000_000_000) + 50_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshHold()
            self.onChange?()
        }
    }

    private func connectOnce() async {
        guard let ep = settings.endpoint() else {
            endpoint = nil
            set(.noTokens, error: "no token file at \(settings.tokenFile.path)")
            return
        }
        if endpoint != ep { endpoint = ep }
        do {
            let (bytes, response) = try await session.bytes(for: BridgeRequests.events(ep))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                bytes.task.cancel()
                set(.unauthorized, error: "HTTP \(code) from /events")
                return
            }
            guard code == 200 else {
                bytes.task.cancel()
                set(.unreachable, error: "HTTP \(code) from /events")
                return
            }
            set(.connected)
            parser = SSEParser()
            var line: [UInt8] = []
            line.reserveCapacity(4096)
            for try await byte in bytes {
                if byte == 0x0A {
                    let text = String(decoding: line, as: UTF8.self)
                    line.removeAll(keepingCapacity: true)
                    if handle(line: text) == .gap { bytes.task.cancel(); break }
                } else {
                    line.append(byte)
                }
            }
            set(.connecting, error: "stream ended")
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                set(.unreachable, error: error.localizedDescription)
            default:
                set(.connecting, error: error.localizedDescription)
            }
        } catch {
            set(.connecting, error: "\(error)")
        }
    }

    @discardableResult
    private func handle(line: String) -> FeedChange? {
        guard let payload = parser.feed(line) else { return nil }
        var next = feed
        let change = next.apply(payload: payload)
        switch change {
        case .sessionsChanged:
            feed = next
            onChange?()
        case .heartbeat:
            feed = next
        case .spawnFailed(let message):
            lastError = message
        case .gap, .ignored, .malformed:
            break
        }
        return change
    }

    // MARK: Control

    public func control(sessionKey: String, body: [String: Any]) async throws -> [String: Any] {
        guard !offline, let ep = settings.endpoint() else { throw BridgeError.noTokens }
        guard !ep.controlToken.isEmpty else { throw BridgeError.noControlToken }
        let (data, response) = try await session.data(for: BridgeRequests.control(ep, sessionKey: sessionKey, body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200 else {
            throw BridgeError.http(code, json["status"] as? String ?? json["error"] as? String
                                   ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return json
    }

    /// Allow/Deny from the strip, with a visible delivery state.
    public func answer(_ row: SessionRow, allow: Bool) {
        delivery[row.sessionKey] = allow ? "allowing…" : "denying…"
        let body = BridgeRequests.approvalBody(for: row.pending, allow: allow)
        Task { @MainActor in
            do {
                let reply = try await control(sessionKey: row.sessionKey, body: body)
                let ack = reply["ack"] as? [String: Any]
                delivery[row.sessionKey] = ack?["status"] as? String ?? "sent"
            } catch {
                delivery[row.sessionKey] = "failed: \(error)"
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            delivery[row.sessionKey] = nil
        }
    }

    // MARK: Dashboard lifecycle

    /// Runs `node webctl.mjs start` in the mechaclaude checkout through a login shell (so the
    /// user's PATH finds node), then reconnects.
    public func startDashboard() {
        guard !isStartingDashboard else { return }
        let dir = settings.mechaclaudePath
        guard FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("webctl.mjs")) else {
            startOutput = "webctl.mjs not found in \(dir). Set the mechaclaude path in Settings."
            return
        }
        isStartingDashboard = true
        startOutput = "$ node webctl.mjs start"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "node webctl.mjs start"]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] p in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.isStartingDashboard = false
                self.startOutput = "$ node webctl.mjs start (exit \(status))\n" + out.trimmingCharacters(in: .whitespacesAndNewlines)
                self.reconnect()
            }
        }
        do {
            try process.run()
        } catch {
            isStartingDashboard = false
            startOutput = "could not run zsh: \(error)"
        }
    }
}
