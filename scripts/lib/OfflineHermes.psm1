Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OfflineHermesRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-NativeWindowsArchitecture {
    # The machine's native architecture (AMD64, ARM64, x86), independent of the
    # current process's bitness or emulation. Deliberately avoids the .NET
    # runtime-information OSArchitecture API: on the first Azure run an
    # interactive Windows PowerShell 5.1 session resolved it without the property.
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $native = (Get-ItemProperty -LiteralPath $key -Name PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
    if (-not $native) {
        $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    return [string]$native
}

function Assert-NativeWindowsX64 {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The windows-x64-desktop profile must be installed from native Windows PowerShell.'
    }

    $arch = Get-NativeWindowsArchitecture
    if ($arch -ne 'AMD64') {
        throw "Unsupported architecture '$arch'. This bundle contains only the windows-x64-desktop profile."
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][string]$WorkingDirectory
    )

    $quotedArguments = @($ArgumentList | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') {
            '"' + $value.Replace('"', '\"') + '"'
        } else {
            $value
        }
    })
    $startArgs = @{
        FilePath = $FilePath
        ArgumentList = $quotedArguments
        Wait = $true
        PassThru = $true
        NoNewWindow = $true
    }
    if ($WorkingDirectory) { $startArgs.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @startArgs
    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-ChecksumRecords {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $checksumFile = Join-Path $RepoRoot 'manifests\checksums.sha256'
    if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
        throw "Missing checksum manifest: $checksumFile"
    }

    $records = @()
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($checksumFile)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+(.+)$') {
            throw "Malformed checksum entry at ${checksumFile}:${lineNumber}"
        }
        $records += [pscustomobject]@{
            Hash = $Matches[1].ToLowerInvariant()
            RelativePath = $Matches[2].Trim().Replace('/', [IO.Path]::DirectorySeparatorChar)
        }
    }
    return $records
}

function Get-ManifestArtifactCount {
    # artifact_count from a manifests/*.lock header. The installer compares
    # the files it is about to install with it, so the expected counts follow
    # a vendor refresh instead of being hard-coded.
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Manifest
    )
    $path = Join-Path $RepoRoot "manifests\$Manifest"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing manifest: manifests/$Manifest" }
    foreach ($line in [IO.File]::ReadLines($path)) {
        if ($line -match '^artifact_count = (\d+)$') { return [int]$Matches[1] }
        if ($line -eq '[[artifact]]') { break }
    }
    throw "manifests/$Manifest has no artifact_count."
}

function Test-VendoredArtifacts {
    param(
        [Parameter()][string]$RepoRoot = (Get-OfflineHermesRepoRoot),
        [Parameter()][switch]$Quiet
    )

    $records = @(Get-ChecksumRecords -RepoRoot $RepoRoot)
    if ($records.Count -eq 0) {
        throw 'The checksum manifest is empty.'
    }

    $listed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $verified = 0
    foreach ($record in $records) {
        $relativePath = $record.RelativePath
        $null = $listed.Add($relativePath)
        $path = Join-Path $RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing required artifact: $relativePath`nManifest: manifests/checksums.sha256`nOffline installation cannot continue."
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $record.Hash) {
            throw "Checksum mismatch: $relativePath`nExpected: $($record.Hash)`nActual:   $actual`nOffline installation cannot continue."
        }
        $verified++
    }

    $vendorRoot = Join-Path $RepoRoot 'vendor'
    foreach ($file in Get-ChildItem -LiteralPath $vendorRoot -File -Recurse) {
        $rootPrefix = $RepoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $file.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Vendor file is outside the repository root: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($rootPrefix.Length)
        if (-not $listed.Contains($relative)) {
            throw "Unmanifested vendor file: $relative`nAdd it to manifests/checksums.sha256 or remove it before installation."
        }
    }

    if (-not $Quiet) {
        Write-Host "Verified $verified vendored files against manifests/checksums.sha256."
    }
    return $verified
}

function Expand-ZipClean {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Resolve-NodePackageDirectory {
    param(
        [Parameter(Mandatory)][string]$FromDirectory,
        [Parameter(Mandatory)][string]$PackageName
    )

    # Mirror Node's node_modules lookup instead of assuming a hoisted layout:
    # npm workspaces may nest a package under apps/<name>/node_modules.
    $directory = [IO.Path]::GetFullPath($FromDirectory)
    while ($directory) {
        $candidate = Join-Path $directory (Join-Path 'node_modules' $PackageName)
        if (Test-Path -LiteralPath (Join-Path $candidate 'package.json') -PathType Leaf) {
            return $candidate
        }
        $directory = Split-Path -Parent $directory
    }
    throw "npm package '$PackageName' is not installed in any node_modules above $FromDirectory.`nThe offline npm closure is incomplete; no download was attempted."
}

function Get-OfflineNetworkGuard {
    param([Parameter(Mandatory)][string]$CacheRoot)

    # Any proxy-aware client that still tries to reach the network is sent to a
    # closed loopback port and fails immediately. Host-level caches are replaced
    # with empty per-install directories so a pre-populated machine cannot hide a
    # missing vendored artifact.
    $deadProxy = 'http://127.0.0.1:9'
    return @{
        HTTP_PROXY = $deadProxy
        HTTPS_PROXY = $deadProxy
        ALL_PROXY = $deadProxy
        NO_PROXY = ''
        npm_config_proxy = $deadProxy
        npm_config_https_proxy = $deadProxy
        npm_config_noproxy = ''
        GLOBAL_AGENT_HTTP_PROXY = $deadProxy
        GLOBAL_AGENT_HTTPS_PROXY = $deadProxy
        ELECTRON_GET_USE_PROXY = '1'
        ELECTRON_MIRROR = "$deadProxy/offline-hermes-blocked/"
        ELECTRON_SKIP_BINARY_DOWNLOAD = '1'
        # Every npm invocation (including `npm run` during the desktop build)
        # writes logs into its cache; keep it out of %LOCALAPPDATA%\npm-cache.
        npm_config_cache = (Join-Path $CacheRoot 'npm')
        npm_config_update_notifier = 'false'
        electron_config_cache = (Join-Path $CacheRoot 'electron')
        ELECTRON_BUILDER_CACHE = (Join-Path $CacheRoot 'electron-builder')
        PIP_NO_INDEX = '1'
        # Keep pip out of the user-level %LOCALAPPDATA%\pip cache.
        PIP_NO_CACHE_DIR = '1'
        UV_OFFLINE = '1'
        HERMES_DISABLE_LAZY_INSTALLS = '1'
    }
}

function Invoke-WithEnvironment {
    param(
        [Parameter(Mandatory)][hashtable]$Variables,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $saved = @{}
    foreach ($name in $Variables.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$Variables[$name], 'Process')
    }
    try {
        & $ScriptBlock
    }
    finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function Get-UpstreamPatchRecords {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $lock = Join-Path $RepoRoot 'manifests\patches.lock'
    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) {
        throw "Missing patch manifest: manifests/patches.lock"
    }
    $records = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in [System.IO.File]::ReadAllLines($lock)) {
        if ($line.Trim() -eq '[[patch]]') {
            $current = @{}
            $records.Add($current)
            continue
        }
        if ($null -ne $current -and $line -match '^\s*([a-z0-9_]+)\s*=\s*"(.*)"\s*$') {
            $current[$Matches[1]] = $Matches[2]
        }
    }
    foreach ($record in $records) {
        foreach ($field in 'path', 'sha256', 'target') {
            if (-not $record.ContainsKey($field)) { throw "manifests/patches.lock has a [[patch]] entry without '$field'." }
        }
    }
    return $records.ToArray()
}

function Install-UpstreamPatches {
    # Apply the reviewed offline-profile patches to the STAGED source copy.
    # upstream/ itself is never modified. A patch that no longer applies (for
    # example after an upstream refresh) stops the install instead of
    # silently shipping unpatched behavior.
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$GitExe
    )

    $records = @(Get-UpstreamPatchRecords -RepoRoot $RepoRoot)
    # Never let git discover a repository above the staged tree.
    $gitEnvironment = @{
        GIT_CEILING_DIRECTORIES = (Split-Path -Parent $SourceRoot)
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = 'NUL'
    }
    foreach ($record in $records) {
        $patch = Join-Path $RepoRoot ($record.path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $patch -PathType Leaf)) {
            throw "Missing patch: $($record.path)`nManifest: manifests/patches.lock"
        }
        $actual = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $record.sha256.ToLowerInvariant()) {
            throw "Patch checksum mismatch: $($record.path)`nExpected: $($record.sha256)`nActual:   $actual"
        }
        Invoke-WithEnvironment -Variables $gitEnvironment -ScriptBlock {
            try {
                Invoke-CheckedCommand -FilePath $GitExe -ArgumentList @('apply', '--check', '-p1', $patch) -WorkingDirectory $SourceRoot
            }
            catch {
                throw "Patch $($record.path) no longer applies to $($record.target) in the pinned upstream source. Update patches/ and manifests/patches.lock before installing."
            }
            Invoke-CheckedCommand -FilePath $GitExe -ArgumentList @('apply', '-p1', $patch) -WorkingDirectory $SourceRoot
        }
        Write-Host "Applied $($record.path) -> $($record.target)"
    }
    return $records.Count
}

function Get-LongPath {
    # Upstream's documentation tree has paths near MAX_PATH; under Windows
    # PowerShell 5.1 without LongPathsEnabled, plain paths fail beyond 260
    # characters. The \\?\ form works in both 5.1 (.NET 4.6.2+) and 7.
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { return $full }
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead((Get-LongPath $Path))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-ReleaseTreeFiles {
    # Relative paths (with /) of every file under $Root, ordinal-sorted.
    param([Parameter(Mandatory)][string]$Root)
    $longRoot = (Get-LongPath $Root).TrimEnd('\') + '\'
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($file in [IO.Directory]::EnumerateFiles($longRoot, '*', [IO.SearchOption]::AllDirectories)) {
        $files.Add($file.Substring($longRoot.Length).Replace('\', '/'))
    }
    $array = $files.ToArray()
    [Array]::Sort($array, [StringComparer]::Ordinal)
    return , $array
}

function Test-ReleaseTree {
    # Verifies an extracted release archive against its release-files.sha256:
    # every listed file present with the recorded hash, and nothing unlisted.
    # This detects partial or damaged extraction (for example a tool that
    # skipped long paths); it is not a signature and does not authenticate
    # the publisher. Check the archive's .sha256 against a trusted copy.
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter()][switch]$Quiet
    )

    $listPath = Join-Path $ReleaseRoot 'release-files.sha256'
    $manifestPath = Join-Path $ReleaseRoot 'RELEASE-MANIFEST.json'
    foreach ($required in $listPath, $manifestPath) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Not an extracted release archive: missing $required`nA Git clone has no release file list; verify it with scripts\verify-deps.ps1."
        }
    }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json

    $expected = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($listPath)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
            throw "Malformed entry at release-files.sha256:$lineNumber"
        }
        $expected[$Matches[2]] = $Matches[1]
    }
    if ($expected.Count -ne [int]$manifest.release_files) {
        throw "release-files.sha256 lists $($expected.Count) files but RELEASE-MANIFEST.json records $($manifest.release_files)."
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    $mismatched = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $expected.GetEnumerator()) {
        $path = Join-Path $ReleaseRoot $entry.Key.Replace('/', '\')
        if (-not [IO.File]::Exists((Get-LongPath $path))) { $missing.Add($entry.Key); continue }
        if ((Get-FileSha256 $path) -ne $entry.Value) { $mismatched.Add($entry.Key) }
    }
    $present = Get-ReleaseTreeFiles -Root $ReleaseRoot
    $unlisted = @($present | Where-Object {
        $_ -ne 'release-files.sha256' -and -not $expected.ContainsKey($_)
    })

    if ($missing.Count -or $mismatched.Count -or $unlisted.Count) {
        $report = @("Release tree verification failed for $ReleaseRoot")
        foreach ($group in @(
            @{ Label = 'Missing'; Items = @($missing) },
            @{ Label = 'Checksum mismatch'; Items = @($mismatched) },
            @{ Label = 'Not in the release'; Items = $unlisted }
        )) {
            if ($group.Items.Count -eq 0) { continue }
            $report += "$($group.Label) ($($group.Items.Count)):"
            $report += @($group.Items | Select-Object -First 20 | ForEach-Object { "  $_" })
            if ($group.Items.Count -gt 20) { $report += "  ... and $($group.Items.Count - 20) more" }
        }
        $report += 'Re-extract the archive with: tar.exe -xf <archive>.zip (File Explorer can skip long paths).'
        throw ($report -join "`n")
    }

    if (-not $Quiet) {
        Write-Host "Verified $($expected.Count) release files against release-files.sha256 (release $($manifest.release_version))."
    }
    return $manifest
}

function Write-OfflineHermesFailure {
    # Print the failure message verbatim on stderr. Write-Error under Windows
    # PowerShell 5.1 prefixes the script path and wraps at the console width,
    # which can split the artifact name the user needs to see.
    param([Parameter(Mandatory)]$ErrorRecord)
    [Console]::Error.WriteLine("ERROR: $($ErrorRecord.Exception.Message)")
}

Export-ModuleMember -Function @(
    'Assert-NativeWindowsX64',
    'Copy-DirectoryContents',
    'Expand-ZipClean',
    'Get-ChecksumRecords',
    'Get-FileSha256',
    'Get-LongPath',
    'Get-ManifestArtifactCount',
    'Get-ReleaseTreeFiles',
    'Get-UpstreamPatchRecords',
    'Install-UpstreamPatches',
    'Get-OfflineHermesRepoRoot',
    'Get-OfflineNetworkGuard',
    'Invoke-CheckedCommand',
    'Invoke-WithEnvironment',
    'Resolve-NodePackageDirectory',
    'Test-ReleaseTree',
    'Test-VendoredArtifacts',
    'Write-OfflineHermesFailure'
)
