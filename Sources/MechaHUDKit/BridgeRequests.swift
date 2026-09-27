import Foundation

/// Where the mechaclaude web bridge is and how to authenticate to it.
public struct BridgeEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var readToken: String
    public var controlToken: String

    public static let defaultURL = URL(string: "http://127.0.0.1:7616")!

    public init(baseURL: URL = BridgeEndpoint.defaultURL, readToken: String, controlToken: String) {
        self.baseURL = baseURL
        self.readToken = readToken
        self.controlToken = controlToken
    }

    /// `scheme://host[:port]`. The bridge's control tier requires an `Origin` whose host:port
    /// equals the `Host` it was reached on.
    public var origin: String {
        let scheme = baseURL.scheme ?? "http"
        let host = baseURL.host ?? "127.0.0.1"
        return baseURL.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    public var cookieHeader: String { "mclaude_web=\(readToken)" }

    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = path
        c.queryItems = query.isEmpty ? nil : query
        return c.url!
    }

    /// The dashboard page, optionally deep-linked to a live session (`?key=<sessionKey>`, the
    /// SPA's route.ts scheme).
    public func dashboardURL(sessionKey: String? = nil) -> URL {
        url("/", query: sessionKey.map { [URLQueryItem(name: "key", value: $0)] } ?? [])
    }
}

/// Builds the HTTP requests MechaHUD sends to the bridge. Pure, so headers and bodies are testable.
public enum BridgeRequests {
    /// `GET /events`: the fleet SSE stream. Read tier: the cookie only. No gzip, so the stream
    /// arrives unbuffered and line-parseable.
    public static func events(_ e: BridgeEndpoint) -> URLRequest {
        var r = URLRequest(url: e.url("/events"))
        r.setValue(e.cookieHeader, forHTTPHeaderField: "Cookie")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        r.httpShouldHandleCookies = false
        r.timeoutInterval = 45   // heartbeats arrive every 15 s; silence past this is a dead stream
        return r
    }

    /// `GET /api/sessions`: a one-shot reachability/auth probe.
    public static func sessions(_ e: BridgeEndpoint) -> URLRequest {
        var r = URLRequest(url: e.url("/api/sessions"))
        r.setValue(e.cookieHeader, forHTTPHeaderField: "Cookie")
        r.httpShouldHandleCookies = false
        r.timeoutInterval = 5
        return r
    }

    /// `POST /api/control`: control tier needs the read cookie, `X-Control-Token`, and a
    /// same-origin `Origin`. The body is `{sessionKey, action, ...}`.
    public static func control(_ e: BridgeEndpoint, sessionKey: String, body: [String: Any],
                               waitForOutcome: Bool = false) -> URLRequest {
        let query = waitForOutcome ? [URLQueryItem(name: "wait", value: "outcome")] : []
        var r = URLRequest(url: e.url("/api/control", query: query))
        r.httpMethod = "POST"
        r.setValue(e.cookieHeader, forHTTPHeaderField: "Cookie")
        r.setValue(e.controlToken, forHTTPHeaderField: "X-Control-Token")
        r.setValue(e.origin, forHTTPHeaderField: "Origin")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpShouldHandleCookies = false
        r.timeoutInterval = 15
        var payload = body
        payload["sessionKey"] = sessionKey
        r.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return r
    }

    /// The control body that answers a permission prompt, mirroring the dashboard's
    /// DecisionSheet: pick an option of the live select overlay with `choose {index}`.
    /// Allow picks the "yes" option (else the first); deny picks the "no" option, else
    /// cancels the overlay (Esc, which Claude Code treats as a rejection).
    public static func approvalBody(for pending: PendingBlock?, allow: Bool) -> [String: Any] {
        let options = pending?.options ?? []
        if allow {
            let i = options.firstIndex { $0.value.lowercased() == "yes" } ?? 0
            return ["action": "choose", "index": i]
        }
        if let i = options.firstIndex(where: { $0.value.lowercased() == "no" }) {
            return ["action": "choose", "index": i]
        }
        return ["action": "choose", "cancel": true]
    }
}

/// `~/.claude/state-taps/web-tokens.json`, written by the bridge at start (mode 0600).
public struct WebTokens: Codable, Equatable, Sendable {
    public var readToken: String
    public var controlToken: String

    public init(readToken: String, controlToken: String) {
        self.readToken = readToken
        self.controlToken = controlToken
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/state-taps/web-tokens.json")
    }

    public static func load(from url: URL = WebTokens.defaultURL) -> WebTokens? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WebTokens.self, from: data)
    }
}
