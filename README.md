# MechaHUD

A MacHUD app that hosts the [mechaclaude](../mechaclaude) dashboard in a glass panel, with a
native strip of live Claude sessions on top. Built on [HUDKit](../hudkit). macOS 14+.

## What it is

MechaHUD is a menu bar app with one **windowed** panel, `dashboard`: a movable, resizable glass
window (Liquid Glass on macOS 26, `NSVisualEffectView` on macOS 14 and 15) that MacHUD can show, hide,
compact or park at a screen edge. It behaves like a normal window (HUDKit `.windowed`):
clicking it or summoning it activates MechaHUD, other windows can cover it, it stays on the
Space it was opened on, and it has a Dock icon and ⌘-Tab entry while it is on screen.

- **Session strip** (native, top of the panel): one pill per live session from the bridge's
  fleet SSE (`GET /events`), with its name, cwd and a status dot (green working, orange
  waiting, grey idle). A session waiting on a tool-permission prompt shows inline
  **Allow / Deny**, sent as `choose {index}` to `POST /api/control`.
- **Dashboard** (WKWebView) at `http://127.0.0.1:7616`, pre-authenticated: the HttpOnly
  `mclaude_web` read cookie is set through `WKHTTPCookieStore` ahead of the page load, and
  `localStorage.mclaude_control_token` is injected by a document-start user script. Clicking a
  pill deep-links the dashboard to that session (`/?key=<sessionKey>`). A short bridge outage
  (a dashboard Redeploy) keeps the WebView mounted under a "reconnecting" note for 30 s.
- **Compact mode**: the strip only. **Parked**: slid off a screen edge, peeking.
- If the dashboard isn't reachable, the panel says so and offers a button that runs
  `node webctl.mjs start` in your mechaclaude checkout.

Tokens are read from `~/.claude/state-taps/web-tokens.json` on every (re)connect.

## Install

Check out HUDKit (the shared kit and build scripts) next to this repo, then install:

```sh
ls ~/dev            # hudkit  mechahud  mechaclaude
~/dev/mechahud/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/MechaHUD.app`, links
the `mechahud` command onto your PATH and launches it.

## Use

| Key | Does |
|---|---|
| Control-Option-M | show or hide the panel |
| Escape (in the panel) | hide the panel |

The menu bar icon (terminal, with the number of sessions waiting on a permission prompt) has
Show MechaHUD, Show/Hide Panel, Compact / Full / Park, Open Dashboard in Browser, Start Dashboard
(`webctl start`), Reconnect, Settings… and Quit. Drag the panel by its handle; ✕ hides it. The
gear button opens Settings. MechaHUD takes no drops.

## MacHUD contract

Panel `dashboard`, kind `windowed`, socket `mechahud`, capability `agent-sessions` (so MacHUD's
broker finds MechaHUD as a session provider without naming it). Verbs: the HUDKit set (`hello`,
`state`, `subscribe`, `panel show|hide|toggle|frame|mode`, `settings get|set`, `action`, `quit`)
plus the actions `open-session`, `approve`, `deny` and `snapshot`, and the capability's own
`sessions` verb. `state` reports the number of sessions waiting on a permission prompt as the
badge. Full reference: [docs/CONTRACT.md](docs/CONTRACT.md).

```sh
mechahud hello
mechahud state                                   # badge = sessions waiting on permission
mechahud panel show id=dashboard                 # hide / toggle
mechahud panel mode id=dashboard compact         # full / parked [edge= peek=]
mechahud panel frame id=dashboard x=100 y=100 w=900 h=640
mechahud sessions                                # every live session, plus whether mechaclaude can start one
mechahud action name=open-session id=claude:1234
mechahud action name=approve id=claude:1234      # deny likewise
mechahud settings set mechaclaudePath=~/dev/mechaclaude
mechahud action name=snapshot path=/tmp/p.png    # render the panel to a PNG
mechahud quit
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `dashboardURL` | URL | `http://127.0.0.1:7616` | the mechaclaude bridge |
| `readToken` | string | empty (token file) | manual read token; reported as `(set)` / `(file)` |
| `controlToken` | string | empty (token file) | manual control token; reported likewise |
| `mechaclaudePath` | path | `~/dev/mechaclaude` | where `node webctl.mjs start` runs |
| `tokenFile` | path | `~/.claude/state-taps/web-tokens.json` | where tokens are read from |

`settings get` also reports `panelFrame`, the panel's last full-mode frame (set by moving or
resizing the panel, or `panel frame`). Set them in the panel's Settings card or with
`mechahud settings set key=value`. Stored in the app's UserDefaults (`xyz.machud.mechahud`), or
in `$MECHAHUD_HOME/preferences.plist` for an isolated instance.

## Build from source

Needs Swift 5.9+ and HUDKit checked out next to this repo (`../hudkit`).

```sh
swift test          # MechaHUDKitTests + MechaHUDTests
./build.sh          # build/MechaHUD.app (release; ./build.sh debug for a debug build)
./install.sh        # build, install to /Applications, link the CLI, launch
build/MechaHUD.app/Contents/MacOS/MechaHUD --snapshot /tmp/mechahud.png   # write a PNG of the panel and quit
```

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and `scripts/hud-install.sh`
(set `HUDKIT_DIR` if HUDKit lives elsewhere). The version comes from [VERSION](VERSION); changes
are in [CHANGELOG.md](CHANGELOG.md).

Layout: `Sources/MechaHUDKit` is the pure core (the SSE parser and fleet model, bridge request
builders and token file, settings, the dashboard pane decision); `Sources/MechaHUD` is the app
(menu bar, `MechaHUDHost`, bridge client, glass panel, WebView) with its bundle files in
`Resources/`; `Sources/MechaHUDCLI` is the `mechahud` command.

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `MECHAHUD_HOME` | base directory for everything MechaHUD writes; settings and the panel frame go to `<dir>/preferences.plist` |
| `MECHAHUD_SOCKET` | socket name (default `mechahud`) or an absolute socket path; the CLI honours it too |
| `MECHAHUD_NO_HOTKEYS` | set to skip registering Control-Option-M |

`MECHAHUD_DEFAULTS=<suite>` (a UserDefaults suite for settings) applies when `MECHAHUD_HOME`
is not set.

```sh
MECHAHUD_HOME=$(mktemp -d) MECHAHUD_SOCKET=mechahud-test MECHAHUD_NO_HOTKEYS=1 build/MechaHUD.app/Contents/MacOS/MechaHUD &
MECHAHUD_SOCKET=mechahud-test build/MechaHUD.app/Contents/Helpers/mechahud hello
```

## License

MIT, see [LICENSE](LICENSE).
