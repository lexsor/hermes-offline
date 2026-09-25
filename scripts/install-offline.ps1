[CmdletBinding()]
param(
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes'),
    [Parameter()][string]$HermesHome = (Join-Path $env:LOCALAPPDATA 'OfflineHermes-home'),
    [Parameter()][switch]$Force,
    [Parameter()][switch]$SkipDesktopBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

function Get-SingleChildDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $children = @(Get-ChildItem -LiteralPath $Path -Directory)
    if ($children.Count -ne 1) {
        throw "Expected one top-level directory in $Path; found $($children.Count)."
    }
    return $children[0].FullName
}

function Install-NodeClosure {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$NodeRoot,
        [Parameter(Mandatory)][string]$WorkRoot
    )

    $nodeExe = Join-Path $NodeRoot 'node.exe'
    $npmCli = Join-Path $NodeRoot 'node_modules\npm\bin\npm-cli.js'
    $npmCache = Join-Path $WorkRoot 'npm-cache'
    New-Item -ItemType Directory -Path $npmCache -Force | Out-Null

    $tarballRoot = Join-Path $RepoRoot 'vendor\node\windows-x64-desktop\tarballs'
    $tarballs = @(Get-ChildItem -LiteralPath $tarballRoot -Filter '*.tgz' -File | Sort-Object Name)
    if ($tarballs.Count -ne 1027) {
        throw "Expected 1027 npm tarballs but found $($tarballs.Count) in $tarballRoot."
    }

    Write-Host "Priming the isolated npm cache from $($tarballs.Count) local tarballs..."
    # npm cache add accepts multiple specs and resolves them concurrently in one
    # process. Keep batches below Windows' command-line length limit.
    $batchSize = 80
    for ($offset = 0; $offset -lt $tarballs.Count; $offset += $batchSize) {
        $last = [Math]::Min($offset + $batchSize - 1, $tarballs.Count - 1)
        $cacheArguments = @($npmCli, 'cache', 'add')
        foreach ($index in $offset..$last) {
            $cacheArguments += $tarballs[$index].FullName
        }
        $cacheArguments += @(
            '--cache', $npmCache,
            '--offline', '--ignore-scripts', '--no-audit', '--no-fund', '--update-notifier=false'
        )
        Invoke-CheckedCommand -FilePath $nodeExe -ArgumentList $cacheArguments -WorkingDirectory $SourceRoot
    }

    $npmEnvironment = @{
        npm_config_cache = $npmCache
        npm_config_offline = 'true'
        npm_config_audit = 'false'
        npm_config_fund = 'false'
        npm_config_update_notifier = 'false'
    }
    Invoke-WithEnvironment -Variables $npmEnvironment -ScriptBlock {
        Invoke-CheckedCommand -FilePath $nodeExe -ArgumentList @(
            $npmCli, 'ci', '--workspace', 'apps/desktop',
            '--offline', '--ignore-scripts', '--legacy-peer-deps',
            '--no-audit', '--no-fund', '--update-notifier=false'
        ) -WorkingDirectory $SourceRoot
    }

    # npm lifecycle scripts are disabled globally. Materialize only the reviewed
    # native/runtime payloads needed by the Windows desktop build, at the
    # location Node resolves from the desktop workspace.
    $desktopRoot = Join-Path $SourceRoot 'apps\desktop'
    $electronPackage = Resolve-NodePackageDirectory -FromDirectory $desktopRoot -PackageName 'electron'
    $electronDist = Join-Path $electronPackage 'dist'
    Expand-ZipClean -Archive (Join-Path $RepoRoot 'vendor\browser\windows-x64\electron-v40.10.2-win32-x64.zip') -Destination $electronDist
    [IO.File]::WriteAllText((Join-Path $electronPackage 'path.txt'), 'electron.exe')
    if (-not (Test-Path -LiteralPath (Join-Path $electronDist 'electron.exe') -PathType Leaf)) {
        throw "Vendored Electron archive did not produce $electronDist\electron.exe"
    }

    $getWindowsPackage = Resolve-NodePackageDirectory -FromDirectory $desktopRoot -PackageName 'get-windows'
    $getWindowsBinding = Join-Path $getWindowsPackage 'lib\binding\napi-9-win32-unknown-x64'
    New-Item -ItemType Directory -Path $getWindowsBinding -Force | Out-Null
    $nativeScratch = Join-Path $WorkRoot 'get-windows-native'
    New-Item -ItemType Directory -Path $nativeScratch -Force | Out-Null
    Invoke-CheckedCommand -FilePath 'tar.exe' -ArgumentList @(
        '-xzf', (Join-Path $RepoRoot 'vendor\binaries\windows-x64\get-windows-9.3.0-napi-9-win32-unknown-x64.tar.gz'),
        '-C', $nativeScratch
    )
    $nativeBinding = Get-ChildItem -LiteralPath $nativeScratch -Filter 'node-get-windows.node' -File -Recurse | Select-Object -First 1
    if (-not $nativeBinding) { throw 'The vendored get-windows archive contains no node-get-windows.node.' }
    Copy-Item -LiteralPath $nativeBinding.FullName -Destination (Join-Path $getWindowsBinding 'node-get-windows.node') -Force

    $esbuildPackage = Resolve-NodePackageDirectory -FromDirectory $desktopRoot -PackageName 'esbuild'
    Invoke-CheckedCommand -FilePath $nodeExe -ArgumentList @((Join-Path $esbuildPackage 'install.js')) -WorkingDirectory $SourceRoot
}

function Build-DesktopApplication {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$NodeRoot,
        [Parameter(Mandatory)][string]$AppDestination
    )

    # upstream's run-electron-builder.mjs silently falls back to @electron/get
    # when it cannot find a local dist; refuse to start the builder in that state.
    $electronPackage = Resolve-NodePackageDirectory -FromDirectory (Join-Path $SourceRoot 'apps\desktop') -PackageName 'electron'
    $electronExe = Join-Path $electronPackage 'dist\electron.exe'
    if (-not (Test-Path -LiteralPath $electronExe -PathType Leaf)) {
        throw "Missing materialized Electron runtime: $electronExe`nExpected from vendor/browser/windows-x64/electron-v40.10.2-win32-x64.zip. No download was attempted."
    }

    $npmCmd = Join-Path $NodeRoot 'npm.cmd'
    Invoke-WithEnvironment -Variables @{ PATH = "$NodeRoot;$env:PATH"; CI = '1' } -ScriptBlock {
        Invoke-CheckedCommand -FilePath $npmCmd -ArgumentList @('run', 'build', '--workspace', 'apps/desktop') -WorkingDirectory $SourceRoot
        Invoke-CheckedCommand -FilePath $npmCmd -ArgumentList @(
            'run', 'builder', '--workspace', 'apps/desktop', '--', '--dir', '--win', '--x64', '--publish', 'never'
        ) -WorkingDirectory $SourceRoot
    }

    $builtApp = Join-Path $SourceRoot 'apps\desktop\release\win-unpacked'
    if (-not (Test-Path -LiteralPath (Join-Path $builtApp 'Hermes.exe') -PathType Leaf)) {
        throw "Desktop build did not produce $builtApp\Hermes.exe"
    }
    Copy-DirectoryContents -Source $builtApp -Destination $AppDestination
}

function Initialize-HermesHome {
    param([Parameter(Mandatory)][string]$HermesHome)

    # The home is user-owned state: create and seed it once, never overwrite it,
    # and keep it outside the replaceable install root.
    New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null
    $configPath = Join-Path $HermesHome 'config.yaml'
    if (Test-Path -LiteralPath $configPath) {
        Write-Host "Keeping existing Hermes configuration: $configPath"
        $existing = [IO.File]::ReadAllText($configPath)
        if ($existing -notmatch '(?m)^model_catalog:' -or $existing -notmatch '(?m)^models_dev:') {
            Write-Warning ("$configPath predates the offline catalog settings. The desktop backend will try to " +
                "reach hermes-agent.nousresearch.com, raw.githubusercontent.com and models.dev until you add:`n" +
                "model_catalog:`n  enabled: false`nmodels_dev:`n  url: `"http://127.0.0.1:9/offline-hermes-models-dev-disabled`"")
        }
        return
    }
    $seed = @'
# Seeded by Offline Hermes. This file is user-owned; edit it freely.
# Passive update checks contact api.github.com; keep them off offline.
updates:
  check: false
telemetry:
  shared_metrics:
    enabled: false
    send: false
# The desktop backend downloads a model catalog (hermes-agent.nousresearch.com,
# falling back to raw.githubusercontent.com) and the models.dev registry.
# Offline, disable the catalog and point models.dev at a closed loopback port
# so the fetch fails instantly without any DNS lookup; Hermes then uses cached
# or built-in model data. Set context lengths for local models explicitly.
model_catalog:
  enabled: false
models_dev:
  url: "http://127.0.0.1:9/offline-hermes-models-dev-disabled"
'@
    [IO.File]::WriteAllText($configPath, $seed + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Seeded offline Hermes configuration: $configPath"
}

function Write-Launchers {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$HermesHome,
        [Parameter(Mandatory)][bool]$HasDesktop
    )

    # Always pin HERMES_HOME so a host-wide online Hermes install (or a global
    # HERMES_HOME) never shares state, caches, or credentials with this one.
    # OFFLINE_HERMES_HOME overrides the location recorded at install time.
    # Two plain lines rather than an if/else block: a parenthesized block would
    # break on paths such as "Program Files (x86)".
    if ($HermesHome -match '[%"]') { throw "HermesHome must not contain % or quote characters: $HermesHome" }
    $homeLine = "set `"HERMES_HOME=$HermesHome`"`nif defined OFFLINE_HERMES_HOME set `"HERMES_HOME=%OFFLINE_HERMES_HOME%`""

    $launcher = @'
@echo off
setlocal
set "OFFLINE_HERMES_ROOT=%~dp0"
__HOME_LINE__
set "HERMES_DESKTOP_HERMES=%OFFLINE_HERMES_ROOT%venv\Scripts\hermes.exe"
set "HERMES_DISABLE_LAZY_INSTALLS=1"
set "UV_OFFLINE=1"
set "PIP_NO_INDEX=1"
set "PATH=%OFFLINE_HERMES_ROOT%runtime\node;%OFFLINE_HERMES_ROOT%runtime\git\cmd;%OFFLINE_HERMES_ROOT%runtime\ripgrep;%OFFLINE_HERMES_ROOT%venv\Scripts;%PATH%"
if not exist "%OFFLINE_HERMES_ROOT%app\Hermes.exe" (
  echo Hermes desktop executable is not installed. Run install-offline.ps1 without -SkipDesktopBuild. 1>&2
  exit /b 1
)
start "Hermes" /D "%OFFLINE_HERMES_ROOT%app" "%OFFLINE_HERMES_ROOT%app\Hermes.exe"
'@
    $launcher = $launcher.Replace('__HOME_LINE__', $homeLine).Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'launch-hermes.cmd'), $launcher, [Text.UTF8Encoding]::new($false))

    $cli = @'
@echo off
setlocal
set "OFFLINE_HERMES_ROOT=%~dp0"
__HOME_LINE__
set "HERMES_DISABLE_LAZY_INSTALLS=1"
set "UV_OFFLINE=1"
set "PIP_NO_INDEX=1"
set "PATH=%OFFLINE_HERMES_ROOT%runtime\node;%OFFLINE_HERMES_ROOT%runtime\git\cmd;%OFFLINE_HERMES_ROOT%runtime\ripgrep;%OFFLINE_HERMES_ROOT%venv\Scripts;%PATH%"
"%OFFLINE_HERMES_ROOT%venv\Scripts\hermes.exe" %*
'@
    $cli = $cli.Replace('__HOME_LINE__', $homeLine).Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText((Join-Path $InstallRoot 'hermes-offline.cmd'), $cli, [Text.UTF8Encoding]::new($false))

    $state = [ordered]@{
        profile = 'windows-x64-desktop'
        installed_at = [DateTime]::UtcNow.ToString('o')
        hermes_home = $HermesHome
        desktop_built = $HasDesktop
        network_fallback = $false
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'install-state.json') -Encoding utf8
}

$repoRoot = Get-OfflineHermesRepoRoot
$installPath = [IO.Path]::GetFullPath($InstallRoot)
$stageRoot = "$installPath.staging-$([Guid]::NewGuid().ToString('N'))"
$hermesHomePath = [IO.Path]::GetFullPath($HermesHome)
$backupRoot = $null
$movedIntoPlace = $false

# Apply the network guard to every child process for the whole install and
# restore the caller's environment afterwards (bootstrap/build-bundle share
# this process).
$guard = Get-OfflineNetworkGuard -CacheRoot (Join-Path $stageRoot '.work\isolated-cache')
$guard.HERMES_HOME = $hermesHomePath
$savedEnvironment = @{}
foreach ($name in $guard.Keys) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, [string]$guard[$name], 'Process')
}

try {
    Assert-NativeWindowsX64
    if ($hermesHomePath.StartsWith($installPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "HermesHome must be outside the replaceable install root: $hermesHomePath"
    }
    Test-VendoredArtifacts -RepoRoot $repoRoot | Out-Null

    if (Test-Path -LiteralPath $installPath) {
        if (-not $Force) {
            throw "Install destination already exists: $installPath`nUse -Force to preserve it as a timestamped backup and replace it."
        }
        $backupRoot = "$installPath.previous-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        Move-Item -LiteralPath $installPath -Destination $backupRoot
        Write-Host "Preserved prior installation at $backupRoot"
    }

    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $runtimeRoot = Join-Path $stageRoot 'runtime'
    $workRoot = Join-Path $stageRoot '.work'
    $sourceRoot = Join-Path $stageRoot 'source\hermes-agent'
    New-Item -ItemType Directory -Path $runtimeRoot, $workRoot, $sourceRoot -Force | Out-Null

    Write-Host 'Copying the pinned Hermes source snapshot...'
    $sourceSnapshot = Join-Path $repoRoot 'upstream\hermes-agent'
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $copyProcess = Start-Process -FilePath $robocopy -ArgumentList @(
        "`"$sourceSnapshot`"", "`"$sourceRoot`"", '/E', '/XD', '.git', '.venv', 'node_modules',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    ) -Wait -PassThru -NoNewWindow
    $robocopyExit = $copyProcess.ExitCode
    if ($robocopyExit -ge 8) {
        throw "Source snapshot copy failed with robocopy exit code $robocopyExit."
    }

    Write-Host 'Extracting managed runtimes...'
    $pythonScratch = Join-Path $workRoot 'python-extract'
    New-Item -ItemType Directory -Path $pythonScratch -Force | Out-Null
    Invoke-CheckedCommand -FilePath 'tar.exe' -ArgumentList @(
        '-xzf', (Join-Path $repoRoot 'vendor\binaries\windows-x64\cpython-3.11.16+20260901-x86_64-pc-windows-msvc-install_only_stripped.tar.gz'),
        '-C', $pythonScratch
    )
    Move-Item -LiteralPath (Join-Path $pythonScratch 'python') -Destination (Join-Path $runtimeRoot 'python')

    $nodeScratch = Join-Path $workRoot 'node-extract'
    Expand-ZipClean -Archive (Join-Path $repoRoot 'vendor\binaries\windows-x64\node-v26.9.0-win-x64.zip') -Destination $nodeScratch
    Move-Item -LiteralPath (Get-SingleChildDirectory -Path $nodeScratch) -Destination (Join-Path $runtimeRoot 'node')

    foreach ($tool in @(
        @{ Archive = 'uv-0.9.28-x86_64-pc-windows-msvc.zip'; Destination = 'uv' },
        @{ Archive = 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; Destination = 'ripgrep' }
    )) {
        $scratch = Join-Path $workRoot "$($tool.Destination)-extract"
        Expand-ZipClean -Archive (Join-Path $repoRoot "vendor\binaries\windows-x64\$($tool.Archive)") -Destination $scratch
        $children = @(Get-ChildItem -LiteralPath $scratch -Force)
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            Move-Item -LiteralPath $children[0].FullName -Destination (Join-Path $runtimeRoot $tool.Destination)
        } else {
            Move-Item -LiteralPath $scratch -Destination (Join-Path $runtimeRoot $tool.Destination)
        }
    }

    $gitRoot = Join-Path $runtimeRoot 'git'
    New-Item -ItemType Directory -Path $gitRoot -Force | Out-Null
    $sevenZipRoot = Join-Path $workRoot '7zip-extract'
    New-Item -ItemType Directory -Path $sevenZipRoot -Force | Out-Null
    Invoke-CheckedCommand -FilePath 'tar.exe' -ArgumentList @(
        '-xzf', (Join-Path $repoRoot 'vendor\binaries\windows-x64\electron-builder-7zip-1.0.0-win-x64.tar.gz'),
        '-C', $sevenZipRoot
    )
    $sevenZip = Get-ChildItem -LiteralPath $sevenZipRoot -Filter '7za.exe' -File -Recurse | Select-Object -First 1
    if (-not $sevenZip) { throw 'The vendored electron-builder 7zip archive contains no 7za.exe.' }
    Invoke-CheckedCommand -FilePath $sevenZip.FullName -ArgumentList @(
        'x', (Join-Path $repoRoot 'vendor\binaries\windows-x64\PortableGit-2.54.0-64-bit.7z.exe'),
        "-o$gitRoot", '-y'
    )
    if (-not (Test-Path -LiteralPath (Join-Path $gitRoot 'cmd\git.exe') -PathType Leaf)) {
        throw 'PortableGit extraction completed without runtime\git\cmd\git.exe.'
    }

    # Reviewed offline-profile patches (manifests/patches.lock) go onto the
    # staged source before anything is built from it.
    Write-Host 'Applying offline-profile patches to the staged source...'
    Install-UpstreamPatches -RepoRoot $repoRoot -SourceRoot $sourceRoot -GitExe (Join-Path $gitRoot 'cmd\git.exe') | Out-Null

    $wheelRoot = Join-Path $repoRoot 'vendor\python\windows-x64-cp311'
    $wheels = @(Get-ChildItem -LiteralPath $wheelRoot -Filter '*.whl' -File | Sort-Object Name)
    if ($wheels.Count -ne 68) { throw "Expected 68 Python wheels but found $($wheels.Count)." }

    Install-NodeClosure -RepoRoot $repoRoot -SourceRoot $sourceRoot -NodeRoot (Join-Path $runtimeRoot 'node') -WorkRoot $workRoot

    $hasDesktop = -not $SkipDesktopBuild
    if ($hasDesktop) {
        Build-DesktopApplication -SourceRoot $sourceRoot -NodeRoot (Join-Path $runtimeRoot 'node') -AppDestination (Join-Path $stageRoot 'app')
    }

    $nodeModules = Join-Path $sourceRoot 'node_modules'
    if (Test-Path -LiteralPath $nodeModules) { Remove-Item -LiteralPath $nodeModules -Recurse -Force }
    $desktopRelease = Join-Path $sourceRoot 'apps\desktop\release'
    if (Test-Path -LiteralPath $desktopRelease) { Remove-Item -LiteralPath $desktopRelease -Recurse -Force }
    Remove-Item -LiteralPath $workRoot -Recurse -Force

    Write-Launchers -InstallRoot $stageRoot -HermesHome $hermesHomePath -HasDesktop $hasDesktop
    Move-Item -LiteralPath $stageRoot -Destination $installPath
    $movedIntoPlace = $true

    # Virtual environments, pip console-script launchers, and editable installs
    # embed absolute paths, so the Python environment is created only after the
    # staging directory has reached its final location.
    $venvRoot = Join-Path $installPath 'venv'
    Invoke-CheckedCommand -FilePath (Join-Path $installPath 'runtime\python\python.exe') -ArgumentList @('-m', 'venv', '--copies', $venvRoot)
    $venvPython = Join-Path $venvRoot 'Scripts\python.exe'
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList (@(
        '-m', 'pip', 'install', '--no-index', '--no-deps', '--disable-pip-version-check'
    ) + @($wheels.FullName))
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @(
        '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-build-isolation',
        '--disable-pip-version-check', '-e', (Join-Path $installPath 'source\hermes-agent')
    )

    Initialize-HermesHome -HermesHome $hermesHomePath
    Invoke-CheckedCommand -FilePath (Join-Path $venvRoot 'Scripts\hermes.exe') -ArgumentList @('--version')

    Write-Host "Offline Hermes installation completed: $installPath"
    Write-Host "CLI launcher:     $installPath\hermes-offline.cmd"
    if ($hasDesktop) { Write-Host "Desktop launcher: $installPath\launch-hermes.cmd" }

    # Without a provider the desktop opens on its cloud-provider setup screen,
    # which offers only options that need the Internet (Phase 4 gap G18).
    $homeConfig = [IO.File]::ReadAllText((Join-Path $hermesHomePath 'config.yaml'))
    if ($homeConfig -notmatch '(?m)^\s+base_url:\s*\S') {
        Write-Host ''
        Write-Host 'Next: point Hermes at your local or LAN model server (OpenAI-compatible API), for example:'
        Write-Host "  .\scripts\configure-provider.ps1 -BaseUrl http://<server>:8000/v1 -Model <model-id> -InstallRoot `"$installPath`""
    }
}
catch {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    if ($movedIntoPlace -and (Test-Path -LiteralPath $installPath)) {
        Remove-Item -LiteralPath $installPath -Recurse -Force
    }
    if ($backupRoot -and -not (Test-Path -LiteralPath $installPath) -and (Test-Path -LiteralPath $backupRoot)) {
        Move-Item -LiteralPath $backupRoot -Destination $installPath
        Write-Warning "Installation failed; restored the prior installation at $installPath."
    }
    Write-OfflineHermesFailure $_
    exit 1
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
