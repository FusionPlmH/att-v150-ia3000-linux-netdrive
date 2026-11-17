#!/bin/sh
# Marvell 88E6190X 间接 SMI 访问库 v2
#
# 相对 v1 的关键修正：
#   1. smi_r 不再把读失败静默变成 0 —— 出错时把 proc 的 "ERR ..." 原文打到 stderr 并返回 1
#   2. sw_r / sw_w 在写 DATA 之前先等 BUSY 清零（对齐 FreeBSD e6000sw_writereg 的做法）
#   3. 所有辅助函数把失败向上传播，调用方必须判断返回值
#
# 协议来源: drivers/net/dsa/mv88e6xxx/{smi.c,smi.h}
#   SMI_CMD = 0x00, SMI_DATA = 0x01  (都挂在 sw_addr = 0x10)
#   命令字 = BUSY(0x8000) | MODE_22(0x1000) | OP | (dev << 5) | reg
#   dev: 端口 N = N ; Global1 = 0x1b(27) ; Global2 = 0x1c(28)

SW_ADDR=16
P=/proc/v150_mdio

smi_r() {  # smi_addr reg -> 打印无符号值; 失败返回 1
	echo "r $1 $2" > $P
	v=$(cat $P)
	case "$v" in
	ERR*|"") echo "SMI_READ_FAIL($1,$2): $v" >&2; return 1 ;;
	esac
	case "$v" in
	*val=0x*) : ;;
	*) echo "SMI_PARSE_FAIL($1,$2): $v" >&2; return 1 ;;
	esac
	v=${v#*val=0x}
	v=${v%% *}
	printf '%u\n' $(( 0x$v & 0xffff ))
}

smi_w() {  # smi_addr reg val; 失败返回 1
	echo "w $1 $2 $3" > $P
	v=$(cat $P)
	case "$v" in
	ERR*) echo "SMI_WRITE_FAIL($1,$2,$3): $v" >&2; return 1 ;;
	esac
	return 0
}

wait_idle() {  # 等 SMI_CMD 的 bit15(BUSY) 清零
	i=0
	while [ $i -lt 100 ]; do
		if v=$(smi_r $SW_ADDR 0 2>/dev/null); then
			[ $(( v & 0x8000 )) -eq 0 ] && return 0
		fi
		i=$((i+1))
	done
	echo "BUSY_TIMEOUT" >&2
	return 1
}

sw_r() {  # dev reg -> 打印值
	dev=$1; reg=$2
	wait_idle || return 1
	smi_w $SW_ADDR 0 $(( 0x9800 | ((dev & 0x1f) << 5) | (reg & 0x1f) )) || return 1
	wait_idle || return 1
	smi_r $SW_ADDR 1
}

sw_w() {  # dev reg val
	dev=$1; reg=$2; val=$3
	wait_idle || return 1
	smi_w $SW_ADDR 1 $(( val & 0xffff )) || return 1
	smi_w $SW_ADDR 0 $(( 0x9400 | ((dev & 0x1f) << 5) | (reg & 0x1f) )) || return 1
	wait_idle
}

# ---------------------------------------------------------------------------
# Global2 间接访问 (0x18=CMD, 0x19=DATA) —— SerDes(C45) 和内部 PHY(C22)
# ---------------------------------------------------------------------------
G2=28
G2_CMD=0x18
G2_DATA=0x19
G2_BUSY=0x8000
G2_C45_WRITE=0x0400
G2_C45_READ=0x0c00
G2_C22_MODE=0x1000
G2_C22_WRITE=0x0400
G2_C22_READ=0x0800
MMD_PHYXS=4

g2_wait() {
	i=0
	while [ $i -lt 100 ]; do
		if v=$(sw_r $G2 $G2_CMD 2>/dev/null); then
			[ $(( v & G2_BUSY )) -eq 0 ] && return 0
		fi
		i=$((i+1))
	done
	echo "G2_BUSY_TIMEOUT" >&2
	return 1
}

serdes_r() {  # port reg -> 值
	p=$1; r=$2
	g2_wait || return 1
	sw_w $G2 $G2_DATA $r || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | ((p & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | G2_C45_READ | ((p & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait || return 1
	sw_r $G2 $G2_DATA
}

serdes_w() {  # port reg val
	p=$1; r=$2; v=$3
	g2_wait || return 1
	sw_w $G2 $G2_DATA $r || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | ((p & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait || return 1
	sw_w $G2 $G2_DATA $(( v & 0xffff )) || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | G2_C45_WRITE | ((p & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait
}

phy_r() {  # port reg -> 值
	p=$1; r=$2
	g2_wait || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | G2_C22_MODE | G2_C22_READ | ((p & 0x1f) << 5) | (r & 0x1f) )) || return 1
	g2_wait || return 1
	sw_r $G2 $G2_DATA
}

phy_w() {  # port reg val
	p=$1; r=$2; v=$3
	g2_wait || return 1
	sw_w $G2 $G2_DATA $(( v & 0xffff )) || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | G2_C22_MODE | G2_C22_WRITE | ((p & 0x1f) << 5) | (r & 0x1f) )) || return 1
	g2_wait
}

# ---------------------------------------------------------------------------
# C45 访问 SFP 笼子的 SerDes —— PHY 地址是 port + 0x10（最容易踩的坑）
# ---------------------------------------------------------------------------
xs_r() {  # port reg -> 值
	p=$1; r=$2
	g2_wait || return 1
	sw_w $G2 $G2_DATA $r || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | (((p + 16) & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | G2_C45_READ | (((p + 16) & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait || return 1
	sw_r $G2 $G2_DATA
}

xs_w() {  # port reg val
	p=$1; r=$2; v=$3
	g2_wait || return 1
	sw_w $G2 $G2_DATA $r || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | (((p + 16) & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait || return 1
	sw_w $G2 $G2_DATA $(( v & 0xffff )) || return 1
	sw_w $G2 $G2_CMD $(( G2_BUSY | G2_C45_WRITE | (((p + 16) & 0x1f) << 5) | MMD_PHYXS )) || return 1
	g2_wait
}

# ---------------------------------------------------------------------------
# VTU（Global1）—— 每端口 2 bit：01=untagged, 10=tagged, 11=丢弃
# 注意 port 8/9/10 在 VTU_DATA2 里；0x1 << (2*8) 会溢出 16 位，必须分开处理。
# ---------------------------------------------------------------------------
G1=27
VTU_FID=0x02
VTU_OP=0x05
VTU_VID=0x06
VTU_DATA=0x07
VTU_DATA2=0x08

vtu_wait() {
	i=0
	while [ $i -lt 300 ]; do
		v=$(sw_r $G1 $VTU_OP) || return 1
		[ $(( v & 0x8000 )) -eq 0 ] && return 0
		i=$((i+1))
	done
	echo "VTU_BUSY_TIMEOUT" >&2
	return 1
}

V150_D1=0
V150_D2=0

vtu_reset() { V150_D1=0xffff; V150_D2=0x003f; }

vtu_member() {  # port mode
	p=$1; m=$2
	if [ "$p" -lt 8 ]; then
		s=$(( p * 2 ))
		V150_D1=$(( (V150_D1 & ~(3 << s)) | (m << s) ))
	else
		s=$(( (p - 8) * 2 ))
		V150_D2=$(( (V150_D2 & ~(3 << s)) | (m << s) ))
	fi
}

vtu_load() {  # vid fid
	vtu_wait || return 1
	sw_w $G1 $VTU_VID $(( ($1 | 0x1000) & 0x1fff )) || return 1
	sw_w $G1 $VTU_FID $(( $2 & 0x0fff )) || return 1
	sw_w $G1 $VTU_DATA  $(( V150_D1 & 0xffff )) || return 1
	sw_w $G1 $VTU_DATA2 $(( V150_D2 & 0xffff )) || return 1
	sw_w $G1 $VTU_OP $(( 0x3000 | 0x8000 )) || return 1
	vtu_wait
}