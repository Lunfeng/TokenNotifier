param(
    [ValidateSet('All', 'Package', 'Config', 'Evaluator', 'ToastXml', 'Registration', 'Collector')]
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

function Test-Collector {
    $testRoot = Join-Path $env:TEMP ('token-notifier-collector-' + [guid]::NewGuid().ToString('N'))
    $dbPath = Join-Path $testRoot 'cc-switch.db'
    $configPath = Join-Path $testRoot 'config.json'
    $capturePath = Join-Path $testRoot 'notification.json'
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
        $startJson = @{hook_event_name='UserPromptSubmit';session_id='s';turn_id='t';cwd='C:\work'} | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collector $startJson).ExitCode 'Start Hook must succeed'
        $insert = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES ('r1','p','codex','m','m','m',1000,200,10,1,'0.01','0.02','0.002','0.001','0.033',1,7,900,200,2,'proxy');
'@
        $insert | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Fixture row must be inserted'
        $stopJson = @{hook_event_name='Stop';session_id='s';turn_id='t';cwd='C:\work';last_assistant_message='secret answer'} | ConvertTo-Json -Compress
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
        Assert-True (-not (Test-Path (Join-Path $testRoot 'state\t.json'))) 'Marker must be removed'
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
if ($Case -in @('All', 'Collector')) { Test-Collector; Write-Output 'PASS: Collector' }
