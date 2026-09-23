#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/verify-deps.sh"

cat <<'EOF'
The vendored dependency closure is intact.
Runtime verification for the windows-x64-desktop profile must run from native Windows PowerShell:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-offline.ps1

Public-network blocking and the live desktop smoke test remain Phase 4 gates.
EOF
