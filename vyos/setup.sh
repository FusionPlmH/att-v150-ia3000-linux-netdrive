#!/usr/bin/env bash
# att-v150-ia3000-linux-netdrive — VyOS setup
#
#   sudo ./vyos/setup.sh                  install + run now
#   sudo ./vyos/setup.sh --dry-run        print the plan only
#   sudo ./vyos/setup.sh --ko /path.ko    use a prebuilt v150_mdio.ko
#   sudo ./vyos/setup.sh --cpu-if0 eth0 --cpu-if1 eth1
#                                         skip the PCI detection and name the
#                                         two uplinks yourself (VyOS renames
#                                         them to ethN, so detection is best-effort)
#
# Why this is not the same as install.sh
# --------------------------------------
# VyOS keeps /config across image upgrades and rewrites /usr and /etc. So the
# bring-up script and the module both have to live under /config, and the boot
# hook has to re-install the module into /lib/modules/<running kernel>/extra
# on every boot.
#
# VyOS also normally ships no compiler and no kernel headers for the running
# kernel, which means v150_mdio.ko cannot be built on the box. Three options:
#
#   1. Build it on a machine with the same kernel version and pass --ko.
#   2. Install matching headers (linux-headers-<ver>-vyos) if your VyOS repo
#      carries them, then this script builds locally.
#   3. Keep a prebuilt copy at /config/scripts/v150/v150_mdio.ko — picked up
#      automatically.
#
# VLAN interfaces are NOT created here. On VyOS, interface configuration
# belongs to the config system; this script prints the commands to use.

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO=$(dirname "$HERE")

DEST=/config/scripts/v150
HOOK=/config/scripts/vyos-postconfig-bootup.script
KDIR="/lib/modules/$(uname -r)/build"
MODDIR="/lib/modules/$(uname -r)/extra"

DRY=0
PREBUILT_KO=""
V150_CPU_IF0=""
V150_CPU_IF1=""

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY=1 ;;
	--ko)      PREBUILT_KO=${2:?--ko needs a path}; shift ;;
	--cpu-if0) V150_CPU_IF0=${2:?--cpu-if0 needs a name}; shift ;;
	--cpu-if1) V150_CPU_IF1=${2:?--cpu-if1 needs a name}; shift ;;
	-h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
	*) echo "unknown option: $1  (try --help)" >&2; exit 1 ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
{ [ -d /opt/vyatta ] || [ -f /usr/bin/vyos-config-encrypt ]; } || {
	echo "this does not look like VyOS (/opt/vyatta missing)" >&2
	exit 1
}

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

# VyOS renames the X553 functions to eth0/eth1/... following config order, so the
# enp5s0fN names from a plain Debian install are useless here. Find them by PCI
# ID, exactly like install.sh does.
detect_x553() {
	local devs="" d nd
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] || continue
		[ "$(cat "$d/vendor")" = "0x8086" ] || continue
		[ "$(cat "$d/device" 2>/dev/null)" = "0x15c2" ] || continue
		for nd in "$d"/net/*; do
			[ -e "$nd" ] || continue
			devs="$devs $(basename "$nd"):$(basename "$d")"
		done
	done

	if [ -z "$devs" ]; then
		say "!! no X553 Backplane (8086:15c2) netdev found"
		say "   check: lspci -nn | grep 15c2   and   ip -br link"
		return 1
	fi

	say "X553 uplinks found:"
	for e in $devs; do say "   ${e%%:*}  (${e##*:})"; done

	local sorted
	sorted=$(for e in $devs; do
		printf '%s %s\n' "${e##*.}" "${e%%:*}"
	done | sort -n | awk '{print $2}')

	V150_CPU_IF0=$(printf '%s\n' "$sorted" | sed -n 1p)
	V150_CPU_IF1=$(printf '%s\n' "$sorted" | sed -n 2p)
	[ -n "$V150_CPU_IF1" ] || {
		say "!! only one X553 function; switch port 9 may be unwired"
		V150_CPU_IF1=$V150_CPU_IF0
	}
	say "   switch port 10 -> $V150_CPU_IF0"
	say "   switch port  9 -> $V150_CPU_IF1"
	return 0
}

# ---------------------------------------------------------------------------
step "environment"
say "kernel    : $(uname -r)"
say "destination: $DEST"

# ---------------------------------------------------------------------------
step "locating the two X553 uplinks"
# --cpu-if0 / --cpu-if1 win; otherwise detect by PCI ID.
if [ -n "$V150_CPU_IF0" ] && [ -n "$V150_CPU_IF1" ]; then
	say "using --cpu-if0 $V150_CPU_IF0  --cpu-if1 $V150_CPU_IF1"
elif [ -n "$V150_CPU_IF0" ] || [ -n "$V150_CPU_IF1" ]; then
	echo "give both --cpu-if0 and --cpu-if1, or neither" >&2
	exit 1
else
	detect_x553 || {
		echo "pass --cpu-if0/--cpu-if1 explicitly, or check lspci -nn | grep 15c2" >&2
		exit 1
	}
fi

# ---------------------------------------------------------------------------
step "locating v150_mdio.ko"

KO=""
if [ -n "$PREBUILT_KO" ]; then
	[ -f "$PREBUILT_KO" ] || { echo "--ko $PREBUILT_KO not found" >&2; exit 1; }
	KO=$PREBUILT_KO
	say "using --ko $KO"
elif [ -f "$DEST/v150_mdio.ko" ]; then
	KO="$DEST/v150_mdio.ko"
	say "using existing $KO"
elif [ -e "$KDIR/Makefile" ]; then
	say "kernel headers present, building locally"
	if [ "$DRY" -eq 0 ]; then
		make -C "$REPO" modules KDIR="$KDIR"
	fi
	KO="$REPO/kernel/v150_mdio.ko"
	say "built $KO"
else
	cat >&2 <<-'EOF'
	!! cannot build: no kernel headers for this exact kernel version.
	!!
	!! Pick one:
	!!   a) build on a machine running the same kernel, copy the .ko here and
	!!      re-run with --ko /path/to/v150_mdio.ko
	!!   b) drop it at /config/scripts/v150/v150_mdio.ko and re-run
	!!   c) install matching linux-headers-<ver>-vyos, then re-run
	!!
	!! Verify the copy: the module must have been built against exactly
	!!   $(uname -r)
	EOF
	exit 1
fi

# ---------------------------------------------------------------------------
step "installing files under /config (persistent)"

if [ "$DRY" -eq 1 ]; then
	say "   + install -d $DEST"
	say "   + install scripts/v150-switch-bringup.sh $DEST/"
	say "   + install scripts/v150_sw.sh $DEST/"
	say "   + copy $KO -> $DEST/v150_mdio.ko"
	say "   + write $HOOK"
else
	install -d "$DEST"
	install -m 0755 "$REPO/scripts/v150-switch-bringup.sh" "$DEST/"
	install -m 0644 "$REPO/scripts/v150_sw.sh" "$DEST/"
	if [ "$KO" != "$DEST/v150_mdio.ko" ]; then
		cp -f "$KO" "$DEST/v150_mdio.ko"
	fi
	say "   files in $DEST:"
	ls -1 "$DEST" | sed 's/^/     /'

	install -d "$(dirname "$HOOK")"
	cat > "$HOOK" <<-'EOF'
	#!/bin/sh
	# Installed by att-v150-ia3000-linux-netdrive.
	# Runs after every VyOS config load: re-install the module for the currently
	# running kernel (VyOS wipes /lib/modules on image upgrade) and program the
	# 88E6190X.
	D=/config/scripts/v150
	[ -x "$D/v150-switch-bringup.sh" ] || exit 0

	ver=$(uname -r)
	extra="/lib/modules/$ver/extra"
	if [ -f "$D/v150_mdio.ko" ] && [ ! -f "$extra/v150_mdio.ko" ]; then
		mkdir -p "$extra"
		cp -f "$D/v150_mdio.ko" "$extra/v150_mdio.ko"
		depmod -a "$ver" 2>/dev/null || depmod -a
	fi

	modprobe v150_mdio 2>/dev/null || exit 0
	[ -e /proc/v150_mdio ] || exit 0
	"$D/v150-switch-bringup.sh"
	EOF
	chmod 0755 "$HOOK"
	say "   wrote $HOOK"
fi

# ---------------------------------------------------------------------------
step "loading module and programming the switch"

if [ "$DRY" -eq 1 ]; then
	say "   + install -d $MODDIR"
	say "   + cp -f $DEST/v150_mdio.ko $MODDIR/"
	say "   + depmod -a && modprobe v150_mdio"
	say "   + $DEST/v150-switch-bringup.sh"
else
	install -d "$MODDIR"
	cp -f "$DEST/v150_mdio.ko" "$MODDIR/v150_mdio.ko"
	depmod -a
	modprobe -r v150_mdio 2>/dev/null || true
	modprobe v150_mdio || {
		echo "modprobe failed — is the .ko built for $(uname -r)?" >&2
		exit 1
	}
	[ -e /proc/v150_mdio ] || { echo "/proc/v150_mdio did not appear" >&2; exit 1; }

	# tell the bring-up which netdevs are the uplinks
	{
		echo "V150_CPU_IF0=$V150_CPU_IF0"
		echo "V150_CPU_IF1=$V150_CPU_IF1"
	} > "$DEST/env"
	# shellcheck disable=SC1091
	. "$DEST/env"
	export V150_CPU_IF0 V150_CPU_IF1

	"$DEST/v150-switch-bringup.sh"
fi

# ---------------------------------------------------------------------------
step "kernel-name to VyOS-interface mapping"

if [ "$DRY" -eq 0 ]; then
	for i in $V150_CPU_IF0 $V150_CPU_IF1; do
		[ -e "/sys/class/net/$i" ] || continue
		printf '  %-14s %s  carrier=%s\n' "$i" \
			"$(readlink -f /sys/class/net/$i/device 2>/dev/null | xargs basename 2>/dev/null)" \
			"$(cat /sys/class/net/$i/carrier 2>/dev/null || echo ?)"
	done
	say "  VyOS names these eth0/eth1/... by config order — check with: show interfaces"
fi

# ---------------------------------------------------------------------------
cat <<EOF

Done. The boot hook re-runs everything on every boot
($HOOK), because VyOS rewrites /lib/modules on image upgrade.

Switch ports 9 and 10 are the two uplinks. Front-panel ports are vifs:

  configure
  set interfaces ethernet <uplink> vif 1 address dhcp     # panel 1 (SFP)
  set interfaces ethernet <uplink> vif 2 address dhcp     # panel 2 (SFP)
  set interfaces ethernet <uplink> vif 3 address dhcp     # panel 3
  ...
  set interfaces ethernet <uplink> vif 8 address dhcp     # panel 8
  commit
  save

Panels 1/3/4/5 are on ${V150_CPU_IF1} (switch port 9).
Panels 2/6/7/8 are on ${V150_CPU_IF0} (switch port 10).

Never address the uplink interface itself — it carries tagged traffic only.

Re-run after a VyOS image upgrade:
  sudo ./vyos/setup.sh            (or copy a matching .ko and use --ko)
EOF
