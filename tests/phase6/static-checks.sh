#!/usr/bin/env bash
# Phase 6 checks. Local only: no network access.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

required=(
  scripts/update-upstream.sh
  scripts/refresh-vendor-artifacts.sh
  scripts/diff-dependency-surface.sh
  scripts/maintenance/ohmaint.py
  scripts/maintenance/python.sh
  profiles/windows-x64-desktop.toml
  docs/upstream-update-workflow.md
)
for relative in "${required[@]}"; do
  [[ -f "$repo_root/$relative" ]] || { echo "Missing Phase 6 output: $relative" >&2; exit 1; }
done

bash -n "$repo_root"/scripts/update-upstream.sh "$repo_root"/scripts/refresh-vendor-artifacts.sh \
  "$repo_root"/scripts/diff-dependency-surface.sh "$repo_root"/scripts/maintenance/python.sh

# The online maintenance commands are labeled as such, and nothing in the
# offline path calls them.
for f in update-upstream.sh refresh-vendor-artifacts.sh diff-dependency-surface.sh; do
  grep -q 'MAINTENANCE' "$repo_root/scripts/$f" || { echo "scripts/$f is not labeled as a maintenance command" >&2; exit 1; }
done
offline=(bootstrap install-offline verify-deps verify-offline verify-release build-bundle uninstall-offline configure-provider)
for name in "${offline[@]}"; do
  for f in "$repo_root/scripts/$name".{ps1,sh}; do
    [[ -f "$f" ]] || continue
    if grep -nE 'ohmaint|maintenance/|update-upstream|refresh-vendor-artifacts|diff-dependency-surface' "$f"; then
      echo "Offline script ${f#$repo_root/} references a maintenance command." >&2
      exit 1
    fi
  done
done
if grep -nE 'ohmaint|maintenance/' "$repo_root/scripts/lib/OfflineHermes.psm1"; then
  echo 'The offline module references the maintenance tool.' >&2
  exit 1
fi

# The installer takes its expected artifact counts from the manifests.
if grep -nE -- '-ne (68|1027)\b' "$repo_root/scripts/install-offline.ps1"; then
  echo 'install-offline.ps1 hard-codes an artifact count; use Get-ManifestArtifactCount.' >&2
  exit 1
fi

# The profile's selection rules reproduce the committed manifests.
source "$repo_root/scripts/maintenance/python.sh"
ohmaint check

echo 'Phase 6 static checks passed.'
