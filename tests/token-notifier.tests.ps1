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

function Wait-ForPath([string]$Path, [int]$TimeoutMilliseconds = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    return Test-Path -LiteralPath $Path
}

function Test-Package {
    $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot '.codex-plugin\plugin.json') | ConvertFrom-Json
    Assert-Equal '0.2.0' $manifest.version 'Toast release version must be 0.2.0'
    $iconPath = Join-Path $repoRoot 'assets\token-notifier.ico'
    Assert-True (Test-Path $iconPath) 'Toast icon must be packaged'
    $iconBytes = [IO.File]::ReadAllBytes($iconPath)
    Assert-Equal 6 ([BitConverter]::ToUInt16($iconBytes, 4)) 'Toast icon must contain six size frames'
    Assert-True (Test-Path (Join-Path $repoRoot 'scripts\unregister-toast.ps1')) 'Toast cleanup script must be packaged'
    $readme = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'README.md')
    Assert-True $readme.Contains('Lunfeng.TokenNotifier') 'README must document the AUMID'
    Assert-True $readme.Contains('"duration": "short"') 'README must document Toast duration'
    Assert-True $readme.Contains('unregister-toast.ps1') 'README must document cleanup'
    Assert-True $readme.Contains('Windows may truncate') 'README must disclose Toast truncation'
    $hooks = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'hooks\hooks.json') | ConvertFrom-Json
    Assert-Equal 1 @($hooks.hooks.UserPromptSubmit).Count 'UserPromptSubmit Hook must exist'
    Assert-Equal 1 @($hooks.hooks.SubagentStop).Count 'SubagentStop Hook must exist'
    Assert-Equal 1 @($hooks.hooks.Stop).Count 'Stop Hook must exist'
    Assert-Equal 1 @($hooks.hooks.Interrupt).Count 'Interrupt Hook must exist'
    Assert-Equal 5 ([int]$hooks.hooks.SubagentStop[0].hooks[0].timeout) 'SubagentStop Hook must be bounded'
    Assert-Equal 10 ([int]$hooks.hooks.Interrupt[0].hooks[0].timeout) 'Interrupt Hook needs collection time'
}

function Test-Config {
    . (Join-Path $repoRoot 'scripts\collector.ps1')
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{})) 'Missing Toast config must default to short'
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'short' } })) 'Short duration must pass through'
    Assert-Equal 'long' (Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'long' } })) 'Long duration must pass through'
    Assert-Equal 'long' (Get-ToastDuration ([pscustomobject]@{ popup = [pscustomobject]@{ auto_close_seconds = 10 } })) 'Legacy ten-second popup must map to long'
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{ popup = [pscustomobject]@{ auto_close_seconds = 8 } })) 'Legacy short popup must map to short'
    Assert-Throws { Get-ToastDuration ([pscustomobject]@{ toast = 'short' }) } 'Toast config must be an object'
    Assert-Throws { Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'forever' } }) } 'Unknown duration must fail'
    $defaults = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'config\default-config.json') | ConvertFrom-Json
    Assert-Equal 'short' $defaults.toast.duration 'Packaged default must use a short Toast'
    Assert-True ($null -eq $defaults.popup) 'Packaged default must not expose obsolete popup settings'
    Assert-Equal 4 @($defaults.items).Count 'Default items must remain unchanged'
}

function Test-Evaluator {
    . (Join-Path $repoRoot 'scripts\evaluator.ps1')
    $context = @{ input_tokens=1000; output_tokens=200; total_cost_usd=[decimal]'0.25'; duration_ms_total=1250 }
    Assert-Equal 1000 (Evaluate-Expression 'input_tokens' $context) 'Direct field lookup must work'
    Assert-Equal 1200 (Evaluate-Expression 'input_tokens + output_tokens' $context) 'Addition must work'
    Assert-Equal 20 (Evaluate-Expression 'output_tokens / input_tokens * 100' $context) 'Precedence must work'
    Assert-Equal 600 (Evaluate-Expression '(input_tokens + output_tokens) / 2' $context) 'Parentheses must work'
    Assert-Equal 3 (Evaluate-Expression 'round(2.6)' $context) 'round must work'
    Assert-Equal 4 (Evaluate-Expression 'max(2, min(4, 7))' $context) 'Functions must compose'
    Assert-Equal 4 (Evaluate-Expression 'abs(-4)' $context) 'abs must work'
    Assert-Equal $true (Evaluate-Expression 'output_tokens < input_tokens' $context) 'Comparison must work'
    Assert-Throws { Evaluate-Expression 'input_tokens / 0' $context } 'Division by zero must fail'
    Assert-Throws { Evaluate-Expression 'unknown_field + 1' $context } 'Unknown fields must fail'
    Assert-Throws { Evaluate-Expression 'Invoke-Expression(1)' $context } 'Executable syntax must fail'
    Assert-Equal '--' (Resolve-DataItem ([pscustomobject]@{label='Bad';expression='input_tokens / 0';format='decimal'}) $context).value 'Failed item must render as --'
    Assert-Equal '1,200' (Format-DisplayValue 1200 'integer') 'Integer format must remain stable'
    Assert-Equal '$0.25' (Format-DisplayValue ([decimal]'0.25') 'currency_usd') 'Currency format must remain stable'
    Assert-Equal '25%' (Format-DisplayValue ([decimal]'0.25') 'percent') 'Percent format must remain stable'
    Assert-Equal '1,250 ms' (Format-DisplayValue 1250 'milliseconds') 'Milliseconds format must remain stable'
}

function Test-ToastXml {
    . (Join-Path $repoRoot 'scripts\notifier.ps1')
    $unicodeLabel = ([string][char]0x8D39) + [char]0x7528
    $items = @(
        [pscustomobject]@{ label=($unicodeLabel + ' & tax'); value='<$0.01>' },
        [pscustomobject]@{ label='Input Token'; value='1,000' },
        [pscustomobject]@{ label='Output Token'; value='200' },
        [pscustomobject]@{ label='Total Token'; value='1,200' },
        [pscustomobject]@{ label='Requests'; value='1' },
        [pscustomobject]@{ label='Duration'; value='900 ms' },
        [pscustomobject]@{ label='Provider'; value='A > B' }
    )
    $data = ConvertTo-NotificationPayload ([pscustomobject]@{kind='usage';title='TokenNotifier model';items=$items;duration='long'})
    $xml = New-ToastXml $data
    Assert-Equal 'long' $xml.DocumentElement.GetAttribute('duration') 'Toast duration must be emitted'
    Assert-Equal 7 @($xml.SelectNodes('/toast/visual/binding/group')).Count 'Every configured item must become a group'
    Assert-Equal ($unicodeLabel + ' & tax') $xml.SelectSingleNode('/toast/visual/binding/group[1]/subgroup[1]/text').InnerText 'Labels must be XML-safe'
    Assert-Equal '<$0.01>' $xml.SelectSingleNode('/toast/visual/binding/group[1]/subgroup[2]/text').InnerText 'Values must be XML-safe'
    Assert-Equal 'right' $xml.SelectSingleNode('/toast/visual/binding/group[1]/subgroup[2]/text').GetAttribute('hint-align') 'Values must align right'
    Assert-True ($null -eq $xml.SelectSingleNode('/toast/actions')) 'Toast must not define actions'
    Assert-True (-not $xml.DocumentElement.HasAttribute('launch')) 'Toast must not define activation arguments'
    $errorXml = New-ToastXml (ConvertTo-NotificationPayload ([pscustomobject]@{kind='error';title='TokenNotifier';items=@();message='Unable <now>';duration='short'}))
    Assert-Equal 'Unable <now>' $errorXml.SelectSingleNode('/toast/visual/binding/text[2]').InnerText 'Error message must be retained'
    Assert-Throws { ConvertTo-NotificationPayload ([pscustomobject]@{kind='usage';title='x';items=@();duration='forever'}) } 'Unknown duration must fail'
    $notifierText = Get-Content -Raw (Join-Path $repoRoot 'scripts\notifier.ps1')
    Assert-True ($notifierText -match 'Windows\.UI\.Notifications\.ToastNotificationManager') 'Notifier must use the native Toast API'
    Assert-True ($notifierText -notmatch 'PresentationFramework|System\.Windows\.Window|ShowDialog|NotifyIcon') 'Notifier must not retain WPF or tray UI'
    Assert-True ($notifierText -notmatch 'Add_Activated|activationType|<actions') 'Notifier must not handle Toast clicks'
}

function Test-Registration {
    . (Join-Path $repoRoot 'scripts\toast-registration.ps1')
    Assert-Equal 'Lunfeng.TokenNotifier' $script:TokenNotifierAppId 'AUMID must remain stable'
    $testRoot = Join-Path $env:TEMP ('token-notifier-registration-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $testRoot | Out-Null
    try {
        $notifier = Join-Path $repoRoot 'scripts\notifier.ps1'
        $icon = Join-Path $repoRoot 'assets\token-notifier.ico'
        Initialize-ToastRegistration -NotifierPath $notifier -IconPath $icon -StartMenuRoot $testRoot -SkipRegistry
        $shortcut = Join-Path $testRoot 'TokenNotifier.lnk'
        Assert-True (Test-Path $shortcut) 'Registration must create a shortcut'
        Assert-Equal 'Lunfeng.TokenNotifier' ([TokenNotifier.ShellIntegration]::GetShortcutAppId($shortcut)) 'Shortcut must carry the AUMID'
        $firstWrite = (Get-Item $shortcut).LastWriteTimeUtc
        Start-Sleep -Milliseconds 20
        Initialize-ToastRegistration -NotifierPath $notifier -IconPath $icon -StartMenuRoot $testRoot -SkipRegistry
        Assert-Equal $firstWrite (Get-Item $shortcut).LastWriteTimeUtc 'Registration must be idempotent'
        Remove-ToastRegistration -StartMenuRoot $testRoot -SkipRegistry
        Assert-True (-not (Test-Path $shortcut)) 'Cleanup must remove the shortcut'
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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

function Add-UsageRecord {
    param(
        [string]$Path,
        [string]$TurnId,
        [string]$RootTurnId,
        [string]$ResponseId,
        [int64]$InputTokens,
        [int64]$OutputTokens,
        [int64]$CachedInputTokens = 0,
        [int64]$CacheWriteInputTokens = 0
    )
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
                reasoning_output_tokens = 0
                total_tokens = $InputTokens + $OutputTokens
            }
        }
    }
    [IO.File]::AppendAllText($Path, (($record | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Test-Attribution {
    . (Join-Path $repoRoot 'scripts\attribution.ps1')
    $testRoot = Join-Path $env:TEMP ('token-notifier-attribution-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $testRoot | Out-Null
    try {
        $transcript = Join-Path $testRoot 'rollout.jsonl'
        $prefix = '{"type":"response_item","payload":{"type":"message","content":"secret prompt"}}' + [Environment]::NewLine
        [IO.File]::WriteAllText($transcript, $prefix, [Text.UTF8Encoding]::new($false))
        $offset = [int64](Get-Item -LiteralPath $transcript).Length
        Add-UsageRecord $transcript 'turn-a' 'turn-a' 'resp_root' 10 2 3 1
        Add-UsageRecord $transcript 'turn-child' 'turn-a' 'resp_child' 20 4 5 0
        Add-UsageRecord $transcript 'turn-b' 'turn-b' 'resp_other' 30 6 0 0
        [IO.File]::AppendAllText($transcript, "not-json`r`n", [Text.UTF8Encoding]::new($false))

        Assert-True ((Get-TranscriptLength $transcript) -gt $offset) 'Transcript length helper must observe appended records'
        $actual = @(Read-TurnUsageRecords $transcript 'turn-a' $offset)
        Assert-Equal 2 $actual.Count 'Root and child usage must be selected'
        Assert-Equal 'resp_root' $actual[0].response_id 'Root response id must survive projection'
        Assert-Equal 'resp_child' $actual[1].response_id 'Child response id must survive projection'
        Assert-Equal 30 (($actual | Measure-Object input_tokens -Sum).Sum) 'Projected input tokens must sum'
        Assert-True (-not (($actual | ConvertTo-Json -Depth 6) -match 'secret prompt')) 'Message text must not enter projections'

        $deduplicated = @(Select-UniqueUsageRecords @($actual[0], $actual[0], $actual[1]))
        Assert-Equal 2 $deduplicated.Count 'Response ids must deduplicate'
        $tokens = Measure-ProjectedTokens $deduplicated
        Assert-Equal 30 $tokens.input_tokens 'Projected input aggregation must work'
        Assert-Equal 6 $tokens.output_tokens 'Projected output aggregation must work'
        Assert-Equal 'resp_root' (Get-ResponseIdFromRequestId 'session:codex:provider:resp_root') 'CC Switch request id must expose response id'
        Assert-True ($null -eq (Get-ResponseIdFromRequestId 'random-request-id')) 'Random request ids must not correlate'

        $rows = @(
            [pscustomobject]@{request_id='session:codex:p:resp_root';input_tokens=999},
            [pscustomobject]@{request_id='session:codex:p:resp_other';input_tokens=888},
            [pscustomobject]@{request_id='random-request-id';input_tokens=777}
        )
        $matched = @(Select-AttributedRows $rows $actual)
        Assert-Equal 1 $matched.Count 'Only requested response ids must match'
        Assert-Equal 'resp_root' $matched[0].attribution_response_id 'Matched row must retain its response id'
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-Collector {
    $testRoot = Join-Path $env:TEMP ('token-notifier-collector-' + [guid]::NewGuid().ToString('N'))
    $dbPath = Join-Path $testRoot 'cc-switch.db'
    $configPath = Join-Path $testRoot 'config.json'
    $capturePath = Join-Path $testRoot 'notification.json'
    $transcriptPath = Join-Path $testRoot 'single-rollout.jsonl'
    New-Item -ItemType Directory -Force $testRoot | Out-Null
    try {
        $schema = @'
CREATE TABLE proxy_request_logs (
 request_id TEXT PRIMARY KEY, provider_id TEXT, app_type TEXT, model TEXT, request_model TEXT,
 pricing_model TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
 cache_read_tokens INTEGER DEFAULT 0, cache_creation_tokens INTEGER DEFAULT 0,
 input_cost_usd TEXT DEFAULT '0', output_cost_usd TEXT DEFAULT '0', cache_read_cost_usd TEXT DEFAULT '0',
 cache_creation_cost_usd TEXT DEFAULT '0', total_cost_usd TEXT DEFAULT '0', cost_multiplier TEXT DEFAULT '1',
 latency_ms INTEGER, first_token_ms INTEGER, duration_ms INTEGER, status_code INTEGER,
 error_message TEXT, session_id TEXT, provider_type TEXT, is_streaming INTEGER DEFAULT 0,
 created_at INTEGER, data_source TEXT DEFAULT 'proxy');
INSERT INTO proxy_request_logs (request_id,provider_id,app_type,model,status_code,created_at,data_source)
 VALUES ('existing','p','codex','m',200,1,'proxy');
'@
        $schema | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Fixture database must be created'
        $config = [ordered]@{
            enabled=$true
            toast=[ordered]@{duration='long'}
            items=@(
                [ordered]@{label='Cost';field='total_cost_usd';format='currency_usd'},
                [ordered]@{label='Input';field='input_tokens';format='integer'},
                [ordered]@{label='Output';field='output_tokens';format='integer'},
                [ordered]@{label='Total';expression='input_tokens + output_tokens';format='integer'},
                [ordered]@{label='Requests';field='request_count';format='integer'},
                [ordered]@{label='Duration';field='duration_ms_total';format='milliseconds'}
            )
        }
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        $captureScript = Join-Path $repoRoot 'tests\capture-notifier.ps1'
        $env:CCSWITCH_DB_PATH = $dbPath
        $env:TOKENNOTIFIER_DATA_ROOT = $testRoot
        $env:TOKENNOTIFIER_CONFIG_PATH = $configPath
        $env:CCSWITCH_SETTLE_DELAY_MS = '0'
        $env:TOKENNOTIFIER_NOTIFIER_COMMAND = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $captureScript + '" -OutputPath "' + $capturePath + '"'
        $collector = Join-Path $repoRoot 'scripts\collector.ps1'
        [IO.File]::WriteAllText($transcriptPath, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        $startJson = @{hook_event_name='UserPromptSubmit';session_id='s';turn_id='t';cwd='C:\work';transcript_path=$transcriptPath} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $startJson).ExitCode 'Start Hook must succeed'
        $insert = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES ('session:codex:p:resp_single','p','codex','m','m','m',1000,200,10,1,'0.01','0.02','0.002','0.001','0.033',1,7,900,200,2,'proxy');
'@
        $insert | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Fixture row must be inserted'
        Add-UsageRecord $transcriptPath 't' 't' 'resp_single' 1000 200 10 1
        $stopJson = @{hook_event_name='Stop';session_id='s';turn_id='t';cwd='C:\work';transcript_path=$transcriptPath;last_assistant_message='secret answer'} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $stopJson).ExitCode 'Stop Hook must succeed'
        Assert-True (Wait-ForPath $capturePath) 'Detached notifier payload must be captured'
        $payload = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal 'long' $payload.duration 'Toast duration must reach notifier'
        Assert-Equal 6 @($payload.items).Count 'All configured items must reach notifier'
        Assert-Equal 'Cost' $payload.items[0].label 'First item order must be preserved'
        Assert-Equal 'Duration' $payload.items[5].label 'Last item must not be truncated'
        Assert-True (-not $payload.PSObject.Properties.Name.Contains('max_visible')) 'WPF row limit must be removed'
        $logText = [IO.File]::ReadAllText((Join-Path $testRoot 'logs\usage.jsonl'), [Text.Encoding]::UTF8)
        Assert-True (-not $logText.Contains('secret answer')) 'Answer content must not be persisted'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'state\turns\t.json'))) 'Marker must be removed'

        $transcriptA = Join-Path $testRoot 'turn-a.jsonl'
        $transcriptB = Join-Path $testRoot 'turn-b.jsonl'
        [IO.File]::WriteAllText($transcriptA, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($transcriptB, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        $startA = @{hook_event_name='UserPromptSubmit';session_id='session-a';turn_id='turn-a';cwd='C:\same-work';transcript_path=$transcriptA} | ConvertTo-Json -Compress
        $startB = @{hook_event_name='UserPromptSubmit';session_id='session-b';turn_id='turn-b';cwd='C:\same-work';transcript_path=$transcriptB} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $startA).ExitCode 'Concurrent turn A must start'
        Assert-Equal 0 (Invoke-CollectorProcess $collector $startB).ExitCode 'Concurrent turn B must start'
        Add-UsageRecord $transcriptA 'turn-a' 'turn-a' 'resp_a1' 100 10 5 0
        Add-UsageRecord $transcriptA 'turn-a' 'turn-a' 'resp_a2' 200 20 10 0
        Add-UsageRecord $transcriptB 'turn-b' 'turn-b' 'resp_b1' 900 90 50 0
        $interleaved = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES
('session:codex:p:resp_a1','p','codex','m','m','m',100,10,5,0,'0.01','0.02','0.001','0','0.031',100,20,300,200,3,'proxy'),
('session:codex:p:resp_b1','p','codex','m','m','m',900,90,50,0,'0.09','0.18','0.01','0','0.28',200,30,500,200,4,'proxy'),
('session:codex:p:resp_a2','p','codex','m','m','m',200,20,10,0,'0.02','0.04','0.002','0','0.062',110,21,310,200,5,'proxy');
'@
        $interleaved | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Interleaved fixture rows must be inserted'

        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $stopA = @{hook_event_name='Stop';session_id='session-a';turn_id='turn-a';cwd='C:\same-work';transcript_path=$transcriptA} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $stopA).ExitCode 'Concurrent turn A must stop'
        Assert-True (Wait-ForPath $capturePath) 'Turn A notification must be captured'
        $payloadA = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal '300' $payloadA.items[1].value 'Turn A must include only its own input tokens'
        Assert-Equal '30' $payloadA.items[2].value 'Turn A must include only its own output tokens'

        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $stopB = @{hook_event_name='Stop';session_id='session-b';turn_id='turn-b';cwd='C:\same-work';transcript_path=$transcriptB} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $stopB).ExitCode 'Concurrent turn B must stop'
        Assert-True (Wait-ForPath $capturePath) 'Turn B notification must be captured'
        $payloadB = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal '900' $payloadB.items[1].value 'Turn B must include only its own input tokens'
        Assert-Equal '90' $payloadB.items[2].value 'Turn B must include only its own output tokens'

        $partialTranscript = Join-Path $testRoot 'turn-partial.jsonl'
        [IO.File]::WriteAllText($partialTranscript, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        $partialStart = @{hook_event_name='UserPromptSubmit';session_id='session-partial';turn_id='turn-partial';cwd='C:\same-work';transcript_path=$partialTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $partialStart).ExitCode 'Partial turn must start'
        Add-UsageRecord $partialTranscript 'turn-partial' 'turn-partial' 'resp_present' 30 3 2 0
        Add-UsageRecord $partialTranscript 'turn-partial' 'turn-partial' 'resp_missing' 40 4 3 0
        $partialRow = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES ('session:codex:p:resp_present','p','codex','m','m','m',30,3,2,0,'0.003','0.006','0.001','0','0.01',50,10,100,200,6,'proxy');
'@
        $partialRow | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Partial fixture row must be inserted'
        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $partialStop = @{hook_event_name='Stop';session_id='session-partial';turn_id='turn-partial';cwd='C:\same-work';transcript_path=$partialTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $partialStop).ExitCode 'Partial turn must stop'
        Assert-True (Wait-ForPath $capturePath) 'Partial notification must be captured'
        $partialPayload = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal '--' $partialPayload.items[0].value 'Partial cost must not look complete'
        Assert-Equal '70' $partialPayload.items[1].value 'Partial token totals must come from rollout usage'
        Assert-Equal '7' $partialPayload.items[2].value 'Partial output totals must come from rollout usage'
        $summaries = @([IO.File]::ReadAllLines((Join-Path $testRoot 'logs\usage.jsonl'), [Text.Encoding]::UTF8) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'turn_summary')
        $partialSummary = $summaries | Where-Object codex_turn_id -eq 'turn-partial' | Select-Object -Last 1
        Assert-Equal 'partial' $partialSummary.attribution_status 'Missing CC Switch rows must mark a partial turn'
        Assert-Equal 1 ([int]$partialSummary.matched_request_count) 'Partial summary must count matched requests'
        Assert-Equal 1 ([int]$partialSummary.unmatched_request_count) 'Partial summary must count unmatched requests'

        $rootTranscript = Join-Path $testRoot 'root-agent-turn.jsonl'
        $agentTranscript = Join-Path $testRoot 'agent-turn.jsonl'
        [IO.File]::WriteAllText($rootTranscript, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($agentTranscript, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        $rootStart = @{hook_event_name='UserPromptSubmit';session_id='session-agent-root';turn_id='root-turn';cwd='C:\agents';transcript_path=$rootTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $rootStart).ExitCode 'Agent root turn must start'
        Add-UsageRecord $rootTranscript 'root-turn' 'root-turn' 'resp_root_turn' 50 5 4 0
        Add-UsageRecord $rootTranscript 'child-turn' 'root-turn' 'resp_child_turn' 70 7 6 0
        Add-UsageRecord $agentTranscript 'child-turn' 'root-turn' 'resp_child_turn' 70 7 6 0
        Add-UsageRecord $agentTranscript 'child-turn' 'root-turn' 'resp_child_turn_2' 30 3 2 0
        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $subagentStop = @{hook_event_name='SubagentStop';session_id='session-agent-root';turn_id='child-turn';agent_id='agent-1';agent_type='worker';agent_transcript_path=$agentTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $subagentStop).ExitCode 'SubagentStop Hook must succeed'
        Assert-True (-not (Test-Path -LiteralPath $capturePath)) 'SubagentStop must not notify independently'
        Assert-True (Test-Path -LiteralPath (Join-Path $testRoot 'state\subagents\root-turn\agent-1.json')) 'Subagent usage fragment must be persisted'
        $agentRows = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES
('session:codex:p:resp_root_turn','p','codex','m','m','m',50,5,4,0,'0.005','0.01','0.001','0','0.016',70,15,160,200,7,'proxy'),
('session:codex:p:resp_child_turn','p','codex','m','m','m',70,7,6,0,'0.007','0.014','0.001','0','0.022',80,16,180,200,8,'proxy'),
('session:codex:p:resp_child_turn_2','p','codex','m','m','m',30,3,2,0,'0.003','0.006','0.001','0','0.01',60,12,120,200,9,'proxy');
'@
        $agentRows | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Root and agent rows must be inserted'
        $rootStop = @{hook_event_name='Stop';session_id='session-agent-root';turn_id='root-turn';cwd='C:\agents';transcript_path=$rootTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $rootStop).ExitCode 'Agent root turn must stop'
        Assert-True (Wait-ForPath $capturePath) 'Aggregated agent notification must be captured'
        $agentPayload = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal '150' $agentPayload.items[1].value 'Root notification must include every child input once'
        Assert-Equal '15' $agentPayload.items[2].value 'Root notification must include every child output once'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'state\subagents\root-turn'))) 'Root completion must remove child fragments'

        $interruptTranscript = Join-Path $testRoot 'interrupted-turn.jsonl'
        [IO.File]::WriteAllText($interruptTranscript, "{`"type`":`"session_meta`"}`r`n", [Text.UTF8Encoding]::new($false))
        $interruptStart = @{hook_event_name='UserPromptSubmit';session_id='session-interrupt';turn_id='turn-interrupt';cwd='C:\interrupt';transcript_path=$interruptTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $interruptStart).ExitCode 'Interrupted turn must start'
        Add-UsageRecord $interruptTranscript 'turn-interrupt' 'turn-interrupt' 'resp_interrupted' 25 2 1 0
        $interruptRow = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES ('session:codex:p:resp_interrupted','p','codex','m','m','m',25,2,1,0,'0.0025','0.004','0.0005','0','0.007',40,9,90,200,10,'proxy');
'@
        $interruptRow | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Interrupted row must be inserted'
        Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        $interrupt = @{hook_event_name='Interrupt';session_id='session-interrupt';turn_id='turn-interrupt';cwd='C:\interrupt';transcript_path=$interruptTranscript} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $interrupt).ExitCode 'Interrupt Hook must succeed'
        Assert-True (Wait-ForPath $capturePath) 'Interrupted notification must be captured'
        $allSummaries = @([IO.File]::ReadAllLines((Join-Path $testRoot 'logs\usage.jsonl'), [Text.Encoding]::UTF8) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'turn_summary')
        $interruptSummary = $allSummaries | Where-Object codex_turn_id -eq 'turn-interrupt' | Select-Object -Last 1
        Assert-Equal 'interrupted' $interruptSummary.turn_outcome 'Interrupt summary must retain its outcome'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'state\turns\turn-interrupt.json'))) 'Interrupt must remove its marker'
    } finally {
        Remove-Item Env:CCSWITCH_DB_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_DATA_ROOT -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CCSWITCH_SETTLE_DELAY_MS -ErrorAction SilentlyContinue
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
