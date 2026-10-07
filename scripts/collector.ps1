$ErrorActionPreference = 'Stop'

$dataRoot = if ($env:TOKENNOTIFIER_DATA_ROOT) { $env:TOKENNOTIFIER_DATA_ROOT } elseif ($env:APINOTIFIER_DATA_ROOT) { $env:APINOTIFIER_DATA_ROOT } elseif ($env:PLUGIN_DATA) { $env:PLUGIN_DATA } else { Join-Path $env:USERPROFILE '.codex\token-notifier' }
$dbPath = if ($env:CCSWITCH_DB_PATH) { $env:CCSWITCH_DB_PATH } else { Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db' }
$stateRoot = Join-Path $dataRoot 'state'
$logPath = Join-Path $dataRoot 'logs\usage.jsonl'
$errorLogPath = Join-Path $dataRoot 'logs\errors.log'
$script:ConfigLoadError = $null
$script:HookPayloadParseError = $false

. (Join-Path $PSScriptRoot 'evaluator.ps1')

function Append-ErrorLog([string]$Detail) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $errorLogPath) | Out-Null
    [IO.File]::AppendAllText($errorLogPath, ('{0} {1}{2}' -f [DateTimeOffset]::Now.ToString('o'), $Detail, [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Read-Utf8Stdin {
    $stream = [Console]::OpenStandardInput(); $memory = New-Object IO.MemoryStream
    $buffer = New-Object byte[] 4096
    try { while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $memory.Write($buffer, 0, $count) }; return [Text.Encoding]::UTF8.GetString($memory.ToArray()) }
    finally { $memory.Dispose() }
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
        if ($null -ne $config.popup.max_visible -and [int]$config.popup.max_visible -lt 1) { throw 'Config popup max_visible must be positive' }
        if ($null -ne $config.popup.auto_close_seconds) {
            try { $autoClose = [int]$config.popup.auto_close_seconds } catch { throw 'Config popup auto_close_seconds must be an integer' }
            if ($autoClose -lt 1) { throw 'Config popup auto_close_seconds must be positive' }
        }
        return $config
    } catch {
        $script:ConfigLoadError = $_.Exception.Message
        try { Append-ErrorLog 'Config file rejected: invalid JSON or schema' } catch { }
        return ([IO.File]::ReadAllText($default, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
}

function Get-ReadOnlySqlRows([string]$Sql) {
    if (-not (Test-Path $dbPath)) { throw "CC Switch database not found: $dbPath" }
    $raw = @(& sqlite3 -readonly -json $dbPath $Sql 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($raw -join [Environment]::NewLine) }
    $text = $raw -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $parsed = $text | ConvertFrom-Json
    foreach ($item in @($parsed)) { Write-Output $item }
}

function Get-MarkerPath([string]$TurnId) { Join-Path $stateRoot (($TurnId -replace '[^A-Za-z0-9._-]', '_') + '.json') }

function Start-Turn([object]$Payload) {
    New-Item -ItemType Directory -Force $stateRoot | Out-Null
    $rows = @(Get-ReadOnlySqlRows "SELECT COALESCE(MAX(rowid), 0) AS max_rowid FROM proxy_request_logs WHERE app_type = 'codex' AND data_source = 'proxy';")
    $marker = [ordered]@{ session_id=[string]$Payload.session_id; turn_id=[string]$Payload.turn_id; cwd=[string]$Payload.cwd; start_rowid=[int64]$rows[0].max_rowid; started_at=[DateTimeOffset]::Now.ToString('o') }
    [IO.File]::WriteAllText((Get-MarkerPath $Payload.turn_id), ($marker | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Append-JsonLine([object]$Value, [string]$Path) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::AppendAllText($Path, (($Value | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function ConvertTo-EvaluatorContext([object]$Context) {
    $result = @{}
    foreach ($property in $Context.PSObject.Properties) { $result[$property.Name] = $property.Value }
    return $result
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
    } else {
        $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $startInfo.Arguments = '/d /s /c ' + (Get-NotifierCommand)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $process.Start() | Out-Null
        $json = $Payload | ConvertTo-Json -Compress -Depth 8
        $bytes = [Text.Encoding]::UTF8.GetBytes($json + [Environment]::NewLine)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
    } finally { $process.Dispose() }
}

function New-ErrorNotification([string]$Message) {
    return [ordered]@{ kind = 'error'; title = 'TokenNotifier'; message = $Message; items = @(); auto_close_seconds = 8; max_visible = 3 }
}

function Invoke-UsageNotification([object]$Config, [object]$Context) {
    $items = @()
    $evaluatorContext = ConvertTo-EvaluatorContext $Context
    foreach ($item in @($Config.items)) {
        $resolved = Resolve-DataItem $item $evaluatorContext
        $items += $resolved
        if ($resolved.PSObject.Properties.Name -contains 'error') {
            try { Append-ErrorLog 'Data item evaluation failed' } catch { }
        }
    }
    if ($script:ConfigLoadError) {
        $items += [pscustomobject]@{ label = 'Config error'; value = 'Using default config'; error = $script:ConfigLoadError }
    }
    $popup = $Config.popup
    $defaultTitle = 'TokenNotifier'
    if ([string]$Context.model -and [string]$Context.model -ne 'multiple') { $defaultTitle = 'TokenNotifier ' + [char]0x00B7 + ' ' + [string]$Context.model }
    $payload = [ordered]@{
        kind = 'usage'
        title = if ([string]::IsNullOrWhiteSpace([string]$Config.title)) { $defaultTitle } else { [string]$Config.title }
        items = $items
        auto_close_seconds = if ($null -eq $popup.auto_close_seconds) { 8 } else { [int]$popup.auto_close_seconds }
        max_visible = if ($null -eq $popup.max_visible) { 3 } else { [int]$popup.max_visible }
    }
    if ($Config.enabled -ne $false) { Invoke-DetachedNotifier $payload }
}

function Build-TurnContext([object[]]$Rows, [object]$Marker, [object]$Payload) {
    $sum = { param($Name) [decimal]$value = 0; foreach ($row in $Rows) { if ($null -ne $row.$Name -and $row.$Name -ne '') { $value += [decimal]::Parse([string]$row.$Name, [Globalization.CultureInfo]::InvariantCulture) } }; return $value }
    $intSum = { param($Name) $value = ($Rows | ForEach-Object { if ($null -ne $_.$Name -and $_.$Name -ne '') { [int64]$_.$Name } else { [int64]0 } } | Measure-Object -Sum).Sum; return [int64]$value }
    $durations = @($Rows | Where-Object { $null -ne $_.duration_ms -and $_.duration_ms -ne '' } | ForEach-Object { [int64]$_.duration_ms })
    $firstToken = @($Rows | Where-Object { $null -ne $_.first_token_ms -and $_.first_token_ms -ne '' } | Select-Object -First 1 | ForEach-Object { [int64]$_.first_token_ms })
    $models = @($Rows | ForEach-Object { [string]$_.model } | Select-Object -Unique)
    $providers = @($Rows | ForEach-Object { [string]$_.provider_id } | Select-Object -Unique)
    $statuses = @($Rows | ForEach-Object { if ($null -ne $_.status_code -and $_.status_code -ne '') { [int]$_.status_code } } | Select-Object -Unique)
    [pscustomobject]@{
        request_count = $Rows.Count; input_tokens = & $intSum 'input_tokens'; output_tokens = & $intSum 'output_tokens'; cache_read_tokens = & $intSum 'cache_read_tokens'; cache_creation_tokens = & $intSum 'cache_creation_tokens'
        input_cost_usd = & $sum 'input_cost_usd'; output_cost_usd = & $sum 'output_cost_usd'; cache_read_cost_usd = & $sum 'cache_read_cost_usd'; cache_creation_cost_usd = & $sum 'cache_creation_cost_usd'; total_cost_usd = & $sum 'total_cost_usd'
        duration_ms_total = if ($durations.Count) { [int64](($durations | Measure-Object -Sum).Sum) } else { $null }; duration_ms_max = if ($durations.Count) { [int64](($durations | Measure-Object -Maximum).Maximum) } else { $null }; first_token_ms_first = if ($firstToken.Count) { $firstToken[0] } else { $null }
        model = if ($models.Count -eq 1) { $models[0] } else { 'multiple' }; provider_id = if ($providers.Count -eq 1) { $providers[0] } else { 'multiple' }; status_code = if ($statuses.Count -eq 1) { $statuses[0] } else { 'multiple' }
        codex_session_id = [string]$Marker.session_id; codex_turn_id = [string]$Marker.turn_id; codex_cwd = [string]$Marker.cwd
    }
}

function Complete-Turn([object]$Payload) {
    $markerPath = Get-MarkerPath $Payload.turn_id
    if (-not (Test-Path $markerPath)) { throw "Turn marker not found: $markerPath" }
    $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $delay = if ($env:CCSWITCH_SETTLE_DELAY_MS) { [int]$env:CCSWITCH_SETTLE_DELAY_MS } else { 750 }; if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    $sql = "SELECT rowid,request_id,provider_id,provider_type,model,request_model,pricing_model,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,cache_creation_cost_usd,total_cost_usd,cost_multiplier,latency_ms,first_token_ms,duration_ms,status_code,error_message,session_id,is_streaming,created_at,data_source FROM proxy_request_logs WHERE rowid > $([int64]$marker.start_rowid) AND app_type = 'codex' AND data_source = 'proxy' ORDER BY rowid;"
    $rows = @(Get-ReadOnlySqlRows $sql); $context = Build-TurnContext $rows $marker $Payload
    foreach ($row in $rows) {
        Append-JsonLine ([ordered]@{ type='ccswitch_request'; logged_at=[DateTimeOffset]::Now.ToString('o'); codex_session_id=[string]$marker.session_id; codex_turn_id=[string]$marker.turn_id; codex_cwd=[string]$marker.cwd; rowid=[int64]$row.rowid; request_id=[string]$row.request_id; provider_id=[string]$row.provider_id; provider_type=[string]$row.provider_type; model=[string]$row.model; request_model=[string]$row.request_model; pricing_model=[string]$row.pricing_model; input_tokens=[int64]$row.input_tokens; output_tokens=[int64]$row.output_tokens; cache_read_tokens=[int64]$row.cache_read_tokens; cache_creation_tokens=[int64]$row.cache_creation_tokens; input_cost_usd=[string]$row.input_cost_usd; output_cost_usd=[string]$row.output_cost_usd; cache_read_cost_usd=[string]$row.cache_read_cost_usd; cache_creation_cost_usd=[string]$row.cache_creation_cost_usd; total_cost_usd=[string]$row.total_cost_usd; cost_multiplier=[string]$row.cost_multiplier; latency_ms=$row.latency_ms; first_token_ms=$row.first_token_ms; duration_ms=$row.duration_ms; status_code=[int]$row.status_code; error_message=$row.error_message; ccswitch_session_id=[string]$row.session_id; is_streaming=([int]$row.is_streaming -eq 1); created_at_unix=[int64]$row.created_at }) $logPath
    }
    $summary = [ordered]@{ type='turn_summary'; logged_at=[DateTimeOffset]::Now.ToString('o'); codex_session_id=$context.codex_session_id; codex_turn_id=$context.codex_turn_id; codex_cwd=$context.codex_cwd; request_count=$context.request_count; input_tokens=$context.input_tokens; output_tokens=$context.output_tokens; cache_read_tokens=$context.cache_read_tokens; cache_creation_tokens=$context.cache_creation_tokens; input_cost_usd=$context.input_cost_usd.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture); output_cost_usd=$context.output_cost_usd.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture); cache_read_cost_usd=$context.cache_read_cost_usd.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture); cache_creation_cost_usd=$context.cache_creation_cost_usd.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture); total_cost_usd=$context.total_cost_usd.ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture); duration_ms_total=$context.duration_ms_total; duration_ms_max=$context.duration_ms_max; first_token_ms_first=$context.first_token_ms_first; model=$context.model; provider_id=$context.provider_id; status_code=$context.status_code }
    Append-JsonLine $summary $logPath
    Remove-Item -LiteralPath $markerPath -Force
    $config = Get-Config
    Invoke-UsageNotification $config $context
}

try {
    $inputText = Read-Utf8Stdin
    if ([string]::IsNullOrWhiteSpace($inputText)) { exit 0 }
    try { $payload = $inputText | ConvertFrom-Json } catch { $script:HookPayloadParseError = $true; throw 'Hook payload JSON is invalid' }
    switch ([string]$payload.hook_event_name) { 'UserPromptSubmit' { Start-Turn $payload }; 'Stop' { Complete-Turn $payload } }
}
catch {
    try {
        if ($script:HookPayloadParseError) { Append-ErrorLog 'Hook payload rejected: invalid JSON' } else { Append-ErrorLog $_.Exception.ToString() }
    } catch { }
    try { Invoke-DetachedNotifier (New-ErrorNotification 'Unable to collect API usage data.') } catch { }
    exit 0
}
