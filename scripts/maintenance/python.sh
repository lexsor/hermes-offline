#!/usr/bin/env bash
# Sourced by the maintenance wrappers: runs scripts/maintenance/ohmaint.py
# with the first Python 3.11+ found. (On Windows, `python3` can be the Store
# alias, which exists but does not run.)
ohmaint() {
  local here candidate
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in "${OFFLINE_HERMES_PYTHON:-}" python3 python "py -3"; do
    [[ -n "$candidate" ]] || continue
    if $candidate -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
      PYTHONUTF8=1 $candidate "$here/ohmaint.py" "$@"
      return $?
    fi
  done
  echo 'Maintenance commands need Python 3.11 or newer (set OFFLINE_HERMES_PYTHON to choose one).' >&2
  return 2
}
