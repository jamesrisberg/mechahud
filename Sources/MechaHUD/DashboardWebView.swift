import AppKit
import SwiftUI
import WebKit
import MechaHUDKit

/// The mechaclaude dashboard in a WKWebView, pre-authenticated:
/// - the HttpOnly read cookie `mclaude_web` is set through `WKHTTPCookieStore` before loading;
/// - `localStorage.mclaude_control_token` is injected by a document-start user script.
/// Navigation stays on the bridge's origin; other links open in the default browser.
struct DashboardWebView: NSViewRepresentable {
    let endpoint: BridgeEndpoint
    let sessionKey: String?
    /// Bump to force a reload.
    let reloadID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.underPageBackgroundColor = .clear
        context.coordinator.load(web, endpoint: endpoint, sessionKey: sessionKey, reloadID: reloadID)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.load(web, endpoint: endpoint, sessionKey: sessionKey, reloadID: reloadID)
    }

    static func controlTokenScript(_ token: String) -> String {
        let literal = (try? String(decoding: JSONEncoder().encode(token), as: UTF8.self)) ?? "\"\""
        return "try { localStorage.setItem(\"mclaude_control_token\", \(literal)); } catch (e) {}"
    }

    static func readCookie(for endpoint: BridgeEndpoint) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: "mclaude_web",
            .value: endpoint.readToken,
            .domain: endpoint.baseURL.host ?? "127.0.0.1",
            .path: "/",
            .expires: Date().addingTimeInterval(365 * 24 * 3600),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ])
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var loadedEndpoint: BridgeEndpoint?
        private var loadedKey: String??
        private var loadedReload = -1
        private var origin: (host: String?, port: Int?) = (nil, nil)

        func load(_ web: WKWebView, endpoint: BridgeEndpoint, sessionKey: String?, reloadID: Int) {
            let authChanged = endpoint != loadedEndpoint
            let keyChanged = loadedKey == nil || loadedKey! != sessionKey
            guard authChanged || keyChanged || reloadID != loadedReload else { return }
            loadedEndpoint = endpoint
            loadedKey = .some(sessionKey)
            loadedReload = reloadID
            origin = (endpoint.baseURL.host, endpoint.baseURL.port)
            let url = endpoint.dashboardURL(sessionKey: sessionKey)
            guard authChanged else { web.load(URLRequest(url: url)); return }
            let controller = web.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: DashboardWebView.controlTokenScript(endpoint.controlToken),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
            guard let cookie = DashboardWebView.readCookie(for: endpoint) else { web.load(URLRequest(url: url)); return }
            web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                web.load(URLRequest(url: url))
            }
        }

        private func isBridge(_ url: URL?) -> Bool {
            guard let url else { return false }
            if ["about", "blob", "data"].contains(url.scheme ?? "") { return true }
            return url.host == origin.host && url.port == origin.port
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if isBridge(action.request.url) { decisionHandler(.allow); return }
            if let url = action.request.url, action.targetFrame?.isMainFrame ?? true {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)   // subframe loads (the SPA has none; CSP forbids framing us)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
