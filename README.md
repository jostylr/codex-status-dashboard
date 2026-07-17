# Codex Status Monitor

An intentionally small, native macOS proof of concept. A Codex lifecycle hook
starts the `codex-status-hook` executable and supplies a structured event on
standard input. The helper posts a local macOS distributed notification, and
`codex-status-dashboard` is a compact, movable floating light strip shown on
every Space. It sweeps blue while work is active, pulses amber for permission,
and glows green at completion. Its configurable base is six lights: one session
uses all six, while two split the strip into left and right groups of three.
Additional sessions divide the strip as evenly as possible. If active sessions
exceed the configured base, the strip expands with one light per extra session.
When a newer thread starts, completed segments clear and active sessions
rebalance; for example, three 2-light groups with two completed threads become
two 3-light groups.

It forwards only the event name, session ID, turn ID, and working directory;
prompt text and other fields are not broadcast. It also continues to accept a
plain command-line event name for the older `notify` integration, but hooks are
the preferred path.

## Release

There is a release version of the app. Not signed. You can clone this repo and build it or you download the app and see if you can get it to run. 

## Run from source

```sh
swift build
swift run codex-status-dashboard
```

Keep that window running, then in a second terminal send a representative event:

```sh
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"demo-session","turn_id":"demo-turn","cwd":"/tmp/demo"}' | swift run codex-status-hook
```

The dashboard should start its blue scanner animation.

## Build an app bundle

For a stable hook-helper path and Launch at Login support, build the native app
bundle, move it to `/Applications`, then open it:

```sh
sh scripts/build-app.sh
open ".build/Codex Status Dashboard.app"
```

The dashboard runs as a menu-bar app. Its menu provides Show/Hide, Quit, a
persisted Base Lights preference, Hook installation, and Launch at Login.
The bundled app icon is generated from [Resources/AppIcon.svg](Resources/AppIcon.svg).
Dragging the strip saves its screen position; choose **Restore Default Position**
from the same menu to return it to the lower-left screen edge.

## Install lifecycle hooks

The hook configuration is deliberately separate from `notify`; the existing
`notify` value in `~/.codex/config.toml` remains unchanged.

Choose **Install / Update Codex Hooks…** from the dashboard's menu-bar icon.
After confirmation, it merges this app's four entries into
`~/.codex/hooks.json`, preserves existing hooks, and never changes
`notify`. Reinstall hooks after moving the app, so the configured helper path
matches the new app location. Not well tested if you have already exsiting hooks. 

The configuration intentionally contains only four low-volume state transitions:

| Codex event | Dashboard meaning |
| --- | --- |
| `SessionStart` | a thread registered |
| `UserPromptSubmit` | work started (blue) |
| `PermissionRequest` | attention needed (amber) |
| `Stop` | work finished (green) |

Codex should ask you to review and trust a newly installed command hook. Keep
that review step; the hook runs a local executable from this checkout.


## Verify

```sh
swift test
```
