param([string]$PayloadPath)
$ErrorActionPreference = 'Stop'

function Read-Utf8Stdin {
    $stream = [Console]::OpenStandardInput()
    $memory = New-Object IO.MemoryStream
    $buffer = New-Object byte[] 4096
    try {
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $memory.Write($buffer, 0, $count) }
        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    } finally { $memory.Dispose() }
}

function Get-NotificationHeight {
    param([int]$ItemCount, [bool]$HasMessage)
    $height = 120 + ([Math]::Max(0, $ItemCount) * 32) + $(if ($HasMessage) { 52 } else { 0 })
    return [double][Math]::Max(120, [Math]::Min(420, $height))
}

function ConvertTo-NotificationPayload {
    param([Parameter(Mandatory = $true)]$Payload)
    if ($null -eq $Payload) { throw 'Notification payload is required' }
    if ($Payload.kind -notin @('usage', 'error')) { throw 'Notification kind must be usage or error' }
    if ([string]::IsNullOrWhiteSpace([string]$Payload.title)) { throw 'Notification title is required' }
    $items = @()
    if ($null -ne $Payload.items) { foreach ($item in @($Payload.items)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.label)) { throw 'Notification item label is required' }
        $items += [pscustomobject]@{ label = [string]$item.label; value = [string]$item.value }
    } }
    $autoClose = if ($null -eq $Payload.auto_close_seconds) { 5 } else { [int]$Payload.auto_close_seconds }
    $maxVisible = if ($null -eq $Payload.max_visible) { 3 } else { [int]$Payload.max_visible }
    if ($maxVisible -lt 1) { throw 'max_visible must be positive' }
    return [pscustomobject]@{ kind = [string]$Payload.kind; title = [string]$Payload.title; items = $items; message = [string]$Payload.message; auto_close_seconds = $autoClose; max_visible = $maxVisible }
}

function Get-NotificationBatches {
    param([Parameter(Mandatory = $true)]$Payload)
    $data = ConvertTo-NotificationPayload $Payload
    $batch = [pscustomobject]@{ items = @($data.items); message = $data.message }
    return @($batch)
}

function Show-NotificationWindow {
    param($Data, $Batch, $IsFinal)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    if (-not ('TokenNotifierNativeWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TokenNotifierNativeWindow { [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int n); [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h,int n,int v); public const int GWL_EXSTYLE=-20,WS_EX_NOACTIVATE=0x08000000,WS_EX_TOOLWINDOW=0x00000080; }
'@ -ErrorAction SilentlyContinue
    }
    $window = New-Object System.Windows.Window
    $window.WindowStyle = 'None'
    $window.ResizeMode = 'NoResize'
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.Topmost = $true
    $window.SizeToContent = 'Manual'
    $window.Width = 380
    $window.Height = Get-NotificationHeight @($Batch.items).Count (-not [string]::IsNullOrWhiteSpace($Batch.message))
    $window.Background = [System.Windows.Media.Brushes]::White
    $window.BorderBrush = [System.Windows.Media.Brushes]::LightGray
    $window.BorderThickness = New-Object System.Windows.Thickness(1)

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(14)
    $root.Width = 350
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $Data.title
    $title.FontSize = 15
    $title.FontWeight = 'SemiBold'
    $title.TextWrapping = 'Wrap'
    $title.MaxWidth = 350
    $root.Children.Add($title) | Out-Null
    foreach ($item in @($Batch.items)) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = New-Object System.Windows.Thickness(0, 7, 0, 0)
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $item.label
        $label.TextWrapping = 'Wrap'
        $label.MaxWidth = 220
        $value = New-Object System.Windows.Controls.TextBlock
        $value.Text = $item.value
        $value.TextWrapping = 'Wrap'
        $value.MaxWidth = 130
        $value.HorizontalAlignment = 'Right'
        [System.Windows.Controls.DockPanel]::SetDock($value, 'Right')
        $row.Children.Add($value) | Out-Null
        $row.Children.Add($label) | Out-Null
        $root.Children.Add($row) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($Batch.message)) {
        $message = New-Object System.Windows.Controls.TextBlock
        $message.Text = $Batch.message
        $message.TextWrapping = 'Wrap'
        $message.MaxWidth = 350
        $message.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
        $message.Foreground = [System.Windows.Media.Brushes]::DarkRed
        $root.Children.Add($message) | Out-Null
    }
    $scroll.Content = $root
    $window.Content = $scroll

    $sourceHandler = {
        $interop = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $handle = $interop.Handle
        [TokenNotifierNativeWindow]::SetWindowLong($handle, [TokenNotifierNativeWindow]::GWL_EXSTYLE, ([TokenNotifierNativeWindow]::GetWindowLong($handle, [TokenNotifierNativeWindow]::GWL_EXSTYLE) -bor [TokenNotifierNativeWindow]::WS_EX_NOACTIVATE -bor [TokenNotifierNativeWindow]::WS_EX_TOOLWINDOW))
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $window.Left = $workArea.Right - $window.Width - 16
        $window.Top = $workArea.Bottom - $window.Height - 16
    }.GetNewClosure()
    $window.Add_SourceInitialized($sourceHandler)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = New-Object TimeSpan(0, 0, [Math]::Max(1, [int]$Data.auto_close_seconds))
    $tickHandler = { $timer.Stop(); $window.Close() }.GetNewClosure()
    $timer.Add_Tick($tickHandler)
    $closedHandler = {
        if ($timer.IsEnabled) { $timer.Stop() }
        if ($IsFinal) { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
    }.GetNewClosure()
    $window.Add_Closed($closedHandler)
    $window.Show()
    $timer.Start()
}

function Show-Notification {
    param([Parameter(Mandatory = $true)]$Payload)
    $data = ConvertTo-NotificationPayload $Payload
    $batches = @(Get-NotificationBatches $data)
    $state = [pscustomobject]@{ Index = 0 }
    $script:NotificationNextBatch = {
        $isFinal = $state.Index -ge ($batches.Count - 1)
        Show-NotificationWindow $data $batches[$state.Index] $isFinal
        $state.Index++
    }.GetNewClosure()
    try {
        & $script:NotificationNextBatch
        [System.Windows.Threading.Dispatcher]::Run()
    } catch { return }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($PayloadPath) {
            try { $json = [IO.File]::ReadAllText($PayloadPath, [Text.Encoding]::UTF8) }
            finally { Remove-Item -LiteralPath $PayloadPath -Force -ErrorAction SilentlyContinue }
        } else { $json = Read-Utf8Stdin }
        if (-not [string]::IsNullOrWhiteSpace($json)) { Show-Notification ($json | ConvertFrom-Json) }
    } catch { exit 0 }
}
