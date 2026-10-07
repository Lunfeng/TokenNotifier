# Windows Toast Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace TokenNotifier's custom WPF popup with a registered native Windows Adaptive Toast that renders every user-configured field or safe expression.

**Architecture:** Keep collection, evaluation, and usage logging in `collector.ps1`; change only its display payload from WPF timing fields to a Toast duration hint. Split notification identity registration into `toast-registration.ps1`, while `notifier.ps1` validates the transient payload, constructs adaptive XML with structured XML APIs, submits it through Windows Runtime, and exits without retaining detail data.

**Tech Stack:** Windows PowerShell 5.1, Windows Runtime `Windows.UI.Notifications`, .NET XML APIs, Shell AppUserModelID/property-store interop, existing Codex Hooks and CC Switch SQLite integration.

**Spec:** `docs/superpowers/specs/2026-10-07-windows-toast-notifications-design.md`

**Implementation status (2026-10-07):** Tasks 1-5 are implemented and verified
in the current session. Automated tests, PowerShell syntax validation, native
Toast submission, per-user registration, unregistration, and automatic repair
all passed. The commit and `v0.2.0` tag steps remain intentionally unexecuted
because no Git commit or release tag was requested.

## Global Constraints

- Support Windows 10 and Windows 11 with Windows PowerShell 5.1.
- Use the stable AppUserModelID `Lunfeng.TokenNotifier` and current-user registration only.
- Add no third-party module, packaged app, service, startup entry, resident process, activation handler, or administrator requirement.
- Submit every configured item in config order; do not cap, batch, summarize, or hide rows.
- Add no detail window, Toast action, activation argument, or plugin click behavior.
- Delete the transient notification JSON immediately after reading and create no notification-history payload store.
- Preserve the existing safe evaluator, formatting, CC Switch collection, `usage.jsonl`, `errors.log`, and privacy guarantees.
- Windows owns Toast size, placement, wrapping, truncation, display duration, theme, notification-center retention, and Do Not Disturb behavior.

## File Structure

| Path | Responsibility |
| --- | --- |
| `scripts/collector.ps1` | Validate Toast config and create the normalized notification payload after evaluating user items. |
| `scripts/notifier.ps1` | Read/delete the transient payload, build adaptive XML, initialize identity, submit the Toast, and log failures. |
| `scripts/toast-registration.ps1` | Define the stable AUMID and idempotently create/update/remove the per-user shortcut and registry metadata. |
| `scripts/unregister-toast.ps1` | User-facing cleanup entry point for only the Toast identity registration. |
| `scripts/build-icon.ps1` | Reproducibly build all ICO frames from drawing primitives. |
| `assets/token-notifier.ico` | Multi-resolution icon referenced by the shortcut and application registration. |
| `config/default-config.json` | Ship the `toast.duration` default while preserving configurable display items. |
| `tests/token-notifier.tests.ps1` | Dependency-free PowerShell contract, evaluator, XML, registration, collector, and privacy tests. |
| `tests/capture-notifier.ps1` | Test-only detached notifier replacement that captures one UTF-8 payload. |
| `README.md` | Document Toast behavior, configuration migration, registration side effects, limits, and cleanup. |
| `.codex-plugin/plugin.json` | Publish the behavior change as version `0.2.0`. |

---

### Task 1: Establish The Toast Configuration And Payload Contract

**Files:**
- Create: `tests/token-notifier.tests.ps1`
- Modify: `config/default-config.json`
- Modify: `scripts/collector.ps1:20-49`
- Modify: `scripts/collector.ps1:117-145`
- Modify: `scripts/collector.ps1:178-191`

**Interfaces:**
- Consumes: Existing `Resolve-DataItem([object]$Item, [hashtable]$Context)` from `scripts/evaluator.ps1`.
- Produces: `Get-ToastDuration([object]$Config) -> string`, returning exactly `short` or `long`.
- Produces: Notification payload `{ kind, title, items, message?, duration }`; later tasks rely on these exact property names.

- [ ] **Step 1: Create the dependency-free test harness and failing config tests**

Create `tests/token-notifier.tests.ps1` with reusable assertions and a `Config` case. Dot-source `collector.ps1` only after adding the standard invocation guard shown in Step 3 so tests do not consume stdin.

```powershell
param(
    [ValidateSet('All', 'Config', 'Evaluator', 'ToastXml', 'Registration', 'Collector')]
    [string]$Case = 'All'
)
$ErrorActionPreference = 'Stop'

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

$repoRoot = Split-Path -Parent $PSScriptRoot

function Test-ToastConfig {
    . (Join-Path $repoRoot 'scripts\collector.ps1')
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{})) 'Missing Toast config must default to short'
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'short' } })) 'Short duration must pass through'
    Assert-Equal 'long' (Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'long' } })) 'Long duration must pass through'
    Assert-Equal 'long' (Get-ToastDuration ([pscustomobject]@{ popup = [pscustomobject]@{ auto_close_seconds = 10 } })) 'Legacy ten-second popup must map to long'
    Assert-Equal 'short' (Get-ToastDuration ([pscustomobject]@{ popup = [pscustomobject]@{ auto_close_seconds = 8 } })) 'Legacy short popup must map to short'
    Assert-Throws { Get-ToastDuration ([pscustomobject]@{ toast = 'short' }) } 'Toast config must be an object'
    Assert-Throws { Get-ToastDuration ([pscustomobject]@{ toast = [pscustomobject]@{ duration = 'forever' } }) } 'Unknown Toast duration must fail validation'

    $defaults = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'config\default-config.json') | ConvertFrom-Json
    Assert-Equal 'short' $defaults.toast.duration 'Packaged default must use a short Toast'
    Assert-True ($null -eq $defaults.popup) 'Packaged default must not expose obsolete WPF popup settings'
    Assert-Equal 4 @($defaults.items).Count 'Default configured items must remain unchanged'
}

if ($Case -in @('All', 'Config')) { Test-ToastConfig; Write-Output 'PASS: Config' }
```

- [ ] **Step 2: Run the config test and verify the new contract is absent**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Config
```

Expected: FAIL because `Get-ToastDuration` and `defaults.toast.duration` do not exist.

- [ ] **Step 3: Add duration validation, payload fields, and a dot-source guard**

Add this pure helper before `Get-Config`, use it from `Get-Config`, and replace the collector's WPF timing properties with `duration`:

```powershell
function Get-ToastDuration([object]$Config) {
    if ($null -ne $Config.toast -and $Config.toast -isnot [pscustomobject]) {
        throw 'Config toast must be an object'
    }
    if ($null -ne $Config.toast -and $null -ne $Config.toast.duration) {
        $duration = [string]$Config.toast.duration
        if ($duration -notin @('short', 'long')) { throw 'Config toast duration must be short or long' }
        return $duration
    }
    if ($null -ne $Config.popup -and $null -ne $Config.popup.auto_close_seconds) {
        try { $seconds = [int]$Config.popup.auto_close_seconds }
        catch { throw 'Config popup auto_close_seconds must be an integer' }
        if ($seconds -ge 10) { return 'long' }
    }
    return 'short'
}

function New-ErrorNotification([string]$Message) {
    return [ordered]@{
        kind = 'error'
        title = 'TokenNotifier'
        items = @()
        message = $Message
        duration = 'short'
    }
}
```

In `Get-Config`, call `Get-ToastDuration $config | Out-Null` after validating
the `items` array. Retain acceptance of a legacy `popup` object, but remove the
old positive `max_visible` requirement because that property is ignored by
Toast rendering.

In `Invoke-UsageNotification`, retain the complete resolved `items` array and emit:

```powershell
$payload = [ordered]@{
    kind = 'usage'
    title = if ([string]::IsNullOrWhiteSpace([string]$Config.title)) { $defaultTitle } else { [string]$Config.title }
    items = $items
    duration = Get-ToastDuration $Config
}
```

Wrap the bottom-level stdin/Hook dispatch block so dot-sourcing exposes functions without running the Hook:

```powershell
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $inputText = Read-Utf8Stdin
        if ([string]::IsNullOrWhiteSpace($inputText)) { exit 0 }
        try { $payload = $inputText | ConvertFrom-Json } catch { $script:HookPayloadParseError = $true; throw 'Hook payload JSON is invalid' }
        switch ([string]$payload.hook_event_name) {
            'UserPromptSubmit' { Start-Turn $payload }
            'Stop' { Complete-Turn $payload }
        }
    } catch {
        try {
            if ($script:HookPayloadParseError) { Append-ErrorLog 'Hook payload rejected: invalid JSON' }
            else { Append-ErrorLog $_.Exception.ToString() }
        } catch { }
        try { Invoke-DetachedNotifier (New-ErrorNotification 'Unable to collect API usage data.') } catch { }
        exit 0
    }
}
```

Replace `config/default-config.json` with the exact schema from the spec: `enabled`, `toast.duration`, and the unchanged four `items`.

- [ ] **Step 4: Add and run evaluator regression tests**

Add this exact evaluator case to the test file so the notification UI change
cannot weaken user-defined calculations:

```powershell
function Test-Evaluator {
    . (Join-Path $repoRoot 'scripts\evaluator.ps1')
    $context = @{
        input_tokens = 1000
        output_tokens = 200
        total_cost_usd = [decimal]'0.25'
        duration_ms_total = 1250
    }
    Assert-Equal 1000 (Evaluate-Expression 'input_tokens' $context) 'Direct field lookup must work'
    Assert-Equal 1200 (Evaluate-Expression 'input_tokens + output_tokens' $context) 'Addition must work'
    Assert-Equal 20 (Evaluate-Expression 'output_tokens / input_tokens * 100' $context) 'Operator precedence must work'
    Assert-Equal 600 (Evaluate-Expression '(input_tokens + output_tokens) / 2' $context) 'Parentheses must work'
    Assert-Equal 3 (Evaluate-Expression 'round(2.6)' $context) 'round must work'
    Assert-Equal 2.34 (Evaluate-Expression 'round(2.345, 2)' $context) 'round must retain midpoint-to-even behavior'
    Assert-Equal 4 (Evaluate-Expression 'max(2, min(4, 7))' $context) 'Allowed functions must compose'
    Assert-Equal 4 (Evaluate-Expression 'abs(-4)' $context) 'abs must work'
    Assert-Equal $true (Evaluate-Expression 'output_tokens < input_tokens' $context) 'Comparisons must work'
    Assert-Throws { Evaluate-Expression 'input_tokens / 0' $context } 'Division by zero must fail safely'
    Assert-Throws { Evaluate-Expression 'unknown_field + 1' $context } 'Unknown identifiers must be rejected'
    Assert-Throws { Evaluate-Expression 'input_tokens +' $context } 'Invalid syntax must be rejected'
    Assert-Throws { Evaluate-Expression 'Invoke-Expression(1)' $context } 'Executable syntax must be rejected'
    Assert-Equal '--' (Resolve-DataItem ([pscustomobject]@{ label='Bad'; expression='input_tokens / 0'; format='decimal' }) $context).value 'Failed item must render as --'
    Assert-Equal '1,200' (Format-DisplayValue 1200 'integer') 'Integer formatting must remain stable'
    Assert-Equal '12.3456' (Format-DisplayValue ([decimal]'12.3456') 'decimal') 'Decimal formatting must remain stable'
    Assert-Equal '$0.25' (Format-DisplayValue ([decimal]'0.25') 'currency_usd') 'Currency formatting must remain stable'
    Assert-Equal '25%' (Format-DisplayValue ([decimal]'0.25') 'percent') 'Percent formatting must remain stable'
    Assert-Equal '1,250 ms' (Format-DisplayValue 1250 'milliseconds') 'Millisecond formatting must remain stable'
    Assert-Equal 'model-x' (Format-DisplayValue 'model-x' 'text') 'Text formatting must remain stable'
}

if ($Case -in @('All', 'Evaluator')) { Test-Evaluator; Write-Output 'PASS: Evaluator' }
```

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Config
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Evaluator
```

Expected: both cases print `PASS` and exit 0.

- [ ] **Step 5: Commit the contract change**

```powershell
git add tests/token-notifier.tests.ps1 config/default-config.json scripts/collector.ps1
git commit -m "refactor: define toast notification contract"
```

---

### Task 2: Build Adaptive Toast XML Without Dropping Rows

**Files:**
- Modify: `scripts/notifier.ps1:14-144`
- Modify: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Consumes: Payload `{ kind, title, items, message?, duration }` from Task 1.
- Produces: `ConvertTo-NotificationPayload([object]$Payload) -> PSCustomObject` with normalized `kind`, `title`, `items`, `message`, and `duration`.
- Produces: `New-ToastXml([object]$Data) -> System.Xml.XmlDocument`, consumed by the Windows Runtime submission function in Task 4.

- [ ] **Step 1: Add failing adaptive XML tests**

Add a `Test-ToastXml` function to `tests/token-notifier.tests.ps1`:

```powershell
function Test-ToastXml {
    . (Join-Path $repoRoot 'scripts\notifier.ps1')
    $items = @(
        [pscustomobject]@{ label = '费用 & 税'; value = '<$0.01>' },
        [pscustomobject]@{ label = '输入 Token'; value = '1,000' },
        [pscustomobject]@{ label = '输出 Token'; value = '200' },
        [pscustomobject]@{ label = '总 Token'; value = '1,200' },
        [pscustomobject]@{ label = '请求'; value = '1' },
        [pscustomobject]@{ label = '耗时'; value = '900 ms' },
        [pscustomobject]@{ label = '供应商'; value = 'A > B' }
    )
    $data = ConvertTo-NotificationPayload ([pscustomobject]@{
        kind = 'usage'; title = 'TokenNotifier · model'; items = $items; duration = 'long'
    })
    $xml = New-ToastXml $data
    Assert-Equal 'long' $xml.DocumentElement.GetAttribute('duration') 'Toast duration must be emitted'
    Assert-Equal 7 @($xml.SelectNodes('/toast/visual/binding/group')).Count 'Every configured item must become a group'
    Assert-Equal '费用 & 税' $xml.SelectSingleNode('/toast/visual/binding/group[1]/subgroup[1]/text').InnerText 'Labels must round-trip through XML escaping'
    Assert-Equal '<$0.01>' $xml.SelectSingleNode('/toast/visual/binding/group[1]/subgroup[2]/text').InnerText 'Values must round-trip through XML escaping'
    Assert-Equal 'right' $xml.SelectSingleNode('/toast/visual/binding/group[1]/subgroup[2]/text').GetAttribute('hint-align') 'Values must align right when Windows honors adaptive hints'
    Assert-True ($null -eq $xml.SelectSingleNode('/toast/actions')) 'Toast must not define actions'
    Assert-True (-not $xml.DocumentElement.HasAttribute('launch')) 'Toast must not define activation arguments'
    Assert-True ((Get-Content -Raw (Join-Path $repoRoot 'scripts\notifier.ps1')) -notmatch 'PresentationFramework|System.Windows.Window|Dispatcher') 'Notifier must not retain WPF code'

    $errorXml = New-ToastXml (ConvertTo-NotificationPayload ([pscustomobject]@{
        kind = 'error'; title = 'TokenNotifier'; items = @(); message = 'Unable <now>'; duration = 'short'
    }))
    Assert-Equal 'Unable <now>' $errorXml.SelectSingleNode('/toast/visual/binding/text[2]').InnerText 'Error message must be escaped and retained'
    Assert-Throws { ConvertTo-NotificationPayload ([pscustomobject]@{ kind='usage'; title='x'; items=@(); duration='forever' }) } 'Unknown duration must fail'
}

if ($Case -in @('All', 'ToastXml')) { Test-ToastXml; Write-Output 'PASS: ToastXml' }
```

- [ ] **Step 2: Run the XML test and verify it fails**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case ToastXml
```

Expected: FAIL because `New-ToastXml` does not exist and WPF references are still present.

- [ ] **Step 3: Replace WPF layout code with structured adaptive XML construction**

Keep `Read-Utf8Stdin`, replace the WPF functions, and construct XML nodes through `System.Xml.XmlDocument` rather than interpolated XML strings. Use these exact helpers and layout rules:

```powershell
function Add-XmlElement {
    param(
        [System.Xml.XmlDocument]$Document,
        [System.Xml.XmlNode]$Parent,
        [string]$Name,
        [hashtable]$Attributes = @{},
        [AllowNull()][string]$Text
    )
    $element = $Document.CreateElement($Name)
    foreach ($key in $Attributes.Keys) { $element.SetAttribute([string]$key, [string]$Attributes[$key]) }
    if ($null -ne $Text) { $element.InnerText = $Text }
    $Parent.AppendChild($element) | Out-Null
    return $element
}

function New-ToastXml {
    param([Parameter(Mandatory = $true)]$Data)
    $document = New-Object System.Xml.XmlDocument
    $toast = Add-XmlElement $document $document 'toast' @{ duration = $Data.duration } $null
    $visual = Add-XmlElement $document $toast 'visual' @{} $null
    $binding = Add-XmlElement $document $visual 'binding' @{ template = 'ToastGeneric' } $null
    Add-XmlElement $document $binding 'text' @{} $Data.title | Out-Null
    foreach ($item in @($Data.items)) {
        $group = Add-XmlElement $document $binding 'group' @{} $null
        $labelColumn = Add-XmlElement $document $group 'subgroup' @{ 'hint-weight' = '2' } $null
        Add-XmlElement $document $labelColumn 'text' @{ 'hint-wrap' = 'true' } ([string]$item.label) | Out-Null
        $valueColumn = Add-XmlElement $document $group 'subgroup' @{ 'hint-weight' = '1' } $null
        Add-XmlElement $document $valueColumn 'text' @{ 'hint-align' = 'right'; 'hint-wrap' = 'true' } ([string]$item.value) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Data.message)) {
        Add-XmlElement $document $binding 'text' @{ 'hint-wrap' = 'true' } ([string]$Data.message) | Out-Null
    }
    return $document
}
```

`ConvertTo-NotificationPayload` must copy all items without a maximum, default a missing duration to `short`, accept only `short`/`long`, and continue validating `usage`/`error`, title, and item labels. Delete `Get-NotificationHeight`, `Get-NotificationBatches`, `Show-NotificationWindow`, the Dispatcher loop, and every WPF assembly/type reference.

- [ ] **Step 4: Run XML and evaluator tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case ToastXml
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Evaluator
```

Expected: both cases print `PASS`; the seven-item fixture produces seven XML groups.

- [ ] **Step 5: Commit adaptive rendering**

```powershell
git add scripts/notifier.ps1 tests/token-notifier.tests.ps1
git commit -m "feat: render usage as adaptive toast XML"
```

---

### Task 3: Register A Per-User TokenNotifier Toast Identity

**Files:**
- Create: `scripts/toast-registration.ps1`
- Create: `scripts/unregister-toast.ps1`
- Create: `assets/token-notifier.ico`
- Modify: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Produces: `$script:TokenNotifierAppId = 'Lunfeng.TokenNotifier'`.
- Produces: `Initialize-ToastRegistration([string]$NotifierPath, [string]$IconPath, [string]$StartMenuRoot) -> void`.
- Produces: `Remove-ToastRegistration([string]$StartMenuRoot) -> void`.
- Produces: `[TokenNotifier.ShellIntegration]::SetCurrentProcessAppId(string)` and `[TokenNotifier.ShellIntegration]::SetShortcutAppId(string,string)` interop methods.

- [ ] **Step 1: Add failing registration contract tests**

Add a `Test-Registration` case. It uses a temporary Start Menu directory and a temporary copy of the icon so it never touches the real Start Menu. The registry write is disabled through the explicit `-SkipRegistry` test switch.

```powershell
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
        Assert-True (Test-Path $shortcut) 'Registration must create the Start Menu shortcut'
        Assert-Equal 'Lunfeng.TokenNotifier' ([TokenNotifier.ShellIntegration]::GetShortcutAppId($shortcut)) 'Shortcut must carry the TokenNotifier AUMID'
        $firstWrite = (Get-Item $shortcut).LastWriteTimeUtc
        Initialize-ToastRegistration -NotifierPath $notifier -IconPath $icon -StartMenuRoot $testRoot -SkipRegistry
        Assert-Equal $firstWrite (Get-Item $shortcut).LastWriteTimeUtc 'Matching registration must be idempotent'
        Remove-ToastRegistration -StartMenuRoot $testRoot -SkipRegistry
        Assert-True (-not (Test-Path $shortcut)) 'Unregistration must remove the exact shortcut'
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Case -in @('All', 'Registration')) { Test-Registration; Write-Output 'PASS: Registration' }
```

- [ ] **Step 2: Run the registration test and verify it fails**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Registration
```

Expected: FAIL because `toast-registration.ps1` and the icon do not exist.

- [ ] **Step 3: Implement Shell identity interop and idempotent registration**

> **Execution correction (2026-10-07):** Loading the shortcut through
> `IPersistFile` returned success from `IPropertyStore.Commit` but did not
> persist `System.AppUserModel.ID` on this Windows host. The implemented and
> tested version in `scripts/toast-registration.ps1` uses
> `SHGetPropertyStoreFromParsingName` with flags `2` for writes and `0` for
> reads. That checked-in script is authoritative; the original ShellLink draft
> below is retained only as implementation history.

In `toast-registration.ps1`, set the stable ID and compile the following
namespaced helper only when the type is absent:

```powershell
$script:TokenNotifierAppId = 'Lunfeng.TokenNotifier'

if (-not ('TokenNotifier.ShellIntegration' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace TokenNotifier {
    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink { }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey {
        public Guid FormatId;
        public uint PropertyId;
        public PropertyKey(Guid formatId, uint propertyId) {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant {
        [FieldOffset(0)] public ushort VariantType;
        [FieldOffset(8)] public IntPtr PointerValue;

        public static PropVariant FromString(string value) {
            return new PropVariant {
                VariantType = (ushort)VarEnum.VT_LPWSTR,
                PointerValue = Marshal.StringToCoTaskMemUni(value)
            };
        }

        public string GetString() {
            return PointerValue == IntPtr.Zero ? null : Marshal.PtrToStringUni(PointerValue);
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public static class ShellIntegration {
        private static readonly PropertyKey AppUserModelIdKey = new PropertyKey(
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        public static void SetCurrentProcessAppId(string appId) {
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appId));
        }

        public static void SetShortcutAppId(string shortcutPath, string appId) {
            object shellLink = new ShellLink();
            try {
                IPersistFile persistFile = (IPersistFile)shellLink;
                persistFile.Load(shortcutPath, 0);
                IPropertyStore propertyStore = (IPropertyStore)shellLink;
                PropertyKey key = AppUserModelIdKey;
                PropVariant value = PropVariant.FromString(appId);
                try {
                    Marshal.ThrowExceptionForHR(propertyStore.SetValue(ref key, ref value));
                    Marshal.ThrowExceptionForHR(propertyStore.Commit());
                    persistFile.Save(shortcutPath, true);
                } finally {
                    PropVariantClear(ref value);
                }
            } finally {
                Marshal.FinalReleaseComObject(shellLink);
            }
        }

        public static string GetShortcutAppId(string shortcutPath) {
            object shellLink = new ShellLink();
            try {
                IPersistFile persistFile = (IPersistFile)shellLink;
                persistFile.Load(shortcutPath, 0);
                IPropertyStore propertyStore = (IPropertyStore)shellLink;
                PropertyKey key = AppUserModelIdKey;
                PropVariant value;
                Marshal.ThrowExceptionForHR(propertyStore.GetValue(ref key, out value));
                try {
                    return value.GetString();
                } finally {
                    PropVariantClear(ref value);
                }
            } finally {
                Marshal.FinalReleaseComObject(shellLink);
            }
        }
    }
}
'@ -ErrorAction Stop
}
```

Use `WScript.Shell.CreateShortcut` for ordinary shortcut fields, then use the
interop helper for the AUMID property. Implement the PowerShell registration
functions with these exact inputs and comparison behavior:

```powershell
function Initialize-ToastRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$NotifierPath,
        [Parameter(Mandatory = $true)][string]$IconPath,
        [string]$StartMenuRoot = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        [switch]$SkipRegistry
    )
    $resolvedNotifier = (Resolve-Path -LiteralPath $NotifierPath).Path
    $resolvedIcon = (Resolve-Path -LiteralPath $IconPath).Path
    New-Item -ItemType Directory -Force -Path $StartMenuRoot | Out-Null
    $shortcutPath = Join-Path $StartMenuRoot 'TokenNotifier.lnk'
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File "' + $resolvedNotifier + '"'
    $workingDirectory = Split-Path -Parent $resolvedNotifier
    $iconLocation = $resolvedIcon + ',0'
    $shell = New-Object -ComObject WScript.Shell
    $rewrite = -not (Test-Path -LiteralPath $shortcutPath)
    if (-not $rewrite) {
        $existing = $shell.CreateShortcut($shortcutPath)
        $existingAppId = [TokenNotifier.ShellIntegration]::GetShortcutAppId($shortcutPath)
        $rewrite = $existing.TargetPath -ne $powerShellPath -or
            $existing.Arguments -ne $arguments -or
            $existing.WorkingDirectory -ne $workingDirectory -or
            $existing.IconLocation -ne $iconLocation -or
            $existingAppId -ne $script:TokenNotifierAppId
    }
    if ($rewrite) {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powerShellPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $workingDirectory
        $shortcut.IconLocation = $iconLocation
        $shortcut.Description = 'TokenNotifier Windows notifications'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        [TokenNotifier.ShellIntegration]::SetShortcutAppId($shortcutPath, $script:TokenNotifierAppId)
    }
    if (-not $SkipRegistry) {
        $registrationPath = 'HKCU:\Software\Classes\AppUserModelId\' + $script:TokenNotifierAppId
        New-Item -Path $registrationPath -Force | Out-Null
        New-ItemProperty -Path $registrationPath -Name DisplayName -Value 'TokenNotifier' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $registrationPath -Name IconUri -Value $resolvedIcon -PropertyType String -Force | Out-Null
    }
}

function Remove-ToastRegistration {
    param(
        [string]$StartMenuRoot = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        [switch]$SkipRegistry
    )
    $shortcutPath = Join-Path $StartMenuRoot 'TokenNotifier.lnk'
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    if (-not $SkipRegistry) {
        $registrationPath = 'HKCU:\Software\Classes\AppUserModelId\' + $script:TokenNotifierAppId
        Remove-Item -LiteralPath $registrationPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
```

The comparison returns without saving when all values match, so the shortcut's
timestamp remains stable. For normal registration, the functions create/update:

```text
HKCU\Software\Classes\AppUserModelId\Lunfeng.TokenNotifier
  DisplayName = TokenNotifier
  IconUri     = <absolute icon path>
```

`Remove-ToastRegistration` must remove only
`TokenNotifier.lnk` and the exact `Lunfeng.TokenNotifier` key. The test-only
`-SkipRegistry` switch must suppress registry access but not shortcut work.

- [ ] **Step 4: Add the multi-resolution icon and cleanup entry point**

Add `assets/token-notifier.ico` containing 16, 20, 24, 32, 48, and 256 pixel
RGBA frames. Use a transparent background and a high-contrast notification
bell with a small token counter; verify the ICO opens in Windows Explorer and
contains every frame.

Create `scripts/unregister-toast.ps1` as the complete cleanup command:

```powershell
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toast-registration.ps1')
Remove-ToastRegistration
Write-Output 'TokenNotifier Toast registration removed.'
```

- [ ] **Step 5: Run registration tests and inspect the temporary shortcut**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Registration
```

Expected: `PASS: Registration`, no administrative prompt, no real Start Menu
change, and no leftover temporary directory.

- [ ] **Step 6: Commit identity registration**

```powershell
git add scripts/toast-registration.ps1 scripts/unregister-toast.ps1 assets/token-notifier.ico tests/token-notifier.tests.ps1
git commit -m "feat: register TokenNotifier toast identity"
```

---

### Task 4: Submit Toasts And Preserve Non-Blocking Failure Behavior

**Files:**
- Create: `tests/capture-notifier.ps1`
- Modify: `scripts/notifier.ps1`
- Modify: `scripts/collector.ps1:89-115`
- Modify: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Consumes: `New-ToastXml($Data)` from Task 2.
- Consumes: `Initialize-ToastRegistration(...)` and `$script:TokenNotifierAppId` from Task 3.
- Produces: `Show-ToastNotification([System.Xml.XmlDocument]$Xml) -> void`.
- Produces: `Invoke-ToastNotification([object]$Payload) -> void` as the notifier's single runtime entry point.

- [ ] **Step 1: Add notifier lifecycle and detached-payload tests**

Create `tests/capture-notifier.ps1` so the collector's existing detached
process path can be exercised without showing a real Toast:

```powershell
param([Parameter(Mandatory = $true)][string]$OutputPath)
$stream = [Console]::OpenStandardInput()
$memory = New-Object IO.MemoryStream
$buffer = New-Object byte[] 4096
try {
    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $memory.Write($buffer, 0, $count)
    }
    [IO.File]::WriteAllText(
        $OutputPath,
        [Text.Encoding]::UTF8.GetString($memory.ToArray()).Trim(),
        [Text.UTF8Encoding]::new($false))
} finally {
    $memory.Dispose()
}
```

Extend `Test-ToastXml` with these lifecycle assertions:

```powershell
$notifierText = Get-Content -Raw (Join-Path $repoRoot 'scripts\notifier.ps1')
Assert-True ($notifierText -match 'Windows\.UI\.Notifications\.ToastNotificationManager') 'Notifier must use the native Toast API'
Assert-True ($notifierText -match 'Remove-Item -LiteralPath \$PayloadPath') 'Transient payload must be deleted after reading'
Assert-True ($notifierText -notmatch 'PresentationFramework|System\.Windows\.Window|ShowDialog|NotifyIcon') 'Notifier must not contain WPF, detail windows, or tray balloons'
Assert-True ($notifierText -notmatch 'Add_Activated|activationType|<actions') 'Notifier must not handle Toast clicks'
```

Add this focused collector test to prove all resolved rows reach the detached
notifier in order. Keep the existing CC Switch aggregation/privacy regression
assertions in the same `Test-Collector` function when moving them into the new
repository-local suite.

```powershell
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
    } finally {
        $process.Dispose()
    }
}

function Test-Collector {
    $testRoot = Join-Path $env:TEMP ('token-notifier-collector-' + [guid]::NewGuid().ToString('N'))
    $dbPath = Join-Path $testRoot 'cc-switch.db'
    $configPath = Join-Path $testRoot 'config.json'
    $capturePath = Join-Path $testRoot 'notification.json'
    $collectorPath = Join-Path $repoRoot 'scripts\collector.ps1'
    $captureScript = Join-Path $repoRoot 'tests\capture-notifier.ps1'
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
            enabled = $true
            toast = [ordered]@{ duration = 'long' }
            items = @(
                [ordered]@{ label='Cost'; field='total_cost_usd'; format='currency_usd' },
                [ordered]@{ label='Input'; field='input_tokens'; format='integer' },
                [ordered]@{ label='Output'; field='output_tokens'; format='integer' },
                [ordered]@{ label='Total'; expression='input_tokens + output_tokens'; format='integer' },
                [ordered]@{ label='Requests'; field='request_count'; format='integer' },
                [ordered]@{ label='Duration'; field='duration_ms_total'; format='milliseconds' }
            )
        }
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        $env:CCSWITCH_DB_PATH = $dbPath
        $env:TOKENNOTIFIER_DATA_ROOT = $testRoot
        $env:TOKENNOTIFIER_CONFIG_PATH = $configPath
        $env:CCSWITCH_SETTLE_DELAY_MS = '0'
        $env:TOKENNOTIFIER_NOTIFIER_COMMAND = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $captureScript + '" -OutputPath "' + $capturePath + '"'

        $startJson = @{ hook_event_name='UserPromptSubmit'; session_id='s'; turn_id='t'; cwd='C:\work' } | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collectorPath $startJson).ExitCode 'Start Hook must succeed'
        $insert = @'
INSERT INTO proxy_request_logs
(request_id,provider_id,app_type,model,request_model,pricing_model,input_tokens,output_tokens,
 cache_read_tokens,cache_creation_tokens,input_cost_usd,output_cost_usd,cache_read_cost_usd,
 cache_creation_cost_usd,total_cost_usd,latency_ms,first_token_ms,duration_ms,status_code,created_at,data_source)
VALUES
('r1','p','codex','m','m','m',1000,200,10,1,'0.01','0.02','0.002','0.001','0.033',1,7,900,200,2,'proxy'),
('ignored','p','claude','m','m','m',9,9,0,0,'0','0','0','0','9',1,1,1,200,3,'proxy');
'@
        $insert | & sqlite3 $dbPath
        Assert-Equal 0 $LASTEXITCODE 'Fixture rows must be inserted'

        $stopJson = @{ hook_event_name='Stop'; session_id='s'; turn_id='t'; cwd='C:\work'; last_assistant_message='secret answer' } | ConvertTo-Json -Compress
        Assert-Equal 0 (Invoke-CollectorProcess $collectorPath $stopJson).ExitCode 'Stop Hook must not block Codex'
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path $capturePath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path $capturePath) 'Detached notifier payload must be captured'
        $payload = [IO.File]::ReadAllText($capturePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal 'long' $payload.duration 'Configured Toast duration must reach notifier'
        Assert-Equal 6 @($payload.items).Count 'Every configured item must reach notifier'
        Assert-Equal 'Cost' $payload.items[0].label 'Item order must match config order'
        Assert-Equal 'Duration' $payload.items[5].label 'Last configured item must not be truncated'
        Assert-True (-not $payload.PSObject.Properties.Name.Contains('auto_close_seconds')) 'WPF timeout must not remain in payload'
        Assert-True (-not $payload.PSObject.Properties.Name.Contains('max_visible')) 'WPF row limit must not remain in payload'

        $logPath = Join-Path $testRoot 'logs\usage.jsonl'
        $logText = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8)
        $records = @($logText -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal 2 $records.Count 'One request and one turn summary must be logged'
        $summary = @($records | Where-Object type -eq 'turn_summary')[0]
        Assert-Equal 1200 ($summary.input_tokens + $summary.output_tokens) 'Token aggregation must remain correct'
        Assert-Equal '0.033' $summary.total_cost_usd 'Decimal cost must remain authoritative'
        Assert-True (-not $logText.Contains('secret answer')) 'Answer content must not be persisted'
        Assert-True (-not (Test-Path (Join-Path $testRoot 'state\t.json'))) 'Marker must be removed after success'
    } finally {
        Remove-Item Env:CCSWITCH_DB_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_DATA_ROOT -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:CCSWITCH_SETTLE_DELAY_MS -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_NOTIFIER_COMMAND -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

```

Add this helper and call it twice after `Test-Collector`; it verifies missing
and malformed CC Switch databases still log diagnostics without blocking the
Hook:

```powershell
function Test-CollectorFailure([bool]$CreateMalformedDatabase) {
    $failureRoot = Join-Path $env:TEMP ('token-notifier-failure-' + [guid]::NewGuid().ToString('N'))
    $failureDb = Join-Path $failureRoot 'cc-switch.db'
    $failureCapture = Join-Path $failureRoot 'notification.json'
    New-Item -ItemType Directory -Force $failureRoot | Out-Null
    try {
        if ($CreateMalformedDatabase) {
            [IO.File]::WriteAllText($failureDb, 'not sqlite', [Text.Encoding]::ASCII)
        }
        $env:CCSWITCH_DB_PATH = $failureDb
        $env:TOKENNOTIFIER_DATA_ROOT = $failureRoot
        $env:TOKENNOTIFIER_NOTIFIER_COMMAND = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $repoRoot 'tests\capture-notifier.ps1') + '" -OutputPath "' + $failureCapture + '"'
        $eventJson = @{ hook_event_name='UserPromptSubmit'; session_id='s'; turn_id='failure'; cwd='C:\work' } | ConvertTo-Json -Compress
        $result = Invoke-CollectorProcess (Join-Path $repoRoot 'scripts\collector.ps1') $eventJson
        Assert-Equal 0 $result.ExitCode 'Collection failure must not block Codex'
        Assert-True (Test-Path (Join-Path $failureRoot 'logs\errors.log')) 'Collection failure must be logged'
    } finally {
        Remove-Item Env:CCSWITCH_DB_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_DATA_ROOT -ErrorAction SilentlyContinue
        Remove-Item Env:TOKENNOTIFIER_NOTIFIER_COMMAND -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $failureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Case -in @('All', 'Collector')) {
    Test-Collector
    Test-CollectorFailure $false
    Test-CollectorFailure $true
    Write-Output 'PASS: Collector'
}
```

- [ ] **Step 2: Run lifecycle and collector tests and verify they fail**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case ToastXml
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Collector
```

Expected: FAIL because native Toast submission and the new captured payload
assertions are not complete.

- [ ] **Step 3: Implement Windows Runtime Toast submission**

Dot-source `toast-registration.ps1` from `notifier.ps1`, then add:

```powershell
function Show-ToastNotification {
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Xml)
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $nativeXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $nativeXml.LoadXml($Xml.OuterXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($nativeXml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:TokenNotifierAppId).Show($toast)
}

function Invoke-ToastNotification {
    param([Parameter(Mandatory = $true)]$Payload)
    $data = ConvertTo-NotificationPayload $Payload
    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $iconPath = Join-Path $pluginRoot 'assets\token-notifier.ico'
    Initialize-ToastRegistration -NotifierPath $PSCommandPath -IconPath $iconPath
    [TokenNotifier.ShellIntegration]::SetCurrentProcessAppId($script:TokenNotifierAppId)
    Show-ToastNotification (New-ToastXml $data)
}
```

Do not attach `Activated`, `Dismissed`, or `Failed` event handlers and do not
run a Dispatcher or WinForms message loop. Successful submission returns and
allows the hidden notifier process to exit immediately.

- [ ] **Step 4: Preserve immediate transient-file deletion and diagnostics**

Keep the read/delete sequence in a `try/finally`, then call
`Invoke-ToastNotification`. Add this notifier-local logger so registration,
XML, and submission failures use the collector's data-root precedence:

```powershell
$notifierDataRoot = if ($env:TOKENNOTIFIER_DATA_ROOT) {
    $env:TOKENNOTIFIER_DATA_ROOT
} elseif ($env:APINOTIFIER_DATA_ROOT) {
    $env:APINOTIFIER_DATA_ROOT
} elseif ($env:PLUGIN_DATA) {
    $env:PLUGIN_DATA
} else {
    Join-Path $env:USERPROFILE '.codex\token-notifier'
}

function Write-NotifierError([string]$Detail) {
    $path = Join-Path $notifierDataRoot 'logs\errors.log'
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    $line = '{0} {1}{2}' -f [DateTimeOffset]::Now.ToString('o'), $Detail, [Environment]::NewLine
    [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
}
```

The entry point must always exit 0 and must not attempt a WPF fallback:

```powershell
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($PayloadPath) {
            try { $json = [IO.File]::ReadAllText($PayloadPath, [Text.Encoding]::UTF8) }
            finally { Remove-Item -LiteralPath $PayloadPath -Force -ErrorAction SilentlyContinue }
        } else {
            $json = Read-Utf8Stdin
        }
        if (-not [string]::IsNullOrWhiteSpace($json)) {
            Invoke-ToastNotification ($json | ConvertFrom-Json)
        }
    } catch {
        try { Write-NotifierError $_.Exception.ToString() } catch { }
        exit 0
    }
}
```

Keep `Invoke-DetachedNotifier` detached and hidden. Do not add waits or retain
the payload after the notifier reads it.

- [ ] **Step 5: Run the complete automated suite**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case All
```

Expected: every case prints `PASS`, the process exits 0, tests do not create a
real notification, and no fixture content is left under the repository.

- [ ] **Step 6: Commit native Toast submission**

```powershell
git add scripts/notifier.ps1 scripts/collector.ps1 tests/token-notifier.tests.ps1 tests/capture-notifier.ps1
git commit -m "feat: submit native Windows toast notifications"
```

---

### Task 5: Document, Smoke-Test, And Release The Behavior Change

**Files:**
- Modify: `README.md`
- Modify: `.codex-plugin/plugin.json`
- Modify: `tests/token-notifier.tests.ps1`

**Interfaces:**
- Consumes: All runtime interfaces from Tasks 1-4.
- Produces: User documentation and version `0.2.0`; no new runtime API.

- [ ] **Step 1: Add failing package and documentation assertions**

Add a package test that checks the release metadata and documentation contract:

```powershell
function Test-Package {
    $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot '.codex-plugin\plugin.json') | ConvertFrom-Json
    Assert-Equal '0.2.0' $manifest.version 'Toast release must use version 0.2.0'
    Assert-True (Test-Path (Join-Path $repoRoot 'assets\token-notifier.ico')) 'Toast icon must be packaged'
    Assert-True (Test-Path (Join-Path $repoRoot 'scripts\unregister-toast.ps1')) 'Registration cleanup script must be packaged'
    $readme = Get-Content -Raw -Encoding UTF8 (Join-Path $repoRoot 'README.md')
    Assert-True ($readme.Contains('Lunfeng.TokenNotifier')) 'README must document the registered identity'
    Assert-True ($readme.Contains('"duration": "short"')) 'README must document Toast duration config'
    Assert-True ($readme.Contains('unregister-toast.ps1')) 'README must document registration cleanup'
    Assert-True ($readme.Contains('Windows may truncate')) 'README must disclose adaptive Toast limits'
}
```

Include `Package` in the parameter `ValidateSet` and `All` dispatch.

- [ ] **Step 2: Run the package test and verify it fails**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case Package
```

Expected: FAIL because the manifest and README still describe version 0.1.1
and WPF popup configuration.

- [ ] **Step 3: Update README and release metadata**

Update the README to cover:

- Native Adaptive Toast behavior and Windows-controlled layout/truncation.
- The exact `toast.duration` values `short` and `long`.
- The unchanged `items`, `field`, `expression`, and `format` examples.
- The fact that every item is submitted with no plugin-side limit.
- Legacy `popup.auto_close_seconds` migration and ignored WPF-only settings.
- Per-user AUMID, shortcut, registry key, icon, no elevation, and no resident
  process.
- No detail window, buttons, click handling, or notification payload history.
- The exact cleanup command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\unregister-toast.ps1
```

- Troubleshooting Windows notification permissions, Do Not Disturb, and
  `logs\errors.log`.

Set `.codex-plugin/plugin.json` version to `0.2.0` and update the long
description to say "native Windows notifications" without claiming unlimited
visible height.

- [ ] **Step 4: Run automated tests and a real Toast smoke test**

Run the suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-notifier.tests.ps1 -Case All
```

Then create a temporary UTF-8 payload and invoke the real notifier:

```powershell
$smokePath = Join-Path $env:TEMP ('token-notifier-smoke-' + [guid]::NewGuid().ToString('N') + '.json')
$smoke = [ordered]@{
    kind = 'usage'
    title = 'TokenNotifier · smoke test'
    duration = 'long'
    items = @(
        [ordered]@{ label = '费用 & 税'; value = '$0.0182' },
        [ordered]@{ label = '输入 Token'; value = '10,230' },
        [ordered]@{ label = '输出 Token'; value = '2,220' },
        [ordered]@{ label = '总 Token'; value = '12,450' },
        [ordered]@{ label = '表达式 <结果>'; value = '12,450 > 0' },
        [ordered]@{ label = '耗时'; value = '8,300 ms' }
    )
}
[IO.File]::WriteAllText($smokePath, ($smoke | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
powershell.exe -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File .\scripts\notifier.ps1 -PayloadPath $smokePath
```

Verify manually:

- One native Toast appears and no WPF window appears.
- It is labeled `TokenNotifier` and uses the packaged icon.
- All six rows are submitted; any visual truncation is attributable to Windows.
- Chinese and XML-special characters render correctly.
- Clicking the Toast invokes no TokenNotifier action or detail window.
- The notification is grouped under TokenNotifier in Notification Center.
- TokenNotifier has an independent entry in Windows notification settings.
- `$smokePath` no longer exists after the notifier reads it.
- Running the smoke test again does not rewrite a correct shortcut.

- [ ] **Step 5: Verify cleanup and automatic repair**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\unregister-toast.ps1
```

Verify the exact Start Menu shortcut and AUMID registry key are gone while
user configuration and logs remain. Run the smoke test once more and verify
the registration is recreated without elevation and the Toast still appears.

- [ ] **Step 6: Commit documentation and version metadata**

```powershell
git add README.md .codex-plugin/plugin.json tests/token-notifier.tests.ps1
git commit -m "docs: release native toast notifications"
```

- [ ] **Step 7: Review the release diff and tag only after all checks pass**

```powershell
git status --short
git diff main...HEAD --check
git log --oneline main..HEAD
git tag -a v0.2.0 -m "TokenNotifier v0.2.0"
```

Expected: the worktree is clean before tagging, `git diff --check` prints no
errors, and the tag is created only after the automated and manual Toast checks
have passed.
