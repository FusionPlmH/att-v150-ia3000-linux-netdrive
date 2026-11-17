#!/usr/bin/env bash
# Remove everything install.sh put on the system.
#
#   sudo ./uninstall.sh
#
# Equivalent to: sudo ./install.sh --uninstall

set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
exec "$HERE/install.sh" --uninstall "$@"
