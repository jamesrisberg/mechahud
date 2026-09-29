import CoreGraphics
import Foundation

/// User settings, stored in UserDefaults. Token fields override the token file when non-empty.
public final class AppSettings {
    public enum Key: String, CaseIterable {
        case dashboardURL, readToken, controlToken, mechaclaudePath, tokenFile
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var dashboardURL: URL {
        get { defaults.string(forKey: Key.dashboardURL.rawValue).flatMap(URL.init(string:)) ?? BridgeEndpoint.defaultURL }
        set { defaults.set(newValue.absoluteString, forKey: Key.dashboardURL.rawValue) }
    }

    /// Manual read token; empty means "use the token file".
    public var readTokenOverride: String {
        get { defaults.string(forKey: Key.readToken.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.readToken.rawValue) }
    }

    public var controlTokenOverride: String {
        get { defaults.string(forKey: Key.controlToken.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.controlToken.rawValue) }
    }

    /// The mechaclaude checkout, where `node webctl.mjs start` runs.
    public var mechaclaudePath: String {
        get { defaults.string(forKey: Key.mechaclaudePath.rawValue) ?? ("~/dev/mechaclaude" as NSString).expandingTildeInPath }
        set { defaults.set(newValue, forKey: Key.mechaclaudePath.rawValue) }
    }

    public var tokenFile: URL {
        get { defaults.string(forKey: Key.tokenFile.rawValue).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? WebTokens.defaultURL() }
        set { defaults.set(newValue.path, forKey: Key.tokenFile.rawValue) }
    }

    public static let panelFrameKey = "panelFrame"

    /// The panel's last full-mode frame (AppKit screen coordinates), restored when it is
    /// summoned again. Nil until the panel has been placed; degenerate values read as nil.
    public var panelFrame: CGRect? {
        get {
            guard let raw = defaults.string(forKey: Self.panelFrameKey) else { return nil }
            let r = NSRectFromString(raw)
            return r.width > 0 && r.height > 0 ? r : nil
        }
        set {
            if let newValue { defaults.set(NSStringFromRect(newValue), forKey: Self.panelFrameKey) }
            else { defaults.removeObject(forKey: Self.panelFrameKey) }
        }
    }

    /// The endpoint to use now: overrides first, then the token file (re-read every call, since
    /// the bridge can rotate tokens). Nil when no read token is known.
    public func endpoint() -> BridgeEndpoint? {
        let file = WebTokens.load(from: tokenFile)
        let read = readTokenOverride.isEmpty ? (file?.readToken ?? "") : readTokenOverride
        let control = controlTokenOverride.isEmpty ? (file?.controlToken ?? "") : controlTokenOverride
        guard !read.isEmpty else { return nil }
        return BridgeEndpoint(baseURL: dashboardURL, readToken: read, controlToken: control)
    }

    /// For the `settings get` verb. Tokens are reported as set/unset, never echoed.
    public var snapshot: [String: Any] {
        var s: [String: Any] = ["dashboardURL": dashboardURL.absoluteString,
         "mechaclaudePath": mechaclaudePath,
         "tokenFile": tokenFile.path,
         "readToken": readTokenOverride.isEmpty ? "(file)" : "(set)",
         "controlToken": controlTokenOverride.isEmpty ? "(file)" : "(set)"]
        if let f = panelFrame { s["panelFrame"] = [f.minX, f.minY, f.width, f.height].map { Double($0) } }
        return s
    }

    /// Applies `settings set` values. Unknown keys throw.
    public func apply(_ values: [String: String]) throws {
        for (k, v) in values {
            guard let key = Key(rawValue: k) else { throw SettingsError.unknownKey(k) }
            switch key {
            case .dashboardURL:
                guard let url = URL(string: v), url.scheme != nil, url.host != nil else { throw SettingsError.invalid(k, v) }
                dashboardURL = url
            case .readToken: readTokenOverride = v
            case .controlToken: controlTokenOverride = v
            case .mechaclaudePath: mechaclaudePath = (v as NSString).expandingTildeInPath
            case .tokenFile: tokenFile = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            }
        }
    }
}

public enum SettingsError: Error, CustomStringConvertible, Equatable {
    case unknownKey(String)
    case invalid(String, String)

    public var description: String {
        switch self {
        case .unknownKey(let k): return "unknown setting \(k)"
        case .invalid(let k, let v): return "invalid value for \(k): \(v)"
        }
    }
}
