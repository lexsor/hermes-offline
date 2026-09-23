Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers for the Phase 4 network-blocked validation harness.
# See docs/phase-4-validation-plan.md.

function Get-Phase4RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsVirtualMachine {
    # HypervisorPresent is true on physical hosts with VBS/Hyper-V enabled, so
    # identify the guest by its virtual hardware model instead.
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $model = [string]$system.Model
    $manufacturer = [string]$system.Manufacturer
    if ($manufacturer -eq 'Microsoft Corporation' -and $model -eq 'Virtual Machine') { return $true }
    return $model -match '^(VMware|VirtualBox|KVM|Standard PC|QEMU|Parallels|HVM domU)' -or
        $manufacturer -match '^(VMware|innotek|QEMU|Xen|Parallels)'
}

function New-EvidenceDirectory {
    param(
        [Parameter()][string]$Root = (Join-Path (Get-Phase4RepoRoot) 'reports\evidence'),
        [Parameter()][string]$RunId = ('phase4-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    )
    $path = Join-Path $Root $RunId
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Write-EvidenceJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject
    )
    $InputObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
}

# Public endpoints the offline path must never reach. Used only as negative
# probes by Assert-NetworkBlocked.ps1.
function Get-PublicProbeTargets {
    return [pscustomobject]@{
        DnsNames = @('pypi.org', 'registry.npmjs.org', 'github.com', 'api.github.com', 'nousresearch.com')
        PublicResolvers = @('8.8.8.8', '1.1.1.1')
        HttpsUrls = @(
            'https://pypi.org/simple/',
            'https://registry.npmjs.org/',
            'https://api.github.com/',
            'https://github.com/',
            'https://nousresearch.com/'
        )
        TcpEndpoints = @(
            @{ Host = '1.1.1.1'; Port = 443 },
            @{ Host = '8.8.8.8'; Port = 53 },
            @{ Host = '140.82.112.3'; Port = 443 },
            @{ Host = '2606:4700:4700::1111'; Port = 443 }
        )
    }
}

function Test-TcpConnect {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter()][int]$TimeoutMilliseconds = 4000
    )
    $client = [System.Net.Sockets.TcpClient]::new(
        $(if ($HostName.Contains(':')) { [System.Net.Sockets.AddressFamily]::InterNetworkV6 } else { [System.Net.Sockets.AddressFamily]::InterNetwork })
    )
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return 'timeout' }
        if ($client.Connected) { return 'connected' }
        return 'failed'
    }
    catch {
        return 'failed'
    }
    finally {
        $client.Dispose()
    }
}

function Get-CleanHostFindings {
    # P0 preflight: anything here could mask a missing vendored artifact.
    $findings = [System.Collections.Generic.List[string]]::new()

    foreach ($command in @('python', 'python3', 'py', 'node', 'npm', 'npx', 'git', 'uv', 'uvx', 'rg', 'pip')) {
        $found = Get-Command $command -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notlike "$env:LOCALAPPDATA\Microsoft\WindowsApps\*" } |
            Select-Object -First 1
        if ($found) { $findings.Add("Host tool on PATH: $command -> $($found.Source)") }
    }

    $cacheDirectories = @(
        (Join-Path $env:LOCALAPPDATA 'electron'),
        (Join-Path $env:LOCALAPPDATA 'electron-builder'),
        (Join-Path $env:LOCALAPPDATA 'npm-cache'),
        (Join-Path $env:APPDATA 'npm-cache'),
        (Join-Path $env:LOCALAPPDATA 'pip'),
        (Join-Path $env:LOCALAPPDATA 'uv'),
        (Join-Path $env:LOCALAPPDATA 'hermes'),
        (Join-Path $env:USERPROFILE '.hermes')
    )
    foreach ($directory in $cacheDirectories) {
        if (Test-Path -LiteralPath $directory) { $findings.Add("Pre-existing cache or install: $directory") }
    }

    foreach ($scope in @('User', 'Machine')) {
        foreach ($name in @('HERMES_HOME', 'npm_config_cache', 'PIP_FIND_LINKS', 'UV_CACHE_DIR', 'ELECTRON_MIRROR')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($value) { $findings.Add("$scope environment sets $name=$value") }
        }
    }

    $longPaths = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue
    if (-not $longPaths -or $longPaths.LongPathsEnabled -ne 1) {
        $findings.Add('LongPathsEnabled is not 1 (HKLM\SYSTEM\CurrentControlSet\Control\FileSystem).')
    }

    return $findings.ToArray()
}

function Start-ProcessSampler {
    # Firewall drop records carry only a PID; sample PID -> image/command line
    # during the run so Collect-NetworkEvidence.ps1 can name the offender.
    param(
        [Parameter(Mandatory)][string]$OutputCsv,
        [Parameter()][int]$IntervalMilliseconds = 500
    )
    '"pid","name","path","command_line","first_seen"' | Set-Content -LiteralPath $OutputCsv -Encoding utf8
    return Start-ThreadJob -ArgumentList $OutputCsv, $IntervalMilliseconds -ScriptBlock {
        param($csv, $interval)
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        while ($true) {
            foreach ($process in Get-CimInstance -ClassName Win32_Process -Property ProcessId, Name, ExecutablePath, CommandLine, CreationDate) {
                $key = "$($process.ProcessId)|$($process.CreationDate)"
                if (-not $seen.Add($key)) { continue }
                [pscustomobject]@{
                    pid = $process.ProcessId
                    name = $process.Name
                    path = $process.ExecutablePath
                    command_line = $process.CommandLine
                    first_seen = [DateTime]::Now.ToString('o')
                } | Export-Csv -LiteralPath $csv -Append -NoTypeInformation -Encoding utf8
            }
            Start-Sleep -Milliseconds $interval
        }
    }
}

function Stop-ProcessSampler {
    param([Parameter(Mandatory)]$Job)
    Stop-Job -Job $Job -ErrorAction SilentlyContinue
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function @(
    'Get-CleanHostFindings',
    'Start-ProcessSampler',
    'Stop-ProcessSampler',
    'Get-Phase4RepoRoot',
    'Get-PublicProbeTargets',
    'New-EvidenceDirectory',
    'Test-IsAdministrator',
    'Test-IsVirtualMachine',
    'Test-TcpConnect',
    'Write-EvidenceJson'
)
