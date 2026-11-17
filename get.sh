#!/usr/bin/env bash
# One-liner installer.
#
#   curl -fsSL https://raw.githubusercontent.com/FusionPlmH/att-v150-ia3000-linux-netdrive/main/get.sh | sudo bash
#
# Extra arguments are passed straight through to install.sh:
#
#   curl ... | sudo bash -s -- --no-vlans --dry-run
#
# Set V150_REF to install a branch or tag other than main.

set -euo pipefail

REPO="FusionPlmH/att-v150-ia3000-linux-netdrive"
REF="${V150_REF:-main}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "tar is required"  >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "fetching $REPO@$REF"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" |
	tar xz -C "$TMP" --strip-components=1

[ -x "$TMP/install.sh" ] || chmod +x "$TMP/install.sh"

exec "$TMP/install.sh" "$@"
