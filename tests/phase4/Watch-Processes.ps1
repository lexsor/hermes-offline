[CmdletBinding()]
param(
    # Where to append PID -> image records (same format as Start-ProcessSampler).
    [Parameter(Mandatory)][string]$OutputCsv,
    [Parameter()][int]$IntervalMilliseconds = 500
)

# Foreground process sampler for the manual Phase 4 cases (T7-T12). The
# automated run's sampler stops when Invoke-Phase4.ps1 ends, so without this
# every network event during the manual cases has an unattributable PID.
# Run it in its own window before starting the manual cases; stop with Ctrl+C.
# Pass the CSV to Collect-NetworkEvidence.ps1 -ProcessLog alongside processes.csv.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$directory = Split-Path -Parent $OutputCsv
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
if (-not (Test-Path -LiteralPath $OutputCsv)) {
    '"pid","name","path","command_line","first_seen"' | Set-Content -LiteralPath $OutputCsv -Encoding utf8
}

$seen = [System.Collections.Generic.HashSet[string]]::new()
Write-Host "Sampling processes into $OutputCsv every $IntervalMilliseconds ms. Press Ctrl+C to stop."
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
        } | Export-Csv -LiteralPath $OutputCsv -Append -NoTypeInformation -Encoding utf8
    }
    Start-Sleep -Milliseconds $IntervalMilliseconds
}
