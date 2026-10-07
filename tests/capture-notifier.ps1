param([Parameter(Mandatory = $true)][string]$OutputPath)

$ErrorActionPreference = 'Stop'
$stream = [Console]::OpenStandardInput()
$memory = New-Object IO.MemoryStream
$buffer = New-Object byte[] 4096
try {
    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $memory.Write($buffer, 0, $count)
    }
    $text = [Text.Encoding]::UTF8.GetString($memory.ToArray()).Trim()
    [IO.File]::WriteAllText($OutputPath, $text, [Text.UTF8Encoding]::new($false))
} finally {
    $memory.Dispose()
}
