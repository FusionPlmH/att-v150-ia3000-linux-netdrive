# 寄存器参考 — Marvell 88E6190X

[English](REGISTER-REFERENCE.en.md) | **简体中文**

除非特别注明，以下内容全部在真机上验证过（芯片 ID `0x0a01`，rev 1）。
位域名沿用 Linux `mv88e6xxx` 驱动 —— 对这个系列它是权威定义。

> `PORT_CTL2` 的位定义在老 Marvell 芯片（6095/6097）和 6190X 上**不一样**。
> FreeBSD 的 `e6000swreg.h` 里带的是**老芯片**的 802.1Q 模式偏移。
> 在 6190X 上照着它写，会静默地写到错误的字段。
> 下面这些值适用于 **6190X / 6390X**。

---

## 1. 间接 SMI 协议

交换芯片挂在 MDIO 总线的 SMI 地址 `0x10` 上。

```
SMI_CMD   = 0x00
SMI_DATA  = 0x01

cmd = BUSY(0x8000) | MODE_22(0x1000) | OP | (dev << 5) | reg

OP_22_READ  = 0x0800
OP_22_WRITE = 0x0400

dev 编码:
    端口 N     -> N
    Global 1   -> 0x1b
    Global 2   -> 0x1c
```

**关键时序**

```
读: 等 BUSY==0 ; CMD = 读命令 ; 等 BUSY==0 ; DATA = 结果
写: 等 BUSY==0 ; DATA = 值  ; CMD = 写命令 ; 等 BUSY==0
```

数据寄存器必须在**发命令之前**、且**在 BUSY 清零之后**装载。
省掉写之前的 BUSY 轮询，写命令会被丢弃，而且没有任何错误提示。

读失败必须报错，不能当成 `0` —— 一个天真的 `${v#*val=0x}` 遇到错误行时
字符串原样保留，`$((0x$v))` 会静默算出 0。

---

## 2. 每端口寄存器

6190X 的基址偏移是 `0x00`（老芯片是 `0x10`）。

| 偏移 | 名称 | 备注 |
|---|---|---|
| `0x00` | `PORT_STS` | bit11 LINK，bit10 DUPLEX，bit9:8 SPEED，**bit3:0 CMODE（只读）** |
| `0x01` | `PORT_MAC` / `PSC_CONTROL` | CPU 口用 `0x203e` |
| `0x02` | 流控 | |
| `0x03` | `PORT_SWITCH_ID` | 读回 `0x0a01` |
| `0x04` | `PORT_CTL0` | bit1:0 状态，bit13:12 EGRESS_MODE |
| `0x05` | `PORT_CTL1` | trunk / FID 高位 |
| `0x06` | `PORT_BASE_VLAN` | 端口图（`VLANMAP`） |
| `0x07` | `PORT_DEFAULT_VLAN` | PVID + 优先级，掩码 `0x0fff` |
| `0x08` | `PORT_CTL2` | 见下 |
| `0x09` | 出口限速 1 | 读回 `0x0001` |
| `0x0a` | 出口限速 2 | 读回 `0x8000` |
| `0x0b` | `PORT_ASSOC_VECTOR` | 只读回自己那一位 |

### `PORT_STS` (0x00)

```
0x100f  无链路，CMODE = 0xf（内部 PHY）
0x1009  无链路，CMODE = 0x9（1000BASE-X）
0xde09  链路 up，1G，全双工，CMODE = 0x9    <- SFP SerDes 上电后
0x1e09  链路 up，1G，全双工，CMODE = 0x9    <- CPU 口
0x0e07  链路 up，CMODE = 0x7（RGMII，BMC 口）
```

CMODE 取值：

| 值 | 模式 |
|---|---|
| `0x7` | RGMII |
| `0x8` | 100BASE-X |
| `0x9` | 1000BASE-X |
| `0xa` | SGMII |
| `0xb` | 2500BASE-X |
| `0xf` | 内部 PHY |

### `PORT_MAC` (0x01)

`0x203e` = 速度 1000 + 强制双工 + 全双工 + 强制链路 + 链路 up + 强制速度
（IPG 13），即强制 1G 全双工。用在 CPU 口上。

2500 的变体（`0x313f`）在这块板子上从来没有建起过链路。

### `PORT_CTL0` (0x04)

```c
#define MV88E6XXX_PORT_CTL0_EGRESS_MODE_MASK   0x3000
#define MV88E6XXX_PORT_CTL0_EGRESS_MODE_UNMODIFIED     0x0000
#define MV88E6XXX_PORT_CTL0_EGRESS_MODE_UNTAGGED       0x1000
#define MV88E6XXX_PORT_CTL0_EGRESS_MODE_TAGGED         0x2000
#define MV88E6XXX_PORT_CTL0_EGRESS_MODE_ETHER_TYPE_DSA 0x3000
#define MV88E6XXX_PORT_CTL0_FRAME_MODE_MASK    0x0300
#define MV88E6XXX_PORT_CTL0_DSA_TAG            0x0100
#define MV88E6XXX_PORT_CTL0_VLAN_TUNNEL        0x0080
#define MV88E6XXX_PORT_CTL0_TAG_IF_BOTH        0x0040
#define MV88E6XXX_PORT_CTL0_STATE_MASK         0x0003
#define MV88E6XXX_PORT_CTL0_STATE_DISABLED     0x0000
#define MV88E6XXX_PORT_CTL0_STATE_BLOCKING     0x0001
#define MV88E6XXX_PORT_CTL0_STATE_LEARNING     0x0002
#define MV88E6XXX_PORT_CTL0_STATE_FORWARDING   0x0003
```

端口 1–8 的出厂值是 `0x100f`（EGRESS_MODE = UNTAGGED、forwarding，
低 4 位 `0x000c`）。bring-up 脚本只把它规整成 Forwarding。

把 `EGRESS_MODE` 设成 `TAGGED` 实测**没有任何可观察变化** ——
出口是否打 tag 由 VTU 成员类型决定。

### `PORT_CTL2` (0x08) —— 最容易坑人的那个

```c
#define MV88E6XXX_PORT_CTL2_IGNORE_FCS          0x8000
#define MV88E6XXX_PORT_CTL2_VTU_PRI_OVERRIDE    0x4000
#define MV88E6XXX_PORT_CTL2_SA_PRIO_OVERRIDE    0x2000
#define MV88E6XXX_PORT_CTL2_DA_PRIO_OVERRIDE    0x1000

#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_MASK     0x3000   /* bit 13:12 */
#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_1522     0x0000
#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_2048     0x1000
#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_10240    0x2000

#define MV88E6XXX_PORT_CTL2_8021Q_MODE_MASK     0x0c00   /* bit 11:10 ***** */
#define MV88E6XXX_PORT_CTL2_8021Q_MODE_DISABLED 0x0000
#define MV88E6XXX_PORT_CTL2_8021Q_MODE_FALLBACK 0x0400
#define MV88E6XXX_PORT_CTL2_8021Q_MODE_CHECK    0x0800
#define MV88E6XXX_PORT_CTL2_8021Q_MODE_SECURE   0x0c00

#define MV88E6XXX_PORT_CTL2_DISCARD_TAGGED      0x0200   /* bit 9 */
#define MV88E6XXX_PORT_CTL2_DISCARD_UNTAGGED    0x0100   /* bit 8 */
#define MV88E6XXX_PORT_CTL2_MAP_DA              0x0080   /* bit 7 */
#define MV88E6XXX_PORT_CTL2_DEFAULT_FORWARD     0x0040
#define MV88E6XXX_PORT_CTL2_EGRESS_MONITOR      0x0020
#define MV88E6XXX_PORT_CTL2_INGRESS_MONITOR     0x0010
```

出厂默认值是 **`0x2c80`** = Secure（`0x0c00`）+ JUMBO_10240（`0x2000`）+ MAP_DA（`0x0080`）。
也就是说芯片上电时**本来就是 Secure 模式** —— 这个细节在排查
"为什么我把 802.1Q 关掉之后 VLAN 反而像是通了" 时非常关键。

真机上做过逐位验证（每次只写一位）：

| 写入值 | untagged 入站 | tagged VID 200 入站 | 结论 |
|---|---|---|---|
| `0x0000` / `0x1000` / `0x2000` / `0x3000` / `0x4000` / `0x8000` / `0xc000` | 通 | **通** | bit15:12 对 VLAN 准入**毫无影响** |
| `0x0100` | **丢弃** | 通 | bit 8 = DiscardUntagged 确认 |
| `0x0200` | 通 | **丢弃** | bit 9 = DiscardTagged 确认 |
| 其它任意单一位 | 通 | 通 | 无影响 |

**后果**

- 写 `0x3000` 或 `0x2000` 想"设置 802.1Q 模式"，实际写的是**巨帧**字段。
- CPU 口的巨帧字段最终必须**清零**。`0x0c00`（JUMBO 2048）或 `0x2000`（JUMBO 10240）
  会让 CPU↔CPU 的数据完全死掉，而且是**单向**的。
- Secure 用 `0x0c00`，`0x3000` 别碰。

### `PORT_ASSOC_VECTOR` (0x0b)

只读回自己端口那一位（端口 9 是 `0x0200`，端口 10 是 `0x0400`，
端口 3 是 `0x0008`，端口 4 是 `0x0010`）。用来确认你正在操作的是哪个端口索引。

---

## 3. VTU（VLAN 表）

寄存器在 **Global 1**（基址 `0x1b`）。

| 偏移 | 名称 |
|---|---|
| `0x01` | `VTU_FID` 伴随 / 优先级 |
| `0x02` | `VTU_FID`（12 位） |
| `0x05` | `VTU_OP` |
| `0x06` | `VTU_VID` |
| `0x07` | `VTU_DATA`（端口 0–7） |
| `0x08` | `VTU_DATA2`（端口 8、9、10） |

`VTU_OP` 位：

```
BUSY     0x8000
LOAD     (3 << 12) = 0x3000
FLUSH    (1 << 12) = 0x1000
GET_NEXT (4 << 12) = 0x4000
```

`VTU_VID` 的 bit 12 = `VTU_VID_VALID`。

### 成员编码 —— 每端口 2 bit

| 值 | 含义 |
|---|---|
| `01` | untagged 成员（出口剥掉 tag） |
| `10` | tagged 成员（出口插入 tag） |
| `11` | 丢弃 |
| `00` | 非成员 |

### 位布局

- 端口 0–7 → `VTU_DATA`，端口 *n* 在 bit `2n+1 : 2n`
- 端口 8 → `VTU_DATA2` bit 1:0
- 端口 9 → `VTU_DATA2` bit 3:2
- 端口 10 → `VTU_DATA2` bit 5:4

**溢出陷阱：** `1 << (2*8)` = `1 << 16` 在 16 位 shell 算术里溢出，
会静默破坏 `VTU_DATA`。端口 8 必须走 `VTU_DATA2`。
用一个按 `port >= 8` 分支的辅助函数就能彻底避开
（见 bring-up 脚本里的 `vtu_member()`）。

### 装载序列

```sh
等 VTU_OP.BUSY == 0
VTU_VID  = vid | 0x1000        # VALID
VTU_FID  = fid
VTU_DATA = data1
VTU_DATA2= data2
VTU_OP   = 0x3000 | 0x8000     # LOAD | BUSY
等 VTU_OP.BUSY == 0
```

### 回读整张表

```sh
VTU_VID = start            # 例如 0
VTU_OP  = 0x8000 | 0x4000  # BUSY | GET_NEXT
等 busy
vid = VTU_VID & 0xfff
```

`GET_NEXT` 返回的是你装载的 VID **之后**那一条。
读到 `0x1ff8` 或 `0x0fff` 表示表尾。如果返回的 VID 和你请求的一样，
说明已经遍历完了（或者没有前进）。

### 本项目实际写入并回读确认的表

```
VID 1:   FID 1  D1=0xff7f D2=0x003b     （端口 3 untagged，端口 9 tagged）
VID 2:   FID 2  D1=0xfdff D2=0x002f     （端口 4 untagged，端口 10 tagged）
VID 3:   FID 3  D1=0xffdf D2=0x003b
VID 4:   FID 4  D1=0xfff7 D2=0x003b
VID 5:   FID 5  D1=0xdfff D2=0x003b
VID 6:   FID 6  D1=0xf7ff D2=0x002f
VID 7:   FID 7  D1=0xffff D2=0x002b     （端口 8 在 D2 里）
VID 8:   FID 8  D1=0x7fff D2=0x002f
VID 100: FID 100 D1=0xffff D2=0x0017    （端口 9 + 10 untagged）
```

`FID = VID` 让每个 VLAN 有独立的转发表。`FID = 0`（共用一张 FDB）
也试过，投递的可靠性明显更差。

---

## 4. Global 2 —— 间接 Clause-45 / Clause-22 访问

**Global 2**（基址 `0x1c`）的寄存器：

| 偏移 | 名称 |
|---|---|
| `0x18` | `G2_CMD` |
| `0x19` | `G2_DATA` |

`G2_CMD` 里的模式位：

```
MODE_22 = 0x1000
MODE_45 = 0x0000     <- 很容易写反
```

### Clause-45 读

```sh
等 busy
G2_DATA = regaddr
G2_CMD  = 0x8000 | (phy << 5) | mmd
等 busy
G2_CMD  = 0x8000 | 0x0c00 | (phy << 5) | mmd
等 busy
结果 = G2_DATA
```

### Clause-45 写

```sh
等 busy
G2_DATA = regaddr
G2_CMD  = 0x8000 | (phy << 5) | mmd
等 busy
G2_DATA = value
G2_CMD  = 0x8000 | 0x0400 | (phy << 5) | mmd
等 busy
```

### Clause-22（前面板铜口 PHY）

```sh
读: G2_CMD = 0x8000 | 0x1000 | 0x0800 | (phy << 5) | reg
写: G2_DATA = value ; G2_CMD = 0x8000 | 0x1000 | 0x0400 | (phy << 5) | reg
```

---

## 5. CPU 口 SerDes（MMD 4）

CPU 口（9、10）的寄存器，寻址时 `phy = port`：

| 寄存器 | 名称 | 实测 |
|---|---|---|
| `0x1000` | `PCS_CTL1` | 读回 `0x2140`，实际是**只读**（固定 1000BASE-X、全双工、AN 关闭） |
| `0x1001` | `PCS_BMSR` | 状态 |
| `0x1004` | `PCS_AN_ADV` | 通告，写 `0x00e0` |
| `0x1005` | `PCS_LPA` | 对端能力 |
| `0x2000` | `SGMII_CTL` | |

因为 `PCS_CTL1` 改不了，**这两个口做不了 MAC 环回自测，也无法使能自协商**。
但端口照样能建起 1G 链路，可用的序列是：

```sh
PORT_STS  CMODE := 0x9              # 1000BASE-X
PORT_CTL0 状态  := Forwarding
PVID            := 100
PORT_MAC        := 0x203e
serdes_w port 0x1004 0x00e0         # 先写通告
serdes_w port 0x1000 <读改写，清 bit 15/14/11，置 12/9>
```

2500BASE-X（`CMODE = 0xb`，`PORT_MAC = 0x313f`）从来建不起链路。

---

## 6. SFP 笼子的 SerDes（MMD 4，PHY 地址 = port + 0x10）

switch port 3 和 4 上的 SFP 笼子有自己独立的 Clause-45 PHY，
地址是 **`phy = port + 0x10`**，复位后处于**下电**状态。

| 寄存器 | 含义 | 冷态值 |
|---|---|---|
| `0x2000` | SGMII / SerDes 控制 | **`0x1940`** → PDOWN 置位 |
| `0x1000` | `PCS_CTL1` | `0x0000` |
| `0x1001` | `PCS_BMSR` | `0x0000` |

上电：往 `0x2000` 写 **`0x9140`**。回读是 `0x1140`（bit 15 不保持），这是正常的。

```
上电前: sw3 STS=0x100f  LINK=0  CMODE=0xf
上电后: sw3 STS=0xde09  LINK=1  CMODE=0x9
```

### 区分内部 PHY 口和 SerDes 口

| 端口类别 | C22 读（`phy = port`） | C45 MMD4 @ `phy = port + 0x10` |
|---|---|---|
| 内部 PHY（1,2,5,6,7,8，也包括 3,4） | 有应答，`BMCR=0x1140`，`BMSR=0x7949` | 端口 3/4：`0x1940` |
| 真 SerDes（9,10） | `0xffff`（无 PHY） | `0x0000` |

端口 3、4 对 C22 的应答和铜口一模一样 —— 这正是它们看起来"就是另一个内部 PHY 口"
的原因，直到你知道那个 `+0x10` 的 C45 PHY 为止。

---

## 7. 前面板铜口 PHY（端口 1、2、5、6、7、8）

Clause-22，`phy 地址 = 端口号`。

| 寄存器 | 冷态值 | 上电后 |
|---|---|---|
| `0x00` BMCR | `0x1940`（PDOWN = 1） | `0x1340` / `0x1140` |
| `0x01` BMSR | `0x7949` | `0x7949`（有链路时 `0x796d`） |

上电序列：

```sh
phy_w port 0x16 0x0000     # 页寄存器 = reg 22 -> 页 0
phy_w port 0x09 0x0200     # 通告 1000BASE-T 全双工
phy_w port 0x00 0x1340     # 清 PDOWN，使能并重启自协商
```

> **不要**套用 DiagOS 的 `page 0xF8` 序列
> （`page 0xf8, reg 0x08 = 0x0036; page 0, reg 0x14 = 0x8020`）。
> 那是 6190 **非 X** 的编程配方，在 6190X 上会把 Clause-22 访问彻底弄坏 ——
> 之后每次读都返回命令回显（`(port<<5)|reg`）。只有冷断电才能恢复。

---

## 8. 绝对不能改的值

| 位置 | 值 | 原因 |
|---|---|---|
| switch port 0 | 保持 disabled | 到 BMC 的 XMII/RGMII。改错可能切断唯一的管理通路 |
| CPU 口 `PORT_CTL2` bit13:12 | 必须 `00` | 巨帧模式会让 CPU↔CPU 转发死掉，而且是单向的 |
| CPU 口 `PORT_MAC` | `0x203e` | 强制 1G 全双工，这才是链路能起来的真正原因 |

---

## 9. 快速自检读数

```
sw_r 0  0x03   -> 0x0a01      芯片在位，88E6190X rev 1
sw_r 9  0x00   -> 0x1e09      CPU 口 up，1G，1000BASE-X
sw_r 10 0x00   -> 0x0e09      CPU 口 up，1G，1000BASE-X
sw_r 3  0x00   -> 0xde09      SFP 1 up，1G，1000BASE-X
sw_r 7  0x08   -> 0x2c00      Secure，巨帧清零，MAP_DA 清零
sw_r 9  0x08   -> 0x0c00      Secure，巨帧已被脚本清掉
```
