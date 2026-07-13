# Claude Usage Monitor

<!-- HQ:META
id: claude-usage-monitor
name: Claude Usage Monitor
status: working
completion: 90
health: amber
category: Personal Tooling
stack: Swift, AppKit (NSPanel), launchd LaunchAgent, Bash, macOS Keychain, OAuth
entry: ClaudeMonitor.swift
run: ./claude-monitor start
github: https://github.com/MackinnonRealG/Apple_Claude_Usage_Diisplay
started: 2026-07
last_verified: 2026-07-13
connections: Quick_Access
value: At-a-glance Claude plan usage so you never hit session or weekly limits unexpectedly
summary: Floating always-on-top macOS widget that shows Claude plan usage bars, reading the OAuth token from the Keychain and refreshing every 60 seconds.
-->

> 🟡 **WORKING** · **90% complete** · health amber · last verified 2026-07-13
> Floating always-on-top macOS widget that shows Claude plan usage bars, reading the OAuth token from the Keychain and refreshing every 60 seconds.

## What it is
A single-file native Swift/AppKit widget for macOS that displays your Claude plan usage limits — the same bars as the Claude settings screen (current session, weekly all-models, weekly per-model) — always on top and draggable anywhere. It reads the Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`), calls the same endpoint the settings screen uses (`api.anthropic.com/api/oauth/usage`), auto-refreshes expired tokens via `console.anthropic.com/v1/oauth/token`, and refreshes the display every 60 seconds. It runs as a launchd LaunchAgent so macOS restarts it on crash and relaunches it at login.

Note: it is a floating desktop widget (an `NSPanel` at `.floating` level, `LSUIElement` accessory app, drag-anywhere), not a menu-bar dropdown item.

## Status & completion — 90%
**Works today:**
- Renders session / weekly-all / weekly-per-model usage bars; bars turn orange at 75% and red at 90%.
- Reads the OAuth token from the Keychain, caches it to `~/.claude-monitor/token.json` (chmod 600), and auto-refreshes expired tokens with the stored refresh token.
- launchd supervision (`com.claude.usage-monitor`): auto-restart on crash, relaunch at login, clean-exit respected.
- Drag-to-reposition (persisted), right-click "Refresh now" / "Quit", re-asserts to front each minute, snaps back on-screen if displays change.
- `make-app` builds two self-contained Desktop apps (Start / Stop) with rendered icons; `claude-monitor` CLI exposes start/stop/restart/status/log.

**Missing / not working:**
- No automated tests (single-file GUI app; none expected, none present).
- Requires a prior `claude auth login`; with no credentials it shows a "Sign in needed" state.
- macOS-only by design (AppKit, launchd, `security` Keychain CLI, `swiftc`).

**Why 90%:** Feature-complete for its purpose and clearly works — token handling, refresh, launchd supervision, off-screen recovery and icon/app generation are all implemented and polished. Held below 95 by the absence of tests and its hard dependency on externally-provisioned Claude Code credentials.

**Health amber:** It runs and is in active use, but the entire current state is uncommitted — all three tracked files (`ClaudeMonitor.swift`, `README.md`, `claude-monitor`) are modified and the `make-app` build script is untracked, against just 3 commits from 2026-07-02 (the latest being "Merge remote placeholder README"). The documented Desktop-app experience does not yet exist on the GitHub remote.

## Tech stack
Swift + AppKit (single-file `NSPanel` accessory app, no third-party dependencies), compiled with `swiftc -O`. launchd LaunchAgent for supervision. Bash tooling (`claude-monitor`, `make-app`). macOS `security` CLI for Keychain access; OAuth token refresh over `URLSession`. Compiled binary and logs live in `~/.claude-monitor/`.

## How to run
```
# one-time: make sure Claude Code is signed in (widget reads its Keychain token)
claude auth login

# run the widget under launchd (builds the binary if needed):
./claude-monitor start
./claude-monitor stop | restart | status | log

# build the two double-click Desktop apps (Start / Stop):
./make-app
```

## Project structure
```
ClaudeMonitor.swift   Single-file AppKit widget: auth/token, usage fetch, NSPanel UI
claude-monitor        Bash CLI: start/stop/restart/status/log via a launchd LaunchAgent
make-app              Builds the two self-contained Desktop .apps + rendered icons
~/.claude-monitor/    (runtime) compiled binary, token.json (chmod 600), monitor.log
```

## Connections
- **Quick_Access** — sibling Personal Tooling widget and the HQ launcher. This monitor is exactly the "app"-type project Quick_Access is designed to manage (executable `start`/`stop`-style scripts + a Swift binary named `ClaudeMonitor` for the process-status check), so it can be registered there, though it is not currently in that registry.
- Ties into the wider HQ only thematically: it tracks the Claude usage that powers Claude Code development across all HQ projects.

## Log
- 2026-07-13 — HQ README created; status assessed at 90%.

## Original project notes

# Claude Usage Monitor

A small floating widget for macOS that shows your Claude plan usage limits —
the same bars as the Claude settings screen (current session, weekly all
models, weekly per-model) — always on top, draggable anywhere, refreshing
every 60 seconds.

## Using it

Two apps live on your Desktop:

- **Claude Usage Monitor.app** — double-click to show the widget.
- **Stop Claude Monitor.app** — double-click to hide it (stays hidden until
  you start it again).

That's all you need day to day. This folder is just the source code; the
apps are self-contained.

## Developing

After editing `ClaudeMonitor.swift` or `claude-monitor`, regenerate the
Desktop apps (this also rebuilds the widget binary):

```bash
./make-app
```

The `claude-monitor` script is also usable directly:

```bash
./claude-monitor start     # show the widget
./claude-monitor stop      # hide it
./claude-monitor restart   # rebuild + restart (after editing the source)
./claude-monitor status    # is it running?
./claude-monitor log       # recent log output
```

The widget:
- **Drag** it anywhere with the mouse — its position is remembered.
- **Right-click** it for "Refresh now" and "Quit".
- Bars turn **orange at 75%** and **red at 90%** used.
- Floats above all windows, on every Space/desktop.

## Reliability

The widget runs as a **launchd LaunchAgent** (`com.claude.usage-monitor`), so
macOS supervises it:

- If it ever **crashes, launchd restarts it** automatically within seconds.
- It **relaunches at login/reboot** until you stop it, which unloads the
  agent completely (right-click → Quit also keeps it quit — clean exits are
  respected, only crashes trigger a restart).
- Every minute it **re-asserts itself to the front**, and if your displays
  change (monitor unplugged, resolution switch) and its saved position ends
  up off-screen, it **snaps back to the top-right** of the main screen so it
  can never be running-but-invisible.

## One-time setup

The widget reads your Claude Code sign-in from the macOS Keychain. If it shows
"Sign in needed", run this once in Terminal and complete the browser login:

```bash
claude auth login
```

Within a minute the widget will pick up the fresh credentials (or right-click →
Refresh now). If macOS shows a Keychain permission prompt, choose **Always
Allow** so the widget can keep reading the token.

## How it works

- `ClaudeMonitor.swift` — a single-file native AppKit app (no dependencies).
  Compiled binary and logs live in `~/.claude-monitor/`.
- `make-app` — builds the two Desktop apps. The start app embeds copies of
  the launcher script and source (macOS privacy protection stops
  Finder-launched apps reading other folders, so the app must carry
  everything it needs).
- Usage data comes from the same endpoint the Claude settings screen uses
  (`api.anthropic.com/api/oauth/usage`), so the percentages and reset times
  match exactly.
- Tokens: reads `Claude Code-credentials` from the Keychain; auto-refreshes
  expired tokens using the stored refresh token and caches them in
  `~/.claude-monitor/token.json` (chmod 600).
