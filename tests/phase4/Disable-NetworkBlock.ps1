[CmdletBinding()]
param(
    [Parameter()][string]$StateDirectory = (Join-Path $env:ProgramData 'OfflineHermesPhase4')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

if (-not (Test-IsAdministrator)) {
    throw 'Disable-NetworkBlock.ps1 must run from an elevated PowerShell.'
}

$statePath = Join-Path $StateDirectory 'state.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "No recorded network block at $statePath; nothing to restore. Revert the VM snapshot if the network is still blocked."
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

# Importing the exported policy restores profiles, logging settings, and every
# rule exactly, including the allow rules that were disabled and removing the
# Phase 4 rule group.
& netsh.exe advfirewall import "$($state.policy_backup)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "netsh advfirewall import failed for $($state.policy_backup); firewall state was not restored."
}

foreach ($route in @($state.removed_routes)) {
    if (-not (Get-NetRoute -InterfaceIndex $route.ifIndex -DestinationPrefix $route.prefix -ErrorAction SilentlyContinue)) {
        New-NetRoute -InterfaceIndex $route.ifIndex -DestinationPrefix $route.prefix -NextHop $route.nextHop -RouteMetric $route.metric | Out-Null
    }
}

$dnsByInterface = @($state.dns_servers) | Group-Object ifIndex
foreach ($group in $dnsByInterface) {
    $servers = @($group.Group | ForEach-Object { $_.servers })
    Set-DnsClientServerAddress -InterfaceIndex ([int]$group.Name) -ServerAddresses $servers
}
& ipconfig.exe /flushdns | Out-Null

$archived = Join-Path $StateDirectory ("restored-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $archived -Force | Out-Null
Move-Item -LiteralPath $statePath -Destination (Join-Path $archived 'state.json')
Move-Item -LiteralPath $state.policy_backup -Destination (Join-Path $archived 'firewall-before.wfw')

Write-Host "Network block removed; firewall policy, routes and DNS restored. Records archived in $archived"
