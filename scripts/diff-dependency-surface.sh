#!/usr/bin/env bash
# MAINTENANCE COMMAND. Reads two commits from the upstream clone; a blobless
# clone fetches the file contents it needs (online). Never part of the
# offline install.
#
# Reports what changed between two upstream commits that matters to the
# offline profile: the Python and npm closures and the vendor refresh plan,
# pinned runtimes, new install scripts, other dependency manifests, new
# network access paths in added code, installer/bootstrap changes, whether
# the offline patches still apply, and license changes.
#
#   scripts/diff-dependency-surface.sh --new <commit|ref> [--old <commit>] [--out <file>] [--git <upstream clone>]
#
# --old defaults to the commit in manifests/upstream.lock.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/maintenance/python.sh"
ohmaint surface "$@"
