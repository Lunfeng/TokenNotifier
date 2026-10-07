# TokenNotifier

TokenNotifier is a Windows 10/11 Codex plugin that reads CC Switch usage
records after each completed answer and displays configurable token, cost,
latency, and calculated metrics in a native Windows Adaptive Toast.

## Install From GitHub

Add the repository marketplace, then install `token-notifier` from the Codex
plugin directory:

```text
https://github.com/Lunfeng/TokenNotifier.git
```

Review and trust the plugin Hooks when Codex asks. The package registers
`UserPromptSubmit` and `Stop`.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1.
- Codex desktop app or Codex CLI with local plugin Hooks enabled.
- CC Switch routing enabled and its usage database readable.
- `sqlite3.exe` available on `PATH`.
- One active Codex turn at a time when exact per-turn attribution matters.

The plugin has no PowerShell Gallery, Node.js, Python, .NET SDK, packaged-app,
administrator, or resident-process dependency.

## Toast Registration

On the first notification, TokenNotifier registers the per-user application
identity `Lunfeng.TokenNotifier`. It creates:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\TokenNotifier.lnk
HKCU\Software\Classes\AppUserModelId\Lunfeng.TokenNotifier
```

This gives TokenNotifier its own name, icon, notification-center grouping, and
entry in Windows notification settings. Registration is idempotent and repairs
a shortcut that points to an older plugin location. It does not install a
service, start automatically, or keep a process running.

To remove only the Toast identity registration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\unregister-toast.ps1
```

This does not remove user configuration, usage logs, or error logs.

## Configuration

Create or edit:

```text
%USERPROFILE%\.codex\token-notifier\config.json
```

The packaged defaults are in `config/default-config.json`:

```json
{
  "enabled": true,
  "toast": {
    "duration": "short"
  },
  "items": [
    { "label": "费用", "field": "total_cost_usd", "format": "currency_usd" },
    { "label": "输入 Token", "field": "input_tokens", "format": "integer" },
    { "label": "输出 Token", "field": "output_tokens", "format": "integer" },
    { "label": "总 Token", "expression": "input_tokens + output_tokens", "format": "integer" }
  ]
}
```

`toast.duration` accepts `short` or `long`. It is a Windows display hint, not
an exact timeout.

Each item must define exactly one `field` or `expression`. Expressions support
numeric literals, parentheses, unary signs, `+`, `-`, `*`, `/`, comparisons,
and the `abs`, `max`, `min`, and `round` functions. They cannot execute
PowerShell, access files, start processes, or use the network.

Supported formats are `text`, `integer`, `decimal`, `currency_usd`, `percent`,
and `milliseconds`. Invalid rows render as `--` and write a diagnostic without
suppressing the notification.

TokenNotifier submits every configured item in order. Windows may truncate,
wrap, or collapse a Toast when the content exceeds the space available; the
plugin does not impose its own row limit or create additional notifications.
Windows also controls placement, width, theme, animation, notification-center
retention, and Do Not Disturb behavior.

There is no detail window, action button, click handler, or saved notification
payload. The temporary JSON used to launch the detached notifier is deleted as
soon as it is read.

### Legacy Configuration

Existing configurations remain valid. If `toast.duration` is missing,
`popup.auto_close_seconds` values of 10 or more map to `long`; other values map
to `short`. Legacy `popup.position`, `popup.max_visible`, and
`popup.always_on_top` are ignored because Windows controls Toast presentation.

## Runtime Data

The Hooks receive `PLUGIN_ROOT` and `PLUGIN_DATA` from Codex. The package uses
`PLUGIN_ROOT` for scripts and assets and `PLUGIN_DATA` for runtime state when
provided. Otherwise data is stored under:

```text
%USERPROFILE%\.codex\token-notifier
```

`usage.jsonl` contains request and turn summaries. `errors.log` contains
non-blocking collection, configuration, registration, or Toast failures. The
plugin does not persist prompt text, answer text, API keys, or provider response
bodies.

`TOKENNOTIFIER_DATA_ROOT`, `TOKENNOTIFIER_CONFIG_PATH`, and
`TOKENNOTIFIER_NOTIFIER_COMMAND` can override local paths or the notifier
command. The former `APINOTIFIER_*` variables remain accepted as migration
aliases.

If an older project-local Hook still invokes ApiNotifier, disable that Hook
before installing this package so each event is handled once.

## Troubleshooting

If no Toast appears:

1. Check Windows Settings > System > Notifications > TokenNotifier.
2. Check whether Do Not Disturb is active.
3. Inspect `%USERPROFILE%\.codex\token-notifier\logs\errors.log` or the
   equivalent `PLUGIN_DATA` path.
4. Run the cleanup command above; the next notification will recreate the
   application identity.

## Development

Run the complete validation suite from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\token-notifier.tests.ps1 -Case All
```

Rebuild the packaged icon after changing its drawing source:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-icon.ps1
```
