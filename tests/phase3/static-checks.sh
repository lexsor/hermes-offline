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
# The desktop backend's catalog downloads must be off in every seeded/example home.
for f in scripts/install-offline.ps1 config/hermes.example.yaml tests/phase4/Start-MockProvider.ps1; do
  require '^model_catalog:' "$repo_root/$f"
  require '127\.0\.0\.1:9/offline-hermes-models-dev-disabled' "$repo_root/$f"
done
require 'model_catalog.enabled is not false' "$repo_root/scripts/verify-offline.ps1"

# Upstream patches: every entry in manifests/patches.lock exists with the
# recorded hash, and the installer applies them to the staged source.
require 'Install-UpstreamPatches' "$repo_root/scripts/install-offline.ps1"
lock="$repo_root/manifests/patches.lock"
[[ -f "$lock" ]] || { echo 'Missing manifests/patches.lock' >&2; exit 1; }
declared="$(sed -n 's/^patch_count = \([0-9]*\)$/\1/p' "$lock")"
listed=0
while IFS= read -r path; do
  IFS= read -r sum
  listed=$((listed + 1))
  file="$repo_root/$path"
  [[ -f "$file" ]] || { echo "Patch listed in patches.lock is missing: $path" >&2; exit 1; }
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [[ "$actual" == "$sum" ]] || { echo "Patch hash mismatch: $path (lock $sum, file $actual)" >&2; exit 1; }
done < <(sed -n 's/^path = "\(.*\)"$/\1/p; s/^sha256 = "\(.*\)"$/\1/p' "$lock")
[[ "$listed" == "$declared" ]] || { echo "patches.lock declares $declared patches but lists $listed" >&2; exit 1; }
for patch in "$repo_root"/patches/*.patch; do
  [[ -e "$patch" ]] || continue
  rel="${patch#$repo_root/}"
  grep -q "path = \"$rel\"" "$lock" || { echo "Unlisted patch file: $rel" >&2; exit 1; }
done

echo 'Phase 3 static checks passed.'
