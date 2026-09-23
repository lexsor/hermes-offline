[CmdletBinding()]
param(
    [Parameter()][string]$OutputDirectory = (Join-Path (Get-Location) 'dist'),
    [Parameter()][switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

Assert-NativeWindowsX64
$temporaryInstall = Join-Path ([IO.Path]::GetTempPath()) "offline-hermes-bundle-$([Guid]::NewGuid().ToString('N'))"
$temporaryHome = "$temporaryInstall-home"
try {
    & (Join-Path $PSScriptRoot 'install-offline.ps1') -InstallRoot $temporaryInstall -HermesHome $temporaryHome
    if ($LASTEXITCODE -ne 0) { throw 'The offline installation used for bundle assembly failed.' }
    & (Join-Path $PSScriptRoot 'verify-offline.ps1') -InstallRoot $temporaryInstall
    if ($LASTEXITCODE -ne 0) { throw 'The assembled offline runtime failed verification.' }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $archive = Join-Path $OutputDirectory 'OfflineHermes-windows-x64-desktop.zip'
    if ((Test-Path -LiteralPath $archive) -and -not $Force) {
        throw "Bundle already exists: $archive (use -Force to replace it)."
    }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -Path (Join-Path $temporaryInstall '*') -DestinationPath $archive -CompressionLevel Optimal
    Write-Host "Built verified bundle: $archive"
}
finally {
    foreach ($path in @($temporaryInstall, $temporaryHome)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}
