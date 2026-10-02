# Changelog

All notable changes to MechaHUD are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

### Added
- A desktop widget, **Claude Sessions**, for MacHUD's widget layer: small shows how many sessions
  are working, waiting on a prompt and idle; medium adds the first four sessions with their state.
  Clicking it opens the dashboard, clicking a session opens that session. It says so when the
  dashboard is down instead of showing old numbers. It needs a MacHUD built on HUDKit 0.3 or later.
- `--snapshot-widgets <dir>` writes a PNG of the widget at each size, without contacting the dashboard.

### Fixed
- `--snapshot` no longer reads the dashboard token file or token settings, opens the dashboard
  stream or adds a second menu bar icon: it draws the panel from made-up sessions.

### Changed
- Built with HUDKit 0.3: `hello` reports contract version 0.3.0 and lists the widget panel next to
  `dashboard`; MacHUD's tool dock still shows only `dashboard`.

## [0.2.0] - 2026-09-29

### Added
- `agent-sessions` HUDKit capability, declared on the `dashboard` panel: MacHUD's broker can find
  MechaHUD as a session provider without naming it. `action open-session id=` accepts a
  mechaclaude session key (`claude:<sessionId>`, or `codex:`/`lux:`), a bare session id or a pid.
- `sessions` socket command: every live session (`id`, `title`, `cwd`, `state`) plus whether
  mechaclaude could start a new detached session right now (`canStart`, and `problem`/`fix` when
  it can't — the bridge unreachable, or `tmux`/the `mclaude` wrapper not found). The same problem
  is shown in the panel's session strip and in MechaHUD's own status-bar menu.

### Changed
- Built with HUDKit 0.2.0: `hello` reports contract version 0.2.0, and a socket request's
  `args` values that are JSON objects or arrays reach the app as JSON text.

### Fixed
- The bridge token file follows mechaclaude's own `MCLAUDE_STATE_DIR` override, else
  `~/.claude/state-taps/web-tokens.json`, so an isolated MechaHUD run with `MCLAUDE_STATE_DIR`
  set never reads the real bridge's tokens.

## [0.1.0] - 2026-09-27

### Added
- **Dashboard panel** `dashboard` (title "Claude Sessions"): a movable, resizable glass window
  (Liquid Glass on macOS 26, `NSVisualEffectView` on macOS 14 and 15) that behaves like a normal
  window (HUDKit `.windowed`): clicking or summoning it activates MechaHUD, other windows can
  cover it, and it has a Dock tile and ⌘-Tab entry while shown. Drag handle, Escape and ✕ hide
  it; its frame is kept in settings.
- **Session strip**: one pill per live session from the mechaclaude bridge's fleet SSE
  (`GET /events`) with name, cwd and status dot; sessions waiting on a permission prompt show
  inline Allow / Deny, sent through `POST /api/control`. Clicking a pill deep-links the dashboard.
- **Dashboard WebView**: the mechaclaude dashboard at `http://127.0.0.1:7616`, pre-authenticated
  (read cookie and control token injected ahead of the page load), kept mounted under a "reconnecting" note
  through a short bridge restart. When the dashboard is unreachable the panel offers to run
  `node webctl.mjs start` in the mechaclaude checkout.
- **Modes**: full, compact (the strip only) and parked (slid off a screen edge, peeking), with
  the `edge=`/`peek=` MacHUD passes remembered.
- **MacHUD contract** through HUDKit: bundled `machud.json` manifest, `MechaHUDHost`, the HUDKit
  verb set, `state` badge = sessions waiting on a permission prompt, and the actions
  `open-session`, `approve`, `deny` and `snapshot`. `panel show reason=hover` orders the window
  in without taking focus.
- **Menu bar**: status item with the badge and the panel, mode, dashboard, reconnect and settings
  commands; Control-Option-M toggles the panel. While MacHUD runs, the menu is served into
  MacHUD's status menu (`menu`, `menu-invoke`) and the icon hides; `menuBar.consumed=false`
  opts out. The setting lives in the app's own store.
- **Settings**: dashboard URL, manual read/control tokens, token file and mechaclaude path, set
  in the panel's Settings card or with `settings set`.
- **App and menu bar icons** from the MacHUD family set, with an SF Symbol fallback.
- **`mechahud` CLI** (`Contents/Helpers`, also `MechaHUD ctl`), `--snapshot <png>`, and
  `MECHAHUD_HOME` / `MECHAHUD_SOCKET` / `MECHAHUD_NO_HOTKEYS` isolation for testing.
- `VERSION`, this changelog, CI, and builds through HUDKit's shared scripts.
