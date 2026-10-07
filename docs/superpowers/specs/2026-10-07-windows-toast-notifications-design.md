# TokenNotifier Windows Toast Notifications Design

**Status:** Approved requirements baseline

**Date:** 2026-10-07

## Goal

Replace the custom WPF notification window with native Windows 10/11 Toast
notifications while preserving TokenNotifier's configurable data fields,
safe arithmetic expressions, formatting, collection, and logging behavior.

## Confirmed Product Decisions

- Use native Windows Adaptive Toast notifications, not a WPF window or legacy
  `NotifyIcon.ShowBalloonTip` notification.
- Submit every configured display item to Windows. TokenNotifier does not cap,
  split, summarize, or hide items; Windows may truncate content according to
  its own notification UI limits.
- Do not add a detail window.
- Do not add buttons, protocol activation, COM activation, or a custom click
  handler. Clicking a Toast is left to Windows' default behavior.
- Register TokenNotifier as its own per-user notification application with the
  stable AppUserModelID `Lunfeng.TokenNotifier`.
- Do not add a resident background process or startup entry.
- Do not add BurntToast or any other third-party runtime dependency.
- Do not persist a notification payload for later activation. The temporary
  JSON used to hand data to the detached notifier process remains allowed and
  must be deleted immediately after it is read.

## Existing Behavior That Must Remain

The `UserPromptSubmit` and `Stop` Hooks, CC Switch database queries, normalized
turn context, `usage.jsonl`, `errors.log`, and safe expression evaluator remain
unchanged except where the notification payload contract must change.

Users continue to choose display rows through `config.json`. Each row contains
exactly one `field` or `expression`, plus a label and format. The supported
fields remain:

```text
request_count
input_tokens
output_tokens
cache_read_tokens
cache_creation_tokens
input_cost_usd
output_cost_usd
cache_read_cost_usd
cache_creation_cost_usd
total_cost_usd
duration_ms_total
duration_ms_max
first_token_ms_first
model
provider_id
status_code
codex_session_id
codex_turn_id
codex_cwd
```

The safe expression language continues to support numeric literals, allowed
field identifiers, parentheses, unary `+` and `-`, arithmetic `+`, `-`, `*`,
`/`, comparisons, and `abs`, `max`, `min`, and `round`. It must not evaluate
PowerShell code, access files, launch processes, or access the network.

Supported formats remain `text`, `integer`, `decimal`, `currency_usd`,
`percent`, and `milliseconds`. A row that cannot be evaluated renders `--` and
writes a diagnostic without suppressing the Toast.

## Configuration

The packaged default changes from the WPF-oriented `popup` object to:

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

`toast.duration` accepts `short` or `long`. It is a Windows hint, not an exact
number of seconds.

Existing user configuration remains compatible:

- A missing `toast` object defaults to `short`.
- When `toast.duration` is absent, a legacy `popup.auto_close_seconds` value of
  10 or more maps to `long`; all other legacy values map to `short`.
- Legacy `popup.position`, `popup.max_visible`, and `popup.always_on_top` are
  ignored because Windows controls Toast placement and presentation.
- The stable AUMID is not user-configurable.

## Toast Presentation

Each notification uses the `ToastGeneric` adaptive binding:

- The payload title is the first text element.
- Each configured item becomes one adaptive `group` with a label subgroup and
  a right-aligned value subgroup. One group per item keeps each label/value
  pair together if Windows wraps text.
- An error or diagnostic message is appended as body text after the item rows.
- All XML nodes and attributes are created through XML APIs so labels, values,
  and messages containing `<`, `>`, `&`, quotes, or non-ASCII text are escaped
  correctly.
- The Toast has no `actions` element and no activation arguments.
- TokenNotifier does not batch rows and does not apply a maximum row count.

Windows owns the rendered width, maximum height, wrapping, truncation,
placement, animation, display time, notification-center retention, theme, and
Do Not Disturb behavior. Pixel equivalence with the WPF window is explicitly
not required.

## Application Identity Registration

Before submitting the first Toast, the notifier idempotently ensures a
per-user registration with these exact values:

```text
AppUserModelID: Lunfeng.TokenNotifier
Shortcut:       %APPDATA%\Microsoft\Windows\Start Menu\Programs\TokenNotifier.lnk
Registry key:   HKCU\Software\Classes\AppUserModelId\Lunfeng.TokenNotifier
Display name:   TokenNotifier
Icon:           <plugin-root>\assets\token-notifier.ico
```

The shortcut targets Windows PowerShell with `-NoProfile`, `-WindowStyle
Hidden`, `-STA`, `-ExecutionPolicy Bypass`, and the absolute path to
`scripts\notifier.ps1`. Starting it without a payload performs no action and
exits successfully.

Registration is current-user only and requires no elevation. It does not
create a service, startup entry, scheduled task, protocol handler, COM
activator, or resident process. The notifier sets its current process AUMID to
the same value before calling the Toast API.

Registration is repaired when the shortcut is missing or points to a previous
plugin location. A separate unregistration script removes only the exact
TokenNotifier shortcut and AppUserModelID registry key. It does not remove
configuration, usage logs, or error logs.

## Runtime Flow

```text
Stop Hook
  -> collect CC Switch rows
  -> normalize and evaluate configured items
  -> persist existing usage logs
  -> write one temporary notification JSON file
  -> launch hidden STA PowerShell notifier
  -> notifier reads and deletes the temporary JSON
  -> ensure TokenNotifier per-user Toast registration
  -> build adaptive Toast XML with every configured item
  -> submit Toast as Lunfeng.TokenNotifier
  -> notifier exits
```

The Hook remains non-blocking. Registration and Toast failures are appended to
the existing `errors.log`; they never cause a nonzero Hook exit and do not
fall back to WPF.

## Privacy And Persistence

Toast content includes only the configured labels and formatted values plus a
short collection/configuration error message when applicable. Prompt text,
answer text, API keys, provider response bodies, and raw request payloads are
never included.

TokenNotifier does not create a notification-history JSON store. Windows may
retain the rendered Toast in Notification Center according to the user's
system settings. Existing `usage.jsonl` persistence remains independent of
Toast delivery.

## Compatibility

- Windows 10 and Windows 11 only.
- Windows PowerShell 5.1 is the baseline runtime.
- No Node.js, Python, .NET SDK, PowerShell Gallery module, packaged app, or
  administrator privilege is required.
- The Toast implementation uses Windows Runtime APIs shipped with Windows and
  a small in-process interop helper for AppUserModelID/shortcut properties.

## Out Of Scope

- Detail windows or notification history UI.
- Toast buttons or click handling.
- Copy actions, protocol handlers, or COM activation.
- User-configurable Toast position, dimensions, colors, fonts, or exact
  timeout.
- Plugin-side row limits, pagination, batching, or overflow summaries.
- A tray icon or resident notification host.
- Changes to turn attribution or CC Switch data collection.

## Acceptance Criteria

1. A completed Codex answer submits one native Windows Toast and no WPF window.
2. The Toast is attributed to `TokenNotifier`, uses the TokenNotifier icon, and
   appears as an independent application in Windows notification settings.
3. Every configured item is emitted into the adaptive Toast XML in config
   order, with no TokenNotifier-imposed maximum.
4. Existing field selection, expressions, formats, `--` failures, and
   diagnostics behave as before.
5. Labels and values containing XML-special characters or Chinese text render
   without malformed XML or mojibake.
6. The Toast contains no action buttons, activation arguments, or plugin click
   handler.
7. `toast.duration` accepts only `short` or `long`; missing and legacy config
   values migrate as specified above.
8. The temporary payload file is removed immediately after reading, and no
   detail/history payload is persisted.
9. Registration is per-user, idempotent, repairs a stale shortcut target, and
   requires no administrator privilege.
10. Registration or Toast failures are logged and never block the Codex Hook.
11. Existing usage logging and privacy guarantees continue to pass automated
    tests.
12. The feature passes automated PowerShell tests plus a manual Windows 10/11
    Toast smoke test.
