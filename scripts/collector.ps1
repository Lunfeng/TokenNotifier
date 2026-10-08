$ErrorActionPreference = 'Stop'

$dataRoot = if ($env:TOKENNOTIFIER_DATA_ROOT) { $env:TOKENNOTIFIER_DATA_ROOT } elseif ($env:APINOTIFIER_DATA_ROOT) { $env:APINOTIFIER_DATA_ROOT } elseif ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { Join-Path $env:USERPROFILE '.codex\token-notifier' }
$stateRoot = Join-Path $dataRoot 'state'
$logPath = Join-Path $dataRoot 'logs\usage.jsonl'
$errorLogPath = Join-Path $dataRoot 'logs\errors.log'
$script:ConfigLoadError = $null
$script:HookPayloadParseError = $false

. (Join-Path $PSScriptRoot 'evaluator.ps1')
. (Join-Path $PSScriptRoot 'attribution.ps1')

function Append-ErrorLog([string]$Detail) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $errorLogPath) | Out-Null
    [IO.File]::AppendAllText($errorLogPath, ('{0} {1}{2}' -f [DateTimeOffset]::Now.ToString('o'), $Detail, [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Read-Utf8Stdin {
    $stream = [Console]::OpenStandardInput(); $memory = New-Object IO.MemoryStream; $buffer = New-Object byte[] 4096
    try { while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $memory.Write($buffer, 0, $count) }; return [Text.Encoding]::UTF8.GetString($memory.ToArray()) }
    finally { $memory.Dispose() }
}

function Get-ToastDuration([object]$Config) {
    if ($null -ne $Config.toast -and $Config.toast -isnot [pscustomobject]) { throw 'Config toast must be an object' }
    if ($null -ne $Config.toast -and $null -ne $Config.toast.duration) {
        $duration = [string]$Config.toast.duration
        if ($duration -notin @('short', 'long')) { throw 'Config toast duration must be short or long' }
        return $duration
    }
    if ($null -ne $Config.popup -and $null -ne $Config.popup.auto_close_seconds) {
        try { $seconds = [int]$Config.popup.auto_close_seconds } catch { throw 'Config popup auto_close_seconds must be an integer' }
        if ($seconds -ge 10) { return 'long' }
    }
    return 'short'
}

function Get-Config {
    $script:ConfigLoadError = $null
    $path = if ($env:TOKENNOTIFIER_CONFIG_PATH) { $env:TOKENNOTIFIER_CONFIG_PATH } elseif ($env:APINOTIFIER_CONFIG_PATH) { $env:APINOTIFIER_CONFIG_PATH } else { Join-Path $env:USERPROFILE '.codex\token-notifier\config.json' }
    $default = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\default-config.json'
    if (-not (Test-Path $path)) { return ([IO.File]::ReadAllText($default, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
    try {
        $config = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $config -or $config -is [string] -or $null -eq $config.items -or -not ($config.items -is [System.Collections.IEnumerable])) { throw 'Config must define an items array' }
        foreach ($item in @($config.items)) {
            if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.label)) { throw 'Config items require labels' }
            $hasField = $null -ne $item.field -and [string]$item.field -ne ''
            $hasExpression = $null -ne $item.expression -and [string]$item.expression -ne ''
            if ($hasField -eq $hasExpression) { throw 'Config items require exactly one field or expression' }
        }
        if ($null -ne $config.popup -and $config.popup -isnot [pscustomobject]) { throw 'Config popup must be an object' }
        Get-ToastDuration $config | Out-Null
        Get-PricingConfig $config | Out-Null
        return $config
    } catch {
        $script:ConfigLoadError = $_.Exception.Message
        try { Append-ErrorLog 'Config file rejected: invalid JSON or schema' } catch { }
        return ([IO.File]::ReadAllText($default, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
}

function Get-MarkerPath([string]$TurnId) {
    return Join-Path (Join-Path $stateRoot 'turns') (($TurnId -replace '[^A-Za-z0-9._-]', '_') + '.json')
}

function Start-Turn([object]$Payload) {
    $markerPath = Get-MarkerPath $Payload.turn_id
    New-Item -ItemType Directory -Force (Split-Path -Parent $markerPath) | Out-Null
    $marker = [ordered]@{
        session_id = [string]$Payload.session_id
        turn_id = [string]$Payload.turn_id
        cwd = [string]$Payload.cwd
        transcript_path = [string]$Payload.transcript_path
        transcript_offset = Get-TranscriptLength ([string]$Payload.transcript_path)
        started_at = [DateTimeOffset]::Now.ToString('o')
    }
    [IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Append-JsonLine([object]$Value, [string]$Path) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $fullPath = [IO.Path]::GetFullPath($Path).ToLowerInvariant(); $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))).Replace('-', '') } finally { $sha256.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\Lunfeng.TokenNotifier.Jsonl.' + $hash)); $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Timed out waiting to append the TokenNotifier usage log' }
        [IO.File]::AppendAllText($Path, (($Value | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function ConvertTo-EvaluatorContext([object]$Context) {
    $result = @{}; foreach ($property in $Context.PSObject.Properties) { $result[$property.Name] = $property.Value }; return $result
}

function Get-NotifierCommand {
    if (-not [string]::IsNullOrWhiteSpace($env:TOKENNOTIFIER_NOTIFIER_COMMAND)) { return [string]$env:TOKENNOTIFIER_NOTIFIER_COMMAND }
    if (-not [string]::IsNullOrWhiteSpace($env:APINOTIFIER_NOTIFIER_COMMAND)) { return [string]$env:APINOTIFIER_NOTIFIER_COMMAND }
    return ('powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'notifier.ps1') + '"')
}

function Invoke-DetachedNotifier([object]$Payload) {
    New-Item -ItemType Directory -Force $stateRoot | Out-Null
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    if ([string]::IsNullOrWhiteSpace($env:TOKENNOTIFIER_NOTIFIER_COMMAND) -and [string]::IsNullOrWhiteSpace($env:APINOTIFIER_NOTIFIER_COMMAND)) {
        $payloadPath = Join-Path $stateRoot ('notification-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($payloadPath, ($Payload | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'notifier.ps1') + '"'), '-PayloadPath', ('"' + $payloadPath + '"')) | Out-Null
        return
    }
    $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }; $startInfo.Arguments = '/d /s /c ' + (Get-NotifierCommand); $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true; $startInfo.RedirectStandardInput = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $startInfo
    try { $process.Start() | Out-Null; $bytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine); $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $process.StandardInput.Close() } finally { $process.Dispose() }
}

function New-ErrorNotification([string]$Message) { return [ordered]@{ kind='error'; title='TokenNotifier'; message=$Message; items=@(); duration='short' } }

function Invoke-UsageNotification([object]$Config, [object]$Context) {
    $items = @(); $evaluatorContext = ConvertTo-EvaluatorContext $Context
    if ([string]$Context.usage_status -ne 'unavailable') {
        foreach ($item in @($Config.items)) {
            $resolved = Resolve-DataItem $item $evaluatorContext; $items += $resolved
            if ($resolved.PSObject.Properties.Name -contains 'error') { try { Append-ErrorLog 'Data item evaluation failed' } catch { } }
        }
    }
    if ($script:ConfigLoadError) { $items += [pscustomobject]@{ label='Config error'; value='Using default config'; error=$script:ConfigLoadError } }
    $defaultTitle = 'TokenNotifier ' + [char]0x00B7 + ' ' + [string]$Context.thread_name
    $payload = [ordered]@{ kind='usage'; title=if ([string]::IsNullOrWhiteSpace([string]$Config.title)) { $defaultTitle } else { [string]$Config.title }; message=Get-AttributionMessage ([string]$Context.turn_outcome) ([string]$Context.pricing_status) ([int]$Context.missing_model_count); items=$items; duration=Get-ToastDuration $Config }
    if ($Config.enabled -ne $false) { Invoke-DetachedNotifier $payload }
}

function Get-ModelSummary([object[]]$Records) {
    $models = @($Records | ForEach-Object { [string]$_.model } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($models.Count -eq 1) { return $models[0] }; if ($models.Count -gt 1) { return 'multiple' }; return $null
}

function Build-TurnContext([object[]]$UsageRecords, [object]$Marker, [string]$Outcome, [object]$Pricing, [object[]]$SessionUsageRecords = $null) {
    $records = @(Select-UniqueUsageRecords $UsageRecords)
    $sessionRecords = if ($null -eq $SessionUsageRecords) { @($records) } else { @(Select-UniqueUsageRecords $SessionUsageRecords) }
    $tokens = Measure-ProjectedTokens $records
    $sessionTokens = Get-SessionTokenTotals $sessionRecords
    $cost = Get-UsageCost $records $Pricing
    $sessionCost = Get-UsageCost $sessionRecords $Pricing
    $requestCount = $records.Count
    $usageStatus = if ($requestCount -eq 0) { 'unavailable' } else { 'exact' }
    $status = if ($usageStatus -eq 'unavailable') { 'unavailable' } else { [string]$cost.status }
    $sessionStatus = if ($sessionRecords.Count -eq 0) { 'unavailable' } else { [string]$sessionCost.status }
    $context = [ordered]@{
        request_count=$requestCount
        matched_request_count=if ($status -eq 'partial') { $requestCount - $cost.missing_model_count } else { $requestCount }
        unmatched_request_count=$cost.missing_model_count
        input_tokens=$tokens.input_tokens
        cached_input_tokens=$tokens.cached_input_tokens
        cache_write_input_tokens=$tokens.cache_write_input_tokens
        cache_read_tokens=$tokens.cache_read_tokens
        cache_creation_tokens=$tokens.cache_creation_tokens
        output_tokens=$tokens.output_tokens
        reasoning_output_tokens=$tokens.reasoning_output_tokens
        total_tokens=$tokens.total_tokens
        input_cost_usd=$cost.input_cost_usd
        output_cost_usd=$cost.output_cost_usd
        cache_read_cost_usd=$cost.cache_read_cost_usd
        cache_creation_cost_usd=$cost.cache_creation_cost_usd
        total_cost_usd=$cost.total_cost_usd
        session_input_tokens=$sessionTokens.input_tokens
        session_cached_input_tokens=$sessionTokens.cached_input_tokens
        session_cache_write_input_tokens=$sessionTokens.cache_write_input_tokens
        session_cache_read_tokens=$sessionTokens.cache_read_tokens
        session_cache_creation_tokens=$sessionTokens.cache_creation_tokens
        session_output_tokens=$sessionTokens.output_tokens
        session_reasoning_output_tokens=$sessionTokens.reasoning_output_tokens
        session_total_tokens=$sessionTokens.total_tokens
        thread_input_tokens=$sessionTokens.input_tokens
        thread_cached_input_tokens=$sessionTokens.cached_input_tokens
        thread_cache_write_input_tokens=$sessionTokens.cache_write_input_tokens
        thread_cache_read_tokens=$sessionTokens.cache_read_tokens
        thread_cache_creation_tokens=$sessionTokens.cache_creation_tokens
        thread_output_tokens=$sessionTokens.output_tokens
        thread_reasoning_output_tokens=$sessionTokens.reasoning_output_tokens
        thread_total_tokens=$sessionTokens.total_tokens
        session_input_cost_usd=$sessionCost.input_cost_usd
        session_output_cost_usd=$sessionCost.output_cost_usd
        session_cache_read_cost_usd=$sessionCost.cache_read_cost_usd
        session_cache_creation_cost_usd=$sessionCost.cache_creation_cost_usd
        session_total_cost_usd=$sessionCost.total_cost_usd
        thread_input_cost_usd=$sessionCost.input_cost_usd
        thread_output_cost_usd=$sessionCost.output_cost_usd
        thread_cache_read_cost_usd=$sessionCost.cache_read_cost_usd
        thread_cache_creation_cost_usd=$sessionCost.cache_creation_cost_usd
        thread_total_cost_usd=$sessionCost.total_cost_usd
        duration_ms_total=$null
        duration_ms_max=$null
        first_token_ms_first=$null
        model=Get-ModelSummary $records
        provider_id=$null
        status_code=$null
        turn_outcome=$Outcome
        usage_status=$usageStatus
        pricing_status=$status
        session_pricing_status=$sessionStatus
        attribution_status=$status
        missing_model_count=$cost.missing_model_count
        session_missing_model_count=$sessionCost.missing_model_count
        thread_name=Get-ThreadDisplayName ([string]$Marker.session_id) ([string]$Marker.cwd) ''
        codex_session_id=[string]$Marker.session_id
        codex_turn_id=[string]$Marker.turn_id
        codex_cwd=[string]$Marker.cwd
    }
    return [pscustomobject]$context
}

function ConvertTo-LogDecimal([object]$Value) { if ($null -eq $Value -or [string]$Value -eq '') { return $null }; return ([decimal]$Value).ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture) }
function Get-SafeStateName([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '_' }; return ($Value -replace '[^A-Za-z0-9._-]', '_') }
function Get-SubagentTurnPath([string]$RootTurnId) { return Join-Path (Join-Path $stateRoot 'subagents') (Get-SafeStateName $RootTurnId) }

function Save-SubagentUsage([object]$Payload) {
    $records = @(Read-AllUsageRecords ([string]$Payload.agent_transcript_path))
    foreach ($group in @($records | Group-Object root_turn_id)) {
        if ([string]::IsNullOrWhiteSpace([string]$group.Name)) { continue }
        $directory = Get-SubagentTurnPath ([string]$group.Name); New-Item -ItemType Directory -Force $directory | Out-Null
        $agentId = if (-not [string]::IsNullOrWhiteSpace([string]$Payload.agent_id)) { Get-SafeStateName ([string]$Payload.agent_id) } elseif (-not [string]::IsNullOrWhiteSpace([string]$Payload.agent_transcript_path)) { Get-SafeStateName ([IO.Path]::GetFileNameWithoutExtension([string]$Payload.agent_transcript_path)) } else { [guid]::NewGuid().ToString('N') }
        $path = Join-Path $directory ($agentId + '.json'); $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try { [IO.File]::WriteAllText($temporary, (@($group.Group) | ConvertTo-Json -Compress -Depth 6), [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $temporary -Destination $path -Force } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Read-SubagentUsage([string]$RootTurnId) {
    $directory = Get-SubagentTurnPath $RootTurnId
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -Filter '*.json')) {
        try { $parsed = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json; foreach ($record in @($parsed)) { Write-Output $record } } catch { try { Append-ErrorLog ('Subagent usage fragment rejected: ' + $file.Name) } catch { } }
    }
}

function Remove-TurnState([string]$TurnId, [string]$MarkerPath) {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    $subagentRoot = Join-Path $stateRoot 'subagents'; $directory = Get-SubagentTurnPath $TurnId
    $rootFull = [IO.Path]::GetFullPath($subagentRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar; $directoryFull = [IO.Path]::GetFullPath($directory)
    if ($directoryFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $directoryFull -PathType Container)) { Remove-Item -LiteralPath $directoryFull -Recurse -Force -ErrorAction SilentlyContinue }
}

function Complete-Turn([object]$Payload, [string]$Outcome = 'completed') {
    $markerPath = Get-MarkerPath $Payload.turn_id
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) { $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    else { $marker = [pscustomobject]@{ session_id=[string]$Payload.session_id; turn_id=[string]$Payload.turn_id; cwd=[string]$Payload.cwd; transcript_path=[string]$Payload.transcript_path; transcript_offset=[int64]0; started_at=[DateTimeOffset]::Now.ToString('o') } }
    $transcriptPath = if (-not [string]::IsNullOrWhiteSpace([string]$Payload.transcript_path)) { [string]$Payload.transcript_path } else { [string]$marker.transcript_path }
    $offset = if ($transcriptPath -eq [string]$marker.transcript_path) { [int64]$marker.transcript_offset } else { [int64]0 }
    $usageRecords = @(Read-TurnUsageRecords $transcriptPath ([string]$marker.turn_id) $offset); $usageRecords += @(Read-SubagentUsage ([string]$marker.turn_id)); $usageRecords = @(Select-UniqueUsageRecords $usageRecords)
    $sessionRecords = @(Read-SessionUsageRecords $transcriptPath ([string]$marker.session_id)); $sessionRecords += $usageRecords; $sessionRecords = @(Select-UniqueUsageRecords $sessionRecords)
    $config = Get-Config; $pricing = Get-PricingConfig $config; $context = Build-TurnContext $usageRecords $marker $Outcome $pricing $sessionRecords
    foreach ($record in $usageRecords) {
        Append-JsonLine ([ordered]@{
            type='rollout_usage_record'; logged_at=[DateTimeOffset]::Now.ToString('o'); codex_session_id=[string]$marker.session_id; codex_turn_id=[string]$marker.turn_id
            response_id=[string]$record.response_id; session_id=[string]$record.session_id; thread_id=[string]$record.thread_id; turn_id=[string]$record.turn_id; root_turn_id=[string]$record.root_turn_id; model=[string]$record.model
            input_tokens=[int64]$record.input_tokens; cached_input_tokens=[int64]$record.cached_input_tokens; cache_write_input_tokens=[int64]$record.cache_write_input_tokens; cache_read_tokens=[int64]$record.cache_read_tokens; cache_creation_tokens=[int64]$record.cache_creation_tokens
            output_tokens=[int64]$record.output_tokens; reasoning_output_tokens=[int64]$record.reasoning_output_tokens; total_tokens=[int64]$record.total_tokens
            thread_input_tokens=$record.thread_input_tokens; thread_cached_input_tokens=$record.thread_cached_input_tokens; thread_cache_write_input_tokens=$record.thread_cache_write_input_tokens; thread_cache_read_tokens=$record.thread_cache_read_tokens; thread_cache_creation_tokens=$record.thread_cache_creation_tokens
            thread_output_tokens=$record.thread_output_tokens; thread_reasoning_output_tokens=$record.thread_reasoning_output_tokens; thread_total_tokens=$record.thread_total_tokens
        }) $logPath
    }
    $summary = [ordered]@{
        type='turn_summary'; logged_at=[DateTimeOffset]::Now.ToString('o'); codex_session_id=$context.codex_session_id; codex_turn_id=$context.codex_turn_id; codex_cwd=$context.codex_cwd; turn_outcome=$context.turn_outcome
        usage_status=$context.usage_status; pricing_status=$context.pricing_status; session_pricing_status=$context.session_pricing_status; attribution_status=$context.attribution_status; request_count=$context.request_count; matched_request_count=$context.matched_request_count; unmatched_request_count=$context.unmatched_request_count; missing_model_count=$context.missing_model_count; session_missing_model_count=$context.session_missing_model_count
        input_tokens=$context.input_tokens; cached_input_tokens=$context.cached_input_tokens; cache_write_input_tokens=$context.cache_write_input_tokens; cache_read_tokens=$context.cache_read_tokens; cache_creation_tokens=$context.cache_creation_tokens; output_tokens=$context.output_tokens; reasoning_output_tokens=$context.reasoning_output_tokens; total_tokens=$context.total_tokens
        session_input_tokens=$context.session_input_tokens; session_cached_input_tokens=$context.session_cached_input_tokens; session_cache_write_input_tokens=$context.session_cache_write_input_tokens; session_cache_read_tokens=$context.session_cache_read_tokens; session_cache_creation_tokens=$context.session_cache_creation_tokens; session_output_tokens=$context.session_output_tokens; session_reasoning_output_tokens=$context.session_reasoning_output_tokens; session_total_tokens=$context.session_total_tokens
        thread_input_tokens=$context.thread_input_tokens; thread_cached_input_tokens=$context.thread_cached_input_tokens; thread_cache_write_input_tokens=$context.thread_cache_write_input_tokens; thread_cache_read_tokens=$context.thread_cache_read_tokens; thread_cache_creation_tokens=$context.thread_cache_creation_tokens; thread_output_tokens=$context.thread_output_tokens; thread_reasoning_output_tokens=$context.thread_reasoning_output_tokens; thread_total_tokens=$context.thread_total_tokens
        input_cost_usd=ConvertTo-LogDecimal $context.input_cost_usd; output_cost_usd=ConvertTo-LogDecimal $context.output_cost_usd; cache_read_cost_usd=ConvertTo-LogDecimal $context.cache_read_cost_usd; cache_creation_cost_usd=ConvertTo-LogDecimal $context.cache_creation_cost_usd; total_cost_usd=ConvertTo-LogDecimal $context.total_cost_usd
        session_input_cost_usd=ConvertTo-LogDecimal $context.session_input_cost_usd; session_output_cost_usd=ConvertTo-LogDecimal $context.session_output_cost_usd; session_cache_read_cost_usd=ConvertTo-LogDecimal $context.session_cache_read_cost_usd; session_cache_creation_cost_usd=ConvertTo-LogDecimal $context.session_cache_creation_cost_usd; session_total_cost_usd=ConvertTo-LogDecimal $context.session_total_cost_usd
        thread_input_cost_usd=ConvertTo-LogDecimal $context.thread_input_cost_usd; thread_output_cost_usd=ConvertTo-LogDecimal $context.thread_output_cost_usd; thread_cache_read_cost_usd=ConvertTo-LogDecimal $context.thread_cache_read_cost_usd; thread_cache_creation_cost_usd=ConvertTo-LogDecimal $context.thread_cache_creation_cost_usd; thread_total_cost_usd=ConvertTo-LogDecimal $context.thread_total_cost_usd
        model=$context.model
    }
    Append-JsonLine $summary $logPath; Invoke-UsageNotification $config $context; Remove-TurnState ([string]$marker.turn_id) $markerPath
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $inputText = Read-Utf8Stdin; if ([string]::IsNullOrWhiteSpace($inputText)) { exit 0 }
        try { $payload = $inputText | ConvertFrom-Json } catch { $script:HookPayloadParseError = $true; throw 'Hook payload JSON is invalid' }
        switch ([string]$payload.hook_event_name) { 'UserPromptSubmit' { Start-Turn $payload }; 'SubagentStop' { Save-SubagentUsage $payload }; 'Stop' { Complete-Turn $payload 'completed' }; 'Interrupt' { Complete-Turn $payload 'interrupted' } }
    } catch { try { if ($script:HookPayloadParseError) { Append-ErrorLog 'Hook payload rejected: invalid JSON' } else { Append-ErrorLog $_.Exception.ToString() } } catch { }; try { Invoke-DetachedNotifier (New-ErrorNotification 'Unable to collect rollout usage data.') } catch { }; exit 0 }
}
