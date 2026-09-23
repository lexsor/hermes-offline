[CmdletBinding()]
param(
    [Parameter()][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

if (-not $RepoRoot) {
    $RepoRoot = Get-OfflineHermesRepoRoot
}

try {
    Test-VendoredArtifacts -RepoRoot $RepoRoot | Out-Null
    Write-Host 'Dependency verification passed.'
}
catch {
    Write-OfflineHermesFailure $_
    exit 1
}
