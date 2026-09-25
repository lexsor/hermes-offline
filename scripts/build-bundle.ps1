<#
.SYNOPSIS
Builds the release archive: this repository's committed tree, verified, with a
release manifest and a per-file checksum list.

.DESCRIPTION
Maintenance command, run on the build machine from a Git clone whose LFS
content has been fetched (git lfs pull). It makes no network access itself.

The archive is the repository, not an installed tree: venvs and console-script
launchers embed absolute paths, so the target machine runs install-offline.ps1
from the extracted archive (the path validated in Phase 4).

Outputs in -OutputDirectory:
  OfflineHermes-<version>-windows-x64-desktop.zip           the release archive
  OfflineHermes-<version>-windows-x64-desktop.zip.sha256    its SHA-256 (sha256sum format)
  OfflineHermes-<version>-windows-x64-desktop.manifest.json copy of RELEASE-MANIFEST.json

Inside the archive, under OfflineHermes-<version>\:
  RELEASE-MANIFEST.json   source commit, upstream pin, patches, file counts
  release-files.sha256    SHA-256 of every file (checked by verify-release.ps1)
#>
[CmdletBinding()]
param(
    [Parameter()][string]$OutputDirectory,
    # Defaults to <upstream version>-offline.<short commit>.
    [Parameter()][string]$ReleaseVersion,
    # Build from a tree with uncommitted changes (recorded in the manifest).
    # Not for releases.
    [Parameter()][switch]$AllowDirtyTree,
    [Parameter()][switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

function Get-LockValues {
    param([Parameter(Mandatory)][string]$Path)
    $values = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([a-z0-9_]+)\s*=\s*"(.*)"\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Get-LicenseRecords {
    param([Parameter(Mandatory)][string]$Path)
    $records = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.Trim() -eq '[[artifact]]') {
            $current = @{ license_files = @() }
            $records.Add($current)
            continue
        }
        if ($line -match '^\[') { $current = $null; continue }
        if ($null -eq $current) { continue }
        if ($line -match '^([a-z0-9_]+) = "(.*)"$') {
            $current[$Matches[1]] = $Matches[2]
        } elseif ($line -match '^license_files = \[(.*)\]$') {
            $current.license_files = @([regex]::Matches($Matches[1], '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
        }
    }
    return $records.ToArray()
}

function New-ThirdPartyNotices {
    # Generated at build time so it always matches manifests/licenses.lock.
    # It indexes where each license text lives; the texts themselves stay in
    # the vendored artifacts (and in the installed tree).
    param([Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][string]$ReleaseVersion)

    $records = @(Get-LicenseRecords (Join-Path $Tree 'manifests\licenses.lock') | Sort-Object { $_.ecosystem }, { $_.name }, { $_.version })
    $cell = { param($text) ([string]$text).Replace('|', '\|') }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("# Third-party notices")
    $out.Add('')
    $out.Add("Offline Hermes $ReleaseVersion redistributes Hermes Agent (MIT, ``upstream/hermes-agent/LICENSE``) and the $($records.Count) third-party artifacts below, unmodified, under ``vendor/``. This file is generated from ``manifests/licenses.lock`` when the release is built. Each license text stays inside its artifact, at the path listed; the installed runtimes and desktop app keep those files.")
    $out.Add('')
    $out.Add('**Status:** the license classification is an automated inventory. Human legal/compliance review is required before public redistribution (gap G11 in `reports/final-gap-list.md`).')
    $out.Add('')
    $out.Add('## Source code offers')
    $out.Add('')
    $out.Add('- **Git for Windows (PortableGit 2.54.0, GPL-2.0-only with bundled components):** the corresponding source ships in this release as `vendor/source/windows-x64/git-for-windows-v2.54.0.windows.1.tar.gz`.')
    $out.Add('- **Lightning CSS 1.32.0 and 1.33.0 (MPL-2.0 native binaries):** the corresponding upstream sources ship as `vendor/source/windows-x64/lightningcss-v1.32.0.tar.gz` and `lightningcss-v1.33.0.tar.gz`.')
    $out.Add('- **Other MPL-2.0 content** (npm packages and Python wheels) ships as the original package archives, which contain their source files.')
    $out.Add('- **Electron 40.10.2:** `LICENSE` and `LICENSES.chromium.html` are inside `vendor/browser/windows-x64/electron-v40.10.2-win32-x64.zip`.')
    $out.Add('')

    $noFile = @($records | Where-Object { $_.license_files.Count -eq 0 })
    $out.Add("## Artifacts with no embedded license file ($($noFile.Count))")
    $out.Add('')
    $out.Add('Their license is recorded from package or release metadata; the attribution text must be confirmed from the upstream project during legal review.')
    $out.Add('')
    $out.Add('| Component | Version | Declared license | Notes |')
    $out.Add('|---|---|---|---|')
    foreach ($r in $noFile) {
        $out.Add("| $(& $cell $r.name) | $(& $cell $r.version) | $(& $cell $r.declared_license) | $(& $cell $r.notes) |")
    }
    $out.Add('')

    $out.Add('## By license')
    $out.Add('')
    $out.Add('| Declared license | Artifacts |')
    $out.Add('|---|---|')
    foreach ($group in ($records | Group-Object { $_.declared_license } | Sort-Object Count -Descending)) {
        $out.Add("| $(& $cell $group.Name) | $($group.Count) |")
    }
    $out.Add('')

    $out.Add('## All artifacts')
    $out.Add('')
    $out.Add('| Ecosystem | Component | Version | Declared license | License file(s) inside the artifact | Artifact |')
    $out.Add('|---|---|---|---|---|---|')
    foreach ($r in $records) {
        $files = @($r.license_files)
        $shown = ($files | Select-Object -First 3 | ForEach-Object { "``$_``" }) -join '<br>'
        if ($files.Count -gt 3) { $shown += "<br>and $($files.Count - 3) more (see licenses.lock)" }
        if (-not $shown) { $shown = 'none embedded' }
        $out.Add("| $($r.ecosystem) | $(& $cell $r.name) | $(& $cell $r.version) | $(& $cell $r.declared_license) | $(& $cell $shown) | ``$($r.artifact_path)`` |")
    }
    [IO.File]::WriteAllText((Join-Path $Tree 'THIRD-PARTY-NOTICES.md'), ($out -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    return $records.Count
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $savedEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    try {
        $output = & git -C $repoRoot -c core.quotepath=off @Arguments
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
        # Callers wrap the result in @(): a single line would otherwise be a
        # bare string, and no output must be an empty array, not @($null).
        return @($output | Where-Object { $_ })
    }
    finally {
        [Console]::OutputEncoding = $savedEncoding
    }
}

$repoRoot = Get-OfflineHermesRepoRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$buildRoot = Join-Path $outputPath ".build-$([Guid]::NewGuid().ToString('N'))"

try {
    Assert-NativeWindowsX64
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'build-bundle.ps1 runs from a Git clone of this repository and needs git on PATH.'
    }

    $commit = @(Invoke-Git @('rev-parse', 'HEAD'))[0]
    $commitDate = @(Invoke-Git @('show', '-s', '--format=%cI', 'HEAD'))[0]
    $dirty = @(Invoke-Git @('status', '--porcelain'))
    if ($dirty.Count -gt 0 -and -not $AllowDirtyTree) {
        throw "The working tree has $($dirty.Count) uncommitted change(s). Commit them first; a release is built from the committed tree."
    }

    $upstream = Get-LockValues (Join-Path $repoRoot 'manifests\upstream.lock')
    $pyproject = [IO.File]::ReadAllText((Join-Path $repoRoot 'upstream\hermes-agent\pyproject.toml'))
    if ($pyproject -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw 'Cannot read the upstream version from upstream/hermes-agent/pyproject.toml.' }
    $upstreamVersion = $Matches[1]
    if (-not $ReleaseVersion) { $ReleaseVersion = "$upstreamVersion-offline.$($commit.Substring(0, 7))" }
    if ($ReleaseVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z.\-]*$') {
        throw "ReleaseVersion may contain only letters, digits, '.' and '-': $ReleaseVersion"
    }

    $releaseName = "OfflineHermes-$ReleaseVersion"
    $archiveBase = "$releaseName-windows-x64-desktop"
    $archive = Join-Path $outputPath "$archiveBase.zip"
    $outputs = @($archive, "$archive.sha256", (Join-Path $outputPath "$archiveBase.manifest.json"))
    foreach ($existing in $outputs) {
        if ((Test-Path -LiteralPath $existing) -and -not $Force) {
            throw "Release output already exists: $existing (use -Force to replace it)."
        }
    }

    # The release is exactly the committed file list, taken from the working
    # tree so Git LFS content (not pointer stubs) is what ships.
    $files = @(Invoke-Git @('ls-files', '--cached') | Where-Object { $_ })
    $tree = Join-Path $buildRoot $releaseName
    Write-Host "Staging $($files.Count) committed files into $tree..."
    foreach ($relative in $files) {
        $source = Join-Path $repoRoot $relative.Replace('/', '\')
        $destination = Join-Path $tree $relative.Replace('/', '\')
        if (-not [IO.File]::Exists((Get-LongPath $source))) {
            throw "Tracked file is missing from the working tree: $relative"
        }
        [void][IO.Directory]::CreateDirectory((Get-LongPath (Split-Path -Parent $destination)))
        [IO.File]::Copy((Get-LongPath $source), (Get-LongPath $destination), $false)
    }

    Write-Host 'Verifying vendored checksums on the staged tree (detects Git LFS pointer files)...'
    try {
        Test-VendoredArtifacts -RepoRoot $tree | Out-Null
    }
    catch {
        throw "$($_.Exception.Message)`nIf vendor files are Git LFS pointers, run 'git lfs pull' in $repoRoot first."
    }

    $patches = @(Get-UpstreamPatchRecords -RepoRoot $tree | ForEach-Object {
        [ordered]@{ path = $_.path; sha256 = $_.sha256; target = $_.target }
    })
    $manifest = [ordered]@{
        format = 1
        release_version = $ReleaseVersion
        profile = 'windows-x64-desktop'
        platforms = @('Windows 11 x64 (validated)', 'Windows 10 x64 (claimed, not yet validated)')
        created_utc = [DateTime]::UtcNow.ToString('o')
        source_commit = $commit
        source_commit_date = $commitDate
        uncommitted_changes = $dirty
        upstream = [ordered]@{
            repository = $upstream.repository
            commit = $upstream.commit
            tree = $upstream.tree
            version = $upstreamVersion
        }
        patches = $patches
        vendored_files = @(Get-ChecksumRecords -RepoRoot $tree).Count
        # Committed files plus the generated RELEASE-MANIFEST.json and THIRD-PARTY-NOTICES.md.
        release_files = $files.Count + 2
        install = 'Extract with tar.exe -xf, then run scripts\verify-release.ps1, scripts\verify-deps.ps1 and scripts\install-offline.ps1. See RELEASE_NOTES.md.'
    }
    $noticeCount = New-ThirdPartyNotices -Tree $tree -ReleaseVersion $ReleaseVersion
    Write-Host "Generated THIRD-PARTY-NOTICES.md for $noticeCount artifacts."
    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $tree 'RELEASE-MANIFEST.json'), $manifestJson + "`n", [Text.UTF8Encoding]::new($false))

    Write-Host 'Hashing every release file...'
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in (Get-ReleaseTreeFiles -Root $tree)) {
        $lines.Add("$(Get-FileSha256 (Join-Path $tree $relative.Replace('/', '\')))  $relative")
    }
    [IO.File]::WriteAllText((Join-Path $tree 'release-files.sha256'), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Test-ReleaseTree -ReleaseRoot $tree | Out-Null

    foreach ($existing in $outputs) {
        if (Test-Path -LiteralPath $existing) { Remove-Item -LiteralPath $existing -Force }
    }
    Write-Host "Creating $archive..."
    # bsdtar (Windows 10 1803+) writes zip64 and long paths; the PowerShell 5.1
    # archive cmdlets do neither reliably.
    Invoke-CheckedCommand -FilePath 'tar.exe' -ArgumentList @('-a', '-cf', $archive, '-C', $buildRoot, $releaseName)

    # Read the archive back: its entry list must be exactly the release files.
    $entries = @(& tar.exe -tf $archive | Where-Object { $_ -and -not $_.EndsWith('/') })
    if ($LASTEXITCODE -ne 0) { throw "tar could not read back $archive." }
    $expectedEntries = $lines.Count + 1
    if ($entries.Count -ne $expectedEntries) {
        throw "The archive holds $($entries.Count) files; expected $expectedEntries."
    }

    $archiveHash = Get-FileSha256 $archive
    [IO.File]::WriteAllText("$archive.sha256", "$archiveHash *$archiveBase.zip`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outputPath "$archiveBase.manifest.json"), $manifestJson + "`n", [Text.UTF8Encoding]::new($false))

    $sizeMb = [Math]::Round((Get-Item -LiteralPath $archive).Length / 1MB)
    Write-Host ''
    Write-Host "Built release $ReleaseVersion from $commit"
    Write-Host "  $archive ($sizeMb MB)"
    Write-Host "  sha256 $archiveHash"
    Write-Host "  $($manifest.release_files) files, $($manifest.vendored_files) vendored artifacts, $($patches.Count) patches"
    if ($dirty.Count -gt 0) { Write-Warning "Built from a dirty tree ($($dirty.Count) changes); do not publish this archive." }
}
catch {
    Write-OfflineHermesFailure $_
    exit 1
}
finally {
    if (Test-Path -LiteralPath $buildRoot) {
        & cmd.exe /d /c "rd /s /q `"$(Get-LongPath $buildRoot)`""
    }
}
