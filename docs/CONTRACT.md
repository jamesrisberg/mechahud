# MechaHUD's MacHUD contract

MechaHUD implements the MacHUD contract through HUDKit; the canonical spec is HUDKit's
[docs/CONTRACT.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md). MacHUD reads
`MechaHUD.app/Contents/Resources/machud.json` without launching the app and talks to the running
app over a Unix socket.

The shared parts are specified there and not repeated here: [socket](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#socket) (location,
framing, replies), the [required verbs](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#verbs), [`subscribe`](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#subscribe-and-state-events),
the [settings schema](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#settings-schema) format, [hover and windowed behaviour](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#behaviour-hover-and-windowed),
the [launch announcement](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#launch-announcement) and [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).
This page lists what MechaHUD adds.

- Manifest: `Sources/MechaHUD/Resources/machud.json`: app `xyz.machud.mechahud`, socket
  `mechahud`, one panel `dashboard` (`kind: windowed`, title "Claude Sessions", symbol
  `terminal`, default 900x640, compact 900x102). `MechaHUDHost.embeddedManifest` mirrors it for
  `swift run` and tests.
- Windowed panel: shown where it was last left, in its last shown mode (`full`, `compact` = the
  session strip only). `parked` slides it off a screen edge with `peek` points showing; the
  `edge=`/`peek=` MacHUD passes are remembered, and until an edge is named it parks at the edge
  nearest its frame. `show` on a parked panel returns it to its last full or compact mode. No hover transitions.
- Socket: `~/Library/Application Support/MacHUD/sockets/mechahud.sock` (0600), one JSON object per
  line: `{"command": "...", "args": {...}}` in, `{"ok": true, ...}` or `{"ok": false, "error": "..."}` out.
- CLI: `mechahud <command> [key=value ...]` (in `MechaHUD.app/Contents/Helpers/mechahud`, linked
  onto PATH by `install.sh`). `MechaHUD ctl <command> ...` does the same from the app binary.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's |
| `state` | | `{panels: [{id: "dashboard", visible, mode, badge, status}]}`: `badge` = sessions waiting on a permission prompt (absent at 0), `status` = the fleet summary or the bridge's state |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", "panels": [...]}` whenever visibility, mode, badge or status changes |
| `panel show` / `hide` / `toggle` | `id=dashboard` | see Windowed panel |
| `panel mode` | `id=dashboard full\|compact\|parked`, `edge=` `peek=` with `parked` | sets the mode; `parked` also shows it |
| `panel frame` | `id=dashboard x= y= w= h=` | AppKit screen coordinates; at least 120x40; remembered as the full-mode frame |
| `settings get` | `key=` (optional) | `{settings: {dashboardURL, mechaclaudePath, tokenFile, readToken, controlToken, panelFrame}}`; tokens as `(set)` / `(file)` |
| `settings set` | `key=value ...` | unknown keys and invalid URLs fail; reconnects the bridge and reloads the dashboard |
| `action open-session` | `id=<sessionKey, sessionId or pid>` | shows the panel full and deep-links the dashboard to the session. `{session}` |
| `action approve` / `deny` | `id=` as above | answers the session's permission prompt through `POST /api/control`. `{status, session, sent, ack}`; not ok unless the session is waiting and the bridge applied it |
| `action snapshot` | `path=` (optional, default `$TMPDIR/mechahud-snapshot.png`) | renders the panel to a PNG (the glass backdrop comes out dark). `{path}` |
| `quit` | | replies, then quits (the socket file is removed) |
| `help` | | lists the registered commands |

## Settings

| Key | Type | Default |
|---|---|---|
| `dashboardURL` | URL | `http://127.0.0.1:7616` |
| `readToken` | string | empty: read from the token file |
| `controlToken` | string | empty: read from the token file |
| `mechaclaudePath` | path | `~/dev/mechaclaude` |
| `tokenFile` | path | `~/.claude/state-taps/web-tokens.json` |

Stored in the app's UserDefaults (`xyz.machud.mechahud`) with the panel frame (`panelFrame`), or
in `$MECHAHUD_HOME/preferences.plist`. MechaHUD ships no `settings.json` schema.

## Menu bar consolidation

While MacHUD runs it shows MechaHUD's status menu inside its own (`menu`, `menu-invoke`) and
the menu bar icon hides; it comes back when MacHUD quits or the user turns the
`menuBar.consumed` setting off (served by HUDKit's router, default `true`). The setting is
kept in the same defaults as its other settings (`<home>/preferences.plist` under `MECHAHUD_HOME`), never in the user's real preferences from a test instance.
See [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation).

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `MECHAHUD_HOME` | app | base directory for everything the app writes: settings and the panel frame in `<dir>/preferences.plist` |
| `MECHAHUD_SOCKET` | app, CLI | socket name (default `mechahud`) or an absolute socket path |
| `MECHAHUD_NO_HOTKEYS` | app | skip the Control-Option-M hotkey |
| `MECHAHUD_DEFAULTS` | app | UserDefaults suite for settings when `MECHAHUD_HOME` is not set |

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel, write a PNG of it after 1.5 s, print the path and quit; starts no socket and no hotkey |
| `ctl <command> [key=value ...]` | run as the CLI; the app does not launch |
