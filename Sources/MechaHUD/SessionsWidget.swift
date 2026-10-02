import Combine
import HUDKit
import MechaHUDKit
import SwiftUI

/// The session model behind the `sessions` widget: the bridge client's fleet feed (the one the
/// strip shows) folded into counts and rows. The widget never talks to the bridge itself.
@MainActor
final class SessionsWidgetModel: ObservableObject {
    @Published private(set) var summary = SessionsWidgetSummary.connecting

    func update(feed: SessionFeed, reachability: BridgeReachability, reconnecting: Bool) {
        let next = SessionsWidgetSummary(feed: feed, reachability: reachability, reconnecting: reconnecting)
        if next != summary { summary = next }
    }
}

/// MechaHUD's widget side: the `sessions` type registered with HUDKit's `HUDWidgetHost`
/// (which owns the windows and the `widget` verb), and the model it draws from.
@MainActor
final class MechaHUDWidgets {
    static let sessionsType = "sessions"

    let host: HUDWidgetHost
    let model = SessionsWidgetModel()

    /// `openDashboard` shows the dashboard panel (a click on the widget); `openSession` shows it
    /// deep-linked to one session (a click on a row of the medium widget).
    init(manifest: HUDManifest?, bundleURL: URL = Bundle.main.bundleURL,
         openDashboard: @escaping () -> Void, openSession: @escaping (String) -> Void) {
        host = HUDWidgetHost(manifest: manifest, bundleURL: bundleURL)
        host.onOpen = { _ in openDashboard() }
        host.register(Self.sessionsType) { [model] context in
            SessionsWidgetView(model: model, context: context, openSession: openSession)
        }
    }
}

extension SessionStatus {
    /// The status colour used by the strip's dots and the widget.
    var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .connecting: return .yellow
        case .closed: return .red.opacity(0.6)
        case .other: return .purple
        }
    }
}

/// The widget: small = three counts, medium = counts plus up to four sessions. Tapping the
/// tile opens the dashboard (`HUDWidgetContext.openApp`); tapping a row opens that session.
struct SessionsWidgetView: View {
    @ObservedObject var model: SessionsWidgetModel
    @ObservedObject var context: HUDWidgetContext
    let openSession: (String) -> Void

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: 8) {
            header(summary)
            if let message = summary.unavailable {
                Spacer(minLength: 0)
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            } else if context.size == .small {
                SmallCounts(summary: summary)
            } else if summary.rows.isEmpty {
                Spacer(minLength: 0)
                Text("No live sessions").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 2) {
                    ForEach(summary.rows) { row in
                        SessionWidgetRow(row: row).onTapGesture { openSession(row.sessionKey) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { context.openApp() }
    }

    private func header(_ summary: SessionsWidgetSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
            Text("Sessions").font(.system(size: 12, weight: .semibold))
            if summary.more > 0, context.size != .small {
                Text("+\(summary.more) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            if context.size != .small, summary.unavailable == nil {
                CountChip(count: summary.working, color: SessionStatus.working.color)
                CountChip(count: summary.waiting, color: SessionStatus.waiting.color)
                CountChip(count: summary.idle, color: SessionStatus.idle.color)
            }
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

private struct CountChip: View {
    let count: Int
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }
}

private struct SmallCounts: View {
    let summary: SessionsWidgetSummary
    var body: some View {
        VStack(spacing: 6) {
            line("Working", summary.working, SessionStatus.working.color)
            line("Waiting", summary.waiting, SessionStatus.waiting.color)
            line("Idle", summary.idle, SessionStatus.idle.color)
        }
        .frame(maxHeight: .infinity)
    }

    private func line(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: label == "Waiting" && count > 0 ? 4 : 0)
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(count > 0 ? 0.9 : 0.5))
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 22, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(count > 0 ? 1 : 0.4))
        }
    }
}

private struct SessionWidgetRow: View {
    let row: SessionsWidgetSummary.Row
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(row.status.color).frame(width: 8, height: 8)
            Text(row.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(row.status.label).font(.system(size: 11)).foregroundStyle(row.status.color)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

/// Made-up sessions for `--snapshot-widgets`: the widget is checked without the bridge.
enum SessionsWidgetSample {
    static var feed: SessionFeed {
        SessionFeed(sessions: [
            SessionRow(sessionKey: "claude:1", cwd: "/Users/me/dev/machud", status: "idle", customName: "machud fixes"),
            SessionRow(sessionKey: "claude:2", cwd: "/Users/me/dev/hudkit", status: "busy", customName: "widget contract"),
            SessionRow(sessionKey: "claude:3", cwd: "/Users/me/dev/stash", status: "waiting", customName: "stash widget",
                       pending: PendingBlock(kind: "permission", prompt: "Bash", tool: "Bash")),
            SessionRow(sessionKey: "claude:4", cwd: "/Users/me/dev/mechaclaude", status: "busy", customName: "bridge tokens"),
            SessionRow(sessionKey: "codex:5", harness: "codex", cwd: "/Users/me/dev/archibald", status: "idle"),
            SessionRow(sessionKey: "claude:6", cwd: "/Users/me/dev/sift", status: "idle", customName: "sift"),
        ])
    }
}
