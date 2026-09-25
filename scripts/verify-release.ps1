[CmdletBinding()]
param(
    # The extracted release folder (default: the one containing this script).
    [Parameter()][string]$ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

if (-not $ReleaseRoot) {
    $ReleaseRoot = Get-OfflineHermesRepoRoot
}

try {
    Test-ReleaseTree -ReleaseRoot $ReleaseRoot | Out-Null
    Write-Host 'Release verification passed.'
}
catch {
    Write-OfflineHermesFailure $_
    exit 1
}
