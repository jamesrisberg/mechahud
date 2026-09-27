import Foundation

// MARK: - SSE framing

/// Minimal Server-Sent Events line parser. Feed it one line at a time (without the trailing
/// newline); it returns the event's `data` payload when a blank line ends an event.
///
/// The mechaclaude bridge sends only unnamed `data: {json}` events, one data line each, but
/// multi-line data is joined with "\n" per the spec. `retry:` and `id:` are remembered;
/// comment lines (`: ok`) are ignored.
public struct SSEParser: Sendable {
    public private(set) var retryMilliseconds: Int?
    public private(set) var lastEventID: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll() }
            return dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "retry": if let ms = Int(value) { retryMilliseconds = ms }
        case "id": lastEventID = String(value)
        default: break
        }
        return nil
    }
}

// MARK: - Session model

/// One option of a pending select prompt (`{value, label}` from the bridge's pending block).
public struct PendingOption: Equatable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// What a waiting session is blocked on (`sessionRow.pending`, status.mjs `pendingBlock`).
public struct PendingBlock: Equatable, Sendable {
    /// "permission" | "question" | "elicitation" | "dialog" | "worker" | "sandbox"
    public var kind: String
    public var prompt: String?
    public var tool: String?
    public var options: [PendingOption]

    public init(kind: String, prompt: String? = nil, tool: String? = nil, options: [PendingOption] = []) {
        self.kind = kind
        self.prompt = prompt
        self.tool = tool
        self.options = options
    }

    public var isPermission: Bool { kind == "permission" }

    init?(json: Any?) {
        guard let d = json as? [String: Any], let kind = d["kind"] as? String else { return nil }
        self.kind = kind
        prompt = d["prompt"] as? String
        tool = d["tool"] as? String
        options = (d["options"] as? [Any] ?? []).compactMap { raw in
            guard let o = raw as? [String: Any] else { return nil }
            let label = (o["label"] as? String) ?? Self.string(o["value"]) ?? ""
            return PendingOption(value: Self.string(o["value"]) ?? label, label: label)
        }
    }

    private static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}

/// The session status the bridge reports (`classifyStatus` plus the fleet overlays).
public enum SessionStatus: Equatable, Sendable {
    case working, waiting, idle, connecting, closed
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "busy", "running", "working": self = .working
        case "waiting": self = .waiting
        case "idle", "ready": self = .idle
        case "connecting": self = .connecting
        case "closed", "ended": self = .closed
        default: self = .other(raw)
        }
    }

    public var label: String {
        switch self {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .closed: return "closed"
        case .other(let raw): return raw
        }
    }
}

/// A fleet row (`sessionRow` in web.mjs), reduced to what MechaHUD shows.
public struct SessionRow: Equatable, Identifiable, Sendable {
    public var sessionKey: String
    public var pid: Int?
    public var harness: String?
    public var sessionId: String?
    public var cwd: String?
    public var rawStatus: String
    public var title: String?
    public var customName: String?
    public var pctUntilCompact: Double?
    public var needsYou: Bool
    public var pending: PendingBlock?

    public var id: String { sessionKey }
    public var status: SessionStatus { SessionStatus(rawStatus) }

    public init(sessionKey: String, pid: Int? = nil, harness: String? = "claude", sessionId: String? = nil,
                cwd: String? = nil, status: String = "idle", title: String? = nil, customName: String? = nil,
                pctUntilCompact: Double? = nil, needsYou: Bool = false, pending: PendingBlock? = nil) {
        self.sessionKey = sessionKey
        self.pid = pid
        self.harness = harness
        self.sessionId = sessionId
        self.cwd = cwd
        self.rawStatus = status
        self.title = title
        self.customName = customName
        self.pctUntilCompact = pctUntilCompact
        self.needsYou = needsYou
        self.pending = pending
    }

    public init?(json: Any?) {
        guard let d = json as? [String: Any], let key = d["sessionKey"] as? String, !key.isEmpty else { return nil }
        sessionKey = key
        pid = (d["pid"] as? NSNumber)?.intValue
        harness = d["harness"] as? String
        sessionId = d["sessionId"] as? String
        cwd = d["cwd"] as? String
        rawStatus = d["status"] as? String ?? "connecting"
        title = d["title"] as? String
        customName = d["customName"] as? String
        pctUntilCompact = (d["pctUntilCompact"] as? NSNumber)?.doubleValue
        needsYou = d["needsYou"] as? Bool ?? false
        pending = PendingBlock(json: d["pending"])
    }

    /// Custom name, else the auto title, else the cwd's last component, else the key.
    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return sessionKey
    }

    /// cwd with the home directory abbreviated to `~`.
    public var shortCwd: String {
        guard let cwd else { return "" }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Waiting on a tool-permission prompt: the case the strip offers Allow/Deny for.
    public var isWaitingOnPermission: Bool {
        status == .waiting && (pending?.isPermission ?? false)
    }
}

// MARK: - Feed

/// What one SSE payload did to the feed.
public enum FeedChange: Equatable, Sendable {
    case sessionsChanged
    case heartbeat
    /// The bridge dropped frames for this subscriber; reconnect to get a fresh full list.
    case gap
    case spawnFailed(String)
    case ignored
    case malformed
}

/// The fleet session list, folded from `GET /events` frames. Pure and value-typed so it can be
/// tested with recorded lines.
///
/// Frames (switch on `type`; the stream has no `event:` names):
/// - `sessions {sessions:[row]}` full replacement, sent once per connect
/// - `sessions_delta {upsert?:[row], remove?:[sessionKey]}`
/// - `session_removed {pid, sessionKey}`
/// - `heartbeat {t}`, `gap`, `spawn_failed {tag, cwd, error}`
/// - `agents`, `agents_delta`, `spawn_pending`, `usage_alert`: ignored here
public struct SessionFeed: Equatable, Sendable {
    public private(set) var sessions: [SessionRow] = []
    public private(set) var lastHeartbeat: Double?
    public private(set) var hasSnapshot = false
    private var parser = SSEParser()

    public init(sessions: [SessionRow] = []) {
        self.sessions = sessions
        hasSnapshot = !sessions.isEmpty
    }

    public static func == (a: SessionFeed, b: SessionFeed) -> Bool {
        a.sessions == b.sessions && a.lastHeartbeat == b.lastHeartbeat && a.hasSnapshot == b.hasSnapshot
    }

    public var retryMilliseconds: Int? { parser.retryMilliseconds }

    /// Feeds one raw SSE line. Returns a change when the line completed an event.
    @discardableResult
    public mutating func feed(line: String) -> FeedChange? {
        guard let payload = parser.feed(line) else { return nil }
        return apply(payload: payload)
    }

    /// Applies one `data:` payload (the JSON text, without the `data:` prefix). Tolerates a
    /// leading `data:` so recorded lines can be passed straight in.
    @discardableResult
    public mutating func apply(payload raw: String) -> FeedChange {
        var text = Substring(raw)
        if text.hasPrefix("data:") { text = text.dropFirst(5).drop { $0 == " " } }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .malformed }
        return apply(frame: obj, type: type)
    }

    private mutating func apply(frame obj: [String: Any], type: String) -> FeedChange {
        switch type {
        case "sessions":
            guard let rows = obj["sessions"] as? [Any] else { return .malformed }
            sessions = rows.compactMap { SessionRow(json: $0) }
            hasSnapshot = true
            return .sessionsChanged
        case "sessions_delta":
            let before = sessions
            for raw in obj["upsert"] as? [Any] ?? [] {
                guard let row = SessionRow(json: raw) else { continue }
                if let i = sessions.firstIndex(where: { $0.sessionKey == row.sessionKey }) {
                    sessions[i] = row
                } else {
                    sessions.append(row)
                }
            }
            let removed = Set((obj["remove"] as? [Any] ?? []).compactMap { $0 as? String })
            if !removed.isEmpty { sessions.removeAll { removed.contains($0.sessionKey) } }
            return sessions == before ? .ignored : .sessionsChanged
        case "session_removed":
            let key = obj["sessionKey"] as? String
            let pid = (obj["pid"] as? NSNumber)?.intValue
            let count = sessions.count
            sessions.removeAll { row in
                if let key { return row.sessionKey == key }
                if let pid { return row.pid == pid }
                return false
            }
            return sessions.count == count ? .ignored : .sessionsChanged
        case "heartbeat":
            lastHeartbeat = (obj["t"] as? NSNumber)?.doubleValue
            return .heartbeat
        case "gap":
            return .gap
        case "spawn_failed":
            let error = obj["error"] as? String ?? "spawn failed"
            let cwd = obj["cwd"] as? String
            return .spawnFailed(cwd.map { "\($0): \(error)" } ?? error)
        default:
            return .ignored
        }
    }

    /// Forget everything (the stream went away).
    public mutating func reset() { self = SessionFeed() }

    public func session(_ key: String) -> SessionRow? { sessions.first { $0.sessionKey == key } }

    // MARK: Derived counts

    public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    public var idleCount: Int { sessions.filter { $0.status == .idle }.count }
    /// Sessions blocked on a tool-permission prompt: MechaHUD's badge.
    public var permissionWaitingCount: Int { sessions.filter(\.isWaitingOnPermission).count }

    /// e.g. "3 working · 1 waiting · 2 idle", or "no sessions".
    public var summary: String {
        var parts: [String] = []
        if workingCount > 0 { parts.append("\(workingCount) working") }
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        if idleCount > 0 { parts.append("\(idleCount) idle") }
        let other = sessions.count - workingCount - waitingCount - idleCount
        if other > 0 { parts.append("\(other) other") }
        return parts.isEmpty ? "no sessions" : parts.joined(separator: " · ")
    }
}
