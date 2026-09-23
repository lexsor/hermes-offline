Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OfflineHermesRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Assert-NativeWindowsX64 {
    $isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
    if (-not $isWindowsHost) {
        throw 'The windows-x64-desktop profile must be installed from native Windows PowerShell.'
    }

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($arch -ne 'X64') {
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
        electron_config_cache = (Join-Path $CacheRoot 'electron')
        ELECTRON_BUILDER_CACHE = (Join-Path $CacheRoot 'electron-builder')
        PIP_NO_INDEX = '1'
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

Export-ModuleMember -Function @(
    'Assert-NativeWindowsX64',
    'Copy-DirectoryContents',
    'Expand-ZipClean',
    'Get-ChecksumRecords',
    'Get-OfflineHermesRepoRoot',
    'Get-OfflineNetworkGuard',
    'Invoke-CheckedCommand',
    'Invoke-WithEnvironment',
    'Resolve-NodePackageDirectory',
    'Test-VendoredArtifacts'
)
