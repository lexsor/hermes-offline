#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$script_dir/build-bundle.ps1")" "$@"
fi

if command -v powershell.exe >/dev/null 2>&1; then
  exec powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$script_dir/build-bundle.ps1")" "$@"
fi

echo 'Bundle assembly requires native Windows x64 PowerShell. No network fallback was attempted.' >&2
exit 2
