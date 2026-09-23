[CmdletBinding()]
param(
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes'),
    [Parameter()][string]$HermesHome = (Join-Path $env:LOCALAPPDATA 'OfflineHermes-home'),
    [Parameter()][string]$EvidenceRoot = (Join-Path (Get-Location) 'phase4-evidence'),
    # Harness development on a connected, non-clean machine: P0 then expects an
    # OPEN network and tolerates host findings. Such a run never counts as a
    # Phase 4 result and is labeled accordingly.
    [Parameter()][switch]$DryRunOnConnectedHost,
    # Reuse an existing install instead of running T4 (iteration only).
    [Parameter()][switch]$SkipInstall,
    [Parameter()][string[]]$Cases = @('P0', 'T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T11')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

# `powershell -File ... -Cases P0,T1` delivers one comma-joined string.
$Cases = @($Cases | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
$knownCases = @('P0', 'T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T11')
$unknown = @($Cases | Where-Object { $knownCases -notcontains $_ })
if ($unknown.Count -gt 0) {
    throw "Unknown or manual-only case(s): $($unknown -join ', '). Automated cases: $($knownCases -join ', '). T7-T10 and T12 are in desktop-checklist.md."
}

$repoRoot = Get-Phase4RepoRoot
$runId = 'phase4-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + $(if ($DryRunOnConnectedHost) { '-dryrun' } else { '' })
$evidence = New-EvidenceDirectory -Root $EvidenceRoot -RunId $runId
$pwsh = (Get-Process -Id $PID).Path
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-LoggedScript {
    # Run a script in a child pwsh so its transcript also captures output from
    # grandchild processes (pip, npm, electron-builder) and its exit code is exact.
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$LogName,
        [Parameter()][hashtable]$Environment = @{}
    )
    $log = Join-Path $evidence "$LogName.log"
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
    $saved = @{}
    foreach ($name in $Environment.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $Environment[$name], 'Process')
    }
    try {
        $process = Start-Process -FilePath $pwsh -Wait -PassThru -NoNewWindow `
            -ArgumentList (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + $quoted) `
            -RedirectStandardOutput $log -RedirectStandardError "$log.stderr"
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    $stderr = Get-Content -LiteralPath "$log.stderr" -Raw -ErrorAction SilentlyContinue
    if ($stderr) { Add-Content -LiteralPath $log -Value "`n--- stderr ---`n$stderr" }
    Remove-Item -LiteralPath "$log.stderr" -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Log = $log; Text = (Get-Content -LiteralPath $log -Raw) }
}

function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    if ($Cases -notcontains $Id) { return }
    Write-Host "`n=== $Id $Name" -ForegroundColor Cyan
    $started = [DateTime]::Now
    $notes = [System.Collections.Generic.List[string]]::new()
    $passed = $false
    try {
        # Judge only the body's final value; stray pipeline output must not
        # turn into a pass.
        $output = @(& $Body $notes)
        $passed = $output.Count -gt 0 -and $output[-1] -is [bool] -and $output[-1]
    }
    catch {
        $notes.Add("Harness error: $($_.Exception.Message)")
    }
    $ended = [DateTime]::Now
    $result = [pscustomobject]@{
        id = $Id; name = $Name; passed = $passed
        started_local = $started.ToString('o'); ended_local = $ended.ToString('o')
        seconds = [Math]::Round(($ended - $started).TotalSeconds, 1)
        notes = @($notes)
    }
    $results.Add($result)
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host ("{0} {1} ({2}s)" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $Id, $result.seconds) -ForegroundColor $color
    $notes | ForEach-Object { Write-Host "  $_" }
    Write-EvidenceJson -Path (Join-Path $evidence 'results.json') -InputObject @($results)
}

function New-ScratchRepository {
    # Copy only what verification/install reads before failing: vendor,
    # manifests and scripts. Never mutate the real repository.
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "phase4-scratch-$([Guid]::NewGuid().ToString('N'))"
    foreach ($part in @('vendor', 'manifests', 'scripts')) {
        & robocopy.exe (Join-Path $repoRoot $part) (Join-Path $scratch $part) /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy of $part failed ($LASTEXITCODE)" }
    }
    return $scratch
}

$sampler = Start-ProcessSampler -OutputCsv (Join-Path $evidence 'processes.csv')
$runInfo = [ordered]@{
    run_id = $runId
    dry_run_on_connected_host = [bool]$DryRunOnConnectedHost
    started_local = [DateTime]::Now.ToString('o')
    computer_is_vm = (Test-IsVirtualMachine)
    os = [Environment]::OSVersion.VersionString
    repo_root = $repoRoot
    repo_commit = $(try { (& git -C $repoRoot rev-parse HEAD 2>$null) } catch { $null })
    install_root = $InstallRoot
    hermes_home = $HermesHome
}
Write-EvidenceJson -Path (Join-Path $evidence 'run.json') -InputObject $runInfo

try {
    Invoke-Case 'P0' 'Preflight: clean host and blocked network' {
        param($notes)
        $findings = @(Get-CleanHostFindings)
        $findings | ForEach-Object { $notes.Add("host: $_") }
        $probeArgs = @('-EvidenceDirectory', $evidence) + $(if ($DryRunOnConnectedHost) { @('-ExpectOpen') } else { @() })
        $probe = Invoke-LoggedScript -Script (Join-Path $PSScriptRoot 'Assert-NetworkBlocked.ps1') -Arguments $probeArgs -LogName 'P0-network'
        $notes.Add("network assertion ($(if ($DryRunOnConnectedHost) { 'expect-open' } else { 'expect-blocked' })) exit $($probe.ExitCode)")
        if ($DryRunOnConnectedHost) { return $probe.ExitCode -eq 0 }
        return $probe.ExitCode -eq 0 -and $findings.Count -eq 0
    }

    Invoke-Case 'T1' 'verify-deps.ps1' {
        param($notes)
        $run = Invoke-LoggedScript -Script (Join-Path $repoRoot 'scripts\verify-deps.ps1') -LogName 'T1-verify-deps'
        $notes.Add(($run.Text -split "`n" | Where-Object { $_ -match 'Verified' } | Select-Object -First 1))
        return $run.ExitCode -eq 0 -and $run.Text -match 'Verified 1110 vendored files'
    }

    if ($Cases -contains 'T2' -or $Cases -contains 'T3') {
        $scratch = New-ScratchRepository
        $scratchInstall = Join-Path ([IO.Path]::GetTempPath()) "phase4-must-not-exist-$([Guid]::NewGuid().ToString('N'))"
        try {
            function Test-MutationFails {
                param($notes, [string]$Label, [string]$RelativePath, [ValidateSet('flip', 'remove')][string]$Mutation, [string]$ExpectText)
                $target = Join-Path $scratch $RelativePath
                $backup = "$target.phase4-original"
                Copy-Item -LiteralPath $target -Destination $backup
                try {
                    if ($Mutation -eq 'flip') {
                        $stream = [IO.File]::Open($target, 'Open', 'ReadWrite')
                        try { $stream.Position = [Math]::Min(1024, $stream.Length - 1); $b = $stream.ReadByte(); $stream.Position--; $stream.WriteByte($b -bxor 0xFF) }
                        finally { $stream.Dispose() }
                    } else {
                        Remove-Item -LiteralPath $target
                    }
                    Move-Item -LiteralPath $backup -Destination "$scratch\..\$(Split-Path $backup -Leaf)" -Force
                    $verify = Invoke-LoggedScript -Script (Join-Path $scratch 'scripts\verify-deps.ps1') -Arguments @('-RepoRoot', $scratch) -LogName "$Label-verify"
                    $install = Invoke-LoggedScript -Script (Join-Path $scratch 'scripts\install-offline.ps1') `
                        -Arguments @('-InstallRoot', $scratchInstall, '-HermesHome', "$scratchInstall-home") -LogName "$Label-install"
                    $namePattern = [regex]::Escape($RelativePath)
                    $ok = $true
                    foreach ($pair in @(@('verify-deps', $verify), @('install-offline', $install))) {
                        $name, $run = $pair
                        # Collapse whitespace so console wrapping cannot split a phrase.
                        $flat = $run.Text -replace '\s+', ' '
                        $mentions = $flat -match $namePattern -and $flat -match $ExpectText
                        $notes.Add("${Label} ${name}: exit $($run.ExitCode); names artifact and '$ExpectText': $mentions")
                        if ($run.ExitCode -eq 0 -or -not $mentions) { $ok = $false }
                    }
                    if (($install.Text -replace '\s+', ' ') -notmatch 'manifests/checksums\.sha256' -and $Mutation -eq 'remove') {
                        $notes.Add("$Label install error does not name the manifest"); $ok = $false
                    }
                    foreach ($path in @($scratchInstall, "$scratchInstall-home")) {
                        if (Test-Path -LiteralPath $path) { $notes.Add("$Label left $path behind"); $ok = $false }
                    }
                    return $ok
                }
                finally {
                    $parked = "$scratch\..\$(Split-Path $backup -Leaf)"
                    if (Test-Path -LiteralPath $parked) { Move-Item -LiteralPath $parked -Destination $target -Force }
                }
            }

            $wheel = 'vendor\python\windows-x64-cp311\' + (Get-ChildItem (Join-Path $scratch 'vendor\python\windows-x64-cp311') -Filter '*.whl' | Sort-Object Name | Select-Object -First 1).Name
            $tarball = 'vendor\node\windows-x64-desktop\tarballs\' + (Get-ChildItem (Join-Path $scratch 'vendor\node\windows-x64-desktop\tarballs') -Filter '*.tgz' | Sort-Object Name | Select-Object -Last 1).Name
            $electron = 'vendor\browser\windows-x64\electron-v40.10.2-win32-x64.zip'

            Invoke-Case 'T2' 'Checksum failure: altered .tgz and .whl' {
                param($notes)
                $a = Test-MutationFails $notes 'T2a' $tarball 'flip' 'Checksum mismatch'
                $b = Test-MutationFails $notes 'T2b' $wheel 'flip' 'Checksum mismatch'
                return $a -and $b
            }
            Invoke-Case 'T3' 'Missing artifact: wheel and Electron zip' {
                param($notes)
                $a = Test-MutationFails $notes 'T3a' $wheel 'remove' 'Missing required artifact'
                $b = Test-MutationFails $notes 'T3b' $electron 'remove' 'Missing required artifact'
                return $a -and $b
            }
        }
        finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Case 'T4' 'Clean offline install' {
        param($notes)
        if ($SkipInstall) {
            $notes.Add('Skipped by -SkipInstall; reusing the existing installation.')
            return (Test-Path -LiteralPath (Join-Path $InstallRoot 'install-state.json'))
        }
        if (Test-Path -LiteralPath $InstallRoot) { throw "Install root already exists: $InstallRoot (T4 requires a clean install)." }
        $run = Invoke-LoggedScript -Script (Join-Path $repoRoot 'scripts\install-offline.ps1') `
            -Arguments @('-InstallRoot', $InstallRoot, '-HermesHome', $HermesHome) -LogName 'T4-install'
        $notes.Add("install-offline exit $($run.ExitCode)")
        foreach ($relative in @('app\Hermes.exe', 'venv\Scripts\hermes.exe', 'runtime\node\node.exe', 'launch-hermes.cmd', 'hermes-offline.cmd')) {
            if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $relative))) { $notes.Add("missing $relative"); return $false }
        }
        if ($run.Text -match 'no local electron dist|downloaded\s+label=electron') {
            $notes.Add('electron-builder reported a download fallback'); return $false
        }
        return $run.ExitCode -eq 0
    }

    Invoke-Case 'T5' 'verify-offline.ps1 and cold-start timing' {
        param($notes)
        $run = Invoke-LoggedScript -Script (Join-Path $repoRoot 'scripts\verify-offline.ps1') -Arguments @('-InstallRoot', $InstallRoot) -LogName 'T5-verify-offline'
        $notes.Add("verify-offline exit $($run.ExitCode)")
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & cmd.exe /c "`"$(Join-Path $InstallRoot 'hermes-offline.cmd')`" --version" *> $null
        $notes.Add("hermes --version wall time $([Math]::Round($timer.Elapsed.TotalSeconds, 1))s (desktop probe timeout risk)")
        return $run.ExitCode -eq 0
    }

    Invoke-Case 'T6' 'CLI smoke against loopback mock provider' {
        param($notes)
        $testHome = Join-Path ([IO.Path]::GetTempPath()) 'phase4-test-home'
        Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
        $mock = & (Join-Path $PSScriptRoot 'Start-MockProvider.ps1') -HermesHome $testHome -EvidenceDirectory $evidence `
            -NodeExe (Join-Path $InstallRoot 'runtime\node\node.exe') | Select-Object -Last 1
        try {
            $prompt = 'Phase 4 smoke: say hello'
            $log = Join-Path $evidence 'T6-cli-chat.log'
            $saved = $env:OFFLINE_HERMES_HOME
            $env:OFFLINE_HERMES_HOME = $testHome
            try { & cmd.exe /c "`"$(Join-Path $InstallRoot 'hermes-offline.cmd')`" -z `"$prompt`"" *> $log; $code = $LASTEXITCODE }
            finally { $env:OFFLINE_HERMES_HOME = $saved }
            $output = Get-Content -LiteralPath $log -Raw
            $state = Get-Content -LiteralPath $mock.StateFile -Raw | ConvertFrom-Json
            $replied = $output -match [regex]::Escape($mock.Reply)
            $received = @($state.prompts) -contains $prompt
            $notes.Add("hermes -z exit $code; mock reply in output: $replied; mock received prompt: $received")
            return $code -eq 0 -and $replied -and $received
        }
        finally {
            Stop-Process -Id $mock.ProcessId -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Case 'T11' 'Secret hygiene scan' {
        param($notes)
        $patterns = @{
            'openai-style key' = 'sk-[A-Za-z0-9_-]{20,}'
            'github token' = 'gh[pousr]_[A-Za-z0-9]{30,}'
            'aws access key' = 'AKIA[0-9A-Z]{16}'
            'private key' = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
            'slack token' = 'xox[abpr]-[A-Za-z0-9-]{10,}'
        }
        $credentialFiles = @('.env', 'auth.json', '*.pem', '*.pfx', '*.p12', 'id_rsa*', 'id_ed25519*', 'credentials.json')
        $ours = [System.Collections.Generic.List[string]]::new()
        $upstreamHits = [System.Collections.Generic.List[string]]::new()
        $textExtensions = '.md', '.ps1', '.psm1', '.sh', '.yaml', '.yml', '.json', '.toml', '.py', '.ts', '.tsx', '.js', '.mjs', '.cjs', '.txt', '.cfg', '.ini', '.lock', '.example'
        $files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\vendor\\' -and $_.FullName -notmatch '\\phase4-evidence\\' }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($repoRoot.Length + 1)
            # Plain assignment: an if-expression would enumerate an empty List to $null.
            $bucket = $ours
            if ($relative -like 'upstream\*') { $bucket = $upstreamHits }
            foreach ($glob in $credentialFiles) { if ($file.Name -like $glob) { $bucket.Add("credential-like file: $relative") } }
            if ($textExtensions -notcontains $file.Extension -and $file.Name -notlike '*.example*') { continue }
            if ($file.Length -gt 2MB) { continue }
            $content = [IO.File]::ReadAllText($file.FullName)
            foreach ($label in $patterns.Keys) {
                if ($content -match $patterns[$label]) { $bucket.Add("${label}: $relative") }
            }
        }
        Set-Content -LiteralPath (Join-Path $evidence 'T11-upstream-hits.txt') -Value $upstreamHits
        $notes.Add("distribution files: $($ours.Count) hits; upstream: $($upstreamHits.Count) hits for manual review (T11-upstream-hits.txt)")
        $ours | ForEach-Object { $notes.Add("  $_") }
        return $ours.Count -eq 0
    }
}
finally {
    Stop-ProcessSampler $sampler
    $runInfo.ended_local = [DateTime]::Now.ToString('o')
    Write-EvidenceJson -Path (Join-Path $evidence 'run.json') -InputObject $runInfo
}

$failed = @($results | Where-Object { -not $_.passed })
$lines = @("# Phase 4 run $runId", '', $(if ($DryRunOnConnectedHost) { '**Dry run on a connected host; not a Phase 4 result.**' } else { 'Network-blocked run.' }), '',
    '| Case | Result | Seconds | Notes |', '|---|---|---:|---|')
foreach ($result in $results) {
    $lines += "| $($result.id) $($result.name) | $(if ($result.passed) { 'PASS' } else { 'FAIL' }) | $($result.seconds) | $((@($result.notes) -join '<br>').Replace('|', '\|')) |"
}
$lines += '', 'Manual cases T7-T10 and T12: see tests/phase4/desktop-checklist.md.',
    '', 'Network evidence (run elevated, after the run):', '',
    '```powershell', ".\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory `"$evidence`" -ProcessLog `"$evidence\processes.csv`" -CaseTimeline `"$evidence\results.json`" -FailOnFindings", '```'
Set-Content -LiteralPath (Join-Path $evidence 'summary.md') -Value $lines -Encoding utf8

Write-Host "`nEvidence: $evidence"
Write-Host "$($results.Count - $failed.Count)/$($results.Count) cases passed."
if ($results.Count -ne $Cases.Count) {
    Write-Host "FAIL: $($Cases.Count) case(s) requested but $($results.Count) ran." -ForegroundColor Red
    exit 1
}
if ($failed.Count -gt 0) { exit 1 }
