# TokenNotifier

TokenNotifier is a Windows 10/11 Codex plugin that reads CC Switch usage
records after each completed answer and shows configurable token, cost, latency,
and calculated metrics in a non-modal notification.

## Install from GitHub

Add the repository marketplace, then install `token-notifier` from the Codex
plugin directory:

```text
https://github.com/Lunfeng/TokenNotifier.git
```

Review and trust the plugin Hooks when Codex asks. The package registers
`UserPromptSubmit` and `Stop`.

## Requirements

- Windows 10 or Windows 11.
- Codex desktop app or Codex CLI with local plugin Hooks enabled.
- CC Switch routing enabled and its usage database readable.
- `sqlite3.exe` available on `PATH`.
- One active Codex turn at a time when exact per-turn attribution matters.

The Hooks receive `PLUGIN_ROOT` and `PLUGIN_DATA` from Codex. The package uses
`PLUGIN_ROOT` to resolve its PowerShell scripts and `PLUGIN_DATA` for runtime
state when that directory is provided. Exact attribution is intentionally
single-turn; concurrent turns are not merged safely by this first release.

## Configuration

Create or edit:

```text
%USERPROFILE%\.codex\token-notifier\config.json
```

The packaged defaults are in `config/default-config.json`. Configure the
visible rows with a field or a safe arithmetic expression, for example:

```json
{
  "enabled": true,
  "popup": {
    "position": "bottom-right",
    "auto_close_seconds": 8,
    "max_visible": 3,
    "always_on_top": true
  },
  "items": [
    { "label": "Cost", "field": "total_cost_usd", "format": "currency_usd" },
    { "label": "Input", "field": "input_tokens", "format": "integer" },
    { "label": "Output", "field": "output_tokens", "format": "integer" },
    { "label": "Total", "expression": "input_tokens + output_tokens", "format": "integer" }
  ]
}
```

Runtime state and `usage.jsonl` are stored under `PLUGIN_DATA` when supplied by
Codex, otherwise under `%USERPROFILE%\.codex\token-notifier`. The plugin does
not persist prompt text, answer text, API keys, or provider response bodies.
Collection and configuration failures are written to `errors.log` in the same
runtime data directory.

If an older project-local Hook still invokes ApiNotifier, disable that old
project Hook before installing this package so each event is handled once.

`TOKENNOTIFIER_DATA_ROOT`, `TOKENNOTIFIER_CONFIG_PATH`, and
`TOKENNOTIFIER_NOTIFIER_COMMAND` can override local paths or the notifier
command. The former `APINOTIFIER_*` variables remain accepted as migration
aliases.

## Development

The plugin package root is this directory. Run the parent project's validation
suite before publishing a release:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ..\..\tests\apinotifier.tests.ps1 -Case All
```

Create a version tag whenever package files change, for example `v0.1.1`.
