# Concurrent Session Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute each CC Switch request to the correct concurrent Codex root turn, aggregate subagent usage, and notify on both completion and interruption with explicit partial-data handling.

**Architecture:** Parse minimal `token_usage_record` projections from Codex rollout JSONL, use their `response_id` values as exact join keys for CC Switch proxy rows, and retain `start_rowid` only as a query bound. Store one root-turn marker and contention-free subagent fragments, then build exact, partial, or unavailable summaries at `Stop` or `Interrupt`.

**Tech Stack:** Windows PowerShell 5.1, Codex command Hooks, JSONL, SQLite through `sqlite3.exe`, Windows Adaptive Toast.

**Spec:** `docs/superpowers/specs/2026-10-07-concurrent-session-attribution-design.md`

## Global Constraints

- Do not modify CC Switch or its database schema.
- Continue to support Windows 10/11 and Windows PowerShell 5.1.
- Add no PowerShell Gallery, Node.js, Python, .NET SDK, service, or resident-process dependency.
- `Stop` and `Interrupt` must notify; `SubagentStop` must aggregate without notifying.
- Missing correlation data must never trigger timing-only attribution.
- Partial and unavailable data must still notify and must be visibly marked.
- Prompt text, answer text, reasoning, tool input, tool output, and raw transcript lines must not be persisted.
- Every Hook path must exit `0` even when collection fails.
- Existing configuration and existing default metric rows remain valid.
- Package version becomes `0.3.0`.

---

## File Structure

- Create `scripts/attribution.ps1`: rollout parsing, response-ID projection, subagent fragment persistence, exact row selection, thread-name lookup, and status-message helpers.
- Modify `scripts/collector.ps1`: Hook orchestration, marker schema, CC Switch polling, summary construction, logging, notification dispatch, and cleanup.
- Modify `scripts/evaluator.ps1`: expose the new attribution and outcome fields to configured rows.
- Modify `hooks/hooks.json`: add `SubagentStop` and `Interrupt` command Hooks.
- Modify `tests/token-notifier.tests.ps1`: add pure attribution tests and concurrent integration fixtures.
- Modify `.codex-plugin/plugin.json`: bump package version to `0.3.0`.
- Modify `README.md`: document concurrent attribution, degradation behavior, new Hooks, runtime state, and overrides.

### Task 1: Rollout Usage Parser and Incremental Root Marker

**Files:**
- Create: `scripts/attribution.ps1`
- Modify: `scripts/collector.ps1:1-84`
- Modify: `tests/token-notifier.tests.ps1:1-30`
- Test: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Produces: `Get-TranscriptLength([string]$Path) -> [int64]`.
- Produces: `Read-TurnUsageRecords([string]$Path, [string]$RootTurnId, [int64]$StartOffset) -> [object[]]`.
- Produces: each usage record with `response_id`, `turn_id`, `root_turn_id`, `input_tokens`, `output_tokens`, `cache_read_tokens`, and `cache_creation_tokens`.
- Updates: `Start-Turn([object]$Payload)` marker with `transcript_path` and `transcript_offset`.

- [ ] **Step 1: Add an Attribution test case and parser fixtures**

Extend the test runner validation set:

```powershell
param(
    [ValidateSet('All', 'Package', 'Config', 'Evaluator', 'ToastXml', 'Registration', 'Attribution', 'Collector')]
    [string]$Case = 'All'
)
```

Add `Test-Attribution` with three JSONL records: one for root turn `turn-a`, one
whose `root_turn_id` is `turn-a`, and one unrelated record. Include a malformed
line and a message containing `secret prompt` to prove that only usage projections
are returned.

```powershell
function Test-Attribution {
    . (Join-Path $repoRoot 'scripts\attribution.ps1')
    $testRoot = Join-Path $env:TEMP ('token-notifier-attribution-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $testRoot | Out-Null
    try {
        $transcript = Join-Path $testRoot 'rollout.jsonl'
        $prefix = '{"type":"response_item","payload":{"type":"message","content":"secret prompt"}}' + [Environment]::NewLine
        [IO.File]::WriteAllText($transcript, $prefix, [Text.UTF8Encoding]::new($false))
        $offset = [IO.FileInfo]::new($transcript).Length
        $records = @(
            [ordered]@{type='token_usage_record';payload=[ordered]@{turn_id='turn-a';root_turn_id='turn-a';response_id='resp_root';usage=[ordered]@{input_tokens=10;output_tokens=2;cached_input_tokens=3;cache_write_input_tokens=1}}},
            [ordered]@{type='token_usage_record';payload=[ordered]@{turn_id='turn-child';root_turn_id='turn-a';response_id='resp_child';usage=[ordered]@{input_tokens=20;output_tokens=4;cached_input_tokens=5;cache_write_input_tokens=0}}},
            [ordered]@{type='token_usage_record';payload=[ordered]@{turn_id='turn-b';root_turn_id='turn-b';response_id='resp_other';usage=[ordered]@{input_tokens=30;output_tokens=6;cached_input_tokens=0;cache_write_input_tokens=0}}}
        )
        foreach ($record in $records) {
            [IO.File]::AppendAllText($transcript, (($record | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::AppendAllText($transcript, "not-json`r`n", [Text.UTF8Encoding]::new($false))
        $actual = @(Read-TurnUsageRecords $transcript 'turn-a' $offset)
        Assert-Equal 2 $actual.Count 'Root and child usage must be selected'
        Assert-Equal 'resp_root' $actual[0].response_id 'Root response id must survive projection'
        Assert-Equal 'resp_child' $actual[1].response_id 'Child response id must survive projection'
        Assert-Equal 30 (($actual | Measure-Object input_tokens -Sum).Sum) 'Projected input tokens must sum'
        Assert-True (-not (($actual | ConvertTo-Json -Depth 6) -match 'secret prompt')) 'Message text must not enter projections'
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```

Register it before the Collector case:

```powershell
if ($Case -in @('All', 'Attribution')) { Test-Attribution; Write-Output 'PASS: Attribution' }
```

- [ ] **Step 2: Run the new test and verify the missing script failure**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Attribution
```

Expected: FAIL because `scripts\attribution.ps1` does not exist.

- [ ] **Step 3: Implement the minimal rollout parser**

Create `scripts/attribution.ps1` with strict projection and tolerant line parsing:

```powershell
$ErrorActionPreference = 'Stop'

function Get-TranscriptLength([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [int64]0 }
    return [int64](Get-Item -LiteralPath $Path).Length
}

function ConvertTo-UsageProjection([object]$Value, [string]$RootTurnId) {
    if ($null -eq $Value -or [string]$Value.type -ne 'token_usage_record') { return $null }
    $payload = $Value.payload
    if ($null -eq $payload) { return $null }
    if ([string]$payload.turn_id -ne $RootTurnId -and [string]$payload.root_turn_id -ne $RootTurnId) { return $null }
    $responseId = [string]$payload.response_id
    if ($responseId -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    $usage = $payload.usage
    if ($null -eq $usage) { return $null }
    return [pscustomobject]@{
        response_id = $responseId
        turn_id = [string]$payload.turn_id
        root_turn_id = [string]$payload.root_turn_id
        input_tokens = [int64]$usage.input_tokens
        output_tokens = [int64]$usage.output_tokens
        cache_read_tokens = [int64]$usage.cached_input_tokens
        cache_creation_tokens = [int64]$usage.cache_write_input_tokens
    }
}

function Read-TurnUsageRecords([string]$Path, [string]$RootTurnId, [int64]$StartOffset = 0) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($StartOffset -lt 0 -or $StartOffset -gt $stream.Length) { $StartOffset = 0 }
        [void]$stream.Seek($StartOffset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.IndexOf('"token_usage_record"', [StringComparison]::Ordinal) -lt 0) { continue }
                try { $value = $line | ConvertFrom-Json } catch { continue }
                $projection = ConvertTo-UsageProjection $value $RootTurnId
                if ($null -ne $projection) { Write-Output $projection }
            }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
```

Dot-source the file near the top of `collector.ps1`:

```powershell
. (Join-Path $PSScriptRoot 'evaluator.ps1')
. (Join-Path $PSScriptRoot 'attribution.ps1')
```

Add these marker properties in `Start-Turn`:

```powershell
transcript_path = [string]$Payload.transcript_path
transcript_offset = Get-TranscriptLength ([string]$Payload.transcript_path)
```

Move marker files into a dedicated directory so root markers and subagent
fragments cannot collide:

```powershell
function Get-MarkerPath([string]$TurnId) {
    $turnRoot = Join-Path $stateRoot 'turns'
    return Join-Path $turnRoot (($TurnId -replace '[^A-Za-z0-9._-]', '_') + '.json')
}
```

`Start-Turn` must create `Split-Path -Parent (Get-MarkerPath $Payload.turn_id)`
before writing. Update the existing cleanup assertion to check
`state\turns\t.json`.

- [ ] **Step 4: Run parser and existing tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Attribution
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: both cases PASS.

- [ ] **Step 5: Commit the parser and marker contract**

```powershell
git add scripts/attribution.ps1 scripts/collector.ps1 tests/token-notifier.tests.ps1
git commit -m "feat: parse per-turn rollout usage"
```

### Task 2: Exact CC Switch Join and Conservative Summary

**Files:**
- Modify: `scripts/attribution.ps1`
- Modify: `scripts/collector.ps1:158-189`
- Modify: `scripts/evaluator.ps1:1-9`
- Modify: `tests/token-notifier.tests.ps1:158-231`
- Test: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Consumes: projected usage records from Task 1.
- Produces: `Get-ResponseIdFromRequestId([string]$RequestId) -> [string|null]`.
- Produces: `Select-AttributedRows([object[]]$Rows, [object[]]$UsageRecords) -> [object[]]`.
- Produces: `Wait-AttributedRows([object[]]$UsageRecords, [int64]$StartRowId) -> [object[]]`.
- Produces: `Build-AttributedTurnContext([object[]]$UsageRecords, [object[]]$Rows, [object]$Marker, [string]$Outcome) -> [pscustomobject]`.

- [ ] **Step 1: Replace the Collector fixture with interleaved response IDs**

Create two transcript files and two turn markers with the same starting database
row. Insert rows in this order:

```sql
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES
('session:codex:p:resp_a1','p','codex','m','m','m',100,10,5,0,'0.01','0.02','0.001','0','0.031',100,20,300,200,2,'proxy'),
('session:codex:p:resp_b1','p','codex','m','m','m',900,90,50,0,'0.09','0.18','0.01','0','0.28',200,30,500,200,3,'proxy'),
('session:codex:p:resp_a2','p','codex','m','m','m',200,20,10,0,'0.02','0.04','0.002','0','0.062',110,21,310,200,4,'proxy');
```

Transcript A contains `resp_a1` and `resp_a2`; transcript B contains `resp_b1`.
Run Stop A first and assert `request_count = 2`, `input_tokens = 300`, and
`total_cost_usd = 0.093`. Run Stop B and assert its independent totals. Assert
that neither turn's usage log contains the other response ID.

- [ ] **Step 2: Run the concurrent fixture and verify it exposes rowid-window contamination**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: FAIL because each current Stop selects every row after `start_rowid`.

- [ ] **Step 3: Add exact response-ID selection**

Append these pure helpers to `attribution.ps1`:

```powershell
function Get-ResponseIdFromRequestId([string]$RequestId) {
    if ($RequestId -match ':(resp_[A-Za-z0-9_-]+)$') { return [string]$Matches[1] }
    return $null
}

function Select-AttributedRows([object[]]$Rows, [object[]]$UsageRecords) {
    $wanted = @{}
    foreach ($record in @($UsageRecords)) { $wanted[[string]$record.response_id] = $true }
    foreach ($row in @($Rows)) {
        $responseId = Get-ResponseIdFromRequestId ([string]$row.request_id)
        if ($null -ne $responseId -and $wanted.ContainsKey($responseId)) {
            $row | Add-Member -NotePropertyName attribution_response_id -NotePropertyValue $responseId -Force
            Write-Output $row
        }
    }
}

function Select-UniqueUsageRecords([object[]]$UsageRecords) {
    $seen = @{}
    foreach ($record in @($UsageRecords)) {
        $id = [string]$record.response_id
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; Write-Output $record }
    }
}
```

Add a pure token aggregation helper used by the new context builder:

```powershell
function Measure-ProjectedTokens([object[]]$UsageRecords) {
    $result = [ordered]@{ input_tokens=[int64]0; output_tokens=[int64]0; cache_read_tokens=[int64]0; cache_creation_tokens=[int64]0 }
    foreach ($record in @($UsageRecords)) {
        foreach ($name in @('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens')) {
            $result[$name] = [int64]$result[$name] + [int64]$record.$name
        }
    }
    return [pscustomobject]$result
}
```

- [ ] **Step 4: Poll only the bounded candidate row set**

Replace the fixed settle sleep and unfiltered return with `Wait-AttributedRows` in
`collector.ps1`. Query the existing columns and `rowid > start_rowid`, then select
only exact IDs:

```powershell
function Wait-AttributedRows([object[]]$UsageRecords, [int64]$StartRowId) {
    $timeout = if ($env:TOKENNOTIFIER_SETTLE_TIMEOUT_MS) { [int]$env:TOKENNOTIFIER_SETTLE_TIMEOUT_MS } elseif ($env:CCSWITCH_SETTLE_DELAY_MS) { [int]$env:CCSWITCH_SETTLE_DELAY_MS } else { 1000 }
    $interval = if ($env:TOKENNOTIFIER_SETTLE_INTERVAL_MS) { [int]$env:TOKENNOTIFIER_SETTLE_INTERVAL_MS } else { 100 }
    $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $timeout))
    do {
        $sql = "SELECT rowid,request_id,provider_id,provider_type,model,request_model,pricing_model,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,cache_creation_cost_usd,total_cost_usd,cost_multiplier,latency_ms,first_token_ms,duration_ms,status_code,error_message,session_id,is_streaming,created_at,data_source FROM proxy_request_logs WHERE rowid > $StartRowId AND app_type = 'codex' AND data_source = 'proxy' ORDER BY rowid;"
        $rows = @(Get-ReadOnlySqlRows $sql)
        $matched = @(Select-AttributedRows $rows $UsageRecords)
        if ($matched.Count -ge @($UsageRecords).Count -or [DateTime]::UtcNow -ge $deadline) { return $matched }
        Start-Sleep -Milliseconds ([Math]::Max(1, $interval))
    } while ($true)
}
```

- [ ] **Step 5: Build exact, partial, and unavailable contexts**

Replace `Build-TurnContext` with `Build-AttributedTurnContext`. Sum tokens from
rollout projections. Build a response-ID map for matched rows. Set:

```powershell
$requestCount = @($UsageRecords).Count
$matchedCount = @($Rows).Count
$unmatchedCount = [Math]::Max(0, $requestCount - $matchedCount)
$attributionStatus = if ($requestCount -eq 0) { 'unavailable' } elseif ($unmatchedCount -gt 0) { 'partial' } else { 'exact' }
```

For `partial` and `unavailable`, assign `$null` to cost and latency fields. For
`exact`, reuse invariant-culture decimal summation over matched CC Switch rows.
Always include:

```powershell
turn_outcome = $Outcome
attribution_status = $attributionStatus
matched_request_count = $matchedCount
unmatched_request_count = $unmatchedCount
```

The context builder must take token totals from `Measure-ProjectedTokens`, not
from CC Switch rows:

```powershell
$tokens = Measure-ProjectedTokens $UsageRecords
$context = [ordered]@{
    request_count = $requestCount
    matched_request_count = $matchedCount
    unmatched_request_count = $unmatchedCount
    input_tokens = $tokens.input_tokens
    output_tokens = $tokens.output_tokens
    cache_read_tokens = $tokens.cache_read_tokens
    cache_creation_tokens = $tokens.cache_creation_tokens
    turn_outcome = $Outcome
    attribution_status = $attributionStatus
    codex_session_id = [string]$Marker.session_id
    codex_turn_id = [string]$Marker.turn_id
    codex_cwd = [string]$Marker.cwd
}
```

Append the existing model/provider/status and decimal cost aggregates only for
`exact`. For other states, append those fields with `$null`; this guarantees the
existing evaluator emits `--` instead of a deceptively low partial cost.

Add these fields to `$script:AllowedEvaluatorFields` in `evaluator.ps1`:

```powershell
'turn_outcome', 'attribution_status', 'matched_request_count',
'unmatched_request_count', 'thread_name'
```

- [ ] **Step 6: Run exact and partial integration tests**

Add a fixture where the transcript contains `resp_present` and `resp_missing`, but
the database contains only `resp_present`. Assert:

- `attribution_status` is `partial`;
- `request_count` is `2`;
- `matched_request_count` and `unmatched_request_count` are both `1`;
- token totals include both rollout records;
- the configured cost row renders `--`.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Evaluator
```

Expected: both cases PASS.

- [ ] **Step 7: Commit exact attribution**

```powershell
git add scripts/attribution.ps1 scripts/collector.ps1 scripts/evaluator.ps1 tests/token-notifier.tests.ps1
git commit -m "feat: correlate usage by response id"
```

### Task 3: Subagent Aggregation and Interrupt Lifecycle

**Files:**
- Modify: `hooks/hooks.json`
- Modify: `scripts/attribution.ps1`
- Modify: `scripts/collector.ps1`
- Modify: `tests/token-notifier.tests.ps1`
- Test: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Produces: `Save-SubagentUsage([object]$Payload)`.
- Produces: `Read-SubagentUsage([string]$RootTurnId) -> [object[]]`.
- Produces: `Complete-Turn([object]$Payload, [string]$Outcome)`.
- Dispatches: `Stop -> Complete-Turn payload 'completed'`.
- Dispatches: `Interrupt -> Complete-Turn payload 'interrupted'`.

- [ ] **Step 1: Add Hook contract tests**

In `Test-Package`, assert one matcher group for each event and equal collector
commands:

```powershell
$hooks = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'hooks\hooks.json') | ConvertFrom-Json
Assert-Equal 1 @($hooks.hooks.SubagentStop).Count 'SubagentStop Hook must exist'
Assert-Equal 1 @($hooks.hooks.Interrupt).Count 'Interrupt Hook must exist'
Assert-Equal 10 ([int]$hooks.hooks.Interrupt[0].hooks[0].timeout) 'Interrupt Hook needs collection time'
```

Add an integration fixture that sends `SubagentStop` with an agent transcript
containing `resp_child` and `root_turn_id = root-turn`, then sends parent `Stop`
whose transcript contains `resp_root`. Assert both requests are included once.

Add an `Interrupt` fixture and assert that it writes `turn_outcome = interrupted`,
captures completed response IDs, invokes the notifier, and removes turn state.

- [ ] **Step 2: Run Package and Collector tests to verify missing Hooks**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Package
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: FAIL because the events and fragment handling are absent.

- [ ] **Step 3: Register SubagentStop and Interrupt**

Add matcher groups using the same command as existing Hooks:

```json
"SubagentStop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command \"& (Join-Path $env:PLUGIN_ROOT 'scripts\\collector.ps1')\"",
        "commandWindows": "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command \"& (Join-Path $env:PLUGIN_ROOT 'scripts\\collector.ps1')\"",
        "timeout": 5
      }
    ]
  }
],
"Interrupt": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command \"& (Join-Path $env:PLUGIN_ROOT 'scripts\\collector.ps1')\"",
        "commandWindows": "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command \"& (Join-Path $env:PLUGIN_ROOT 'scripts\\collector.ps1')\"",
        "timeout": 10
      }
    ]
  }
]
```

- [ ] **Step 4: Persist contention-free subagent fragments**

Implement `Save-SubagentUsage` in `collector.ps1`. Read the full stopped agent
transcript, group projections by `root_turn_id`, and atomically write one file per
agent and root turn:

```powershell
function Save-SubagentUsage([object]$Payload) {
    $agentPath = [string]$Payload.agent_transcript_path
    $records = @(Read-AllUsageRecords $agentPath)
    foreach ($group in @($records | Group-Object root_turn_id)) {
        if ([string]::IsNullOrWhiteSpace([string]$group.Name)) { continue }
        $directory = Join-Path (Join-Path $stateRoot 'subagents') (($group.Name -replace '[^A-Za-z0-9._-]', '_'))
        New-Item -ItemType Directory -Force $directory | Out-Null
        $agentId = if ([string]::IsNullOrWhiteSpace([string]$Payload.agent_id)) { [guid]::NewGuid().ToString('N') } else { ([string]$Payload.agent_id -replace '[^A-Za-z0-9._-]', '_') }
        $path = Join-Path $directory ($agentId + '.json')
        $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temporary, (@($group.Group) | ConvertTo-Json -Compress -Depth 6), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
}
```

Add `Read-AllUsageRecords` to `attribution.ps1`; it uses the same validation as
`Read-TurnUsageRecords` but accepts every non-empty `root_turn_id` so fragments can
be grouped safely.

Implement it as a projection-only reader, without returning raw JSON objects:

```powershell
function Read-AllUsageRecords([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::UTF8)) {
        if ($line.IndexOf('"token_usage_record"', [StringComparison]::Ordinal) -lt 0) { continue }
        try { $value = $line | ConvertFrom-Json } catch { continue }
        if ([string]$value.type -ne 'token_usage_record') { continue }
        $rootTurnId = [string]$value.payload.root_turn_id
        if ([string]::IsNullOrWhiteSpace($rootTurnId)) { continue }
        $projection = ConvertTo-UsageProjection $value $rootTurnId
        if ($null -ne $projection) { Write-Output $projection }
    }
}
```

- [ ] **Step 5: Merge and clean subagent records at root completion**

Implement `Read-SubagentUsage` by reading `state/subagents/<root-turn-id>/*.json`,
then pass root and child records through `Select-UniqueUsageRecords`. After handing
the notification to `Invoke-DetachedNotifier`, remove only:

```text
state/turns/<turn-id>.json
state/subagents/<turn-id>/
```

Use `-LiteralPath` for cleanup and log cleanup errors without changing Hook exit
status.

If a root marker is missing, `Complete-Turn` must not throw. Construct this
in-memory fallback marker, scan the supplied transcript from byte zero, and use
exact response-ID filtering without a rowid optimization:

```powershell
$marker = [pscustomobject]@{
    session_id = [string]$Payload.session_id
    turn_id = [string]$Payload.turn_id
    cwd = [string]$Payload.cwd
    transcript_path = [string]$Payload.transcript_path
    transcript_offset = [int64]0
    start_rowid = [int64]0
    started_at = [DateTimeOffset]::Now.ToString('o')
}
```

- [ ] **Step 6: Dispatch all four Hook events**

Use this bottom-level dispatch:

```powershell
switch ([string]$payload.hook_event_name) {
    'UserPromptSubmit' { Start-Turn $payload }
    'SubagentStop' { Save-SubagentUsage $payload }
    'Stop' { Complete-Turn $payload 'completed' }
    'Interrupt' { Complete-Turn $payload 'interrupted' }
}
```

- [ ] **Step 7: Run lifecycle tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Package
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Attribution
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: all three cases PASS.

- [ ] **Step 8: Commit lifecycle support**

```powershell
git add hooks/hooks.json scripts/attribution.ps1 scripts/collector.ps1 tests/token-notifier.tests.ps1
git commit -m "feat: aggregate interrupted and subagent usage"
```

### Task 4: Session-Aware Titles and Degraded Notification Copy

**Files:**
- Modify: `scripts/attribution.ps1`
- Modify: `scripts/collector.ps1`
- Modify: `tests/token-notifier.tests.ps1`
- Test: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Produces: `Get-ThreadDisplayName([string]$SessionId, [string]$Cwd, [string]$IndexPath) -> [string]`.
- Produces: `Get-AttributionMessage([string]$Outcome, [string]$Status, [int]$UnmatchedCount) -> [string]`.
- Consumes: `thread_name`, `turn_outcome`, `attribution_status`, and `unmatched_request_count` from Task 2.

- [ ] **Step 1: Add title and copy tests**

Write a temporary session index containing two JSONL entries. Assert exact ID
selection, directory fallback, and short-ID fallback. Add the six message assertions
from the design spec, including:

```powershell
Assert-Equal '任务已中断。' (Get-AttributionMessage 'interrupted' 'exact' 0) 'Interrupted exact copy must be explicit'
Assert-Equal '部分数据：2 个请求缺少 CCSwitch 成本信息。' (Get-AttributionMessage 'completed' 'partial' 2) 'Partial copy must include the count'
Assert-Equal '任务已中断；本回合用量暂不可用。' (Get-AttributionMessage 'interrupted' 'unavailable' 0) 'Unavailable interrupt copy must be explicit'
```

In the Collector integration fixture, assert the default title is
`TokenNotifier · Concurrent task A`, while a configured title still wins.

- [ ] **Step 2: Run tests and verify the helpers are missing**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Attribution
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: FAIL because title and message helpers do not exist.

- [ ] **Step 3: Implement local thread-name lookup**

Add to `attribution.ps1`:

```powershell
function Get-ThreadDisplayName([string]$SessionId, [string]$Cwd, [string]$IndexPath) {
    if ([string]::IsNullOrWhiteSpace($IndexPath)) { $IndexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl' }
    if (Test-Path -LiteralPath $IndexPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($IndexPath, [Text.Encoding]::UTF8)) {
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            if ([string]$entry.id -eq $SessionId -and -not [string]::IsNullOrWhiteSpace([string]$entry.thread_name)) { return [string]$entry.thread_name }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $leaf = Split-Path -Leaf $Cwd.TrimEnd('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { return $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)) }
    return 'TokenNotifier'
}
```

- [ ] **Step 4: Implement status copy and payload fields**

Add `Get-AttributionMessage` as a closed switch over the design's exact strings.
Set the default title in `Invoke-UsageNotification` to
`TokenNotifier + [char]0x00B7 + thread_name`. Set the existing payload `message`
property to the status copy. Do not modify `notifier.ps1`; it already safely renders
an optional message below configured rows.

Use this implementation so copy does not drift from the specification:

```powershell
function Get-AttributionMessage([string]$Outcome, [string]$Status, [int]$UnmatchedCount) {
    if ($Status -eq 'unavailable') {
        if ($Outcome -eq 'interrupted') { return '任务已中断；本回合用量暂不可用。' }
        return '任务已完成；本回合用量暂不可用。'
    }
    if ($Status -eq 'partial') {
        $partial = '部分数据：' + $UnmatchedCount + ' 个请求缺少 CCSwitch 成本信息。'
        if ($Outcome -eq 'interrupted') { return '任务已中断；' + $partial }
        return $partial
    }
    if ($Outcome -eq 'interrupted') { return '任务已中断。' }
    return ''
}
```

When status is `unavailable`, invoke the usage notification with no configured
metric rows and the unavailable message. Do not emit a collector error Toast for a
valid Hook whose transcript merely lacks usable usage records.

- [ ] **Step 5: Verify Toast XML and integration output**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case ToastXml
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Attribution
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: all three cases PASS, and existing configured item order remains
unchanged for exact notifications.

- [ ] **Step 6: Commit session-aware notification behavior**

```powershell
git add scripts/attribution.ps1 scripts/collector.ps1 tests/token-notifier.tests.ps1
git commit -m "feat: label concurrent task notifications"
```

### Task 5: Logging, Privacy, Package Metadata, and Documentation

**Files:**
- Modify: `scripts/collector.ps1`
- Modify: `tests/token-notifier.tests.ps1`
- Modify: `.codex-plugin/plugin.json`
- Modify: `README.md`
- Test: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Persists: matched `ccswitch_request` records and one enriched `turn_summary`.
- Documents: exact/partial/unavailable semantics and environment overrides.

- [ ] **Step 1: Add persistence and documentation assertions**

Extend Collector tests to assert that `turn_summary` contains:

```text
turn_outcome
attribution_status
matched_request_count
unmatched_request_count
```

Place `secret prompt`, `secret answer`, and `secret tool output` in transcript and
Hook fixtures. Assert that none appears in `state`, `usage.jsonl`, or `errors.log`.

Update `Test-Package` to assert version `0.3.0`, README mentions concurrent turns,
and README no longer contains `One active Codex turn at a time`.

- [ ] **Step 2: Run Package and Collector tests and verify metadata failures**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Package
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: FAIL until metadata, logs, and README are updated.

- [ ] **Step 3: Enrich summary logs without storing thread names**

Add the four attribution fields to the existing `turn_summary` object. For every
rollout record without a matched CC Switch row, append this minimal record:

```powershell
[ordered]@{
    type = 'unmatched_request'
    logged_at = [DateTimeOffset]::Now.ToString('o')
    codex_session_id = [string]$Marker.session_id
    codex_turn_id = [string]$Marker.turn_id
    response_id = [string]$record.response_id
    input_tokens = [int64]$record.input_tokens
    output_tokens = [int64]$record.output_tokens
    cache_read_tokens = [int64]$record.cache_read_tokens
    cache_creation_tokens = [int64]$record.cache_creation_tokens
}
```

Do not add `thread_name`, transcript paths, raw lines, or any Hook message fields to
the usage log.

- [ ] **Step 4: Update package metadata and README**

Set `.codex-plugin/plugin.json` version to `0.3.0`.

In README:

- list `UserPromptSubmit`, `SubagentStop`, `Stop`, and `Interrupt` Hooks;
- replace the one-active-turn limitation with exact concurrent attribution;
- explain exact, partial, and unavailable notifications;
- document subagent aggregation and interrupted reminders;
- document `TOKENNOTIFIER_SETTLE_TIMEOUT_MS` and
  `TOKENNOTIFIER_SETTLE_INTERVAL_MS`;
- state that rollout format changes can temporarily degrade usage to unavailable;
- retain the existing privacy statement and add that only minimal ID/usage
  projections are read and stored.

- [ ] **Step 5: Run the complete suite**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case All
```

Expected output contains:

```text
PASS: Package
PASS: Config
PASS: Evaluator
PASS: ToastXml
PASS: Registration
PASS: Attribution
PASS: Collector
```

- [ ] **Step 6: Commit release documentation and privacy coverage**

```powershell
git add .codex-plugin/plugin.json README.md scripts/collector.ps1 tests/token-notifier.tests.ps1
git commit -m "docs: document concurrent usage attribution"
```

### Task 6: Live Concurrent Verification

**Files:**
- Verify only; no source file changes expected.

**Interfaces:**
- Consumes: installed TokenNotifier `0.3.0` and a running CC Switch 3.20.4 or later.
- Produces: runtime evidence that two overlapping root turns and an interrupted turn notify independently.

- [ ] **Step 1: Install the local plugin build through the existing development marketplace flow**

Confirm the installed cache contains version `0.3.0` and the four Hook events.

- [ ] **Step 2: Start two Codex turns and keep their model calls overlapped**

Use distinct thread names but the same project and model so directory or model
heuristics could not separate them.

- [ ] **Step 3: Verify the two Toasts**

Confirm each Toast title contains its own thread name and each summary's logged
response IDs occur only in that thread's rollout `token_usage_record` entries.

- [ ] **Step 4: Run and interrupt a third turn**

Confirm an interrupted Toast appears, contains `任务已中断。` or the corresponding
partial/unavailable variant, and its state directory is removed.

- [ ] **Step 5: Verify privacy and diagnostics**

Search runtime state and logs for the three test prompts and verify zero matches.
Confirm no Hook timeout, SQLite lock, malformed transcript, or Toast registration
error appears in `logs/errors.log`.

- [ ] **Step 6: Record the verification commit**

If live verification required no correction, add no generated runtime files. Create
an empty verification commit only when the project release process requires it;
otherwise retain the Task 5 commit as the release candidate.

## Self-Review Results

- Spec coverage: all sixteen design sections map to Tasks 1 through 6.
- Concurrency correctness: tests use interleaved requests with the same starting
  rowid and never accept timing as attribution.
- Lifecycle coverage: `Stop`, `Interrupt`, and `SubagentStop` each have an explicit
  integration fixture.
- Degradation coverage: exact, partial, and unavailable states have defined data
  and copy behavior.
- Privacy coverage: both unit projection and end-to-end persistence tests include
  sensitive sentinel strings.
- Compatibility coverage: configuration, Toast, registration, evaluator, package,
  and Collector suites all run in the final gate.
- Type consistency: helper names and context property names are identical across
  tasks and the design spec.
