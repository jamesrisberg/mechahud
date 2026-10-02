import Foundation

/// What the `sessions` desktop widget shows, derived from the same `SessionFeed` and
/// `BridgeReachability` the dashboard strip uses: counts per state and the first few sessions.
public struct SessionsWidgetSummary: Equatable, Sendable {
    /// One listed session.
    public struct Row: Equatable, Identifiable, Sendable {
        public var sessionKey: String
        public var name: String
        public var status: SessionStatus
        public var id: String { sessionKey }
    }

    public var working = 0
    public var idle = 0
    /// Sessions blocked on a prompt (permission, question, dialog): they need the user.
    public var waiting = 0
    /// At most `rowLimit` sessions: waiting first, then working, then the rest, each group in
    /// the feed's order.
    public var rows: [Row] = []
    /// Sessions beyond `rowLimit`.
    public var more = 0
    /// Set instead of counts while the bridge is not connected (or is being reconnected after a
    /// dashboard restart); the counts and rows are then empty rather than stale.
    public var unavailable: String?

    public var isEmpty: Bool { working + idle + waiting == 0 && rows.isEmpty }

    public static let connecting = SessionsWidgetSummary(feed: SessionFeed(), reachability: .connecting)

    public init(feed: SessionFeed, reachability: BridgeReachability, reconnecting: Bool = false, rowLimit: Int = 4) {
        if reconnecting { unavailable = "Reconnecting…"; return }
        switch reachability {
        case .connected: break
        case .connecting: unavailable = "Connecting…"; return
        case .unreachable: unavailable = "Dashboard not running"; return
        case .unauthorized: unavailable = "Dashboard rejected tokens"; return
        case .noTokens: unavailable = "No dashboard tokens"; return
        }
        working = feed.workingCount
        idle = feed.idleCount
        waiting = feed.waitingCount
        func rank(_ s: SessionStatus) -> Int { s == .waiting ? 0 : s == .working ? 1 : 2 }
        let sorted = feed.sessions.enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
        rows = sorted.prefix(max(rowLimit, 0)).map { Row(sessionKey: $0.sessionKey, name: $0.displayName, status: $0.status) }
        more = max(sorted.count - rows.count, 0)
    }
}
