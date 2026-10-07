$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toast-registration.ps1')

Remove-ToastRegistration
Write-Output 'TokenNotifier Toast registration removed.'
