#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checksum_file="$repo_root/manifests/checksums.sha256"

if [[ ! -f "$checksum_file" ]]; then
  echo "Missing checksum manifest: $checksum_file" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$repo_root" && sha256sum --check manifests/checksums.sha256)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$repo_root" && shasum --algorithm 256 --check manifests/checksums.sha256)
else
  echo 'No SHA-256 verifier found. Install sha256sum/shasum or run scripts/verify-deps.ps1 on Windows.' >&2
  exit 1
fi

expected_count="$(awk 'NF { count++ } END { print count + 0 }' "$checksum_file")"
actual_count="$(find "$repo_root/vendor" -type f | wc -l | tr -d '[:space:]')"
if [[ "$expected_count" != "$actual_count" ]]; then
  echo "Vendor coverage mismatch: checksum entries=$expected_count vendor files=$actual_count" >&2
  exit 1
fi

echo "Dependency verification passed: $expected_count vendored files verified."
