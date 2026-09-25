#!/usr/bin/env bash
# Verifies an extracted release archive against its release-files.sha256, for
# example on a POSIX transfer host before the files go to the offline machine.
set -euo pipefail

release_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
list="$release_root/release-files.sha256"

if [[ ! -f "$list" || ! -f "$release_root/RELEASE-MANIFEST.json" ]]; then
  echo "Not an extracted release archive: $release_root has no release-files.sha256 / RELEASE-MANIFEST.json." >&2
  echo 'A Git clone has no release file list; verify it with scripts/verify-deps.sh.' >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$release_root" && sha256sum --check --quiet release-files.sha256)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$release_root" && shasum --algorithm 256 --check --quiet release-files.sha256)
else
  echo 'No SHA-256 verifier found. Install sha256sum/shasum or run scripts/verify-release.ps1 on Windows.' >&2
  exit 1
fi

listed="$(awk 'NF { count++ } END { print count + 0 }' "$list")"
present="$(cd "$release_root" && find . -type f ! -path ./release-files.sha256 | wc -l | tr -d '[:space:]')"
if [[ "$listed" != "$present" ]]; then
  echo "Release coverage mismatch: release-files.sha256 lists $listed files, the tree has $present." >&2
  exit 1
fi

echo "Release verification passed: $listed files verified."
