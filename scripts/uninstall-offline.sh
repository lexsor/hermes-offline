#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$script_dir/uninstall-offline.ps1")" "$@"
fi

if command -v powershell.exe >/dev/null 2>&1; then
  exec powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$script_dir/uninstall-offline.ps1")" "$@"
fi

cat >&2 <<'EOF'
The windows-x64-desktop profile is uninstalled from Windows PowerShell:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-offline.ps1
EOF
exit 2
