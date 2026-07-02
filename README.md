# Claude Usage Monitor

A small floating widget for macOS that shows your Claude plan usage limits —
the same bars as the Claude settings screen (current session, weekly all
models, weekly per-model) — always on top, draggable anywhere, refreshing
every 60 seconds.

## Commands

```bash
claude-monitor start     # show the widget
claude-monitor stop      # hide it
claude-monitor restart   # rebuild + restart (after editing the source)
claude-monitor status    # is it running?
claude-monitor log       # recent log output
```

The widget:
- **Drag** it anywhere with the mouse — its position is remembered.
- **Right-click** it for "Refresh now" and "Quit".
- Bars turn **orange at 75%** and **red at 90%** used.
- Floats above all windows, on every Space/desktop.

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
- Usage data comes from the same endpoint the Claude settings screen uses
  (`api.anthropic.com/api/oauth/usage`), so the percentages and reset times
  match exactly.
- Tokens: reads `Claude Code-credentials` from the Keychain; auto-refreshes
  expired tokens using the stored refresh token and caches them in
  `~/.claude-monitor/token.json` (chmod 600).
