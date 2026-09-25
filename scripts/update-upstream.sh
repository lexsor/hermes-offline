#!/usr/bin/env bash
# ONLINE MAINTENANCE COMMAND. Never part of the offline install.
#
# Imports a new upstream Hermes commit into upstream/hermes-agent on a new
# branch (upstream-update/<commit>), verifies the imported tree is
# byte-identical to upstream's, updates manifests/upstream.lock, and writes
# the surface diff to reports/upstream-updates/<old>..<new>.md. Changes are
# staged, not committed.
#
#   scripts/update-upstream.sh [--ref main|<tag>|<commit>] [--git <upstream clone>] [--no-branch]
#
# The upstream clone defaults to .maintenance/upstream.git (a blobless bare
# clone created on first use); OFFLINE_HERMES_UPSTREAM_GIT or --git overrides it.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/maintenance/python.sh"
echo 'ONLINE MAINTENANCE: fetches from the upstream Git repository.' >&2
ohmaint update-upstream "$@"
