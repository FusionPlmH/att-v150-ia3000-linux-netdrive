#!/bin/sh
# Silicom IA3000 / AT&T ATT-V150 —— Marvell 88E6190X bring-up
#
# 一口一 VLAN。全部寄存器访问走 v150_sw.sh，这里只有本板特有的时序。
#
# 拓扑（面板号 -> switch port）:
#   面板 1,2 = SFP        -> switch port 3,4   （默认下电，必须 xs_w 上电）
#   面板 3..8 = 电口       -> switch port 2,1,6,5,8,7
#   switch port 9  = CPU -> PCI 05:00.1 -> enp5s0f1
#   switch port 10 = CPU -> PCI 05:00.0 -> enp5s0f0
#   switch port 0  = XMII/RGMII -> BMC，未使用
#
# 可配置项（环境变量，或 /etc/default/v150-switch）:
#   V150_CPU_IF0  switch port 10 对应的网口（默认 enp5s0f0）
#   V150_CPU_IF1  switch port 9  对应的网口（默认 enp5s0f1）
#   V150_LIB      寄存器库路径（默认自动查找）
#
# 关键结论（全部实测，勿凭猜）:
#   * 写 SMI_DATA 之前必须先等 CMD.BUSY 清零，否则写命令被静默丢弃。
#   * PORT_CTL2 的 802.1Q 模式在 bit11:10 (0x0c00)；bit13:12 是 JUMBO。
#     CPU 口的 JUMBO 位必须清零，否则 CPU<->CPU 单向不通。
#   * 出口的 tag 行为由 VTU 成员类型决定，不是 PORT_CTL0 的 EGRESS_MODE。
#   * CMODE 只读。SFP 口靠 SerDes 上电自己变成 0x9。
#   * 前面板铜口 PHY 冷启动 PDOWN=1 (BMCR=0x1940)，必须清掉。

# 网口名优先级：环境变量 > install.sh 写的 /etc/default/v150-switch > 内置默认
_e0=${V150_CPU_IF0:-}
_e1=${V150_CPU_IF1:-}
# shellcheck source=/dev/null
[ -r /etc/default/v150-switch ] && . /etc/default/v150-switch
[ -n "$_e0" ] && V150_CPU_IF0=$_e0
[ -n "$_e1" ] && V150_CPU_IF1=$_e1

CPU_IF0=${V150_CPU_IF0:-enp5s0f0}
CPU_IF1=${V150_CPU_IF1:-enp5s0f1}

log() { echo "v150-switch: $*"; }
die() { log "ERROR: $*"; exit 1; }

# --- 定位寄存器库 ---------------------------------------------------------
for c in "${V150_LIB:-}" /usr/local/lib/v150/v150_sw.sh "$(dirname "$0")/v150_sw.sh"; do
	[ -n "$c" ] && [ -f "$c" ] && { . "$c"; V150_HAVE_LIB=1; break; }
done
[ -n "${V150_HAVE_LIB:-}" ] || die "v150_sw.sh not found (set V150_LIB)"

P=/proc/v150_mdio

# =====================================================================
# 0. 确保模块已加载
if [ ! -e "$P" ]; then
	modprobe v150_mdio 2>/dev/null
	i=0
	while [ $i -lt 60 ]; do
		[ -e "$P" ] && break
		sleep 1
		i=$((i+1))
	done
fi
[ -e "$P" ] || die "$P missing (is v150_mdio loaded?)"

id=$(sw_r 0 0x03) || die "SMI access failed"
[ $(( id & 0xfff0 )) -eq 2560 ] || die "unexpected switch id 0x$(printf %04x "$id")"
log "88E6190X rev $(( id & 0xf )) detected"

# --- 1. 前面板铜口 PHY 上电（1,2,5,6,7,8）---------------------------------
for p in 1 2 5 6 7 8; do
	b=$(phy_r $p 0x00) || { log "port$p PHY read failed"; continue; }
	case "$b" in 0|65535) log "port$p PHY not responding"; continue ;; esac
	want=$(( (b | 0x1000 | 0x0200 | 0x0100) & ~0x0800 ))
	phy_w $p 0x16 0x0000     # 页寄存器 -> 页 0
	phy_w $p 0x09 0x0200     # 通告 1000BASE-T 全双工
	phy_w $p 0x00 "$want"    # 清 PDOWN，使能并重启自协商
done
log 'copper PHYs powered up'

# --- 1b. SFP SerDes 上电（switch port 3,4）--------------------------------
# C45 MMD4 的 0x2000 写 0x9140；PHY 地址 = port + 0x10（由 xs_w 处理）。
# 不做这一步端口永远停在 CMODE=0xf / LINK=0，看起来像硬件坏了。
for p in 3 4; do
	before=$(xs_r $p 0x2000) || before=0
	xs_w $p 0x2000 0x9140
	after=$(xs_r $p 0x2000) || after=0
	log "SFP serdes port$p powered up (MMD4/0x2000 0x$(printf %04x "$before") -> 0x$(printf %04x "$after"))"
done

# --- 2. 所有端口 forwarding + 802.1Q Secure -------------------------------
for p in 1 2 3 4 5 6 7 8 9 10; do
	c0=$(sw_r $p 0x04) || continue
	sw_w $p 0x04 $(( (c0 & ~0x0003) | 0x0003 ))
	c2=$(sw_r $p 0x08) || continue
	sw_w $p 0x08 $(( (c2 & ~0x0c00) | 0x0c00 ))
done
# CPU 口额外清掉 JUMBO(0x3000)：留着会让 CPU<->CPU 完全不通
for p in 9 10; do
	c2=$(sw_r $p 0x08)
	sw_w $p 0x08 $(( (c2 & ~0x3000) | 0x0c00 ))
done
log '802.1Q Secure enabled on ports 1-10'

# port 0 是接 BMC 的 XMII，未使用，关掉
c0=$(sw_r 0 0x04) && sw_w 0 0x04 $(( c0 & ~0x0003 )) && log 'port0 (XMII) disabled'

# --- 3. CPU 口 9/10: 1000BASE-X + 自协商 --------------------------------
for p in 9 10; do
	sts=$(sw_r $p 0x00) || { log "port$p read failed"; continue; }
	sw_w $p 0x00 $(( (sts & ~0x000f) | 0x0009 )) || continue
	sleep 0.05
	c0=$(sw_r $p 0x04)
	sw_w $p 0x04 $(( (c0 & ~0x0003) | 0x0003 ))
	sw_w $p 0x01 0x203e          # 强制 1G 全双工
	serdes_w $p 0x1004 0x00e0    # 先写通告
	b=$(serdes_r $p 0x1000) || b=0
	serdes_w $p 0x1000 $(( (b & ~(0x8000 | 0x4000 | 0x0800)) | 0x1000 | 0x0200 ))
done
log 'CPU ports 9/10 configured (1000BASE-X, AN on)'

# --- 4. PVID: 面板号 = VLAN id -------------------------------------------
for p in 1 2 3 4 5 6 7 8 9 10; do
	case $p in
	1) vid=4 ;; 2) vid=3 ;; 3) vid=1 ;; 4) vid=2 ;;
	5) vid=6 ;; 6) vid=5 ;; 7) vid=8 ;; 8) vid=7 ;;
	9 | 10) vid=100 ;;
	esac
	sw_w $p 0x07 "$vid"
done
log 'PVID set (front port VLAN = panel number)'

# --- 5. VTU 表项 ---------------------------------------------------------
# VLAN 100: 仅两个 CPU 口 untagged（主机侧普通 L2 通路）
vtu_reset; vtu_member 9 1; vtu_member 10 1
vtu_load 100 100 || log 'WARN: VLAN 100 load failed'

# VLAN 1..8: 前面板口 untagged，对应 CPU 口 tagged
for t in 1:3:9 2:4:10 3:2:9 4:1:9 5:6:9 6:5:10 7:8:10 8:7:10; do
	vid=${t%%:*}; r=${t#*:}
	f=${r%%:*};   c=${r#*:}
	vtu_reset; vtu_member "$f" 1; vtu_member "$c" 2
	vtu_load "$vid" "$vid" || log "WARN: VLAN $vid load failed"
	log "VLAN $vid: switch port $f (untagged) -> CPU port $c (tagged)"
done

# --- 6. 拉起 CPU 网口 ----------------------------------------------------
for i in "$CPU_IF0" "$CPU_IF1"; do
	[ -e "/sys/class/net/$i" ] && ip link set "$i" up 2>/dev/null
done

sleep 2
for p in 9 10; do
	s=$(sw_r $p 0x00) || continue
	[ $(( (s >> 11) & 1 )) -eq 1 ] && st=up || st=DOWN
	log "CPU port $p: $st"
done
log 'done'
