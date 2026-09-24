#!/usr/bin/env bash
set -euo pipefail

# Static checks for the Phase 4 harness. PowerShell syntax is checked by
# parsing each file with pwsh when available.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="$repo_root/tests/phase4"

if ! command -v rg >/dev/null 2>&1; then
  echo 'static-checks.sh requires ripgrep (rg) on PATH.' >&2
  exit 2
fi

required=(
  Phase4.psm1
  Enable-NetworkBlock.ps1
  Disable-NetworkBlock.ps1
  Assert-NetworkBlocked.ps1
  Collect-NetworkEvidence.ps1
  Start-MockProvider.ps1
  mock-provider.mjs
  Invoke-Phase4.ps1
  New-Phase4Vm.ps1
  desktop-checklist.md
)
for relative in "${required[@]}"; do
  if [[ ! -f "$harness/$relative" ]]; then
    echo "Missing Phase 4 harness file: tests/phase4/$relative" >&2
    exit 1
  fi
done

# Public endpoints may appear only in the negative-probe list in Phase4.psm1.
if rg -n 'https?://[a-z0-9.-]+\.(org|com|io|net|dev)' --glob '*.ps1' --glob '*.mjs' "$harness"; then
  echo 'Phase 4 scripts reference a public URL outside Phase4.psm1 (Get-PublicProbeTargets).' >&2
  exit 1
fi

# The block script must keep its safety interlocks.
rg -q 'IUnderstandThisBlocksAllOutboundTraffic' "$harness/Enable-NetworkBlock.ps1"
rg -q 'Test-IsVirtualMachine' "$harness/Enable-NetworkBlock.ps1"
rg -q 'Test-IsAdministrator' "$harness/Enable-NetworkBlock.ps1"
rg -q 'advfirewall export' "$harness/Enable-NetworkBlock.ps1"
rg -q 'advfirewall import' "$harness/Disable-NetworkBlock.ps1"
# New-NetFirewallRule rejects loopback addresses (found on the first Azure
# run), and a failed enable must roll itself back.
if rg -n "RemoteAddress[^#]*('127\.|'::1')" "$harness/Enable-NetworkBlock.ps1"; then
  echo 'Enable-NetworkBlock.ps1 passes a loopback address to a firewall rule; Windows rejects it.' >&2
  exit 1
fi
rg -q 'Disable-NetworkBlock.ps1' "$harness/Enable-NetworkBlock.ps1"

# The VM must never be staged while connected.
rg -q 'SwitchType Private' "$harness/New-Phase4Vm.ps1"
rg -q 'non-isolated switch' "$harness/New-Phase4Vm.ps1"

# A clean guest has only Windows PowerShell 5.1: forbid PowerShell 7-only
# features and non-ASCII (5.1 reads BOM-less scripts as ANSI).
if rg -n -e 'Start-ThreadJob|SkipHttpErrorCheck|ForEach-Object -Parallel|AsHashtable|SkipCertificateCheck' \
     --glob '*.ps1' --glob '*.psm1' "$harness" "$repo_root/scripts"; then
  echo 'PowerShell 7-only feature used; the offline target has Windows PowerShell 5.1.' >&2
  exit 1
fi
# Evidence completeness (first Azure run: the 1 MB DNS log wrapped and lost
# every test-window event while the collector still reported "read").
rg -q '/ms:536870912' "$harness/Enable-NetworkBlock.ps1"
rg -q -- '-Oldest -MaxEvents 1' "$harness/Collect-NetworkEvidence.ps1"
rg -q 'firewallOldest -gt \$Since' "$harness/Collect-NetworkEvidence.ps1"
# PIDs are resolved per event time, not joined across reuse.
rg -q 'Resolve-ProcessOwner' "$harness/Collect-NetworkEvidence.ps1"
rg -q "PIP_NO_CACHE_DIR" "$repo_root/scripts/lib/OfflineHermes.psm1"
rg -q "npm_config_cache = \(Join-Path \\\$CacheRoot" "$repo_root/scripts/lib/OfflineHermes.psm1"
rg -q 'install changed host state' "$harness/Invoke-Phase4.ps1"

# The firewall service holds pfirewall.log open for writing; it must be read
# with ReadWrite sharing (File.ReadLines failed on the first VM run).
if rg -n 'ReadLines\(\$FirewallLogPath' "$harness/Collect-NetworkEvidence.ps1"; then
  echo 'Collect-NetworkEvidence.ps1 reads pfirewall.log without ReadWrite sharing.' >&2
  exit 1
fi

# 5.1's ConvertFrom-Json emits a JSON array as one pipeline object; assign it
# to a variable before iterating (broke evidence collection on the first VM run).
if rg -n 'ConvertFrom-Json *\| *(ForEach-Object|Where-Object|%|\?)' --glob '*.ps1' --glob '*.psm1' "$harness" "$repo_root/scripts"; then
  echo 'ConvertFrom-Json piped into ForEach/Where-Object; Windows PowerShell 5.1 does not enumerate JSON arrays there.' >&2
  exit 1
fi
if rg -n '[^\x00-\x7F]' --glob '*.ps1' --glob '*.psm1' "$harness" "$repo_root/scripts"; then
  echo 'Non-ASCII character in a PowerShell file (Windows PowerShell 5.1 would misread it).' >&2
  exit 1
fi

# Parse with Windows PowerShell 5.1 when present (the target engine), else pwsh.
pwsh_bin="$(command -v powershell.exe || command -v pwsh || command -v pwsh.exe || true)"
if [[ -n "$pwsh_bin" ]]; then
  PHASE4_HARNESS="$(cygpath -w "$harness" 2>/dev/null || echo "$harness")" "$pwsh_bin" -NoLogo -NoProfile -Command '
    $bad = 0
    foreach ($f in Get-ChildItem -LiteralPath $env:PHASE4_HARNESS -Recurse -File | Where-Object { $_.Extension -in ".ps1", ".psm1" }) {
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
      foreach ($e in $errors) { Write-Host "$($f.Name):$($e.Extent.StartLineNumber): $($e.Message)"; $bad++ }
    }
    exit $bad'
else
  echo 'pwsh not found; skipped PowerShell parse checks.' >&2
fi

echo 'Phase 4 harness static checks passed.'
