import Foundation

/// Whether the bridge is up, as far as the host needs to know for `state`.
public enum BridgeReachability: Equatable, Sendable {
    case connecting, connected, unreachable, unauthorized, noTokens
}
