[CmdletBinding()]
param(
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

try {
    Assert-NativeWindowsX64
    Test-VendoredArtifacts -RepoRoot (Get-OfflineHermesRepoRoot) -Quiet | Out-Null

    $required = @(
        'install-state.json',
        'venv\Scripts\python.exe',
        'venv\Scripts\hermes.exe',
        'runtime\node\node.exe',
        'runtime\git\cmd\git.exe',
        'hermes-offline.cmd'
    )
    foreach ($relative in $required) {
        $path = Join-Path $InstallRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Installed runtime is incomplete; missing $path"
        }
    }

    $state = Get-Content -LiteralPath (Join-Path $InstallRoot 'install-state.json') -Raw | ConvertFrom-Json
    if ($state.profile -ne 'windows-x64-desktop' -or $state.network_fallback -ne $false) {
        throw 'install-state.json does not describe a sealed windows-x64-desktop installation.'
    }

    $hermesHome = $state.hermes_home
    if (-not $hermesHome) { throw 'install-state.json does not record hermes_home; reinstall with the current installer.' }
    $configPath = Join-Path $hermesHome 'config.yaml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Offline Hermes home has no configuration: $configPath"
    }

    # Also route stray egress to a closed loopback port so this probe cannot
    # reach the network even on a connected host.
    $guard = Get-OfflineNetworkGuard -CacheRoot (Join-Path ([IO.Path]::GetTempPath()) 'offline-hermes-verify-cache')
    $guard.HERMES_HOME = $hermesHome
    Invoke-WithEnvironment -Variables $guard -ScriptBlock {
        $venvPython = Join-Path $InstallRoot 'venv\Scripts\python.exe'
        $probe = 'import yaml, dotenv; from hermes_cli.config import load_config; c = load_config(); ' +
            'assert c.get("updates", {}).get("check", True) is False, "updates.check is not false"; ' +
            'assert (c.get("model_catalog") or {}).get("enabled", True) is False, "model_catalog.enabled is not false"; ' +
            'assert str((c.get("models_dev") or {}).get("url", "")).startswith("http://127.0.0.1"), "models_dev.url is not a loopback address"; ' +
            'print("Hermes Python import/config probe passed.")'
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @('-c', $probe)

        # Every console-script launcher must point at the final venv, not a
        # staging directory.
        foreach ($launcher in @('hermes.exe', 'pip.exe')) {
            $launcherPath = Join-Path $InstallRoot "venv\Scripts\$launcher"
            $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($launcherPath))
            if ($text -match '\.staging-[0-9a-f]{32}') {
                throw "Console-script launcher still references a staging path: $launcherPath"
            }
        }

        $versionOutput = & (Join-Path $InstallRoot 'venv\Scripts\hermes.exe') --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "hermes --version failed with exit code $LASTEXITCODE`n$versionOutput" }
        Write-Host $versionOutput.TrimEnd()
        if ($versionOutput -match 'Update available|Up to date') {
            throw 'hermes --version performed an update check; the offline home must set updates.check: false.'
        }
    }

    if ($state.desktop_built) {
        $desktop = Join-Path $InstallRoot 'app\Hermes.exe'
        if (-not (Test-Path -LiteralPath $desktop -PathType Leaf)) {
            throw "install-state.json records a desktop build, but $desktop is missing."
        }
    }

    Write-Host 'Offline runtime verification passed.'
    Write-Host 'Note: public-network blocking and the live desktop smoke test remain Phase 4 validation gates.'
}
catch {
    Write-OfflineHermesFailure $_
    exit 1
}
