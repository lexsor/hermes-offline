[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    # Only events at or after this local time are considered (default: when
    # Enable-NetworkBlock.ps1 ran).
    [Parameter()][Nullable[datetime]]$Since,
    # CSV(s) written by Start-ProcessSampler / Watch-Processes.ps1, used to name
    # the process behind a PID. Pass the automated run's and the manual cases'.
    [Parameter()][string[]]$ProcessLog,
    # results.json from Invoke-Phase4.ps1; attributes each event to a test case.
    [Parameter()][string]$CaseTimeline,
    # Paths whose processes belong to the test (anything else is host background).
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes'),
    [Parameter()][string]$HermesHome = (Join-Path $env:LOCALAPPDATA 'OfflineHermes-home'),
    [Parameter()][string]$FirewallLogPath = (Join-Path $env:SystemRoot 'System32\LogFiles\Firewall\pfirewall.log'),
    [Parameter()][string]$StateDirectory = (Join-Path $env:ProgramData 'OfflineHermesPhase4'),
    # Exit 1 when a Hermes/test process attempted public network access, or when
    # either log does not cover the whole window (so "no attempts" is unprovable).
    [Parameter()][switch]$FailOnFindings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

$invariant = [Globalization.CultureInfo]::InvariantCulture
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

if (-not $Since) {
    $statePath = Join-Path $StateDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw "Pass -Since, or run Enable-NetworkBlock.ps1 first (no $statePath)."
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $Since = [datetime]::Parse($state.enabled_at_local, $invariant)
}

# --- Process ownership ------------------------------------------------------
# Windows reuses PIDs, so a PID is resolved to the image that held it at the
# moment of the event, not to every image that ever had it.
$processTimeline = @{}
$processLogs = @(@($ProcessLog) | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })
foreach ($log in $processLogs) {
    if (-not (Test-Path -LiteralPath $log)) { Write-Warning "Process log not found: $log"; continue }
    $entries = @(foreach ($row in Import-Csv -LiteralPath $log) {
        [pscustomobject]@{
            pid = $row.pid
            start = [DateTimeOffset]::Parse($row.first_seen, $invariant).LocalDateTime
            image = $(if ($row.path) { $row.path } else { $row.name })
            sampledUntil = $null
        }
    })
    if ($entries.Count -eq 0) { continue }
    # A sampler only knows PID owners while it runs. The newest record in its
    # log approximates when it stopped; after that a PID may have been reused
    # (the Azure rerun misattributed Edge WebView lookups made 12 minutes after
    # sampling ended to an exited Hermes python.exe).
    $sampledUntil = ($entries | Measure-Object -Property start -Maximum).Maximum
    foreach ($entry in $entries) {
        if ($entry.pid -eq '-1') { continue }   # sampler heartbeat
        $entry.sampledUntil = $sampledUntil
        if (-not $processTimeline.ContainsKey($entry.pid)) {
            $processTimeline[$entry.pid] = [System.Collections.Generic.List[object]]::new()
        }
        $processTimeline[$entry.pid].Add($entry)
    }
}
# Sort once, after every log is loaded (sorting yields fixed-size arrays).
foreach ($key in @($processTimeline.Keys)) {
    $processTimeline[$key] = @($processTimeline[$key] | Sort-Object start)
}
function Resolve-ProcessOwner {
    param([string]$ProcessId, [datetime]$When)
    if (-not $ProcessId -or $ProcessId -eq '-') { return 'unknown' }
    if (-not $processTimeline.ContainsKey($ProcessId)) { return "pid $ProcessId (never sampled)" }
    $owner = $null
    # The sampler polls every 500 ms; a process can connect before it is seen.
    $cutoff = $When.AddSeconds(2)
    foreach ($entry in $processTimeline[$ProcessId]) {
        if ($entry.start -le $cutoff) { $owner = $entry } else { break }
    }
    if (-not $owner) { return "pid $ProcessId (not yet sampled)" }
    if ($When -gt $owner.sampledUntil.AddSeconds(5)) {
        return "pid $ProcessId (after sampling ended; last seen as $($owner.image))"
    }
    return $owner.image
}

$testRoots = @(
    (Get-Phase4RepoRoot), $InstallRoot, $HermesHome, (Join-Path ([IO.Path]::GetTempPath()) 'phase4-')
) | ForEach-Object { $_.TrimEnd('\') }
$testImages = @('node.exe', 'python.exe', 'pythonw.exe', 'hermes.exe', 'electron.exe', 'git.exe', 'git-remote-https.exe',
    'curl.exe', 'ssh.exe', 'uv.exe', 'uvx.exe', 'rg.exe', 'pip.exe', 'npm.cmd', 'npx.cmd', 'tar.exe', '7za.exe', 'bash.exe', 'sh.exe')
function Get-OwnerBucket {
    # test: a Hermes/installer/tool process; any public attempt is a finding.
    # unattributed: the PID could not be resolved; review by hand.
    # host: Windows, Azure agents, Edge, OneDrive, Defender... (background noise).
    param([string]$Owner)
    if ($Owner -match '^(unknown|pid \d+)') { return 'unattributed' }
    foreach ($root in $testRoots) {
        if ($Owner.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return 'test' }
    }
    if ($testImages -contains ([IO.Path]::GetFileName($Owner)).ToLowerInvariant()) { return 'test' }
    return 'host'
}

$caseWindows = @()
if ($CaseTimeline -and (Test-Path -LiteralPath $CaseTimeline)) {
    # Assign before iterating: Windows PowerShell 5.1's ConvertFrom-Json emits a
    # JSON array as ONE pipeline object.
    $timeline = Get-Content -LiteralPath $CaseTimeline -Raw | ConvertFrom-Json
    $caseWindows = @(foreach ($entry in @($timeline)) {
        [pscustomobject]@{
            id = $entry.id
            start = [datetime]::Parse($entry.started_local, $invariant).AddSeconds(-1)
            end = [datetime]::Parse($entry.ended_local, $invariant).AddSeconds(1)
        }
    })
}
function Resolve-CaseId {
    param([datetime]$When)
    foreach ($window in $caseWindows) {
        if ($When -ge $window.start -and $When -le $window.end) { return $window.id }
    }
    return 'between-cases'
}

# Evidence must cover all TEST activity: from the first case's start (or, with
# no timeline, from when the block was enabled). Enable-NetworkBlock.ps1
# clears the DNS log right after recording enabled_at, so requiring coverage
# from enabled_at itself would always report a spurious gap of a few seconds.
$requiredFrom = $Since
if ($caseWindows.Count -gt 0) {
    $firstCase = ($caseWindows | Sort-Object start | Select-Object -First 1).start
    if ($firstCase -gt $requiredFrom) { $requiredFrom = $firstCase }
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
$firewallOldest = $null
$reader = $null
# At its size limit the firewall renames pfirewall.log to pfirewall.log.old
# (discarding any previous .old); read both, oldest first.
$firewallFiles = @(@("$FirewallLogPath.old", $FirewallLogPath) | Where-Object { Test-Path -LiteralPath $_ })
if ($firewallFiles.Count -eq 0) { $firewallFiles = @($FirewallLogPath) }
try {
  foreach ($firewallFile in $firewallFiles) {
    $fields = $null
    # The firewall service keeps pfirewall.log open for writing; File.ReadLines
    # asks for exclusive read access and fails, so open it with ReadWrite sharing.
    $stream = [System.IO.FileStream]::new($firewallFile, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    $reader = [System.IO.StreamReader]::new($stream)
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.StartsWith('#Fields:')) { $fields = $line.Substring(8).Trim() -split '\s+'; continue }
        if (-not $fields -or $line.StartsWith('#') -or -not $line.Trim()) { continue }
        $values = $line -split '\s+'
        $record = @{}
        for ($i = 0; $i -lt [Math]::Min($fields.Count, $values.Count); $i++) { $record[$fields[$i]] = $values[$i] }
        $when = [datetime]::ParseExact("$($record['date']) $($record['time'])", 'yyyy-MM-dd HH:mm:ss', $invariant)
        if ($null -eq $firewallOldest) { $firewallOldest = $when }
        if ($record['action'] -ne 'DROP' -or $record['path'] -ne 'SEND') { continue }
        if ($when -lt $Since) { continue }
        $class = Get-DestinationClass $record['dst-ip']
        if ($class -eq 'loopback') { continue }
        $owner = Resolve-ProcessOwner $record['pid'] $when
        $drops.Add([pscustomobject]@{
            time = $when.ToString('s')
            protocol = $record['protocol']
            destination = "$($record['dst-ip']):$($record['dst-port'])"
            class = $class
            case = Resolve-CaseId $when
            pid = $record['pid']
            process = $owner
            bucket = Get-OwnerBucket $owner
        })
    }
    $reader.Dispose()
    $reader = $null
  }
    if ($null -eq $firewallOldest) {
        $firewallStatus = 'incomplete: log has no records'
    } elseif ($firewallOldest -gt $requiredFrom) {
        # More than one rotation discarded records, or logging started late.
        $firewallStatus = "incomplete: log starts at $($firewallOldest.ToString('s')), after the first test started ($($requiredFrom.ToString('s')))"
    }
}
catch [System.UnauthorizedAccessException] {
    $firewallStatus = 'unavailable: access denied (run elevated)'
}
catch [System.IO.FileNotFoundException] {
    $firewallStatus = 'unavailable: missing (dropped-packet logging not enabled?)'
}
catch [System.IO.IOException] {
    $firewallStatus = "unavailable: $($_.Exception.Message)"
}
finally {
    if ($reader) { $reader.Dispose() }
}

# --- DNS client queries ---------------------------------------------------
# Lookups are sent by the DNS client service (svchost), so the firewall log
# cannot name the requester. Event 3006 records the requesting process.
$dnsLog = 'Microsoft-Windows-DNS-Client/Operational'
$queries = [System.Collections.Generic.List[object]]::new()
$dnsStatus = 'read'
$localSuffixes = @('localhost', '.local', '.localdomain', '.home.arpa', '.in-addr.arpa', '.ip6.arpa', '.lan')
$computerName = $env:COMPUTERNAME.ToLowerInvariant()
try {
    $oldestEvent = Get-WinEvent -LogName $dnsLog -Oldest -MaxEvents 1 -ErrorAction Stop
    if ($oldestEvent.TimeCreated -gt $requiredFrom) {
        # The log wrapped: its default 1 MB fills in about a minute on a busy host.
        $dnsStatus = "incomplete: log starts at $($oldestEvent.TimeCreated.ToString('s')), after the first test started ($($requiredFrom.ToString('s'))); log too small?"
    }
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = $dnsLog; Id = 3006; StartTime = $Since } -ErrorAction SilentlyContinue)
    foreach ($event in $events) {
        $name = ([string]$event.Properties[0].Value).TrimEnd('.').ToLowerInvariant()
        if (-not $name) { continue }
        $isLocal = $name -eq $computerName -or $name -notmatch '\.' -or
            @($localSuffixes | Where-Object { $name -eq $_.TrimStart('.') -or $name.EndsWith($_) }).Count -gt 0
        $owner = Resolve-ProcessOwner ([string]$event.ProcessId) $event.TimeCreated
        $queries.Add([pscustomobject]@{
            time = $event.TimeCreated.ToString('s')
            name = $name
            class = $(if ($isLocal) { 'local' } else { 'public' })
            case = Resolve-CaseId $event.TimeCreated
            pid = $event.ProcessId
            process = $owner
            bucket = Get-OwnerBucket $owner
        })
    }
}
catch {
    if ($_.Exception.Message -match 'No events were found') { $dnsStatus = 'incomplete: log has no events (logging not enabled?)' }
    else { $dnsStatus = "unavailable: $($_.Exception.Message)" }
}

function Get-ByProcess {
    param($Items, [string]$Field)
    return @($Items | Group-Object process | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{
            process = $_.Name
            count = $_.Count
            cases = @($_.Group.case | Select-Object -Unique)
            targets = @($_.Group.$Field | Select-Object -Unique | Select-Object -First 20)
        }
    })
}

$publicDrops = @($drops | Where-Object class -eq 'public')
$publicQueries = @($queries | Where-Object class -eq 'public')
$buckets = @{}
foreach ($bucket in 'test', 'unattributed', 'host') {
    $buckets[$bucket] = [pscustomobject]@{
        drops = @($publicDrops | Where-Object bucket -eq $bucket)
        queries = @($publicQueries | Where-Object bucket -eq $bucket)
    }
}

$summary = [pscustomobject]@{
    collected_at = [DateTime]::UtcNow.ToString('o')
    since_local = $Since.ToString('o')
    coverage_required_from_local = $requiredFrom.ToString('o')
    process_logs = $processLogs
    firewall_log = $firewallStatus
    dns_log = $dnsStatus
    test_public_drops = $buckets.test.drops.Count
    test_public_dns_queries = $buckets.test.queries.Count
    unattributed_public_drops = $buckets.unattributed.drops.Count
    unattributed_public_dns_queries = $buckets.unattributed.queries.Count
    host_public_drops = $buckets.host.drops.Count
    host_public_dns_queries = $buckets.host.queries.Count
    other_drops = $drops.Count - $publicDrops.Count
    public_events_by_case = @(@($publicDrops) + @($publicQueries) | Group-Object case |
        ForEach-Object { [pscustomobject]@{ case = $_.Name; count = $_.Count } })
    test_drops_by_process = Get-ByProcess $buckets.test.drops 'destination'
    test_dns_by_process = Get-ByProcess $buckets.test.queries 'name'
    unattributed_drops_by_process = Get-ByProcess $buckets.unattributed.drops 'destination'
    unattributed_dns_by_process = Get-ByProcess $buckets.unattributed.queries 'name'
    host_drops_by_process = Get-ByProcess $buckets.host.drops 'destination'
    host_dns_by_process = Get-ByProcess $buckets.host.queries 'name'
}

Write-EvidenceJson -Path (Join-Path $EvidenceDirectory 'network-evidence.json') -InputObject $summary
$drops | Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'firewall-drops.csv') -NoTypeInformation -Encoding utf8
$queries | Export-Csv -LiteralPath (Join-Path $EvidenceDirectory 'dns-queries.csv') -NoTypeInformation -Encoding utf8

Write-Host "Network evidence since $($Since.ToString('s')); coverage required from $($requiredFrom.ToString('s'))"
Write-Host "  firewall log: $firewallStatus"
Write-Host "  DNS log:      $dnsStatus"
Write-Host "Hermes/test processes:  $($buckets.test.drops.Count) public drops, $($buckets.test.queries.Count) public DNS queries"
foreach ($entry in @($summary.test_drops_by_process) + @($summary.test_dns_by_process)) {
    Write-Host "  FINDING $($entry.count)x $($entry.process) [$($entry.cases -join ',')] -> $($entry.targets -join ', ')" -ForegroundColor Red
}
Write-Host "Unattributed PIDs:      $($buckets.unattributed.drops.Count) public drops, $($buckets.unattributed.queries.Count) public DNS queries (review by hand)"
foreach ($entry in @($summary.unattributed_drops_by_process) + @($summary.unattributed_dns_by_process) | Select-Object -First 10) {
    Write-Host "  review  $($entry.count)x $($entry.process) [$($entry.cases -join ',')] -> $($entry.targets -join ', ')"
}
Write-Host "Host background:        $($buckets.host.drops.Count) public drops, $($buckets.host.queries.Count) public DNS queries (Windows/Azure; blocked, not findings)"
foreach ($entry in @($summary.host_drops_by_process) + @($summary.host_dns_by_process) | Sort-Object count -Descending | Select-Object -First 8) {
    Write-Host "  host    $($entry.count)x $($entry.process)"
}

$incomplete = $firewallStatus -ne 'read' -or $dnsStatus -ne 'read'
if ($incomplete) {
    Write-Host 'Evidence is INCOMPLETE: a log does not cover the whole window, so "no attempts" cannot be claimed.' -ForegroundColor Red
}
if ($FailOnFindings -and ($buckets.test.drops.Count -gt 0 -or $buckets.test.queries.Count -gt 0 -or $incomplete)) {
    exit 1
}
exit 0
