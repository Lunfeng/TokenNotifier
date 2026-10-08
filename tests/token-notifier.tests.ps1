param(
    [ValidateSet('All', 'Package', 'Config', 'Evaluator', 'ToastXml', 'Registration', 'Attribution', 'Collector')]
    [string]$Case = 'All'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message. Expected=[$Expected] Actual=[$Actual]" }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function From-Codes([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }

function Wait-ForPath([string]$Path, [int]$TimeoutMilliseconds = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    return Test-Path -LiteralPath $Path
}

function Invoke-CollectorProcess([string]$ScriptPath, [string]$Json) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $process.Start() | Out-Null
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json + [Environment]::NewLine)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode=$process.ExitCode; Stdout=$stdout; Stderr=$stderr }
    } finally { $process.Dispose() }
}

function Add-TurnContext {
    param([string]$Path, [string]$TurnId, [string]$RootTurnId, [string]$Model)
    $record = [ordered]@{
        type = 'turn_context'
        payload = [ordered]@{ turn_id=$TurnId; root_turn_id=$RootTurnId; model=$Model }
    }
    [IO.File]::AppendAllText($Path, (($record | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Add-UsageRecord {
    param(
        [string]$Path,
        [string]$TurnId,
        [string]$RootTurnId,
        [string]$ResponseId,
        [int64]$InputTokens,
        [int64]$OutputTokens,
        [int64]$CachedInputTokens = 0,
        [int64]$CacheWriteInputTokens = 0,
        [int64]$ReasoningOutputTokens = 0,
        [int64]$ThreadInputTokens = -1,
        [int64]$ThreadCachedInputTokens = -1,
        [int64]$ThreadCacheWriteInputTokens = -1,
        [int64]$ThreadOutputTokens = -1,
        [int64]$ThreadReasoningOutputTokens = -1,
        [int64]$ThreadTotalTokens = -1
    )
    $threadInput = if ($ThreadInputTokens -ge 0) { $ThreadInputTokens } else { $InputTokens }
    $threadCached = if ($ThreadCachedInputTokens -ge 0) { $ThreadCachedInputTokens } else { $CachedInputTokens }
    $threadCacheWrite = if ($ThreadCacheWriteInputTokens -ge 0) { $ThreadCacheWriteInputTokens } else { $CacheWriteInputTokens }
    $threadOutput = if ($ThreadOutputTokens -ge 0) { $ThreadOutputTokens } else { $OutputTokens }
    $threadReasoning = if ($ThreadReasoningOutputTokens -ge 0) { $ThreadReasoningOutputTokens } else { $ReasoningOutputTokens }
    $threadTotal = if ($ThreadTotalTokens -ge 0) { $ThreadTotalTokens } else { $threadInput + $threadOutput }
    $turnTotal = $InputTokens + $OutputTokens
    $record = [ordered]@{
        type = 'token_usage_record'
        payload = [ordered]@{
            thread_id = 'thread-fixture'
            session_id = 'thread-fixture'
            turn_id = $TurnId
            root_turn_id = $RootTurnId
            response_id = $ResponseId
            usage = [ordered]@{
                input_tokens = $InputTokens
                cached_input_tokens = $CachedInputTokens
                cache_write_input_tokens = $CacheWriteInputTokens
                output_tokens = $OutputTokens
                reasoning_output_tokens = $ReasoningOutputTokens
                total_tokens = $turnTotal
            }
            turn_token_usage = [ordered]@{
                input_tokens = $InputTokens
                cached_input_tokens = $CachedInputTokens
                cache_write_input_tokens = $CacheWriteInputTokens
                output_tokens = $OutputTokens
                reasoning_output_tokens = $ReasoningOutputTokens
                total_tokens = $turnTotal
            }
            thread_token_usage = [ordered]@{
                input_tokens = $threadInput
                cached_input_tokens = $threadCached
                cache_write_input_tokens = $threadCacheWrite
                output_tokens = $threadOutput
                reasoning_output_tokens = $threadReasoning
                total_tokens = $threadTotal
            }
        }
    }
    [IO.File]::AppendAllText($Path, (($record | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Test-Package {
    $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot '.codex-plugin\plugin.json') | ConvertFrom-Json
    Assert-Equal '0.4.0' $manifest.version 'Rollout pricing release version must be 0.4.0'
    Assert-True (-not ($manifest.description -match 'CC Switch|CCSwitch')) 'Manifest must not describe CC Switch'
    Assert-True (-not (($manifest.keywords -join ' ') -match 'cc-switch|ccswitch')) 'Manifest must not advertise CC Switch'
    $iconPath = Join-Path $repoRoot 'assets\token-notifier.ico'
    Assert-True (Test-Path $iconPath) 'Toast icon must be packaged'
    $iconBytes = [IO.File]::ReadAllBytes($iconPath)
    Assert-Equal 6 ([BitConverter]::ToUInt16($iconBytes, 4)) 'Toast icon must contain six size frames'
    $readme = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'README.md')
    Assert-True $readme.Contains('pricing') 'README must document pricing configuration'
    Assert-True (-not ($readme -match 'CC Switch|CCSwitch|sqlite3')) 'README must not require CC Switch or SQLite'
    $collectorText = Get-Content -Raw (Join-Path $repoRoot 'scripts\collector.ps1')
    Assert-True (-not ($collectorText -match 'CCSWITCH|ccswitch|sqlite3|proxy_request_logs')) 'Collector must not contain CC Switch operations'
}

function Test-Config {
    . (Join-Path $repoRoot 'scripts\collector.ps1')
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{})) 'Missing Toast config must default to short'
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'short' } })) 'Short duration must pass through'
    Assert-Equal 'long' (Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'long' } })) 'Long duration must pass through'
    Assert-Throws { Get-ToastDuration ([pscustomobject]@{ toast = 'short' }) } 'Toast config must be an object'
    $valid = [pscustomobject]@{ pricing=[pscustomobject]@{ unit='per_million_tokens'; currency='USD'; models=[pscustomobject]@{ 'gpt-test'=[pscustomobject]@{ input=2.5; cache_read=0.25; cache_creation=0; output=15 } } } }
    Assert-Equal 'gpt-test' ((Get-PricingConfig $valid).models.PSObject.Properties | Select-Object -First 1).Name 'Pricing model must load'
    Assert-Throws { Get-PricingConfig ([pscustomobject]@{ pricing=[pscustomobject]@{ unit='per_token' } }) } 'Unknown pricing unit must fail'
    $defaults = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'config\default-config.json') | ConvertFrom-Json
    Assert-Equal 'short' $defaults.toast.duration 'Packaged default must use a short Toast'
    Assert-Equal 'per_million_tokens' $defaults.pricing.unit 'Packaged default must define pricing units'
    Assert-Equal 6 @($defaults.items).Count 'Default item order must include session totals'
    Assert-Equal 'session_total_tokens' $defaults.items[4].field 'Default config must expose session total tokens'
    Assert-Equal 'session_total_cost_usd' $defaults.items[5].field 'Default config must expose session total cost'
}

function Test-Evaluator {
    . (Join-Path $repoRoot 'scripts\evaluator.ps1')
    $context = @{ input_tokens=1000; output_tokens=200; session_total_tokens=5000; total_cost_usd=[decimal]'0.25'; duration_ms_total=1250 }
    Assert-Equal 1000 (Evaluate-Expression 'input_tokens' $context) 'Direct field lookup must work'
    Assert-Equal 1200 (Evaluate-Expression 'input_tokens + output_tokens' $context) 'Addition must work'
    Assert-Equal 5000 (Evaluate-Expression 'session_total_tokens' $context) 'Session total token field must be evaluable'
    Assert-Equal 20 (Evaluate-Expression 'output_tokens / input_tokens * 100' $context) 'Precedence must work'
    Assert-Equal '--' (Resolve-DataItem ([pscustomobject]@{label='Bad';expression='input_tokens / 0';format='decimal'}) $context).value 'Failed item must render as --'
    Assert-Equal '1,200' (Format-DisplayValue 1200 'integer') 'Integer format must remain stable'
    Assert-Equal '$0.25' (Format-DisplayValue ([decimal]'0.25') 'currency_usd') 'Currency format must remain stable'
    Assert-Equal '1,250 ms' (Format-DisplayValue 1250 'milliseconds') 'Milliseconds format must remain stable'
}

function Test-ToastXml {
    . (Join-Path $repoRoot 'scripts\notifier.ps1')
    $items = @(
        [pscustomobject]@{ label='费用'; value='$0.01' },
        [pscustomobject]@{ label='Input Token'; value='1,000' },
        [pscustomobject]@{ label='Output Token'; value='200' }
    )
    $xml = New-ToastXml (ConvertTo-NotificationPayload ([pscustomobject]@{kind='usage';title='TokenNotifier';items=$items;duration='long'}))
    Assert-Equal 'long' $xml.DocumentElement.GetAttribute('duration') 'Toast duration must be emitted'
    Assert-Equal 3 @($xml.SelectNodes('/toast/visual/binding/group')).Count 'Every configured item must become a group'
    Assert-True ($null -eq $xml.SelectSingleNode('/toast/actions')) 'Toast must not define actions'
    $notifierText = Get-Content -Raw (Join-Path $repoRoot 'scripts\notifier.ps1')
    Assert-True ($notifierText -match 'Windows\.UI\.Notifications\.ToastNotificationManager') 'Notifier must use the native Toast API'
}

function Test-Registration {
    . (Join-Path $repoRoot 'scripts\toast-registration.ps1')
    Assert-Equal 'Lunfeng.TokenNotifier' $script:TokenNotifierAppId 'AUMID must remain stable'
}

function Test-Attribution {
    . (Join-Path $repoRoot 'scripts\attribution.ps1')
    $testRoot = Join-Path $env:TEMP ('token-notifier-attribution-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $testRoot | Out-Null
    try {
        $transcript = Join-Path $testRoot 'rollout.jsonl'
        [IO.File]::WriteAllText($transcript, '{"type":"session_meta"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $offset = [int64](Get-Item -LiteralPath $transcript).Length
        Add-TurnContext $transcript 'turn-a' 'turn-a' 'gpt-test'
        Add-UsageRecord $transcript 'turn-a' 'turn-a' 'resp-a' 1000 200 100 10 -ReasoningOutputTokens 20 -ThreadInputTokens 4000 -ThreadCachedInputTokens 1000 -ThreadCacheWriteInputTokens 100 -ThreadOutputTokens 400 -ThreadReasoningOutputTokens 40 -ThreadTotalTokens 5000
        Add-TurnContext $transcript 'turn-child' 'turn-a' 'gpt-child'
        Add-UsageRecord $transcript 'turn-child' 'turn-a' 'resp-child' 500 50 50 0 -ReasoningOutputTokens 30 -ThreadInputTokens 6000 -ThreadCachedInputTokens 1500 -ThreadCacheWriteInputTokens 200 -ThreadOutputTokens 300 -ThreadReasoningOutputTokens 60 -ThreadTotalTokens 6500
        Add-UsageRecord $transcript 'turn-b' 'turn-b' 'resp-other' 900 90
        $actual = @(Read-TurnUsageRecords $transcript 'turn-a' $offset)
        Assert-Equal 2 $actual.Count 'Root and child usage must be selected'
        Assert-Equal 'gpt-test' $actual[0].model 'Usage record must inherit model from turn context'
        Assert-Equal 'gpt-child' $actual[1].model 'Child usage must retain its own model'
        Assert-Equal 5000 $actual[0].thread_total_tokens 'Rollout thread total must survive projection'
        Assert-Equal 6500 (Get-SessionTotalTokens $actual) 'Session total must use the latest cumulative rollout value'
        Assert-Equal 1500 ((Measure-ProjectedTokens $actual).input_tokens) 'Projected input aggregation must work'
        $projected = Measure-ProjectedTokens $actual
        Assert-Equal 250 $projected.output_tokens 'Projected output aggregation must work'
        Assert-Equal 150 $projected.cache_read_tokens 'Projected cache-read aggregation must work'
        Assert-Equal 10 $projected.cache_creation_tokens 'Projected cache-write aggregation must work'
        Assert-Equal 50 $projected.reasoning_output_tokens 'Projected reasoning aggregation must work'
        Assert-Equal 1750 $projected.total_tokens 'Projected total aggregation must work'
        $sessionTokens = Get-SessionTokenTotals $actual
        Assert-Equal 6000 $sessionTokens.input_tokens 'Session input total must use rollout thread usage'
        Assert-Equal 1500 $sessionTokens.cache_read_tokens 'Session cache-read total must use rollout thread usage'
        Assert-Equal 200 $sessionTokens.cache_creation_tokens 'Session cache-write total must use rollout thread usage'
        Assert-Equal 300 $sessionTokens.output_tokens 'Session output total must use rollout thread usage'
        Assert-Equal 60 $sessionTokens.reasoning_output_tokens 'Session reasoning total must use rollout thread usage'
        $pricing = [pscustomobject]@{ unit='per_million_tokens'; currency='USD'; models=[pscustomobject]@{ 'gpt-test'=[pscustomobject]@{ input=2.5; cache_read=0.25; cache_creation=1; output=15 }; 'gpt-child'=[pscustomobject]@{ input=2.5; cache_read=0.25; cache_creation=1; output=15 } } }
        $cost = Get-UsageCost $actual $pricing
        Assert-Equal 'exact' $cost.status 'Configured model must produce exact pricing status'
        Assert-Equal ([decimal]'0.0071475') $cost.total_cost_usd 'Token costs must exclude cached input from ordinary input pricing'
        $unknown = [pscustomobject]@{ response_id='x'; model='gpt-unknown'; input_tokens=1; output_tokens=1; cache_read_tokens=0; cache_creation_tokens=0 }
        $partialCost = Get-UsageCost @($unknown) $pricing
        Assert-Equal 'partial' $partialCost.status 'Unknown model must produce partial pricing status'
        Assert-True ($null -eq $partialCost.total_cost_usd) 'Partial pricing must not display a misleading total'
        $partialMessage = (From-Codes @(0x90e8,0x5206,0x6570,0x636e,0xff1a)) + '1 ' + (From-Codes @(0x4e2a,0x6a21,0x578b,0x7f3a,0x5c11,0x4ef7,0x683c,0x914d,0x7f6e,0x3002))
        Assert-Equal $partialMessage (Get-AttributionMessage 'completed' 'partial' 1) 'Missing price message must be explicit'
        Assert-Equal (From-Codes @(0x4efb,0x52a1,0x5df2,0x4e2d,0x65ad,0x3002)) (Get-AttributionMessage 'interrupted' 'exact' 0) 'Interrupted message must remain explicit'
    } finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-Collector {
    $testRoot = Join-Path $env:TEMP ('token-notifier-collector-' + [guid]::NewGuid().ToString('N'))
    $configPath = Join-Path $testRoot 'config.json'
    $capturePath = Join-Path $testRoot 'notification.json'
    $transcriptPath = Join-Path $testRoot 'rollout.jsonl'
    New-Item -ItemType Directory -Force $testRoot | Out-Null
    try {
        [IO.File]::WriteAllText($transcriptPath, '{"type":"session_meta"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $config = [ordered]@{
            enabled=$true
            toast=[ordered]@{duration='long'}
            pricing=[ordered]@{unit='per_million_tokens';currency='USD';models=[ordered]@{ 'gpt-test'=[ordered]@{input=2.5;cache_read=0.25;cache_creation=1;output=15} }}
            items=@(
                [ordered]@{label='Cost';field='total_cost_usd';format='currency_usd'},
                [ordered]@{label='Input';field='input_tokens';format='integer'},
                [ordered]@{label='Output';field='output_tokens';format='integer'},
                [ordered]@{label='Model';field='model';format='text'},
                [ordered]@{label='Session total';field='session_total_tokens';format='integer'},
                [ordered]@{label='Session cost';field='session_total_cost_usd';format='currency_usd'}
            )
        }
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $captureScript = Join-Path $repoRoot 'tests\capture-notifier.ps1'
        $env:TOKENNOTIFIER_DATA_ROOT = $testRoot
        $env:TOKENNOTIFIER_CONFIG_PATH = $configPath
        $env:TOKENNOTIFIER_NOTIFIER_COMMAND = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $captureScript + '" -OutputPath "' + $capturePath + '"'
        $env:USERPROFILE = $testRoot
        New-Item -ItemType Directory -Force (Join-Path $testRoot '.codex') | Out-Null
        [IO.File]::WriteAllText((Join-Path $testRoot '.codex\session_index.jsonl'), '{"id":"session-a","thread_name":"Rollout task"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $collector = Join-Path $repoRoot 'scripts\collector.ps1'
        $start = @{hook_event_name='UserPromptSubmit';session_id='session-a';turn_id='turn-a';cwd='C:\work';transcript_path=$transcriptPath} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $start).ExitCode 'Start Hook must succeed without a database'
        Add-TurnContext $transcriptPath 'turn-a' 'turn-a' 'gpt-test'
        Add-UsageRecord $transcriptPath 'turn-a' 'turn-a' 'resp-a' 1000 200 100 10 -ThreadTotalTokens 12345
        $stop = @{hook_event_name='Stop';session_id='session-a';turn_id='turn-a';cwd='C:\work';transcript_path=$transcriptPath} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $stop).ExitCode 'Stop Hook must succeed without a database'
        Assert-True (Wait-ForPath $capturePath) 'Detached notifier payload must be captured'
        $payload = Get-Content -Raw -Encoding UTF8 $capturePath | ConvertFrom-Json
        Assert-Equal '$0.00526' $payload.items[0].value 'Calculated cost must reach notifier'
        Assert-Equal '1,000' $payload.items[1].value 'Input tokens must reach notifier'
        Assert-Equal 'gpt-test' $payload.items[3].value 'Rollout model must reach notifier'
        Assert-Equal '12,345' $payload.items[4].value 'Session total tokens must reach notifier'
        Assert-Equal '$0.00526' $payload.items[5].value 'Session cost must reach notifier'
        $rootTranscript = Join-Path $testRoot 'root-rollout.jsonl'
        $agentTranscript = Join-Path $testRoot 'agent-rollout.jsonl'
        [IO.File]::WriteAllText($rootTranscript, '{"type":"session_meta"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($agentTranscript, '{"type":"session_meta"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $rootStart = @{hook_event_name='UserPromptSubmit';session_id='session-root';turn_id='root-turn';cwd='C:\work';transcript_path=$rootTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $rootStart).ExitCode 'Root start must succeed'
        Add-TurnContext $rootTranscript 'root-turn' 'root-turn' 'gpt-test'
        Add-UsageRecord $rootTranscript 'root-turn' 'root-turn' 'resp-root' 100 10
        Add-TurnContext $agentTranscript 'child-turn' 'root-turn' 'gpt-test'
        Add-UsageRecord $agentTranscript 'child-turn' 'root-turn' 'resp-child' 200 20
        $subagentStop = @{hook_event_name='SubagentStop';session_id='session-root';turn_id='child-turn';agent_id='agent-1';agent_transcript_path=$agentTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $subagentStop).ExitCode 'Subagent stop must succeed'
        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $rootStop = @{hook_event_name='Stop';session_id='session-root';turn_id='root-turn';cwd='C:\work';transcript_path=$rootTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $rootStop).ExitCode 'Root stop must succeed'
        Assert-True (Wait-ForPath $capturePath) 'Aggregated root notification must be captured'
        $rootPayload = Get-Content -Raw -Encoding UTF8 $capturePath | ConvertFrom-Json
        Assert-Equal '300' $rootPayload.items[1].value 'Subagent input must be aggregated once'
        $logText = Get-Content -Raw -Encoding UTF8 (Join-Path $testRoot 'logs\usage.jsonl')
        Assert-True (-not ($logText -match 'ccswitch|proxy_request_logs|secret')) 'Runtime log must not contain CC Switch or secret data'
    } finally {
        Remove-Item Env:TOKENNOTIFIER_DATA_ROOT -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_NOTIFIER_COMMAND -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Case -in @('All', 'Package')) { Test-Package; Write-Output 'PASS: Package' }
if ($Case -in @('All', 'Config')) { Test-Config; Write-Output 'PASS: Config' }
if ($Case -in @('All', 'Evaluator')) { Test-Evaluator; Write-Output 'PASS: Evaluator' }
if ($Case -in @('All', 'ToastXml')) { Test-ToastXml; Write-Output 'PASS: ToastXml' }
if ($Case -in @('All', 'Registration')) { Test-Registration; Write-Output 'PASS: Registration' }
if ($Case -in @('All', 'Attribution')) { Test-Attribution; Write-Output 'PASS: Attribution' }
if ($Case -in @('All', 'Collector')) { Test-Collector; Write-Output 'PASS: Collector' }
