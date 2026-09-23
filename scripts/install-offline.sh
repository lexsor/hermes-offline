#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$script_dir/install-offline.ps1")" "$@"
fi

if command -v powershell.exe >/dev/null 2>&1; then
  exec powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$script_dir/install-offline.ps1")" "$@"
fi

cat >&2 <<'EOF'
The approved profile is native Windows x64 and cannot be installed by this POSIX shell.
Run the native entry point from Windows PowerShell:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-offline.ps1

No network fallback was attempted.
EOF
exit 2
