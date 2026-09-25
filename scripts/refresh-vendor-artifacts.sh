#!/usr/bin/env bash
# ONLINE MAINTENANCE COMMAND (except --dry-run). Never part of the offline install.
#
# Recomputes the Python and npm closures for upstream/hermes-agent with the
# rules in profiles/windows-x64-desktop.toml, downloads new wheels and
# tarballs, verifies each against the hash in uv.lock / package-lock.json
# before writing it, removes artifacts that left the closure, and rewrites
# python.lock, node.lock, licenses.lock, checksums.sha256 and the vendor
# README counts. Unchanged records are kept byte for byte.
#
#   scripts/refresh-vendor-artifacts.sh --dry-run          # plan only, no network
#   scripts/refresh-vendor-artifacts.sh [--report <file>]
#
# It stops without writing anything if a pinned runtime (Electron, get-windows,
# Lightning CSS, electron-builder toolsets) needs a manual update, a package
# gains an unreviewed install script, or a hash changed for an unchanged
# version. Pinned binaries in binaries/browser/source.lock are never
# downloaded automatically.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/maintenance/python.sh"
if [[ " $* " != *" --dry-run "* ]]; then
  echo 'ONLINE MAINTENANCE: downloads from PyPI and the npm registry.' >&2
fi
ohmaint refresh "$@"
