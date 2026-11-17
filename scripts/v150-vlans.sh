#!/bin/sh
# Create or delete the host-side VLAN sub-interfaces for the 8 front-panel ports.
#
#   V150_CPU_IF0=enp5s0f0 V150_CPU_IF1=enp5s0f1 ./v150-vlans.sh create
#   ./v150-vlans.sh delete
#   ./v150-vlans.sh show
#
# VLAN id == panel number. Panels 1/3/4/5 hang off switch port 9 (CPU_IF1),
# panels 2/6/7/8 off switch port 10 (CPU_IF0).
#
# This only creates the interfaces and brings them up. It never assigns an
# address, so it cannot break an existing management path.

set -eu

CPU_IF0=${V150_CPU_IF0:-enp5s0f0}
CPU_IF1=${V150_CPU_IF1:-enp5s0f1}
VLANS=${V150_VLANS:-1 2 3 4 5 6 7 8}

CMD=${1:-show}

# panel -> parent uplink
parent_of() {
	case "$1" in
	1|3|4|5) echo "$CPU_IF1" ;;
	2|6|7|8) echo "$CPU_IF0" ;;
	*) echo "" ;;
	esac
}

do_create() {
	for v in $VLANS; do
		p=$(parent_of "$v")
		[ -n "$p" ] || { echo "skip VLAN $v: no panel with that number" >&2; continue; }
		[ -e "/sys/class/net/$p" ] || { echo "skip VLAN $v: $p missing" >&2; continue; }

		iface="$p.$v"
		if [ -e "/sys/class/net/$iface" ]; then
			echo "exists  $iface"
		else
			ip link add link "$p" name "$iface" type vlan id "$v"
			echo "created $iface"
		fi
		ip link set "$iface" up
	done
}

do_delete() {
	for v in $VLANS; do
		p=$(parent_of "$v")
		[ -n "$p" ] || continue
		iface="$p.$v"
		if [ -e "/sys/class/net/$iface" ]; then
			ip link del "$iface" 2>/dev/null && echo "deleted $iface"
		fi
	done
}

do_show() {
	printf '%-16s %-6s %-8s %-4s %s\n' IFACE PANEL PARENT VLAN STATE
	for v in 1 2 3 4 5 6 7 8; do
		p=$(parent_of "$v")
		iface="$p.$v"
		if [ -e "/sys/class/net/$iface" ]; then
			st=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)
			printf '%-16s %-6s %-8s %-4s %s\n' "$iface" "$v" "$p" "$v" "$st"
		else
			printf '%-16s %-6s %-8s %-4s %s\n' "$iface" "$v" "$p" "$v" "-"
		fi
	done
}

case "$CMD" in
	create) do_create ;;
	delete) do_delete ;;
	show)   do_show ;;
	*) echo "usage: $0 create|delete|show" >&2; exit 1 ;;
esac
