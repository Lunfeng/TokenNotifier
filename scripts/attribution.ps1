function Get-TranscriptLength([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [int64]0 }
    return [int64](Get-Item -LiteralPath $Path).Length
}

function ConvertTo-UsageTokenValue([object]$Usage, [string]$Name, [bool]$Required) {
    $property = $Usage.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]$property.Value -eq '') {
        if ($Required) { throw "Usage field is required: $Name" }
        return [int64]0
    }
    try { $value = [int64]$property.Value } catch { throw "Usage field must be an integer: $Name" }
    if ($value -lt 0) { throw "Usage field must not be negative: $Name" }
    return $value
}

function ConvertTo-OptionalUsageTokenValue([object]$Usage, [string]$Name) {
    if ($null -eq $Usage) { return $null }
    $property = $Usage.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]$property.Value -eq '') { return $null }
    return ConvertTo-UsageTokenValue $Usage $Name $true
}

function Read-RolloutModelMap([string]$Path) {
    $models = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $models }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.IndexOf('"turn_context"', [StringComparison]::Ordinal) -lt 0) { continue }
                try {
                    $value = $line | ConvertFrom-Json
                    if ([string]$value.type -ne 'turn_context' -or $null -eq $value.payload) { continue }
                    $model = [string]$value.payload.model
                    if ([string]::IsNullOrWhiteSpace($model)) { continue }
                    $turnId = [string]$value.payload.turn_id
                    $rootTurnId = [string]$value.payload.root_turn_id
                    if (-not [string]::IsNullOrWhiteSpace($turnId)) { $models[$turnId] = $model }
                    if (-not [string]::IsNullOrWhiteSpace($rootTurnId) -and -not $models.ContainsKey($rootTurnId)) { $models[$rootTurnId] = $model }
                } catch { continue }
            }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    return $models
}

function ConvertTo-UsageProjection([object]$Value, [string]$RootTurnId, [object]$Models = $null, [bool]$AcceptAnyRoot = $false) {
    if ($Models -is [bool]) { $AcceptAnyRoot = [bool]$Models; $Models = @{} }
    elseif ($null -eq $Models) { $Models = @{} }
    if ($null -eq $Value -or [string]$Value.type -ne 'token_usage_record') { return $null }
    $payload = $Value.payload
    if ($null -eq $payload) { return $null }
    $turnId = [string]$payload.turn_id
    $recordRootTurnId = [string]$payload.root_turn_id
    if ($AcceptAnyRoot) {
        if ([string]::IsNullOrWhiteSpace($recordRootTurnId)) { return $null }
    } elseif ($turnId -ne $RootTurnId -and $recordRootTurnId -ne $RootTurnId) { return $null }
    $responseId = [string]$payload.response_id
    if ($responseId -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    $usage = $payload.usage
    if ($null -eq $usage) { return $null }
    $model = $null
    if (-not [string]::IsNullOrWhiteSpace($turnId) -and $Models.ContainsKey($turnId)) { $model = [string]$Models[$turnId] }
    elseif (-not [string]::IsNullOrWhiteSpace($recordRootTurnId) -and $Models.ContainsKey($recordRootTurnId)) { $model = [string]$Models[$recordRootTurnId] }
    $reasoningOutputTokens = ConvertTo-OptionalUsageTokenValue $usage 'reasoning_output_tokens'
    if ($null -eq $reasoningOutputTokens) { $reasoningOutputTokens = [int64]0 }
    $totalTokens = ConvertTo-OptionalUsageTokenValue $usage 'total_tokens'
    if ($null -eq $totalTokens) { $totalTokens = [int64]$payload.usage.input_tokens + [int64]$payload.usage.output_tokens }
    $threadUsage = $payload.thread_token_usage
    $threadInputTokens = ConvertTo-OptionalUsageTokenValue $threadUsage 'input_tokens'
    $threadCacheReadTokens = ConvertTo-OptionalUsageTokenValue $threadUsage 'cached_input_tokens'
    $threadCacheCreationTokens = ConvertTo-OptionalUsageTokenValue $threadUsage 'cache_write_input_tokens'
    $threadOutputTokens = ConvertTo-OptionalUsageTokenValue $threadUsage 'output_tokens'
    $threadReasoningOutputTokens = ConvertTo-OptionalUsageTokenValue $threadUsage 'reasoning_output_tokens'
    $threadTotalTokens = ConvertTo-OptionalUsageTokenValue $threadUsage 'total_tokens'
    return [pscustomobject]@{
        response_id = $responseId
        session_id = [string]$payload.session_id
        thread_id = [string]$payload.thread_id
        turn_id = $turnId
        root_turn_id = $recordRootTurnId
        model = $model
        thread_total_tokens = $threadTotalTokens
        thread_input_tokens = $threadInputTokens
        thread_cache_read_tokens = $threadCacheReadTokens
        thread_cache_creation_tokens = $threadCacheCreationTokens
        thread_cached_input_tokens = $threadCacheReadTokens
        thread_cache_write_input_tokens = $threadCacheCreationTokens
        thread_output_tokens = $threadOutputTokens
        thread_reasoning_output_tokens = $threadReasoningOutputTokens
        input_tokens = ConvertTo-UsageTokenValue $usage 'input_tokens' $true
        output_tokens = ConvertTo-UsageTokenValue $usage 'output_tokens' $true
        cache_read_tokens = ConvertTo-UsageTokenValue $usage 'cached_input_tokens' $false
        cache_creation_tokens = ConvertTo-UsageTokenValue $usage 'cache_write_input_tokens' $false
        cached_input_tokens = ConvertTo-UsageTokenValue $usage 'cached_input_tokens' $false
        cache_write_input_tokens = ConvertTo-UsageTokenValue $usage 'cache_write_input_tokens' $false
        reasoning_output_tokens = $reasoningOutputTokens
        total_tokens = $totalTokens
    }
}

function Read-UsageProjectionStream([string]$Path, [string]$RootTurnId, [int64]$StartOffset, [bool]$AcceptAnyRoot) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $models = Read-RolloutModelMap $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($StartOffset -lt 0 -or $StartOffset -gt $stream.Length) { $StartOffset = 0 }
        [void]$stream.Seek($StartOffset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.IndexOf('"token_usage_record"', [StringComparison]::Ordinal) -lt 0) { continue }
                try {
                    $value = $line | ConvertFrom-Json
                    $projection = ConvertTo-UsageProjection $value $RootTurnId $models $AcceptAnyRoot
                    if ($null -ne $projection) { Write-Output $projection }
                } catch { continue }
            }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Read-TurnUsageRecords([string]$Path, [string]$RootTurnId, [int64]$StartOffset = 0) { Read-UsageProjectionStream $Path $RootTurnId $StartOffset $false }
function Read-AllUsageRecords([string]$Path) { Read-UsageProjectionStream $Path '' 0 $true }

function Get-SessionRolloutPaths([string]$TranscriptPath) {
    $paths = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($TranscriptPath) -and (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        $fullTranscriptPath = [IO.Path]::GetFullPath($TranscriptPath)
        $paths[$fullTranscriptPath.ToLowerInvariant()] = $fullTranscriptPath
    }
    $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { return @($paths.Values) }
    try {
        $fullRoot = [IO.Path]::GetFullPath($sessionsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $fullTranscript = [IO.Path]::GetFullPath($TranscriptPath)
        if (-not $fullTranscript.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return @($paths.Values) }
        $dateDirectory = Split-Path -Parent $fullTranscript
        foreach ($file in @(Get-ChildItem -LiteralPath $dateDirectory -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
            $fullPath = [IO.Path]::GetFullPath($file.FullName)
            $paths[$fullPath.ToLowerInvariant()] = $fullPath
        }
    } catch { }
    return @($paths.Values)
}

function Read-SessionUsageRecords([string]$TranscriptPath, [string]$SessionId) {
    $records = @()
    $paths = @(Get-SessionRolloutPaths $TranscriptPath)
    foreach ($path in $paths) {
        foreach ($record in @(Read-AllUsageRecords $path)) {
            $isCurrentTranscript = ([IO.Path]::GetFullPath($path) -eq [IO.Path]::GetFullPath($TranscriptPath))
            if ($isCurrentTranscript -or [string]::IsNullOrWhiteSpace($SessionId) -or [string]$record.session_id -eq $SessionId) {
                $records += $record
            }
        }
    }
    return @(Select-UniqueUsageRecords $records)
}

function Select-UniqueUsageRecords([object[]]$UsageRecords) {
    $seen = @{}
    foreach ($record in @($UsageRecords)) {
        $responseId = [string]$record.response_id
        if ([string]::IsNullOrWhiteSpace($responseId) -or $seen.ContainsKey($responseId)) { continue }
        $seen[$responseId] = $true
        Write-Output $record
    }
}

function Measure-ProjectedTokens([object[]]$UsageRecords) {
    $result = [ordered]@{ input_tokens=[int64]0; cached_input_tokens=[int64]0; cache_write_input_tokens=[int64]0; output_tokens=[int64]0; reasoning_output_tokens=[int64]0; total_tokens=[int64]0; cache_read_tokens=[int64]0; cache_creation_tokens=[int64]0 }
    foreach ($record in @($UsageRecords)) {
        $result.input_tokens = [int64]$result.input_tokens + [int64]$record.input_tokens
        $result.cached_input_tokens = [int64]$result.cached_input_tokens + [int64]$record.cached_input_tokens
        $result.cache_write_input_tokens = [int64]$result.cache_write_input_tokens + [int64]$record.cache_write_input_tokens
        $result.output_tokens = [int64]$result.output_tokens + [int64]$record.output_tokens
        $result.reasoning_output_tokens = [int64]$result.reasoning_output_tokens + [int64]$record.reasoning_output_tokens
        $result.total_tokens = [int64]$result.total_tokens + [int64]$record.total_tokens
    }
    $result.cache_read_tokens = $result.cached_input_tokens
    $result.cache_creation_tokens = $result.cache_write_input_tokens
    return [pscustomobject]$result
}

function Get-SessionTotalTokens([object[]]$UsageRecords) {
    return (Get-SessionTokenTotals $UsageRecords).total_tokens
}

function Get-SessionTokenTotals([object[]]$UsageRecords) {
    $result = [ordered]@{ input_tokens=$null; cached_input_tokens=$null; cache_write_input_tokens=$null; output_tokens=$null; reasoning_output_tokens=$null; total_tokens=$null; cache_read_tokens=$null; cache_creation_tokens=$null }
    $records = @(Select-UniqueUsageRecords $UsageRecords)
    $latestByThread = [ordered]@{}
    foreach ($record in $records) {
        $threadId = [string]$record.thread_id
        if ([string]::IsNullOrWhiteSpace($threadId)) { $threadId = '<default>' }
        $latestByThread[$threadId] = $record
    }
    foreach ($field in @('input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens','reasoning_output_tokens','total_tokens')) {
        $threadFields = @('thread_' + $field)
        if ($field -eq 'cached_input_tokens') { $threadFields = @('thread_cached_input_tokens', 'thread_cache_read_tokens') }
        elseif ($field -eq 'cache_write_input_tokens') { $threadFields = @('thread_cache_write_input_tokens', 'thread_cache_creation_tokens') }
        $sum = [int64]0; $found = $false
        foreach ($record in @($latestByThread.Values)) {
            $value = $null
            foreach ($threadField in $threadFields) {
                $property = $record.PSObject.Properties[$threadField]
                if ($null -ne $property -and $null -ne $property.Value) { $value = $property.Value; break }
            }
            if ($null -ne $value) { $sum += [int64]$value; $found = $true }
        }
        if ($found) { $result[$field] = $sum }
    }
    if ($null -ne $result.cached_input_tokens) { $result.cache_read_tokens = $result.cached_input_tokens }
    if ($null -ne $result.cache_write_input_tokens) { $result.cache_creation_tokens = $result.cache_write_input_tokens }
    return [pscustomobject]$result
}

function ConvertTo-PricingDecimal([object]$Value, [string]$Name) {
    if ($null -eq $Value -or [string]$Value -eq '') { return [decimal]0 }
    try { $number = [decimal]$Value } catch { throw "Pricing value must be numeric: $Name" }
    if ($number -lt 0) { throw "Pricing value must not be negative: $Name" }
    return $number
}

function Get-PricingConfig([object]$Config) {
    $pricing = $Config.pricing
    if ($null -eq $pricing) { return [pscustomobject]@{ unit='per_million_tokens'; currency='USD'; models=[pscustomobject]@{} } }
    if ($pricing -isnot [pscustomobject]) { throw 'Config pricing must be an object' }
    $unit = if ($null -eq $pricing.unit) { 'per_million_tokens' } else { [string]$pricing.unit }
    if ($unit -ne 'per_million_tokens') { throw 'Config pricing unit must be per_million_tokens' }
    $currency = if ($null -eq $pricing.currency) { 'USD' } else { [string]$pricing.currency }
    if ($currency -ne 'USD') { throw 'Config pricing currency must be USD' }
    $models = [ordered]@{}
    if ($null -ne $pricing.models) {
        if ($pricing.models -isnot [pscustomobject]) { throw 'Config pricing models must be an object' }
        foreach ($property in $pricing.models.PSObject.Properties) {
            $modelName = [string]$property.Name
            if ([string]::IsNullOrWhiteSpace($modelName) -or $property.Value -isnot [pscustomobject]) { throw 'Pricing models require objects with model names' }
            $model = $property.Value
            if ($null -eq $model.input -or $null -eq $model.output) { throw "Pricing model requires input and output rates: $modelName" }
            $models[$modelName] = [pscustomobject]@{
                input = ConvertTo-PricingDecimal $model.input ($modelName + '.input')
                cache_read = ConvertTo-PricingDecimal $model.cache_read ($modelName + '.cache_read')
                cache_creation = ConvertTo-PricingDecimal $model.cache_creation ($modelName + '.cache_creation')
                output = ConvertTo-PricingDecimal $model.output ($modelName + '.output')
            }
        }
    }
    return [pscustomobject]@{ unit=$unit; currency=$currency; models=[pscustomobject]$models }
}

function Get-UsageCost([object[]]$UsageRecords, [object]$Pricing) {
    $cost = [ordered]@{ status='unavailable'; missing_model_count=0; missing_models=@(); input_cost_usd=$null; output_cost_usd=$null; cache_read_cost_usd=$null; cache_creation_cost_usd=$null; total_cost_usd=$null }
    $records = @(Select-UniqueUsageRecords $UsageRecords)
    if ($records.Count -eq 0) { return [pscustomobject]$cost }
    [decimal]$inputCost = 0; [decimal]$outputCost = 0; [decimal]$cacheReadCost = 0; [decimal]$cacheCreationCost = 0
    $missing = [ordered]@{}
    foreach ($record in $records) {
        $modelName = [string]$record.model
        $property = if (-not [string]::IsNullOrWhiteSpace($modelName)) { $Pricing.models.PSObject.Properties[$modelName] } else { $null }
        if ($null -eq $property) {
            $missingKey = if ([string]::IsNullOrWhiteSpace($modelName)) { '<unknown>' } else { $modelName }
            $missing[$missingKey] = $true
            continue
        }
        $rate = $property.Value; $scale = [decimal]1000000
        $cachedInputTokens = if ($null -ne $record.cached_input_tokens) { [int64]$record.cached_input_tokens } else { [int64]$record.cache_read_tokens }
        $cacheWriteInputTokens = if ($null -ne $record.cache_write_input_tokens) { [int64]$record.cache_write_input_tokens } else { [int64]$record.cache_creation_tokens }
        $billableInputTokens = [int64]$record.input_tokens - $cachedInputTokens - $cacheWriteInputTokens
        if ($billableInputTokens -lt 0) { $billableInputTokens = 0 }
        $inputCost += ([decimal]$billableInputTokens * [decimal]$rate.input) / $scale
        $outputCost += ([decimal]$record.output_tokens * [decimal]$rate.output) / $scale
        $cacheReadCost += ([decimal]$cachedInputTokens * [decimal]$rate.cache_read) / $scale
        $cacheCreationCost += ([decimal]$cacheWriteInputTokens * [decimal]$rate.cache_creation) / $scale
    }
    $cost.status = if ($missing.Count -gt 0) { 'partial' } else { 'exact' }
    $cost.missing_model_count = $missing.Count
    $cost.missing_models = @($missing.Keys)
    if ($missing.Count -eq 0) {
        $cost.input_cost_usd = $inputCost; $cost.output_cost_usd = $outputCost; $cost.cache_read_cost_usd = $cacheReadCost; $cost.cache_creation_cost_usd = $cacheCreationCost; $cost.total_cost_usd = $inputCost + $outputCost + $cacheReadCost + $cacheCreationCost
    }
    return [pscustomobject]$cost
}

function Get-ThreadDisplayName([string]$SessionId, [string]$Cwd, [string]$IndexPath) {
    if ([string]::IsNullOrWhiteSpace($IndexPath)) { $IndexPath = Join-Path $env:USERPROFILE '.codex\session_index.jsonl' }
    if (Test-Path -LiteralPath $IndexPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($IndexPath, [Text.Encoding]::UTF8)) {
            try { $entry = $line | ConvertFrom-Json } catch { continue }
            if ([string]$entry.id -eq $SessionId -and -not [string]::IsNullOrWhiteSpace([string]$entry.thread_name)) { return [string]$entry.thread_name }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) { $leaf = Split-Path -Leaf $Cwd.TrimEnd('\', '/'); if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf } }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { return $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)) }
    return 'TokenNotifier'
}

function ConvertFrom-CharCodes([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }

function Get-AttributionMessage([string]$Outcome, [string]$Status, [int]$UnmatchedCount) {
    $interruptedUnavailable = ConvertFrom-CharCodes @(0x4efb,0x52a1,0x5df2,0x4e2d,0x65ad,0xff1b,0x672c,0x56de,0x5408,0x7528,0x91cf,0x6682,0x4e0d,0x53ef,0x7528,0x3002)
    $completedUnavailable = ConvertFrom-CharCodes @(0x4efb,0x52a1,0x5df2,0x5b8c,0x6210,0xff1b,0x672c,0x56de,0x5408,0x7528,0x91cf,0x6682,0x4e0d,0x53ef,0x7528,0x3002)
    $interrupted = ConvertFrom-CharCodes @(0x4efb,0x52a1,0x5df2,0x4e2d,0x65ad,0x3002)
    $partialPrefix = ConvertFrom-CharCodes @(0x90e8,0x5206,0x6570,0x636e,0xff1a)
    $partialSuffix = ConvertFrom-CharCodes @(0x4e2a,0x6a21,0x578b,0x7f3a,0x5c11,0x4ef7,0x683c,0x914d,0x7f6e,0x3002)
    if ($Status -eq 'unavailable') { if ($Outcome -eq 'interrupted') { return $interruptedUnavailable }; return $completedUnavailable }
    if ($Status -eq 'partial') { $partial = $partialPrefix + $UnmatchedCount + ' ' + $partialSuffix; if ($Outcome -eq 'interrupted') { return $interrupted + $partial }; return $partial }
    if ($Outcome -eq 'interrupted') { return $interrupted }
    return ''
}
