<#
.SYNOPSIS
Removes an Offline Hermes installation.

.DESCRIPTION
Removes the install root (runtimes, venv, desktop app, launchers). The Hermes
home (settings, sessions, memories, desktop user data) is kept unless
-RemoveHermesHome is given. Backups left by install-offline.ps1 -Force are kept
unless -RemoveBackups is given.

Only a folder whose install-state.json describes a windows-x64-desktop install
is removed. Folders that may belong to an online Hermes install
(%LOCALAPPDATA%\hermes, %APPDATA%\Hermes) are reported, never removed.

Use -WhatIf to see what would be removed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes'),
    # Also remove the Hermes home recorded in install-state.json (your
    # settings and history). Pass -HermesHome to name a different one.
    [Parameter()][switch]$RemoveHermesHome,
    [Parameter()][string]$HermesHome,
    [Parameter()][switch]$RemoveBackups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

function Assert-RemovablePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -match '[%"]') { throw "$Label path contains % or a quote character; remove it manually: $full" }
    $protected = @(
        [IO.Path]::GetPathRoot($full), $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP,
        $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Get-OfflineHermesRepoRoot)
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    foreach ($candidate in $protected) {
        # Refuse the folder itself and anything that contains it.
        if ($full -eq $candidate -or $candidate.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove $Label '$full': it is, or contains, $candidate."
        }
    }
    return $full
}

function Test-OfflineInstall {
    param([Parameter(Mandatory)][string]$Path)
    $statePath = Join-Path $Path 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.profile -ne 'windows-x64-desktop') { return $null }
    return $state
}

function Remove-Tree {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not $PSCmdlet.ShouldProcess($Path, "Remove $Label")) {
        if ($WhatIfPreference) { $script:removed++ }
        return
    }
    # rd handles paths beyond MAX_PATH (the upstream docs tree) and does not
    # follow junctions.
    & cmd.exe /d /c "rd /s /q `"$(Get-LongPath $Path)`""
    if (Test-Path -LiteralPath $Path) {
        throw "Could not fully remove $Label at $Path. Close any program using it and run this script again."
    }
    Write-Host "Removed $Label`: $Path"
    $script:removed++
}

$script:removed = 0
try {
    Assert-NativeWindowsX64
    $installPath = Assert-RemovablePath -Path $InstallRoot -Label 'install root'

    $state = $null
    if (Test-Path -LiteralPath $installPath) {
        $state = Test-OfflineInstall -Path $installPath
        if (-not $state) {
            throw "$installPath has no windows-x64-desktop install-state.json, so it is not an Offline Hermes install. Nothing was removed."
        }
    } else {
        Write-Host "No installation at $installPath."
    }

    if ($RemoveHermesHome -and -not $HermesHome) {
        if (-not $state) { throw 'The install is gone, so its Hermes home is unknown. Pass -HermesHome <path> with -RemoveHermesHome.' }
        $HermesHome = $state.hermes_home
    }
    $homePath = $null
    if ($RemoveHermesHome) {
        $homePath = Assert-RemovablePath -Path $HermesHome -Label 'Hermes home'
        if ($installPath.StartsWith($homePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove Hermes home '$homePath': it contains the install root."
        }
    }

    # Running processes would keep files open and leave a half-removed tree.
    $roots = @($installPath) + @(if ($homePath) { $homePath })
    # A local $WhatIfPreference keeps -WhatIf from echoing the CimCmdlets
    # module's alias setup when it autoloads.
    $processes = & { $WhatIfPreference = $false; Get-CimInstance -ClassName Win32_Process }
    $running = @($processes | Where-Object {
        $exe = $_.ExecutablePath
        $exe -and @($roots | Where-Object { $exe.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    })
    if ($running.Count -gt 0) {
        $list = ($running | ForEach-Object { "  $($_.Name) (PID $($_.ProcessId)): $($_.ExecutablePath)" }) -join "`n"
        throw "Offline Hermes is still running. Close it first:`n$list"
    }

    if ($state) { Remove-Tree -Path $installPath -Label 'install root' }

    $parent = Split-Path -Parent $installPath
    $leaf = Split-Path -Leaf $installPath
    $siblings = @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "$leaf.previous-*" -or $_.Name -like "$leaf.staging-*"
    })
    foreach ($sibling in $siblings) {
        $isStaging = $sibling.Name -like "$leaf.staging-*"
        if (-not $RemoveBackups) {
            Write-Host "Kept $(if ($isStaging) { 'leftover staging folder' } else { 'backup' }): $($sibling.FullName) (use -RemoveBackups)"
            continue
        }
        # A backup must be a real install; a staging folder is the installer's
        # own scratch space from an interrupted run.
        if (-not $isStaging -and -not (Test-OfflineInstall -Path $sibling.FullName)) {
            Write-Warning "Skipped $($sibling.FullName): no windows-x64-desktop install-state.json."
            continue
        }
        Remove-Tree -Path $sibling.FullName -Label $(if ($isStaging) { 'staging folder' } else { 'backup' })
    }

    $verifyCache = Join-Path ([IO.Path]::GetTempPath()) 'offline-hermes-verify-cache'
    if (Test-Path -LiteralPath $verifyCache) { Remove-Tree -Path $verifyCache -Label 'verify-offline cache' }

    if ($homePath) {
        if (Test-Path -LiteralPath $homePath) { Remove-Tree -Path $homePath -Label 'Hermes home' }
    } elseif ($state -and $state.hermes_home) {
        Write-Host "Kept your Hermes home: $($state.hermes_home) (use -RemoveHermesHome to delete it)"
    }

    # Created by builds before patch 0002, or by any online Hermes install.
    foreach ($residue in @((Join-Path $env:LOCALAPPDATA 'hermes'), (Join-Path $env:APPDATA 'Hermes'))) {
        if (Test-Path -LiteralPath $residue) {
            Write-Host "Not removed: $residue. It belongs to an online Hermes install or to an Offline Hermes build older than patch 0002. Check it before deleting it."
        }
    }

    $verb = if ($WhatIfPreference) { 'would be removed' } else { 'removed' }
    Write-Host "Uninstall finished: $script:removed item(s) $verb."
}
catch {
    Write-OfflineHermesFailure $_
    exit 1
}
