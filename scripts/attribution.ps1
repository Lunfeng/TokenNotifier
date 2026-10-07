function Get-TranscriptLength([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [int64]0
    }
    return [int64](Get-Item -LiteralPath $Path).Length
}

function ConvertTo-UsageTokenValue([object]$Usage, [string]$Name, [bool]$Required) {
    $property = $Usage.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]$property.Value -eq '') {
        if ($Required) { throw "Usage field is required: $Name" }
        return [int64]0
    }
    try { $value = [int64]$property.Value }
    catch { throw "Usage field must be an integer: $Name" }
    if ($value -lt 0) { throw "Usage field must not be negative: $Name" }
    return $value
}

function ConvertTo-UsageProjection([object]$Value, [string]$RootTurnId, [bool]$AcceptAnyRoot = $false) {
    if ($null -eq $Value -or [string]$Value.type -ne 'token_usage_record') { return $null }
    $payload = $Value.payload
    if ($null -eq $payload) { return $null }

    $turnId = [string]$payload.turn_id
    $recordRootTurnId = [string]$payload.root_turn_id
    if ($AcceptAnyRoot) {
        if ([string]::IsNullOrWhiteSpace($recordRootTurnId)) { return $null }
    } elseif ($turnId -ne $RootTurnId -and $recordRootTurnId -ne $RootTurnId) {
        return $null
    }

    $responseId = [string]$payload.response_id
    if ($responseId -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    $usage = $payload.usage
    if ($null -eq $usage) { return $null }

    return [pscustomobject]@{
        response_id = $responseId
        turn_id = $turnId
        root_turn_id = $recordRootTurnId
        input_tokens = ConvertTo-UsageTokenValue $usage 'input_tokens' $true
        output_tokens = ConvertTo-UsageTokenValue $usage 'output_tokens' $true
        cache_read_tokens = ConvertTo-UsageTokenValue $usage 'cached_input_tokens' $false
        cache_creation_tokens = ConvertTo-UsageTokenValue $usage 'cache_write_input_tokens' $false
    }
}

function Read-UsageProjectionStream([string]$Path, [string]$RootTurnId, [int64]$StartOffset, [bool]$AcceptAnyRoot) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
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
                    $projection = ConvertTo-UsageProjection $value $RootTurnId $AcceptAnyRoot
                    if ($null -ne $projection) { Write-Output $projection }
                } catch {
                    continue
                }
            }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Read-TurnUsageRecords([string]$Path, [string]$RootTurnId, [int64]$StartOffset = 0) {
    Read-UsageProjectionStream $Path $RootTurnId $StartOffset $false
}

function Read-AllUsageRecords([string]$Path) {
    Read-UsageProjectionStream $Path '' 0 $true
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
    $result = [ordered]@{
        input_tokens = [int64]0
        output_tokens = [int64]0
        cache_read_tokens = [int64]0
        cache_creation_tokens = [int64]0
    }
    foreach ($record in @($UsageRecords)) {
        foreach ($name in @('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens')) {
            $result[$name] = [int64]$result[$name] + [int64]$record.$name
        }
    }
    return [pscustomobject]$result
}

function Get-ResponseIdFromRequestId([string]$RequestId) {
    if ($RequestId -match ':(resp_[A-Za-z0-9_-]+)$') { return [string]$Matches[1] }
    return $null
}

function Select-AttributedRows([object[]]$Rows, [object[]]$UsageRecords) {
    $wanted = @{}
    foreach ($record in @($UsageRecords)) { $wanted[[string]$record.response_id] = $true }
    $matched = @{}
    foreach ($row in @($Rows)) {
        $responseId = Get-ResponseIdFromRequestId ([string]$row.request_id)
        if ($null -eq $responseId -or -not $wanted.ContainsKey($responseId) -or $matched.ContainsKey($responseId)) { continue }
        $matched[$responseId] = $true
        $row | Add-Member -NotePropertyName attribution_response_id -NotePropertyValue $responseId -Force
        Write-Output $row
    }
}
