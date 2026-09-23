[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    # Only events at or after this local time are considered (default: when
    # Enable-NetworkBlock.ps1 ran).
    [Parameter()][Nullable[datetime]]$Since,
    # CSV written by Start-ProcessSampler, used to name the process behind a PID.
    [Parameter()][string]$ProcessLog,
    # results.json from Invoke-Phase4.ps1; attributes each event to a test case.
    [Parameter()][string]$CaseTimeline,
    [Parameter()][string]$FirewallLogPath = (Join-Path $env:SystemRoot 'System32\LogFiles\Firewall\pfirewall.log'),
    [Parameter()][string]$StateDirectory = (Join-Path $env:ProgramData 'OfflineHermesPhase4'),
    # Exit 1 when any public-destination drop or public-name DNS query is found.
    [Parameter()][switch]$FailOnFindings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

if (-not $Since) {
    $statePath = Join-Path $StateDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw "Pass -Since, or run Enable-NetworkBlock.ps1 first (no $statePath)."
    }
    $Since = [datetime]::Parse((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).enabled_at_local)
}

$processNames = @{}
if ($ProcessLog -and (Test-Path -LiteralPath $ProcessLog)) {
    foreach ($row in Import-Csv -LiteralPath $ProcessLog) {
        if (-not $processNames.ContainsKey($row.pid)) { $processNames[$row.pid] = @() }
        $processNames[$row.pid] += $(if ($row.path) { $row.path } else { $row.name })
    }
}
function Resolve-ProcessLabel {
    param([string]$ProcessId)
    if (-not $ProcessId -or $ProcessId -eq '-') { return 'unknown' }
    if ($processNames.ContainsKey($ProcessId)) { return (($processNames[$ProcessId] | Select-Object -Unique) -join ' | ') }
    return "pid $ProcessId (not sampled)"
}

$caseWindows = @()
if ($CaseTimeline -and (Test-Path -LiteralPath $CaseTimeline)) {
    $caseWindows = @(Get-Content -LiteralPath $CaseTimeline -Raw | ConvertFrom-Json | ForEach-Object {
        [pscustomobject]@{ id = $_.id; start = [datetime]::Parse($_.started_local); end = [datetime]::Parse($_.ended_local) }
    })
}
function Resolve-CaseId {
    param([datetime]$When)
    $match = $caseWindows | Where-Object { $When -ge $_.start.AddSeconds(-1) -and $When -le $_.end.AddSeconds(1) } | Select-Object -First 1
    if ($match) { return $match.id }
    return 'between-cases'
}

function Get-DestinationClass {
    param([string]$Address)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return 'unparsed' }
    if ([System.Net.IPAddress]::IsLoopback($ip)) { return 'loopback' }
    $bytes = $ip.GetAddressBytes()
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if ($bytes[0] -ge 224) { return 'multicast-broadcast' }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return 'link-local' }
        if ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) { return 'private-lan' }
        return 'public'
    }
    if ($ip.IsIPv6Multicast) { return 'multicast-broadcast' }
    if ($ip.IsIPv6LinkLocal) { return 'link-local' }
    if (($bytes[0] -band 0xfe) -eq 0xfc) { return 'private-lan' }
    return 'public'
}

# --- Firewall drops -------------------------------------------------------
$drops = [System.Collections.Generic.List[object]]::new()
$firewallStatus = 'read'
try {
    $fields = $null
    foreach ($line in [System.IO.File]::ReadLines($FirewallLogPath)) {
        if ($line.StartsWith('#Fields:')) { $fields = $line.Substring(8).Trim() -split '\s+'; continue }
        if (-not $fields -or $line.StartsWith('#') -or -not $line.Trim()) { continue }
        $values = $line -split '\s+'
        $record = @{}
        for ($i = 0; $i -lt [Math]::Min($fields.Count, $values.Count); $i++) { $record[$fields[$i]] = $values[$i] }
        if ($record['action'] -ne 'DROP' -or $record['path'] -ne 'SEND') { continue }
        $when = [datetime]::ParseExact("$($record['date']) $($record['time'])", 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        if ($when -lt $Since) { continue }
        $class = Get-DestinationClass $record['dst-ip']
        if ($class -eq 'loopback') { continue }
        $drops.Add([pscustomobject]@{
            time = $when.ToString('s')
            protocol = $record['protocol']
            destination = "$($record['dst-ip']):$($record['dst-port'])"
            class = $class
            case = Resolve-CaseId $when
            pid = $record['pid']
            process = Resolve-ProcessLabel $record['pid']
        })
    }
}
catch [System.UnauthorizedAccessException] {
    $firewallStatus = 'access-denied (run elevated)'
}
catch [System.IO.FileNotFoundException] {
    $firewallStatus = 'missing (dropped-packet logging not enabled?)'
}

# --- DNS client queries ---------------------------------------------------
$queries = [System.Collections.Generic.List[object]]::new()
$dnsStatus = 'read'
$localSuffixes = @('localhost', '.local', '.localdomain', '.home.arpa', '.in-addr.arpa', '.ip6.arpa', '.lan')
$computerName = $env:COMPUTERNAME.ToLowerInvariant()
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-DNS-Client/Operational'; Id = 3006; StartTime = $Since
    } -ErrorAction Stop
    foreach ($event in $events) {
        $name = ([string]$event.Properties[0].Value).TrimEnd('.').ToLowerInvariant()
        if (-not $name) { continue }
        $isLocal = $name -eq $computerName -or $name -notmatch '\.' -or
            @($localSuffixes | Where-Object { $name -eq $_.TrimStart('.') -or $name.EndsWith($_) }).Count -gt 0
        $queries.Add([pscustomobject]@{
            time = $event.TimeCreated.ToString('s')
            name = $name
            class = $(if ($isLocal) { 'local' } else { 'public' })
            case = Resolve-CaseId $event.TimeCreated
            pid = $event.ProcessId
            process = Resolve-ProcessLabel ([string]$event.ProcessId)
        })
    }
}
catch {
    if ($_.Exception.Message -match 'No events were found') { $dnsStatus = 'read (no events)' }
    else { $dnsStatus = "unavailable: $($_.Exception.Message)" }
}

$publicDrops = @($drops | Where-Object class -eq 'public')
$publicQueries = @($queries | Where-Object class -eq 'public')

$summary = [pscustomobject]@{
    collected_at = [DateTime]::UtcNow.ToString('o')
    since_local = $Since.ToString('o')
    firewall_log = $firewallStatus
    dns_log = $dnsStatus
    public_drops = $publicDrops.Count
    other_drops = $drops.Count - $publicDrops.Count
    public_dns_queries = $publicQueries.Count
    public_events_by_case = @(@($publicDrops) + @($publicQueries) | Group-Object case |
        ForEach-Object { [pscustomobject]@{ case = $_.Name; count = $_.Count } })
    public_drops_by_process = @($publicDrops | Group-Object process | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ process = $_.Name; count = $_.Count; destinations = @($_.Group.destination | Select-Object -Unique) } })
    public_dns_by_process = @($publicQueries | Group-Object process | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ process = $_.Name; count = $_.Count; names = @($_.Group.name | Select-Object -Unique) } })
}

Write-EvidenceJson -Path (Join-Path $EvidenceDirectory 'network-evidence.json') -InputObject $summary
$drops | Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'firewall-drops.csv') -NoTypeInformation -Encoding utf8
$queries | Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'dns-queries.csv') -NoTypeInformation -Encoding utf8

Write-Host "Network evidence since $($Since.ToString('s')): firewall log $firewallStatus; DNS log $dnsStatus."
Write-Host "Public-destination drops: $($publicDrops.Count); other drops: $($drops.Count - $publicDrops.Count); public-name DNS queries: $($publicQueries.Count)."
foreach ($entry in $summary.public_drops_by_process) { Write-Host "  DROP  $($entry.count)x $($entry.process) -> $($entry.destinations -join ', ')" }
foreach ($entry in $summary.public_dns_by_process) { Write-Host "  DNS   $($entry.count)x $($entry.process) -> $($entry.names -join ', ')" }

$incomplete = $firewallStatus -ne 'read' -or $dnsStatus -like 'unavailable*'
if ($FailOnFindings -and ($publicDrops.Count -gt 0 -or $publicQueries.Count -gt 0 -or $incomplete)) {
    if ($incomplete) { Write-Host 'FAIL: evidence is incomplete, so "no attempts" cannot be claimed.' -ForegroundColor Red }
    exit 1
}
exit 0
