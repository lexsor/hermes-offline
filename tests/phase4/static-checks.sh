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

pwsh_bin="$(command -v pwsh || command -v pwsh.exe || true)"
if [[ -n "$pwsh_bin" ]]; then
  PHASE4_HARNESS="$(cygpath -w "$harness" 2>/dev/null || echo "$harness")" "$pwsh_bin" -NoLogo -NoProfile -Command '
    $bad = 0
    foreach ($f in Get-ChildItem -LiteralPath $env:PHASE4_HARNESS -Include *.ps1,*.psm1 -Recurse) {
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
      foreach ($e in $errors) { Write-Host "$($f.Name):$($e.Extent.StartLineNumber): $($e.Message)"; $bad++ }
    }
    exit $bad'
else
  echo 'pwsh not found; skipped PowerShell parse checks.' >&2
fi

echo 'Phase 4 harness static checks passed.'
