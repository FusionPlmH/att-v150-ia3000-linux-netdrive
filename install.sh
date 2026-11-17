#!/usr/bin/env bash
# att-v150-ia3000-linux-netdrive installer
#
# Lights up all 8 front-panel ports of a Silicom IA3000 / AT&T ATT-V150 uCPE
# (Marvell 88E6190X + 2x Intel X553 Backplane) on Proxmox VE, Debian or VyOS.
#
#   sudo ./install.sh                  install, enable at boot, run now
#   sudo ./install.sh --no-vlans       same, but do not create host VLAN interfaces
#   sudo ./install.sh --dry-run        print what would be done
#   sudo ./install.sh --dkms           build and install through DKMS
#   sudo ./install.sh --uninstall      remove everything (keeps /etc/default file)
#   sudo ./install.sh -h               full option list
#
# Nothing here assigns IP addresses. It builds and installs the MDIO bridge
# module, programs the switch, and creates (but does not address) one 802.1Q
# sub-interface per front-panel port.

set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

BINDIR=/usr/local/sbin
SCRIPT="$BINDIR/v150-switch-bringup.sh"
STATUS="$BINDIR/v150-status.sh"
VLANS="$BINDIR/v150-vlans.sh"
LIBDIR=/usr/local/lib/v150
UNIT=/etc/systemd/system/v150-switch.service
ENVFILE=/etc/default/v150-switch
MODCONF=/etc/modprobe.d/v150_mdio.conf
LOADCONF=/etc/modules-load.d/v150_mdio.conf
DOCDIR=/usr/share/doc/v150-netdrive

KDIR="/lib/modules/$(uname -r)/build"
MODDIR="/lib/modules/$(uname -r)/extra"

DRY=0
DO_VLANS=1
USE_DKMS=0
ACTION=install
CPU_IF0=""
CPU_IF1=""
VLAN_LIST="1 2 3 4 5 6 7 8"

# Front panel -> VLAN -> CPU port. 4 + 4 split across the two uplinks.
PANEL_VLANS="1:1:0 2:2:1 3:3:0 4:4:0 5:5:0 6:6:1 7:7:1 8:8:1"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
	if [ "$DRY" -eq 1 ]; then
		printf '   + %s\n' "$*"
	else
		printf '   + %s\n' "$*"
		"$@"
	fi
}

usage() {
	cat <<'EOF'
att-v150-ia3000-linux-netdrive installer

  --cpu-if0 NAME     netdev for switch port 10 (default: auto-detect)
  --cpu-if1 NAME     netdev for switch port  9 (default: auto-detect)
  --vlans "1 3 6"    VLAN ids to create on the host (default: 1..8)
  --no-vlans         do not touch host networking at all
  --dkms             build and install through DKMS instead of directly
  --ko PATH          use a prebuilt v150_mdio.ko (useful where no headers exist)
  --dry-run          print the plan, change nothing
  --uninstall        remove module, service and installed files
  -h, --help         this text

Detected automatically: distribution, kernel headers, the two X553 uplink
netdevs and which of them is switch port 9 vs 10.

After installing, these are on PATH:
  v150-switch-bringup.sh   re-program the switch (systemd runs this at boot)
  v150-status.sh           read-only health report
  v150-vlans.sh create|delete|show   host-side VLAN sub-interfaces

VyOS users: use vyos/setup.sh instead. VyOS rewrites /usr and /etc on upgrade,
so the unit, the module and the VLAN config all have to live under /config.
EOF
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./install.sh)"
}

# ---------------------------------------------------------------------------
# detection
# ---------------------------------------------------------------------------

detect_distro() {
	if command -v pveversion >/dev/null 2>&1; then
		DISTRO=pve
	elif [ -d /opt/vyatta ] || [ -f /usr/bin/vyos-config-encrypt ]; then
		DISTRO=vyos
	elif [ -f /etc/debian_version ]; then
		DISTRO=debian
	else
		DISTRO=unknown
	fi
	say "distribution : $DISTRO"
}

kernel_tree_ok() {
	[ -e "$KDIR/Makefile" ] || [ -e "$KDIR/include/linux/kbuild.h" ] || [ -e "$KDIR/.config" ]
}

ensure_headers() {
	if kernel_tree_ok; then
		say "kernel tree  : $KDIR  (ok)"
		return 0
	fi

	warn "no kernel build tree at $KDIR"
	case "$DISTRO" in
		pve)
			say "   trying: apt-get install pve-headers-$(uname -r)"
			run apt-get install -y "pve-headers-$(uname -r)" || \
				run apt-get install -y "proxmox-headers-$(uname -r)" || true
			;;
		debian)
			say "   trying: apt-get install linux-headers-$(uname -r)"
			run apt-get install -y "linux-headers-$(uname -r)" || true
			;;
		vyos)
			say "   VyOS usually ships no kernel headers for the running kernel."
			say "   Either build the module on another machine and pass --ko PATH,"
			say "   or install matching headers manually."
			;;
		*)
			say "   install the kernel headers for $(uname -r) and re-run"
			;;
	esac

	kernel_tree_ok || {
		if [ -n "${PREBUILT_KO:-}" ] && [ -f "${PREBUILT_KO}" ]; then
			warn "continuing with prebuilt $PREBUILT_KO"
			return 0
		fi
		die "kernel headers for $(uname -r) are required (or pass --ko PATH)"
	}
	say "kernel tree  : $KDIR  (ok)"
}

# Find the two X553 Backplane functions and work out which is switch port 9/10.
# Both boards in this family wire PCI function 0 to switch port 10 and
# function 1 to switch port 9, but never assume: report what was found.
detect_x553() {
	local devs="" d nd fn
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
		warn "no X553 Backplane (8086:15c2) netdev found"
		return 1
	fi

	say "X553 uplinks :"
	for e in $devs; do
		say "   ${e%%:*}  (${e##*:})"
	done

	# order by PCI function number: lowest -> switch port 10, next -> port 9
	local sorted
	sorted=$(for e in $devs; do
		nd=${e%%:*}; bdf=${e##*:}
		fn=${bdf##*.}
		printf '%s %s\n' "$fn" "$nd"
	done | sort -n | awk '{print $2}')

	[ -n "$CPU_IF0" ] || CPU_IF0=$(printf '%s\n' "$sorted" | sed -n 1p)
	[ -n "$CPU_IF1" ] || CPU_IF1=$(printf '%s\n' "$sorted" | sed -n 2p)

	[ -n "$CPU_IF1" ] || warn "only one X553 function found; switch port 9 may be unwired"
	return 0
}

# ---------------------------------------------------------------------------
# build / install
# ---------------------------------------------------------------------------

build_module() {
	step "building modules"
	if [ "$USE_DKMS" -eq 1 ]; then
		command -v dkms >/dev/null 2>&1 || die "dkms is not installed"
		run dkms remove -m v150-netdrive -v 1.0.0 --all || true
		run cp -a "$HERE" "/usr/src/v150-netdrive-1.0.0"
		run dkms add -m v150-netdrive -v 1.0.0
		run dkms build -m v150-netdrive -v 1.0.0
		run dkms install -m v150-netdrive -v 1.0.0 --force
		return 0
	fi

	if [ -n "${PREBUILT_KO:-}" ] && [ -f "${PREBUILT_KO}" ]; then
		say "   using prebuilt module $PREBUILT_KO"
		return 0
	fi

	run make -C "$HERE" modules KDIR="$KDIR"
}

install_module_file() {
	[ "$USE_DKMS" -eq 1 ] && return 0

	local src
	if [ -n "${PREBUILT_KO:-}" ] && [ -f "${PREBUILT_KO}" ]; then
		src=$PREBUILT_KO
	else
		src="$HERE/kernel/v150_mdio.ko"
	fi
	if [ "$DRY" -eq 0 ] && [ ! -f "$src" ]; then
		die "module not found at $src (did the build fail?)"
	fi

	step "installing module"
	run install -d "$MODDIR"
	# cp -f rather than install -m: install has produced 0-byte modules here
	if [ "$DRY" -eq 1 ]; then
		say "   + cp -f $src $MODDIR/v150_mdio.ko"
	else
		cp -f "$src" "$MODDIR/v150_mdio.ko"
		say "   + cp -f $src $MODDIR/v150_mdio.ko"
	fi
	run depmod -a
}

write_config() {
	step "writing configuration"

	if [ "$DRY" -eq 1 ]; then
		say "   + $MODCONF  (options v150_mdio netdev=$CPU_IF0)"
		say "   + $LOADCONF (v150_mdio)"
		say "   + $ENVFILE   (V150_CPU_IF0=$CPU_IF0 V150_CPU_IF1=$CPU_IF1)"
	else
		install -d "$(dirname "$MODCONF")" "$(dirname "$ENVFILE")" "$(dirname "$LOADCONF")"
		cat > "$MODCONF" <<-EOF
		# V150 88E6190X board support.
		# v150_mdio borrows the MDIO bus that ixgbe registers for the X553
		# uplink, then programming of the switch happens over /proc/v150_mdio.
		# netdev must be one of the two X553 uplink netdevs (they share a bus).
		options v150_mdio netdev=$CPU_IF0
		EOF
		cat > "$LOADCONF" <<-EOF
		# Load the V150 MDIO bridge at boot.
		v150_mdio
		EOF
		cat > "$ENVFILE" <<-EOF
		# Configuration for v150-switch.service.
		# Detected by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
		# switch port 10 -> PCI function 0, switch port 9 -> PCI function 1
		V150_CPU_IF0=$CPU_IF0
		V150_CPU_IF1=$CPU_IF1
		EOF
		say "   + $MODCONF"
		say "   + $LOADCONF"
		say "   + $ENVFILE"
	fi
}

load_module() {
	step "loading module"
	if [ "$DRY" -eq 1 ]; then
		say "   + modprobe -r v150_mdio || true"
		say "   + modprobe v150_mdio"
		say "   + verify /proc/v150_mdio and chip id (indirect read of port 0 reg 3)"
		return 0
	fi
	run modprobe -r v150_mdio 2>/dev/null || true
	run modprobe v150_mdio
	[ -e /proc/v150_mdio ] || die "/proc/v150_mdio did not appear"

	# The chip id is **not** a direct MDIO read: the 88E6190X answers through the
	# indirect CMD/DATA protocol, so borrow sw_r() which does the BUSY dance.
	if [ -f "$HERE/scripts/v150_sw.sh" ]; then
		# shellcheck disable=SC1090
		. "$HERE/scripts/v150_sw.sh"
		if id=$(sw_r 0 0x03 2>/dev/null); then
			printf '   chip id: 0x%04x\n' "$id"
			if [ $(( id & 0xfff0 )) -eq 2560 ]; then
				say "   chip   : 88E6190X rev $(( id & 0xf )) ok"
			else
				warn "unexpected chip id 0x$(printf %04x "$id")"
			fi
		else
			warn "could not read the chip id over the indirect SMI protocol"
		fi
	else
		say "   (scripts/v150_sw.sh missing, skipping chip id check)"
	fi
}

install_bringup() {
	step "installing bring-up script, library and unit"
	run install -d "$BINDIR"
	run install -m 0755 "$HERE/scripts/v150-switch-bringup.sh" "$SCRIPT"
	run install -m 0755 "$HERE/scripts/v150-status.sh" "$STATUS"
	run install -m 0755 "$HERE/scripts/v150-vlans.sh" "$VLANS"
	run install -m 0644 "$HERE/scripts/v150_sw.sh" "$LIBDIR/v150_sw.sh"
	run install -m 0644 "$HERE/systemd/v150-switch.service" "$UNIT"
	run install -d "$DOCDIR"
	run install -m 0644 "$HERE/README.md" "$HERE/README.en.md" "$DOCDIR/"
	run install -d "$DOCDIR/docs"
	run install -m 0644 "$HERE/docs/REGISTER-REFERENCE.md" "$DOCDIR/docs/" || true
	run install -m 0644 "$HERE/docs/REGISTER-REFERENCE.en.md" "$DOCDIR/docs/" || true
	run install -m 0644 "$HERE/docs/TECHNICAL-NOTES.md" "$DOCDIR/docs/" || true
	run install -m 0644 "$HERE/docs/TECHNICAL-NOTES.en.md" "$DOCDIR/docs/" || true
	command -v systemctl >/dev/null 2>&1 && run systemctl daemon-reload
}

enable_service() {
	step "enabling v150-switch.service"
	command -v systemctl >/dev/null 2>&1 || { warn "no systemd; run $SCRIPT by hand"; return 0; }
	run systemctl enable v150-switch.service
	run systemctl restart v150-switch.service
	if [ "$DRY" -eq 0 ]; then
		sleep 2
		say ""
		systemctl status v150-switch.service --no-pager --lines=0 || true
	fi
}
setup_vlans() {
	[ "$DO_VLANS" -eq 1 ] || { step "skipping host VLAN interfaces (--no-vlans)"; return 0; }
	step "creating host VLAN interfaces"
	if [ -x "$HERE/scripts/v150-vlans.sh" ]; then
		V150_CPU_IF0="$CPU_IF0" V150_CPU_IF1="$CPU_IF1" V150_VLANS="$VLAN_LIST" \
			run "$HERE/scripts/v150-vlans.sh" create
	else
		warn "scripts/v150-vlans.sh missing; skipped"
	fi
}

show_status() {
	if [ -x "$HERE/scripts/v150-status.sh" ] && [ "$DRY" -eq 0 ]; then
		V150_CPU_IF0="$CPU_IF0" V150_CPU_IF1="$CPU_IF1" "$HERE/scripts/v150-status.sh" || true
	fi
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
	step "removing service"
	if command -v systemctl >/dev/null 2>&1; then
		run systemctl disable --now v150-switch.service || true
	fi
	run rm -f "$UNIT"
	command -v systemctl >/dev/null 2>&1 && run systemctl daemon-reload

	step "removing host VLAN interfaces"
	if [ -x "$HERE/scripts/v150-vlans.sh" ]; then
		run "$HERE/scripts/v150-vlans.sh" delete || true
	fi

	step "removing module"
	run modprobe -r v150_mdio 2>/dev/null || true
	run rm -f "$MODDIR/v150_mdio.ko"
	run depmod -a
	if [ "$USE_DKMS" -eq 1 ] && command -v dkms >/dev/null 2>&1; then
		run dkms remove -m v150-netdrive -v 1.0.0 --all || true
	fi

	step "removing files"
	run rm -f "$SCRIPT" "$STATUS" "$VLANS" "$MODCONF" "$LOADCONF"
	run rm -rf "$DOCDIR" "$LIBDIR"

	say ""
	say "Done. Kept: $ENVFILE (delete it by hand if you want a clean machine)."
	say "Note: the switch keeps its configuration until power is cycled."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
		--cpu-if0) CPU_IF0=${2:?--cpu-if0 needs a value}; shift 2 ;;
		--cpu-if1) CPU_IF1=${2:?--cpu-if1 needs a value}; shift 2 ;;
		--vlans)   VLAN_LIST=${2:?--vlans needs a value}; shift 2 ;;
		--no-vlans) DO_VLANS=0; shift ;;
		--dkms)    USE_DKMS=1; shift ;;
		--ko)      PREBUILT_KO=${2:?--ko needs a path}; shift 2 ;;
		--dry-run) DRY=1; shift ;;
		--uninstall) ACTION=uninstall; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1  (try --help)" ;;
	esac
done

require_root

say "att-v150-ia3000-linux-netdrive installer"
say "kernel       : $(uname -r)  $(uname -m)"
detect_distro

if [ "$ACTION" = uninstall ]; then
	[ -n "$CPU_IF0" ] || CPU_IF0=$(sed -n 's/^V150_CPU_IF0=//p' "$ENVFILE" 2>/dev/null || true)
	do_uninstall
	exit 0
fi

ensure_headers
detect_x553 || die "cannot locate the X553 uplinks; pass --cpu-if0/--cpu-if1 explicitly"

say "switch port 10 -> ${CPU_IF0:-(unset)}"
say "switch port  9 -> ${CPU_IF1:-(unset)}"

build_module
install_module_file
write_config
load_module
install_bringup
enable_service
setup_vlans
show_status

cat <<EOF

All done.

Front-panel ports are isolated on VLAN 1..8 and reachable as:

  panel 1 (SFP) -> $CPU_IF1.1      panel 5 -> $CPU_IF1.5
  panel 2 (SFP) -> $CPU_IF0.2      panel 6 -> $CPU_IF0.6
  panel 3       -> $CPU_IF1.3      panel 7 -> $CPU_IF0.7
  panel 4       -> $CPU_IF1.4      panel 8 -> $CPU_IF0.8

Give them addresses, bridge them, or pass them into VMs:

  ip addr add 192.168.50.1/24 dev $CPU_IF0.8

Status:            v150-status.sh
Re-create VLANs:   v150-vlans.sh create
Re-program switch: systemctl restart v150-switch
Remove everything: sudo ./install.sh --uninstall
EOF
