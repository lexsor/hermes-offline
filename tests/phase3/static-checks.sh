#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# The negative checks below are `if rg ...`; without rg they would pass vacuously.
if ! command -v rg >/dev/null 2>&1; then
  echo 'static-checks.sh requires ripgrep (rg) on PATH.' >&2
  exit 2
fi

# Positive checks: fail loudly, naming the missing pattern (a bare `rg -q`
# under `set -e` exits silently).
require() {
  if [[ "$1" == "--" ]]; then shift; fi
  if ! rg -q -- "$1" "$2"; then
    echo "Static check failed: pattern '$1' not found in ${2#$repo_root/}" >&2
    exit 1
  fi
}

required=(
  scripts/bootstrap.sh
  scripts/install-offline.sh
  scripts/verify-deps.sh
  scripts/verify-offline.sh
  scripts/build-bundle.sh
  scripts/bootstrap.ps1
  scripts/install-offline.ps1
  scripts/verify-deps.ps1
  scripts/verify-offline.ps1
  scripts/build-bundle.ps1
  scripts/lib/OfflineHermes.psm1
  config/env.example
  config/hermes.example.yaml
  config/honcho.example.yaml
  config/mcps.example.yaml
  docs/offline-install.md
)

for relative in "${required[@]}"; do
  if [[ ! -f "$repo_root/$relative" ]]; then
    echo "Missing Phase 3 output: $relative" >&2
    exit 1
  fi
done

bash -n "$repo_root"/scripts/*.sh

if rg -n --glob '*.sh' --glob '*.ps1' \
  '(^|[[:space:]])(curl|wget)([[:space:]]|$)|https?://(registry\.npmjs\.org|pypi\.org|files\.pythonhosted\.org|github\.com)' \
  "$repo_root/scripts"; then
  echo 'Offline scripts contain a direct public-network command or endpoint.' >&2
  exit 1
fi

require -- '--no-index' "$repo_root/scripts/install-offline.ps1"
require -- '--offline' "$repo_root/scripts/install-offline.ps1"
require -- '--ignore-scripts' "$repo_root/scripts/install-offline.ps1"
require -- '--legacy-peer-deps' "$repo_root/scripts/install-offline.ps1"
require 'HERMES_DISABLE_LAZY_INSTALLS' "$repo_root/scripts/install-offline.ps1"

# Regression guards for defects found in the first native Windows run.
# Electron must be materialized where Node resolves it, never at a hard-coded
# hoisted path (that let upstream's builder fall back to @electron/get).
if rg -n -e 'Join-Path \$SourceRoot .node_modules\x5c(electron|get-windows|esbuild)' "$repo_root/scripts/install-offline.ps1"; then
  echo 'install-offline.ps1 hard-codes a hoisted node_modules path; use Resolve-NodePackageDirectory.' >&2
  exit 1
fi
require 'Resolve-NodePackageDirectory' "$repo_root/scripts/install-offline.ps1"
require 'Get-OfflineNetworkGuard' "$repo_root/scripts/install-offline.ps1"
require 'ELECTRON_MIRROR' "$repo_root/scripts/lib/OfflineHermes.psm1"
require 'electron_config_cache' "$repo_root/scripts/lib/OfflineHermes.psm1"
require 'ELECTRON_BUILDER_CACHE' "$repo_root/scripts/lib/OfflineHermes.psm1"
# The offline install must own its HERMES_HOME and disable passive update checks.
require 'HERMES_HOME' "$repo_root/scripts/install-offline.ps1"
require 'check: false' "$repo_root/scripts/install-offline.ps1"
require 'check: false' "$repo_root/config/hermes.example.yaml"

echo 'Phase 3 static checks passed.'
