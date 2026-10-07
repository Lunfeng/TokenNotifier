param([string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\token-notifier.ico'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$frames = New-Object 'System.Collections.Generic.List[object]'
foreach ($size in @(16, 20, 24, 32, 48, 256)) {
    $bitmap = New-Object Drawing.Bitmap($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::Transparent)
        $scale = $size / 64.0
        $blue = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 37, 99, 235))
        $white = New-Object Drawing.SolidBrush([Drawing.Color]::White)
        $green = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 34, 197, 94))
        try {
            $graphics.FillEllipse($blue, 2 * $scale, 2 * $scale, 60 * $scale, 60 * $scale)
            $bell = New-Object Drawing.Drawing2D.GraphicsPath
            try {
                $bell.AddArc(18 * $scale, 15 * $scale, 28 * $scale, 28 * $scale, 180, 180)
                $bell.AddLine(46 * $scale, 29 * $scale, 50 * $scale, 43 * $scale)
                $bell.AddLine(50 * $scale, 43 * $scale, 14 * $scale, 43 * $scale)
                $bell.AddLine(14 * $scale, 43 * $scale, 18 * $scale, 29 * $scale)
                $bell.CloseFigure()
                $graphics.FillPath($white, $bell)
            } finally {
                $bell.Dispose()
            }
            $graphics.FillEllipse($white, 27 * $scale, 44 * $scale, 10 * $scale, 7 * $scale)
            $graphics.FillEllipse($green, 42 * $scale, 39 * $scale, 16 * $scale, 16 * $scale)
        } finally {
            $blue.Dispose()
            $white.Dispose()
            $green.Dispose()
        }
        $memory = New-Object IO.MemoryStream
        $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
        $frames.Add([pscustomobject]@{ Size=$size; Bytes=$memory.ToArray() })
        $memory.Dispose()
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

New-Item -ItemType Directory -Force (Split-Path -Parent $OutputPath) | Out-Null
$file = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
$writer = New-Object IO.BinaryWriter($file)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$frames.Count)
    $offset = 6 + (16 * $frames.Count)
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
} finally {
    $writer.Dispose()
    $file.Dispose()
}

Write-Output $OutputPath
