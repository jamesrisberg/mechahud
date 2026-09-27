import AppKit
import HUDKit
import SwiftUI
import MechaHUDKit

/// View state shared by the panel's SwiftUI tree and the controller.
@MainActor
final class PanelUIState: ObservableObject {
    @Published var mode: HUDPanelMode = .full
    @Published var selectedKey: String?
    @Published var showingSettings = false
    @Published var reloadID = 0
}

enum PanelMetrics {
    /// The drag handle bar above the strip: title, grip, ✕.
    static let handleHeight: CGFloat = 28
    static let stripHeight: CGFloat = 74
    /// Compact mode shows the handle and the strip.
    static let compactHeight: CGFloat = handleHeight + stripHeight
    static let fullSize = CGSize(width: 900, height: 640)
}

struct PanelRootView: View {
    @ObservedObject var bridge: BridgeClient
    @ObservedObject var ui: PanelUIState
    let setMode: (HUDPanelMode) -> Void
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DragHandleBar(hide: hide)
            SessionStripView(bridge: bridge, ui: ui, setMode: setMode)
                .frame(height: PanelMetrics.stripHeight)
            if ui.mode != .compact {
                Divider().opacity(0.4)
                Group {
                    switch pane {
                    case .settings:
                        SettingsCard(bridge: bridge, ui: ui)
                    case .web, .webReconnecting:
                        // One view identity for both cases, so a bridge restart never remounts it.
                        if let ep = bridge.endpoint {
                            DashboardWebView(endpoint: ep, sessionKey: ui.selectedKey, reloadID: ui.reloadID)
                                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                                .overlay(alignment: .top) {
                                    if pane == .webReconnecting { ReconnectingNote() }
                                }
                        }
                    case .down:
                        BridgeDownView(bridge: bridge, ui: ui)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var pane: DashboardPane {
        DashboardPane.decide(reachability: bridge.reachability, holding: bridge.holdingDashboard,
                             showingSettings: ui.showingSettings, hasEndpoint: bridge.endpoint != nil)
    }
}

/// Shown over the kept WebView while the bridge restarts (e.g. after a dashboard Redeploy).
struct ReconnectingNote: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Dashboard restarting — reconnecting…").font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.top, 10)
        .allowsHitTesting(false)
    }
}

// MARK: - Drag handle

/// The bar across the top of the panel. The WKWebView swallows mouse events, so this is the
/// panel's dependable grab point: everything but the ✕ drags the window. ✕ dismisses (hides).
struct DragHandleBar: View {
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("MechaHUD").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(maxHeight: .infinity)
            .overlay(WindowDragArea())
            StripButton(symbol: "xmark", help: "Hide (Esc, ⌃⌥M)", action: hide)
                .padding(.trailing, 8)
        }
        .frame(height: PanelMetrics.handleHeight)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }
}

// MARK: - Strip

struct SessionStripView: View {
    @ObservedObject var bridge: BridgeClient
    @ObservedObject var ui: PanelUIState
    let setMode: (HUDPanelMode) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(connectionColor).frame(width: 7, height: 7)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(width: 118, alignment: .leading)
            .frame(maxHeight: .infinity)
            .overlay(WindowDragArea())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if bridge.feed.sessions.isEmpty {
                        Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(bridge.feed.sessions) { row in
                        SessionPill(row: row, selected: ui.selectedKey == row.sessionKey,
                                    delivery: bridge.delivery[row.sessionKey],
                                    select: { select(row) },
                                    answer: { bridge.answer(row, allow: $0) })
                    }
                }
                .padding(.vertical, 6)
            }

            HStack(spacing: 4) {
                StripButton(symbol: ui.mode == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                            help: ui.mode == .compact ? "Show dashboard" : "Compact (strip only)") {
                    setMode(ui.mode == .compact ? .full : .compact)
                }
                StripButton(symbol: "gearshape", help: "Settings") {
                    ui.showingSettings.toggle()
                    if ui.showingSettings, ui.mode == .compact { setMode(.full) }
                }
            }
        }
        .padding(.horizontal, 14)
        .background(WindowDragArea())
    }

    private func select(_ row: SessionRow) {
        ui.selectedKey = row.sessionKey
        ui.showingSettings = false
        if ui.mode == .compact { setMode(.full) }
    }

    private var summary: String {
        if bridge.holdingDashboard { return "reconnecting…" }
        switch bridge.reachability {
        case .connected: return bridge.feed.summary
        case .connecting: return "connecting…"
        case .unreachable: return "dashboard down"
        case .unauthorized: return "tokens rejected"
        case .noTokens: return "no tokens"
        }
    }

    private var emptyText: String {
        if bridge.holdingDashboard { return "Dashboard restarting — reconnecting…" }
        return bridge.reachability == .connected ? "No live sessions" : (bridge.lastError ?? "Not connected")
    }

    private var connectionColor: Color {
        if bridge.holdingDashboard { return .yellow }
        switch bridge.reachability {
        case .connected: return .green
        case .connecting: return .yellow
        default: return .red
        }
    }
}

struct SessionPill: View {
    let row: SessionRow
    let selected: Bool
    let delivery: String?
    let select: () -> Void
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.8), radius: row.status == .waiting ? 4 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 190, alignment: .leading)
            if row.isWaitingOnPermission {
                if let delivery {
                    Text(delivery).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button("Allow") { answer(true) }
                        .buttonStyle(PillButtonStyle(tint: .green))
                    Button("Deny") { answer(false) }
                        .buttonStyle(PillButtonStyle(tint: .red))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.18 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(row.status == .waiting ? Color.orange.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help("\(row.sessionKey)\n\(row.cwd ?? "")")
    }

    private var detail: String {
        if row.isWaitingOnPermission {
            let what = row.pending?.tool ?? row.pending?.prompt ?? "permission"
            return "wants \(what)"
        }
        var parts = [row.status.label]
        if !row.shortCwd.isEmpty { parts.append(row.shortCwd) }
        return parts.joined(separator: " · ")
    }

    private var dotColor: Color {
        switch row.status {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .connecting: return .yellow
        case .closed: return .red.opacity(0.6)
        case .other: return .purple
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.55 : 0.35)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 0.5))
    }
}

struct StripButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// Drags the (borderless) panel: the handle bar, and the strip's empty areas.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // The panel never activates the app, so the first click must already drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Bridge down

struct BridgeDownView: View {
    @ObservedObject var bridge: BridgeClient
    @ObservedObject var ui: PanelUIState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                if bridge.reachability == .unreachable || bridge.reachability == .noTokens {
                    Button(bridge.isStartingDashboard ? "Starting…" : "Start dashboard") { bridge.startDashboard() }
                        .disabled(bridge.isStartingDashboard)
                        .keyboardShortcut(.defaultAction)
                }
                Button("Retry") { bridge.reconnect() }
                Button("Settings…") { ui.showingSettings = true }
            }
            if let out = bridge.startOutput {
                ScrollView {
                    Text(out).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            }
            if let err = bridge.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(24)
    }

    private var icon: String {
        bridge.reachability == .connecting ? "antenna.radiowaves.left.and.right" : "bolt.horizontal.circle"
    }

    private var title: String {
        switch bridge.reachability {
        case .connecting: return "Connecting to the dashboard…"
        case .unauthorized: return "The dashboard rejected MechaHUD's tokens"
        case .noTokens: return "No dashboard tokens yet"
        default: return "The mechaclaude dashboard is not running"
        }
    }

    private var message: String {
        let url = bridge.settings.dashboardURL.absoluteString
        let dir = (bridge.settings.mechaclaudePath as NSString).abbreviatingWithTildeInPath
        switch bridge.reachability {
        case .unauthorized:
            return "Tokens rotate when the bridge restarts. MechaHUD re-reads \(bridge.settings.tokenFile.path) on every reconnect; set them manually in Settings if you use a different bridge."
        case .connecting:
            return "Waiting for \(url)."
        default:
            return "Nothing answered at \(url). Start it with `node webctl.mjs start` in \(dir), or press the button below."
        }
    }
}

// MARK: - Settings

struct SettingsCard: View {
    @ObservedObject var bridge: BridgeClient
    @ObservedObject var ui: PanelUIState
    @State private var url = ""
    @State private var read = ""
    @State private var control = ""
    @State private var path = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 16, weight: .semibold))
            Form {
                TextField("Dashboard URL", text: $url)
                SecureField("Read token (blank = token file)", text: $read)
                SecureField("Control token (blank = token file)", text: $control)
                TextField("mechaclaude checkout", text: $path)
            }
            .textFieldStyle(.roundedBorder)
            Text("Token file: \(bridge.settings.tokenFile.path)").font(.system(size: 10)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { ui.showingSettings = false }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .onAppear {
            let s = bridge.settings
            url = s.dashboardURL.absoluteString
            read = s.readTokenOverride
            control = s.controlTokenOverride
            path = s.mechaclaudePath
        }
    }

    private func save() {
        do {
            try bridge.settings.apply(["dashboardURL": url, "readToken": read, "controlToken": control, "mechaclaudePath": path])
            ui.showingSettings = false
            ui.reloadID += 1
            bridge.reconnect()
        } catch {
            self.error = "\(error)"
        }
    }
}
