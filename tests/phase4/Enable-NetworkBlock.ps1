[CmdletBinding()]
param(
    # Required acknowledgement: this blocks ALL non-loopback outbound traffic.
    [Parameter()][switch]$IUnderstandThisBlocksAllOutboundTraffic,
    # Second layer: also remove default routes and point DNS at 127.0.0.1.
    [Parameter()][switch]$AlsoRemoveRoutesAndDns,
    # The harness is meant for a disposable VM. Override only for a dedicated,
    # physically isolated test machine.
    [Parameter()][switch]$AllowPhysicalHost,
    [Parameter()][string]$StateDirectory = (Join-Path $env:ProgramData 'OfflineHermesPhase4')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

$ruleGroup = 'OfflineHermes Phase4'

if (-not $IUnderstandThisBlocksAllOutboundTraffic) {
    throw 'Refusing to run without -IUnderstandThisBlocksAllOutboundTraffic. This script blocks all non-loopback outbound traffic until Disable-NetworkBlock.ps1 is run or the VM snapshot is reverted.'
}
if (-not (Test-IsAdministrator)) {
    throw 'Enable-NetworkBlock.ps1 must run from an elevated PowerShell.'
}
if (-not (Test-IsVirtualMachine) -and -not $AllowPhysicalHost) {
    $model = (Get-CimInstance Win32_ComputerSystem).Model
    throw "This machine does not look like a VM (model '$model'). The Phase 4 harness is designed for a disposable VM; pass -AllowPhysicalHost only on a dedicated test machine."
}

# On a cloud VM the admin reaches the machine over RDP. Removing the default
# route stops RDP replies from reaching the client and locks the operator out.
$isAzure = (Test-Path -LiteralPath 'C:\WindowsAzure') -or [bool](Get-Service -Name 'WindowsAzureGuestAgent' -ErrorAction SilentlyContinue)
if ($isAzure -and $AlsoRemoveRoutesAndDns) {
    throw 'Refusing -AlsoRemoveRoutesAndDns on an Azure VM: removing the default route would drop your RDP session. Use an NSG outbound deny rule as the outer layer instead (see docs/phase-4-azure-runbook.md).'
}
if ($isAzure) {
    Write-Warning 'Azure VM detected. Keep this RDP session open, and make sure Serial Console is enabled for recovery. Azure Run Command will stop working while the block is on, because the guest agent cannot reach 168.63.129.16.'
}

$statePath = Join-Path $StateDirectory 'state.json'
if (Test-Path -LiteralPath $statePath) {
    throw "A network block is already recorded at $statePath. Run Disable-NetworkBlock.ps1 first."
}
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null

# 1. Snapshot the complete firewall policy; Disable-NetworkBlock.ps1 imports it.
$policyBackup = Join-Path $StateDirectory 'firewall-before.wfw'
& netsh.exe advfirewall export "$policyBackup" | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $policyBackup)) {
    throw "netsh advfirewall export failed; nothing was changed."
}

$state = [ordered]@{
    enabled_at = [DateTime]::UtcNow.ToString('o')
    enabled_at_local = [DateTime]::Now.ToString('o')
    policy_backup = $policyBackup
    disabled_allow_rules = @()
    removed_routes = @()
    dns_servers = @()
}
# Write state before mutating so a partial failure can still be reverted.
Write-EvidenceJson -Path $statePath -InputObject $state

try {
    # 2. Default-deny outbound on every profile, with dropped-packet logging.
    Set-NetFirewallProfile -All -Enabled True -DefaultOutboundAction Block -DefaultInboundAction Block `
        -LogBlocked True -LogAllowed False -LogMaxSizeKilobytes 32767 `
        -LogFileName '%systemroot%\system32\LogFiles\Firewall\pfirewall.log'

    # 3. Built-in outbound ALLOW rules (e.g. Core Networking DNS) still permit
    #    traffic under a default-deny profile; disable every enabled one.
    $allowRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)
    $state.disabled_allow_rules = @($allowRules | ForEach-Object Name)
    if ($allowRules.Count -gt 0) { $allowRules | Disable-NetFirewallRule }

    # 4. Explicit BLOCK rule for every non-loopback destination. Block rules
    #    take precedence over allow rules, including GPO/app-added ones.
    Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName "$ruleGroup - block non-loopback outbound" -Group $ruleGroup `
        -Direction Outbound -Action Block -Profile Any `
        -RemoteAddress @('0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255', '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff') | Out-Null
    New-NetFirewallRule -DisplayName "$ruleGroup - allow loopback outbound" -Group $ruleGroup `
        -Direction Outbound -Action Allow -Profile Any -RemoteAddress @('127.0.0.0/8', '::1') | Out-Null

    # 5. Optional second layer.
    if ($AlsoRemoveRoutesAndDns) {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue) +
            @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
        $state.removed_routes = @($routes | ForEach-Object {
            [ordered]@{ ifIndex = $_.ifIndex; prefix = $_.DestinationPrefix; nextHop = $_.NextHop; metric = $_.RouteMetric }
        })
        $routes | Remove-NetRoute -Confirm:$false

        $dns = @(Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses.Count -gt 0 })
        $state.dns_servers = @($dns | ForEach-Object {
            [ordered]@{ ifIndex = $_.InterfaceIndex; family = [int]$_.AddressFamily; servers = @($_.ServerAddresses) }
        })
        foreach ($entry in $dns) {
            Set-DnsClientServerAddress -InterfaceIndex $entry.InterfaceIndex -ServerAddresses @('127.0.0.1')
        }
    }
}
finally {
    Write-EvidenceJson -Path $statePath -InputObject $state
}

# 6. Start evidence logs clean. The firewall log is filtered by enabled_at
#    because the firewall service keeps pfirewall.log open.
& wevtutil.exe sl 'Microsoft-Windows-DNS-Client/Operational' /e:true | Out-Null
& wevtutil.exe cl 'Microsoft-Windows-DNS-Client/Operational' | Out-Null
& ipconfig.exe /flushdns | Out-Null

Write-Host "Outbound network blocked. State: $statePath"
Write-Host "Disabled $($state.disabled_allow_rules.Count) outbound allow rules; removed $($state.removed_routes.Count) default routes."
Write-Host 'Verifying...'
& (Join-Path $PSScriptRoot 'Assert-NetworkBlocked.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'The block is in place but verification found reachable public endpoints. Check for Group Policy firewall rules, then rerun Assert-NetworkBlocked.ps1.'
    exit 1
}
