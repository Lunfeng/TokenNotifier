param([string]$PayloadPath)

$ErrorActionPreference = 'Stop'
$script:NotifierScriptPath = $PSCommandPath
$script:NotifierDataRoot = if ($env:TOKENNOTIFIER_DATA_ROOT) {
    $env:TOKENNOTIFIER_DATA_ROOT
} elseif ($env:APINOTIFIER_DATA_ROOT) {
    $env:APINOTIFIER_DATA_ROOT
} elseif ($env:PLUGIN_DATA) {
    $env:PLUGIN_DATA
} else {
    Join-Path $env:USERPROFILE '.codex\token-notifier'
}

. (Join-Path $PSScriptRoot 'toast-registration.ps1')

function Read-Utf8Stdin {
    $stream = [Console]::OpenStandardInput()
    $memory = New-Object IO.MemoryStream
    $buffer = New-Object byte[] 4096
    try {
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $count)
        }
        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    } finally {
        $memory.Dispose()
    }
}

function Write-NotifierError([string]$Detail) {
    $path = Join-Path $script:NotifierDataRoot 'logs\errors.log'
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    $line = '{0} {1}{2}' -f [DateTimeOffset]::Now.ToString('o'), $Detail, [Environment]::NewLine
    [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-NotificationPayload {
    param([Parameter(Mandatory = $true)]$Payload)

    if ($null -eq $Payload) { throw 'Notification payload is required' }
    if ($Payload.kind -notin @('usage', 'error')) { throw 'Notification kind must be usage or error' }
    if ([string]::IsNullOrWhiteSpace([string]$Payload.title)) { throw 'Notification title is required' }
    $duration = if ($null -eq $Payload.duration) { 'short' } else { [string]$Payload.duration }
    if ($duration -notin @('short', 'long')) { throw 'Notification duration must be short or long' }
    $items = @()
    if ($null -ne $Payload.items) {
        foreach ($item in @($Payload.items)) {
            if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.label)) {
                throw 'Notification item label is required'
            }
            $items += [pscustomobject]@{ label=[string]$item.label; value=[string]$item.value }
        }
    }
    return [pscustomobject]@{
        kind = [string]$Payload.kind
        title = [string]$Payload.title
        items = $items
        message = [string]$Payload.message
        duration = $duration
    }
}

function Add-XmlElement {
    param(
        [System.Xml.XmlDocument]$Document,
        [System.Xml.XmlNode]$Parent,
        [string]$Name,
        [hashtable]$Attributes = @{},
        [AllowNull()][string]$Text
    )

    $element = $Document.CreateElement($Name)
    foreach ($key in $Attributes.Keys) {
        $element.SetAttribute([string]$key, [string]$Attributes[$key])
    }
    if ($null -ne $Text) { $element.InnerText = $Text }
    $Parent.AppendChild($element) | Out-Null
    return $element
}

function New-ToastXml {
    param([Parameter(Mandatory = $true)]$Data)

    $document = New-Object System.Xml.XmlDocument
    $toast = Add-XmlElement $document $document 'toast' @{ duration=$Data.duration } $null
    $visual = Add-XmlElement $document $toast 'visual' @{} $null
    $binding = Add-XmlElement $document $visual 'binding' @{ template='ToastGeneric' } $null
    Add-XmlElement $document $binding 'text' @{} $Data.title | Out-Null
    foreach ($item in @($Data.items)) {
        $group = Add-XmlElement $document $binding 'group' @{} $null
        $labelColumn = Add-XmlElement $document $group 'subgroup' @{ 'hint-weight'='2' } $null
        Add-XmlElement $document $labelColumn 'text' @{ 'hint-wrap'='true' } ([string]$item.label) | Out-Null
        $valueColumn = Add-XmlElement $document $group 'subgroup' @{ 'hint-weight'='1' } $null
        Add-XmlElement $document $valueColumn 'text' @{ 'hint-align'='right'; 'hint-wrap'='true' } ([string]$item.value) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Data.message)) {
        Add-XmlElement $document $binding 'text' @{ 'hint-wrap'='true' } ([string]$Data.message) | Out-Null
    }
    return $document
}

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
    Initialize-ToastRegistration -NotifierPath $script:NotifierScriptPath -IconPath $iconPath
    [TokenNotifier.ShellIntegration]::SetCurrentProcessAppId($script:TokenNotifierAppId)
    Show-ToastNotification (New-ToastXml $data)
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($PayloadPath) {
            try { $json = [IO.File]::ReadAllText($PayloadPath, [Text.Encoding]::UTF8) }
            finally { Remove-Item -LiteralPath $PayloadPath -Force -ErrorAction SilentlyContinue }
        } elseif ([Console]::IsInputRedirected) {
            $json = Read-Utf8Stdin
        } else {
            exit 0
        }
        if (-not [string]::IsNullOrWhiteSpace($json)) {
            Invoke-ToastNotification ($json | ConvertFrom-Json)
        }
    } catch {
        try { Write-NotifierError $_.Exception.ToString() } catch { }
        exit 0
    }
}
