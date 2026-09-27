import Foundation

/// What the panel's lower area shows.
public enum DashboardPane: Equatable {
    case settings
    /// The dashboard WebView.
    case web
    /// The WebView stays mounted under a "reconnecting" note: the bridge dropped after a good
    /// connection (a dashboard Redeploy restarts it on purpose) and the SPA reconnects itself.
    case webReconnecting
    /// `BridgeDownView`: never connected, tokens missing/rejected, or the outage outlived the grace.
    case down

    public static func decide(reachability: BridgeReachability, holding: Bool,
                       showingSettings: Bool, hasEndpoint: Bool) -> DashboardPane {
        if showingSettings { return .settings }
        guard hasEndpoint else { return .down }
        if reachability == .connected { return .web }
        if holding, reachability == .connecting || reachability == .unreachable { return .webReconnecting }
        return .down
    }
}

/// Keeps the dashboard WebView alive across a short bridge outage.
///
/// The dashboard's Redeploy pulls, rebuilds and then restarts the bridge (`webctl restart` or a
/// launchd respawn), which ends MechaHUD's `/events` stream for a second or two. Tearing the
/// WebView down for that gap would drop the SPA's redeploy progress modal (whose Reload waits
/// for the bridge to come back), its IndexedDB cache (the data store is non-persistent) and any
/// unsent draft, and would offer "Start dashboard" while `webctl restart` is mid-flight. So a
/// drop after a good connection is held for `grace`; only a longer outage shows the down view.
public struct ReconnectHold: Equatable {
    public static let grace: TimeInterval = 30

    public private(set) var wasConnected = false
    public private(set) var droppedAt: Date?

    public init() {}

    public mutating func observe(_ r: BridgeReachability, now: Date) {
        switch r {
        case .connected:
            wasConnected = true
            droppedAt = nil
        case .connecting, .unreachable:
            if wasConnected, droppedAt == nil { droppedAt = now }
        case .unauthorized, .noTokens:
            reset()
        }
    }

    public func holding(at now: Date) -> Bool {
        guard let droppedAt else { return false }
        return now.timeIntervalSince(droppedAt) < Self.grace
    }

    public mutating func reset() {
        wasConnected = false
        droppedAt = nil
    }
}
