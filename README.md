# TokenNotifier

TokenNotifier is a Windows 10/11 Codex plugin that reads token usage from the
Codex rollout JSONL supplied by each Hook. It calculates cost from a local
model-pricing table and displays configurable metrics in a native Windows
Adaptive Toast after each completed or interrupted turn.

## Install From GitHub

Add the repository marketplace, then install `token-notifier` from the Codex
plugin directory:

```text
https://github.com/Lunfeng/TokenNotifier.git
```

Review and trust the plugin Hooks when Codex asks. The package registers four
Hooks: `UserPromptSubmit`, `SubagentStop`, `Stop`, and `Interrupt`.

`UserPromptSubmit` starts a byte-offset marker for the root turn.
`SubagentStop` stores that subagent's rollout usage for the root turn without
showing a separate Toast. `Stop` and `Interrupt` finish the root turn, include
its subagent usage, and show one completed or interrupted notification. These
markers and fragments are transient and are removed when the root turn is
finished.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1.
- Codex desktop app or Codex CLI with local plugin Hooks enabled.

The plugin reads only the Hook-provided rollout path. It has no resident
process, database, Node.js, Python, .NET SDK, administrator, or network
dependency.

## Rollout Usage and Pricing

At `UserPromptSubmit`, TokenNotifier records the current byte offset of the
rollout JSONL. At `Stop` or `Interrupt`, it reads the appended
`token_usage_record` entries for the current turn and its subagents, then reads
the session's rollout records to build cumulative values. The model for each
record is taken from the matching `turn_context.payload.model` entry. Records
are deduplicated by `response_id`, and no prompt, answer, reasoning, tool input,
or tool output is persisted.

Each notification title uses the Codex thread name from the local session index
(`TokenNotifier · <thread name>`), which keeps concurrent turns distinguishable.
Set `title` in the user configuration to override the generated title.

The current-turn fields are `input_tokens`, `cached_input_tokens`,
`cache_write_input_tokens`, `cache_read_tokens`, `cache_creation_tokens`,
`output_tokens`, `reasoning_output_tokens`, and `total_tokens`. The cache-read
and cache-creation names are aliases for the rollout's cached-input and
cache-write-input fields.

Session totals are exposed as `session_*_tokens` and equivalent `thread_*_tokens`
fields, including input, cached input, cache-write input, cache read, cache
creation, output, reasoning output, and total tokens. They use the latest
`thread_token_usage` snapshot for each rollout thread and sum those snapshots
once, so historical cumulative snapshots are not double-counted.

Pricing is configured in the same user configuration file. Rates are USD per
one million tokens:

```json
{
  "pricing": {
    "unit": "per_million_tokens",
    "currency": "USD",
    "models": {
      "gpt-5.6-sol": {
        "input": 1,
        "cache_read": 0.1,
        "cache_creation": 1.25,
        "output": 5
      }
    }
  }
}
```

For each record, billable ordinary input is calculated as
`max(0, input_tokens - cached_input_tokens - cache_write_input_tokens)`. The
four components are then calculated independently and summed:

```text
input_cost       = billable ordinary input * input / 1,000,000
cache_read_cost  = cached input * cache_read / 1,000,000
cache_write_cost = cache-write input * cache_creation / 1,000,000
output_cost      = output * output / 1,000,000
total_cost       = input_cost + cache_read_cost + cache_write_cost + output_cost
```

Current-turn costs are `input_cost_usd`, `output_cost_usd`,
`cache_read_cost_usd`, `cache_creation_cost_usd`, and `total_cost_usd`.
Session-wide costs use the corresponding `session_*_cost_usd` fields, including
`session_total_cost_usd` (also available as `thread_total_cost_usd`). Multiple
models and subagent records are priced independently before aggregation. If a
model has no pricing entry, the turn is marked partial: token rows still
render, cost rows render as `--`, and the Toast reports how many models are
missing a price. If no usable usage record is available, the turn is marked
unavailable: the Toast remains visible with no metric rows and identifies the
missing usage. Interrupted turns use the corresponding interrupted status.

## Toast Registration

On the first notification, TokenNotifier registers the per-user application
identity `Lunfeng.TokenNotifier`. It creates:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\TokenNotifier.lnk
HKCU\Software\Classes\AppUserModelId\Lunfeng.TokenNotifier
```

To remove only the Toast identity registration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\unregister-toast.ps1
```

The command does not remove user configuration or runtime logs.

## Configuration

Create or edit:

```text
%USERPROFILE%\.codex\token-notifier\config.json
```

The packaged defaults are in `config/default-config.json`:

```json
{
  "enabled": true,
  "toast": { "duration": "short" },
  "pricing": {
    "unit": "per_million_tokens",
    "currency": "USD",
    "models": {
      "gpt-5.6-sol": {
        "input": 1,
        "cache_read": 0.1,
        "cache_creation": 1.25,
        "output": 5
      }
    }
  },
  "items": [
    { "label": "费用", "field": "total_cost_usd", "format": "currency_usd" },
    { "label": "输入 Token", "field": "input_tokens", "format": "integer" },
    { "label": "输出 Token", "field": "output_tokens", "format": "integer" },
    { "label": "总 Token", "expression": "input_tokens + output_tokens", "format": "integer" },
    { "label": "会话总 Token", "field": "session_total_tokens", "format": "integer" },
    { "label": "会话总费用", "field": "session_total_cost_usd", "format": "currency_usd" }
  ]
}
```

Rates in the packaged file are the current default for `gpt-5.6-sol`; change
the model table to match the models and rates used by your account. A user
configuration file is loaded as the complete configuration, so copy any
packaged sections you want to keep when creating it.

Each item must define exactly one `field` or `expression`. Expressions support
numeric literals, parentheses, unary signs, `+`, `-`, `*`, `/`, comparisons,
and the `abs`, `max`, `min`, and `round` functions. Supported formats are
`text`, `integer`, `decimal`, `currency_usd`, `percent`, and `milliseconds`.
Invalid rows render as `--` and write a diagnostic without suppressing the
notification.

Existing Toast and legacy popup duration settings remain valid. Windows
controls placement, width, theme, animation, notification-center retention,
and Do Not Disturb behavior. TokenNotifier does not impose a row limit or add
actions and click handlers.

## Runtime Data

The Hooks receive `PLUGIN_ROOT` and `PLUGIN_DATA` from Codex. The package uses
`PLUGIN_ROOT` for scripts and assets and `PLUGIN_DATA` for runtime state when
provided. Otherwise data is stored under:

```text
%USERPROFILE%\.codex\token-notifier
```

`state` contains transient turn markers, subagent fragments, and the short-lived
notification handoff payload. `usage.jsonl` contains minimal rollout usage
projections and turn summaries. `errors.log` contains non-blocking collection,
configuration, registration, or Toast failures. `TOKENNOTIFIER_DATA_ROOT`,
`TOKENNOTIFIER_CONFIG_PATH`, and `TOKENNOTIFIER_NOTIFIER_COMMAND` can override
local paths or the notifier command. The former `APINOTIFIER_*` variables
remain accepted as migration aliases.

Hooks are fail-open: collection or notification failures never block Codex.

## Troubleshooting

If no Toast appears:

1. Check Windows Settings > System > Notifications > TokenNotifier.
2. Check whether Do Not Disturb is active.
3. Inspect `%USERPROFILE%\.codex\token-notifier\logs\errors.log` or the
   equivalent `PLUGIN_DATA` path.
4. Run the cleanup command above; the next notification recreates the
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
