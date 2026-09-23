[CmdletBinding()]
param(
    # Where to write network-probe.json. Omit to print results only.
    [Parameter()][string]$EvidenceDirectory,
    # Dry-run mode for validating the harness on a connected machine: assert that
    # the public probes SUCCEED, proving each probe can detect an open network.
    [Parameter()][switch]$ExpectOpen,
    [Parameter()][int]$TimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

$targets = Get-PublicProbeTargets
$results = [System.Collections.Generic.List[object]]::new()

function Add-ProbeResult {
    param([string]$Kind, [string]$Target, [bool]$Reached, [string]$Detail)
    $results.Add([pscustomobject]@{ kind = $Kind; target = $Target; reached = $Reached; detail = $Detail })
}

foreach ($name in $targets.DnsNames) {
    try {
        $answer = Resolve-DnsName -Name $name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
            Where-Object { $_.PSObject.Properties['IPAddress'] } | Select-Object -First 1
        Add-ProbeResult 'dns-system' $name ([bool]$answer) $(if ($answer) { $answer.IPAddress } else { 'no A record' })
    }
    catch {
        Add-ProbeResult 'dns-system' $name $false $_.Exception.Message
    }
}

foreach ($resolver in $targets.PublicResolvers) {
    try {
        $answer = Resolve-DnsName -Name 'github.com' -Type A -Server $resolver -DnsOnly -QuickTimeout -ErrorAction Stop |
            Where-Object { $_.PSObject.Properties['IPAddress'] } | Select-Object -First 1
        Add-ProbeResult 'dns-direct' "github.com via $resolver" ([bool]$answer) $(if ($answer) { $answer.IPAddress } else { 'no A record' })
    }
    catch {
        Add-ProbeResult 'dns-direct' "github.com via $resolver" $false $_.Exception.Message
    }
}

foreach ($url in $targets.HttpsUrls) {
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop
        # Any HTTP status means a TCP+TLS session to the public host succeeded.
        Add-ProbeResult 'https' $url $true "HTTP $([int]$response.StatusCode)"
    }
    catch {
        Add-ProbeResult 'https' $url $false $_.Exception.Message
    }
}

foreach ($endpoint in $targets.TcpEndpoints) {
    $outcome = Test-TcpConnect -HostName $endpoint.Host -Port $endpoint.Port -TimeoutMilliseconds ($TimeoutSeconds * 1000)
    Add-ProbeResult 'tcp' "$($endpoint.Host):$($endpoint.Port)" ($outcome -eq 'connected') $outcome
}

# Loopback must keep working: the mock inference provider listens on 127.0.0.1.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    $loopbackPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $loopback = Test-TcpConnect -HostName '127.0.0.1' -Port $loopbackPort -TimeoutMilliseconds 2000
}
finally {
    $listener.Stop()
}

$public = @($results)
$reached = @($public | Where-Object reached)
$unreached = @($public | Where-Object { -not $_.reached })

$summary = [pscustomobject]@{
    checked_at = [DateTime]::UtcNow.ToString('o')
    mode = $(if ($ExpectOpen) { 'expect-open' } else { 'expect-blocked' })
    computer_is_vm = (Test-IsVirtualMachine)
    loopback = $loopback
    public_probes = $public.Count
    public_reached = $reached.Count
    probes = $public
}
if ($EvidenceDirectory) {
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    $suffix = [DateTime]::UtcNow.ToString('HHmmss')
    Write-EvidenceJson -Path (Join-Path $EvidenceDirectory "network-probe-$suffix.json") -InputObject $summary
}

$public | Format-Table kind, target, reached, detail -AutoSize | Out-String -Width 200 | Write-Host

$failures = [System.Collections.Generic.List[string]]::new()
if ($loopback -ne 'connected') { $failures.Add("Loopback TCP to 127.0.0.1 failed ($loopback); the mock provider cannot work.") }
if ($ExpectOpen) {
    # Harness validation: DNS and HTTPS must be observable as open. The IPv6
    # TCP probe is informational because many networks lack IPv6.
    foreach ($probe in $unreached) {
        if ($probe.kind -eq 'tcp' -and $probe.target.Contains('::')) { continue }
        $failures.Add("Expected an open network but $($probe.kind) probe could not reach $($probe.target): $($probe.detail)")
    }
} else {
    foreach ($probe in $reached) {
        $failures.Add("Public network reachable: $($probe.kind) $($probe.target) ($($probe.detail))")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
if ($ExpectOpen) {
    Write-Host "Harness dry run passed: $($reached.Count)/$($public.Count) probes observed the open network (IPv6 optional); loopback OK."
} else {
    Write-Host "Network block verified: 0/$($public.Count) public probes reached; loopback OK."
}
exit 0
