[CmdletBinding()]
param(
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes'),
    [Parameter()][string]$HermesHome = (Join-Path $env:LOCALAPPDATA 'OfflineHermes-home'),
    [Parameter()][switch]$Force,
    [Parameter()][switch]$SkipDesktopBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'install-offline.ps1') @PSBoundParameters
exit $LASTEXITCODE
