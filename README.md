# Codex Status Monitor

An intentionally small, native macOS proof of concept. A Codex lifecycle hook
starts the `codex-status-hook` executable and supplies a structured event on
standard input. The helper posts a local macOS distributed notification, and
`codex-status-dashboard` is a plain AppKit window that displays the latest
notification.

It forwards only the event name, session ID, turn ID, and working directory;
prompt text and other fields are not broadcast. It also continues to accept a
plain command-line event name for the older `notify` integration, but hooks are
the preferred path.

## Run the dashboard

```sh
swift run codex-status-dashboard
```

Keep that window running, then in a second terminal send a representative event:

```sh
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"demo-session","turn_id":"demo-turn","cwd":"/tmp/demo"}' | swift run codex-status-hook
```

The dashboard should change to `Received UserPromptSubmit`.

## Install lifecycle hooks

Build a release helper once:

```sh
swift build -c release
```

The hook configuration is deliberately separate from `notify`; the existing
`notify` value in `~/.codex/config.toml` remains unchanged.

Merge the entries from [examples/codex-status-hooks.json](examples/codex-status-hooks.json)
into the global `hooks.json` file described by Codex Desktop's hook documentation
(the current embedded Codex identifies its global hook file as
`~/.codex/hooks/hooks.json`). The command in the example points at this checkout's
release executable; update it if you move the repository.

The configuration intentionally contains only four low-volume state transitions:

| Codex event | Dashboard meaning |
| --- | --- |
| `SessionStart` | a thread registered |
| `UserPromptSubmit` | work started (blue) |
| `PermissionRequest` | attention needed (amber) |
| `Stop` | work finished (green) |

Codex should ask you to review and trust a newly installed command hook. Keep
that review step; the hook runs a local executable from this checkout.

This prototype uses distributed notifications, so the dashboard must already be
running when `turn-ended` fires. That is deliberate for the first vertical slice;
a later version can replace it with a socket and launch-at-login app lifecycle.

## Verify

```sh
swift test
```
