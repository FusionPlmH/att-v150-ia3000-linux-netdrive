#!/bin/sh
# Health report: module, switch state, uplink link, host VLAN interfaces.
#
#   ./v150-status.sh
#
# Read-only. Safe to run at any time; it does not write any register.

set -u

P=/proc/v150_mdio

# 网口名优先级：环境变量 > install.sh 写的 /etc/default/v150-switch > 内置默认
_e0=${V150_CPU_IF0:-}
_e1=${V150_CPU_IF1:-}
# shellcheck source=/dev/null
[ -r /etc/default/v150-switch ] && . /etc/default/v150-switch
[ -n "$_e0" ] && V150_CPU_IF0=$_e0
[ -n "$_e1" ] && V150_CPU_IF1=$_e1

CPU_IF0=${V150_CPU_IF0:-enp5s0f0}
CPU_IF1=${V150_CPU_IF1:-enp5s0f1}
SMI=16

hr() { printf '\n----- %s -----\n' "$*"; }

# The 88E6190X has no directly-addressable registers: everything goes through
# the indirect CMD/DATA pair at SMI 0x10, so borrow the shell library.
LIB=""
for c in "$(dirname "$0")/v150_sw.sh" \
         /usr/local/lib/v150/v150_sw.sh \
         "$(dirname "$0")/../tools/v150_sw.sh"; do
	[ -f "$c" ] && { LIB=$c; break; }
done
if [ -n "$LIB" ]; then
	# shellcheck disable=SC1090
	. "$LIB"
else
	echo "warning: v150_sw.sh not found, register detail unavailable" >&2
fi

# --- module ---------------------------------------------------------------
hr "module"
if [ -e "$P" ]; then
	echo "  /proc/v150_mdio       present"
	printf '  netdev parameter      '
	cat /sys/module/v150_mdio/parameters/netdev 2>/dev/null || echo "(unknown)"
	printf '  switch id             '
	if [ -n "$LIB" ] && id=$(sw_r 0 0x03 2>/dev/null); then
		printf '0x%04x  ' "$id"
		if [ $(( id & 0xfff0 )) -eq 2560 ]; then
			echo "88E6190X rev $(( id & 0xf )) ok"
		else
			echo "unexpected"
		fi
	else
		echo "read failed"
	fi
else
	echo "  /proc/v150_mdio       MISSING (modprobe v150_mdio)"
fi

# --- uplinks --------------------------------------------------------------
hr "uplinks"
for i in "$CPU_IF0" "$CPU_IF1"; do
	if [ -e "/sys/class/net/$i" ]; then
		role="switch port 10"
		[ "$i" = "$CPU_IF1" ] && role="switch port 9"
		printf '  %-12s %-16s carrier=%s speed=%s\n' "$i" "$role" \
			"$(cat /sys/class/net/$i/carrier 2>/dev/null || echo ?)" \
			"$(cat /sys/class/net/$i/speed 2>/dev/null || echo ?)"
	else
		printf '  %-12s missing\n' "$i"
	fi
done

# --- switch ports ---------------------------------------------------------
if [ -e "$P" ] && [ -n "$LIB" ]; then
	hr "switch ports"
	printf '  %-6s %-4s %-6s %-6s %s\n' PORT LNK SPEED CMODE PVID
	for p in 1 2 3 4 5 6 7 8 9 10; do
		if ! st=$(sw_r "$p" 0x00 2>/dev/null); then
			printf '  %-6s read failed\n' "$p"
			continue
		fi
		sp=$(( (st >> 8) & 3 ))
		link=$(( (st >> 11) & 1 ))
		if [ "$link" -eq 1 ]; then
			case "$sp" in 0) s=10M ;; 1) s=100M ;; 2) s=1G ;; 3) s=2.5G ;; esac
		else
			s='-'
		fi
		printf '  %-6s %-4s %-6s 0x%-4x %s\n' "$p" "$link" "$s" "$(( st & 0xf ))" \
			"$(sw_r "$p" 0x07 2>/dev/null)"
	done
fi

# --- host vlan interfaces -------------------------------------------------
hr "host VLAN interfaces"
found=0
for v in 1 2 3 4 5 6 7 8; do
	case "$v" in 1|3|4|5) p=$CPU_IF1 ;; *) p=$CPU_IF0 ;; esac
	iface="$p.$v"
	if [ -e "/sys/class/net/$iface" ]; then
		found=1
		printf '  %-16s panel %-2s %-10s %s\n' "$iface" "$v" \
			"$(cat /sys/class/net/$iface/operstate 2>/dev/null)" \
			"$(ip -br addr show "$iface" 2>/dev/null | awk '{print $3}')"
	fi
done
[ "$found" -eq 1 ] || echo "  none (run scripts/v150-vlans.sh create)"

# --- service --------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
	hr "service"
	printf '  v150-switch.service   %s / %s\n' \
		"$(systemctl is-active v150-switch 2>/dev/null || echo -)" \
		"$(systemctl is-enabled v150-switch 2>/dev/null || echo -)"
fi

echo
