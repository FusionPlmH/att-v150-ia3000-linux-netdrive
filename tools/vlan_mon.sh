#!/bin/sh
# 统计 8 个前面板 VLAN 接口在 N 秒内的收包增量，自动标出活跃的那个。
#
#   ./vlan_mon.sh 8          观察 8 秒
#
# 配合对端打 UDP 广播使用（不要用 ping，Windows 侧 ARP 一失败就完全不发包）。
# 这是确认"线到底插在哪个面板"最快的办法。

SECS=${1:-8}

# 网口名优先级：环境变量 > install.sh 写的 /etc/default/v150-switch > 内置默认
_e0=${V150_CPU_IF0:-}
_e1=${V150_CPU_IF1:-}
# shellcheck source=/dev/null
[ -r /etc/default/v150-switch ] && . /etc/default/v150-switch
[ -n "$_e0" ] && V150_CPU_IF0=$_e0
[ -n "$_e1" ] && V150_CPU_IF1=$_e1

CPU_IF0=${V150_CPU_IF0:-enp5s0f0}
CPU_IF1=${V150_CPU_IF1:-enp5s0f1}

# 面板 1/3/4/5 在 switch port 9（CPU_IF1），2/6/7/8 在 switch port 10（CPU_IF0）
iface_of() {
	case "$1" in
	1 | 3 | 4 | 5) echo "$CPU_IF1.$1" ;;
	*) echo "$CPU_IF0.$1" ;;
	esac
}

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT

for v in 1 2 3 4 5 6 7 8; do
	i=$(iface_of "$v")
	[ -e "/sys/class/net/$i" ] || continue
	p=$(cat "/sys/class/net/$i/statistics/rx_packets" 2>/dev/null || echo 0)
	b=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
	echo "$i $p $b" >> "$TMP"
done

[ -s "$TMP" ] || { echo "没有 VLAN 接口，先跑 v150-vlans.sh create" >&2; exit 1; }

sleep "$SECS"

printf '  %-16s %-5s %8s %10s  %s\n' IFACE PANEL RX_PKTS RX_BYTES STATE
while read -r i a o; do
	n=$(cat "/sys/class/net/$i/statistics/rx_packets" 2>/dev/null || echo 0)
	b=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
	panel=${i##*.}
	mark=''
	[ $((n - a)) -gt 0 ] && mark="  <== active (panel $panel)"
	printf '  %-16s %-5s %8d %10d%s\n' "$i" "$panel" $((n - a)) $((b - o)) "$mark"
done < "$TMP"