# TokenNotifier Concurrent Session Attribution Design

**Date:** 2026-10-07

**Status:** Confirmed for implementation

## 1. Goal

Make TokenNotifier attribute CC Switch proxy usage to the correct Codex turn when
multiple tasks run concurrently, without modifying CC Switch.

The completed feature must:

- notify for both completed and interrupted root turns;
- aggregate subagent usage into the owning root turn;
- still show a notification when only partial usage data is available;
- clearly label partial or unavailable data instead of guessing;
- preserve the existing configurable metrics and Windows Toast behavior;
- never persist prompts, answers, tool output, or provider response bodies.

## 2. Confirmed Product Decisions

The following decisions are final:

1. `Interrupt` produces a notification.
2. Subagent usage is included in the root task notification.
3. Partial data still produces a notification and is visibly marked as partial.

The design favors correct incomplete data over complete-looking data attributed to
the wrong task.

## 3. Current Problem

The current collector records the maximum CC Switch `proxy_request_logs.rowid` at
`UserPromptSubmit`. At `Stop`, it selects every later Codex proxy row. If turns A
and B overlap, each turn can collect rows created by the other turn.

Neither of these CC Switch fields solves the problem:

- `proxy_request_logs.session_id` is generated per request when Codex does not send
  a supported session header or metadata field. It is not the Codex thread ID.
- the prefix of `proxy_request_logs.request_id` is scoped by application and
  provider, not by Codex thread.

Therefore `rowid`, timestamp, model, working directory, token counts, and CC Switch
`session_id` must not be used as the primary attribution key.

## 4. Correlation Model

Codex rollout JSONL contains `token_usage_record` entries with the following fields:

```json
{
  "type": "token_usage_record",
  "payload": {
    "thread_id": "01...",
    "session_id": "01...",
    "turn_id": "01...",
    "root_turn_id": "01...",
    "response_id": "resp_...",
    "usage": {
      "input_tokens": 100,
      "cached_input_tokens": 20,
      "cache_write_input_tokens": 0,
      "output_tokens": 10,
      "reasoning_output_tokens": 4,
      "total_tokens": 110
    }
  }
}
```

CC Switch 3.20.4 derives successful Codex proxy request IDs from the upstream
response ID:

```text
session:codex:<provider-id>:<response-id>
```

The exact correlation key is therefore the rollout `payload.response_id` matched
against the final colon-delimited segment of CC Switch `request_id`.

`start_rowid` remains useful only as a query lower bound. A CC Switch row belongs
to a turn only when its response ID appears in that turn's collected rollout
records.

## 5. Hook Lifecycle

The plugin registers four Hook events:

| Hook | Responsibility | User notification |
|---|---|---|
| `UserPromptSubmit` | Save root-turn marker, transcript path and byte offset, and CC Switch starting rowid | No |
| `SubagentStop` | Parse the stopped agent transcript and save a minimal usage fragment grouped by `root_turn_id` | No |
| `Stop` | Resolve root and subagent response IDs, join CC Switch rows, build summary, notify as completed | Yes |
| `Interrupt` | Resolve all usage recorded before interruption, build summary, notify as interrupted | Yes |

Hook commands must remain fail-open: collection, parsing, database, title lookup,
and Toast failures always exit with code `0` and never block Codex.

## 6. Runtime State

### 6.1 Root turn marker

`UserPromptSubmit` writes one marker per turn under `state/turns/`:

```json
{
  "session_id": "01...",
  "turn_id": "01...",
  "cwd": "D:\\work",
  "transcript_path": "C:\\Users\\...\\rollout.jsonl",
  "transcript_offset": 123456,
  "start_rowid": 4679,
  "started_at": "2026-10-07T17:30:00+08:00"
}
```

The byte offset prevents rescanning a large resumed-session transcript. If the
path is missing, the file was replaced, or the offset is outside the file, the
collector scans the available file from byte zero and still filters by turn ID.

### 6.2 Subagent fragments

`SubagentStop` reads only `token_usage_record` entries from
`agent_transcript_path`. It groups minimal records by `root_turn_id` and writes an
atomic fragment under:

```text
state/subagents/<root-turn-id>/<agent-id>.json
```

Each stored record contains only:

- `response_id`;
- `turn_id`;
- `root_turn_id`;
- numeric fields from `usage`.

It must not store any message, reasoning, tool input, tool output, or transcript
line outside the minimal usage projection.

Separate fragment files avoid write contention when multiple subagents finish at
the same time. Root completion deduplicates all records by `response_id`.

### 6.3 Cleanup

After a root `Stop` or `Interrupt` notification payload has been handed to the
detached notifier, remove that turn's marker and subagent fragment directory.
Cleanup failures are logged but do not suppress the notification.

## 7. Rollout Parsing Rules

The parser accepts a line only when all of the following are true:

1. the line is valid JSON;
2. top-level `type` equals `token_usage_record`;
3. `payload.response_id` is non-empty and matches `^[A-Za-z0-9_-]+$`;
4. `payload.turn_id` equals the requested turn, or
   `payload.root_turn_id` equals the requested root turn;
5. `payload.usage` contains numeric token fields.

Malformed, unrelated, or unknown records are ignored and counted for diagnostics.
The parser must tolerate additive fields.

OpenAI documents `session_id`, `turn_id`, and `transcript_path` as Hook inputs, but
also states that transcript format is not a stable Hook interface. Consequently,
the parser is version-tolerant and failure must produce an unavailable or partial
notification rather than time-based attribution.

## 8. CC Switch Join and Settling

At root completion:

1. collect root transcript records after the marker offset;
2. load all saved subagent fragments for the root turn;
3. deduplicate records by `response_id`;
4. query only `app_type = 'codex'`, `data_source = 'proxy'`, and
   `rowid > start_rowid`;
5. map each CC Switch row by the final `request_id` segment;
6. retain a row only when that segment exactly equals a collected response ID;
7. poll unresolved IDs until the settle timeout expires.

Defaults:

- settle timeout: `1000 ms`;
- polling interval: `100 ms`;
- one immediate database query even when timeout is `0`;
- Hook timeout: `10 seconds` for `Stop` and `Interrupt`.

`TOKENNOTIFIER_SETTLE_TIMEOUT_MS` and
`TOKENNOTIFIER_SETTLE_INTERVAL_MS` provide test and diagnostic overrides.
`CCSWITCH_SETTLE_DELAY_MS` remains accepted as a legacy timeout alias.

Rows with random UUID request IDs, error attempts created before an upstream
response ID exists, and successful responses without an ID cannot be attributed
exactly. They are never assigned by temporal proximity.

## 9. Attribution States

Every root-turn summary has one of three states:

| State | Condition | Notification behavior |
|---|---|---|
| `exact` | At least one rollout usage record exists and every response ID has one CC Switch row | Show configured metrics normally |
| `partial` | Rollout usage exists but one or more response IDs have no CC Switch row | Show rollout token totals, render cost/latency as `--`, and add a partial-data message |
| `unavailable` | No usable rollout usage record can be parsed | Show the completion/interruption reminder with a usage-unavailable message |

For `partial`, do not display a partial cost as though it were the complete turn
cost. Cost and latency fields are `null`; the evaluator renders them as `--`.

`exact` describes every billable response observed in the rollout. It does not
claim attribution for failed network attempts that ended before Codex received a
response ID; those attempts have no safe join key and are outside the summary.

The following context fields are added:

```text
thread_name
turn_outcome                 # completed | interrupted
attribution_status           # exact | partial | unavailable
matched_request_count
unmatched_request_count
```

`request_count` is the number of unique rollout response records. Existing fields
remain available and retain their names.

## 10. Token and Cost Semantics

For every unique rollout record:

- `usage.input_tokens` contributes to `input_tokens`;
- `usage.output_tokens` contributes to `output_tokens`;
- `usage.cached_input_tokens` contributes to `cache_read_tokens`;
- `usage.cache_write_input_tokens` contributes to `cache_creation_tokens`.

Rollout usage supplies token totals in both `exact` and `partial` states. This
prevents a temporarily missing CC Switch row from erasing known token usage.

CC Switch supplies:

- all cost fields;
- provider and pricing model;
- multiplier;
- first-token latency, request latency, and duration;
- HTTP status.

Those CC Switch-derived aggregates are exposed only when attribution is `exact`.

## 11. Notification Identity and Copy

The default title is:

```text
TokenNotifier · <thread-name>
```

Thread name resolution reads `~/.codex/session_index.jsonl` and matches the Hook
`session_id`. It falls back in this order:

1. leaf directory name from `cwd`;
2. first eight characters of `session_id`;
3. `TokenNotifier`.

A user-provided `config.title` still overrides the generated title.

Messages:

- exact completed turn: no status message;
- exact interrupted turn: `任务已中断。`;
- partial completed turn: `部分数据：N 个请求缺少 CCSwitch 成本信息。`;
- partial interrupted turn: `任务已中断；部分数据：N 个请求缺少 CCSwitch 成本信息。`;
- unavailable completed turn: `任务已完成；本回合用量暂不可用。`;
- unavailable interrupted turn: `任务已中断；本回合用量暂不可用。`.

The Toast remains non-interactive and continues to use Windows notification
settings, grouping, and history.

## 12. Logging and Privacy

`logs/usage.jsonl` continues to store matched `ccswitch_request` rows and one
`turn_summary` row. The summary adds outcome, attribution state, match counts, and
the Codex identifiers already stored today.

Unmatched records may log their `response_id` and numeric usage, but no transcript
text. Thread names are used for the transient Toast title and are not written to
the usage log.

`logs/errors.log` records structural diagnostics without including raw transcript
lines or Hook fields such as `last_assistant_message`.

## 13. Compatibility

- Windows 10 and Windows 11 remain supported.
- Windows PowerShell 5.1 remains the runtime.
- No new PowerShell Gallery, Node.js, Python, .NET SDK, service, or resident
  process dependency is added.
- Existing configuration remains valid.
- Existing default metric rows remain unchanged.
- Existing `APINOTIFIER_*` migration aliases remain valid.
- Package version advances from `0.2.0` to `0.3.0`.
- README no longer claims that exact attribution requires one active turn.

## 14. Failure Policy

All failures are fail-open for Codex and fail-closed for attribution:

- never block or continue a Codex turn because TokenNotifier failed;
- never attach a CC Switch row without an exact response ID match;
- never silently substitute another session's usage;
- still notify for `Stop` and `Interrupt` when notification infrastructure works;
- use `partial` or `unavailable` copy to expose degraded results.

## 15. Acceptance Criteria

1. Two interleaved root turns receive only their own request rows.
2. Identical models, providers, token counts, and working directories do not cause
   cross-attribution.
3. A subagent response is included exactly once in its root turn summary.
4. An interrupted root turn produces a notification and cleans its state.
5. A missing CC Switch row produces a partial notification with rollout token
   totals and `--` cost.
6. An unreadable or incompatible transcript produces an unavailable notification.
7. No timing-only fallback runs when exact IDs are absent.
8. Existing single-turn exact behavior, configurable items, Toast registration,
   and expression evaluation continue to pass.
9. Tests verify that prompts, answers, and tool output are absent from state and
   logs.
10. The complete PowerShell test suite passes on Windows PowerShell 5.1.

## 16. Out of Scope

- modifying CC Switch or its database schema;
- intercepting or rewriting Codex HTTP traffic;
- attributing failed pre-response network attempts exactly;
- adding Toast actions or a detail window;
- displaying a persistent usage dashboard;
- synchronizing usage across machines;
- guaranteeing compatibility with undocumented future rollout formats without a
  plugin update.
