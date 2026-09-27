import Foundation

// A copy of Tests/MechaHUDKitTests/Samples.swift: test targets cannot share sources.
/// Lines recorded from the live bridge (`GET /events`, 2026-09-26) plus rows shaped like
/// web.mjs `sessionRow` / status.mjs `pendingBlock`.
enum Samples {
    static let connectPreamble = [
        "retry: 3000",
        "",
        ": ok",
        "",
        #"data: {"type":"sessions","sessions":[]}"#,
        "",
        #"data: {"type":"agents","agents":[]}"#,
        "",
        #"data: {"type":"spawn_pending","pending":[]}"#,
        "",
        #"data: {"type":"heartbeat","t":1790396772664}"#,
        "",
    ]

    static let busyRow = #"{"pid":4242,"sessionKey":"claude:4242","harness":"claude","processId":null,"sessionId":"0b9d7c1e-1111-4a4a-9c9c-2f2f2f2f2f2f","cwd":"/Users/jrisberg/dev/mechahud","startedAt":1790396700000,"launchedAt":1790396700000,"status":"busy","title":"Build MechaHUD","customName":null,"tokensUsed":18234,"pctUntilCompact":91,"willCompactSoon":false,"contextStale":false,"pending":null,"needsYou":false}"#

    static let waitingRow = #"{"pid":5151,"sessionKey":"claude:5151","harness":"claude","sessionId":"7e0f3a2b-2222-4b4b-8d8d-3e3e3e3e3e3e","cwd":"/Users/jrisberg/dev/machud","status":"waiting","title":null,"customName":"machud fixes","pctUntilCompact":64.5,"pending":{"kind":"permission","tool":"Bash","prompt":"Bash","options":[{"value":"yes","label":"Yes"},{"value":"yes-dont-ask-again","label":"Yes, and don't ask again for this command"},{"value":"no","label":"No, and tell Claude what to do differently (esc)"}]},"needsYou":false}"#

    static let questionRow = #"{"pid":6161,"sessionKey":"claude:6161","harness":"claude","cwd":"/tmp/q","status":"waiting","pending":{"kind":"question","prompt":"Which color do you prefer?","options":[{"value":"Blue","label":"Blue"},{"value":"Red","label":"Red"}]}}"#

    static let idleCodexRow = #"{"pid":null,"sessionKey":"codex:thread-abc","harness":"codex","sessionId":"abc","cwd":"/Users/jrisberg/dev/archibald","status":"idle"}"#
}
