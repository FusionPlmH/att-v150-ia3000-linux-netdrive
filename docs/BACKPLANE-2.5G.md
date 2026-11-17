# 2.5G Backplane 调查结论

> 调查日期：2026-11-18　设备：Silicom IA3000 / AT&T ATT-V150
> 状态：**技术结论已确定 —— 卡点定位在 Marvell SerDes 物理层，当前条件下无法启用 2.5G。**

---

## 一句话结论

**这块板子的 CPU 上行跑在 1G。Intel 侧的 NVM 其实已经配成 2.5G-only，卡点在 Marvell 的 SerDes 物理层。**

Intel X553（`MAC:6 = x550em_a`，`PHY:4 = x550em_kr`）的 `NW_MNG_IF_SEL.PHY_SPEED_2_5G` 已经置位
—— 所以驱动只报 `2500baseT/Full`，连一个 1G 选项都不给（见证据链 ①）。
88E6190X 也支持 2500BASE-X，原厂手册 Table 13 写得很清楚（见证据链 ⑤）。

但 **switch 侧的 `PORT_STS` bit[9:8] 是只读的 SerDes 实际速率**。
`CMODE` 虽然可写、能被读回，SerDes 的物理速率却不跟着变
—— 结果就是 Intel 侧直接 link down（见实验 D）。

> 注意：设计目标是 **2×2.5G = 5G 上行**（port 9 与 port 10 各 2.5G），
> 这对 4+4 分摊的 8 个 1G 面板口是有实际意义的（收敛比从 4:1 降到 1.6:1）。
> 不是"2.5G 没意义"，是"当前做不到"。

---

## 证据链

### ① Intel 侧：支持 2.5G，但协商到 1G

```
$ ethtool enp5s0f0
	Supported ports: [ FIBRE ]
	Supported link modes:   2500baseT/Full
	Speed: 1000Mb/s
	Duplex: Full
	Auto-negotiation: on
```

注意 `Supported link modes` **只有 `2500baseT/Full` 一行，没有 `1000baseT/Full`**。
这不是 ethtool 显示问题，而是驱动代码的直接结果。

dmesg 里的 PHY 类型是关键：

```
ixgbe 0000:05:00.0: MAC: 6, PHY: 4, PBA No: 000500-000
```

对照 mainline `ixgbe_type.h` 的枚举（**注意顺序，PHY 4 不是 ext_1g_t**）：

```c
enum ixgbe_mac_type {           enum ixgbe_phy_type {
    ixgbe_mac_unknown = 0,          ixgbe_phy_unknown = 0,
    ixgbe_mac_82598EB,      // 1    ixgbe_phy_none,          // 1
    ixgbe_mac_82599EB,      // 2    ixgbe_phy_tn,            // 2
    ixgbe_mac_X540,         // 3    ixgbe_phy_aq,            // 3
    ixgbe_mac_X550,         // 4    ixgbe_phy_x550em_kr,     // 4  ← 我们
    ixgbe_mac_X550EM_x,     // 5    ixgbe_phy_x550em_kx4,    // 5
    ixgbe_mac_x550em_a,     // 6 ← 我们   ixgbe_phy_x550em_xfi,    // 6
    ...                             ixgbe_phy_x550em_ext_t,  // 7
};                                  ixgbe_phy_ext_1g_t,      // 8
                                    ...
```

`MAC: 6` = X553，`PHY: 4` = **KR 背板 PHY**（不是铜线 PHY）。

而 2.5G 的开关就在 `ixgbe_get_link_capabilities_x550em()` 里：

```c
case ixgbe_phy_x550em_kr:
    if (hw->mac.type == ixgbe_mac_x550em_a) {
        if (hw->phy.nw_mng_if_sel & IXGBE_NW_MNG_IF_SEL_PHY_SPEED_2_5G) {
            *speed = IXGBE_LINK_SPEED_2_5GB_FULL;
            break;                    /* ← 只给 2.5G，不 fallthrough */
        } else if (hw->device_id == IXGBE_DEV_ID_X550EM_A_KR_L) {
            *speed = IXGBE_LINK_SPEED_1GB_FULL;
            break;
        }
    }
    fallthrough;
default:
    *speed = IXGBE_LINK_SPEED_10GB_FULL | IXGBE_LINK_SPEED_1GB_FULL;
```

`ethtool` 只报 2.5G ⇒ 走的就是第一个分支 ⇒ **`NW_MNG_IF_SEL` bit20 已经是 1**。
**Intel 侧不需要动，它已经按 2.5G 配好了。**

> 顺带解释了另一件事：`ethtool -s enp5s0f0 speed 2500 autoneg on` 会返回 `Invalid argument`。
> 因为 `ixgbe_set_link_ksettings()` 里非 copper / 非 multispeed_fiber 的分支写着
> `/* in this case we currently only support 10Gb/FULL */`，
> 只要 `autoneg == AUTONEG_ENABLE` 或速率不是 10000 就直接 `-EINVAL`。
> **背板模式下 ethtool 根本没有暴露 2.5G 的设置入口**，这条路口是死的。

`NW_MNG_IF_SEL` 是 BAR0 偏移 `0x11178` 的普通 MMIO 寄存器（不是 NVM），
但 PVE 的 `CONFIG_STRICT_DEVMEM=y` 挡住了 `/dev/mem` 访问
（读 CTRL `0x00000` 和 `NW_MNG_IF_SEL` 都返回 `0xffffffff`）。
要直接读它得加内核参数 `iomem=relaxed`——不过上面的代码链已经能反推结论，不必为此重启。

### ② Switch 侧：只有 CMODE 可写，所有速率位都只读

`PORT_STS` (port reg `0x00`) 的低 4 位是 CMODE，**可以写**：

| 值 | 含义（mainline `port.h`） |
|---|---|
| `0x9` | `MV88E6XXX_PORT_STS_CMODE_1000BASEX` ← 当前 |
| `0xa` | `MV88E6XXX_PORT_STS_CMODE_SGMII` |
| `0xb` | `MV88E6XXX_PORT_STS_CMODE_2500BASEX` ← 目标 |

实测 `0x0e09` → `0x0e0b` 写成功，读回 `0x0e0b`。

**但同一个寄存器的 bit[9:8]（速度状态）写不进去**：

```
写 PORT_STS = 0x34b  (CMODE=0xb, bit[9:8]=0b11)
读回        = 0x0e0b (CMODE=0xb, bit[9:8]=0b10)   ← 3 被硬件改回 2
```

`MMD4 0x2000`（SGMII/SerDes 控制）的 bit[13:12] 是 SGMII 速率选择，同样只读：

```
当前 0x2000 = 0x1100
写 0x3140 (bit13:12=0b11)  -> 读回 0x0100    ← bit15/13/12/6 全被清掉
写 0x1140                  -> 读回 0x0100
写 0x0140                  -> 读回 0x0100
```

`MMD4 0x1000` (PCS_CTL1) 也是只读：

```
写 0x2160 -> 读回 0x2140
写 0x2120 -> 读回 0x2140
写 0x2100 -> 读回 0x2140
写 0x2180 -> 读回 0x2140
```

`0x2140` 的 bit6=1 → Clause 45 速度选择 = 1000 Mb/s。**这一位锁死，改不了。**

`MMD4 0x2000`（SGMII/SerDes 控制）部分可写，`0x2140` 写 `0xb140` 后读回 `0x0100`
（bit15/13/12/6 被硬件清掉），但不产生链路。

### ③ 原厂 SDK 对 Agate 家族的 2.5G 返回错误

反汇编 `libmarvell-umsd.so.0.0.0`（Vyatta rootfs 里的 Marvell SDK，671 KB）：

原厂的 backplane 配置序列（`libfal-mvl.so.1` @ `0x6dd0`）：

```asm
movzx esi, WORD PTR [rbp+0x10]     ; port
xor   edi, edi                      ; dev = 0
mov   edx, 0x4                      ; speed mode = 4
call  msdPortForceSpeedModeSet
...
mov   edx, 0x2                      ; link mode = 2
call  msdPortForceLinkModeSet
```

追下去：

```
msdPortForceSpeedModeSet        -> 查 [dev+0x418] 函数指针
88E6190X = Agate 家族           -> Agate_gprtSetForceSpeedIntf @ 0x69660
Agate_gprtSetForceSpeedIntf     -> 跳转表 @ 0x80a50，7 项
```

跳转表解出来（每项相对 0x80a50 的 32 位偏移）：

| mode | 落点 | 效果 |
|---|---|---|
| 0 | `0x696c0` | `edx=0` → speed 0（10M） |
| 1 | `0x696d0` | `edx=1` → speed 1（100M） |
| 2 | `0x69690` | `edx=2` → speed 2（1G） |
| 3 | `0x696a0` | `edx=3` → speed 3（10G） |
| **4** | `0x69680` | **`eax=0x10; ret`** ← 不支持 |
| **5** | `0x69680` | **`eax=0x10; ret`** ← 不支持 |
| 6 | `0x696b0` | `edx=6` → speed 6 |

**原厂给 backplane 传的 mode 4，在 Agate 家族上直接返回 `0x10`（不支持）。**

所以原厂启动日志里那句"Backplane speed is 2.5G"只是**配置意图**，
随后应该跟着一行 `set speed to 2.5G (bkp port N) failed rc:16`
（字符串在 `libfal-mvl.so.1` @ `0x107d8`）。

> 注：这条日志路径只有在一个全局字节 `0x2182f3` 非零时才走。见下。

### ④ 原厂配置里根本没有 2.5G

Vyatta 的配置文件（从 `vy-snap.tgz` 解出）：

```ini
# /etc/vyatta/platform-params.conf
[Platform]

[Defaults]
platform-type=switch
```

就这些。没有 backplane 速率配置。

`'2.5g' => 2500` 只出现在 `vyatta-intf-end` / `validate-interfaces.pl` 里，
那是 Vyatta CLI 的**通用**速度枚举，任何平台都有，不代表这台机器用它。

`libfal-mvl.so.1` 里 2.5G 分支的前置条件：

```asm
6d93: cmp BYTE PTR [rip+0x211559], 0x0    # 0x2182f3
6dba: je  0x719c                           # 为 0 就跳过 2.5G 路径
```

这个字节由配置驱动，原厂没配 → 走非 2.5G 分支。

### ⑤ 原厂手册确认硬件支持，但不含寄存器定义

`MV-S110663-00 Rev.A`（88E6390/88E6190/88E6290 Datasheet）里三处明确写了 2.5G：

- **p04 OVERVIEW**：`tenth and eleventh ports provide two SerDes interfaces
  supporting 2500BASE-X (2.5Gbps), 1000BASE-X, and SGMII`
- **p05 Features**：`2 integrated SerDes interfaces - Supports 2500BASE-X, 1000BASE-X, and SGMII`
- **p06 Table 1**：`# SerDes with 1 Gbps = 2`、`# SerDes with 2.5 Gbps = 2`

**p40 Table 13** 直接列出每个口的接口能力：

| Port | 1000BASE-T | RGMII | RMII | MII/200Mbps | **2.5G** | **SGMII/1000BASE-X** |
|---|---|---|---|---|---|---|
| 0 | | x | x | x | | |
| 1-8 | x | | | | | |
| **9-10** | | | | | **x** | **x** |

**p18 Table 2** 给出 P9/P10 的引脚：`P10_RXP[0] / P10_RXN[0] / P10_TXP[0] / P10_TXN[0]`，
是标准 SerDes 差分对。**p07/p08 的框图**也把 P9/P10 标成 `2.5Gbps / 1Gbps SerDes`。

**但是**——这本 Datasheet 只到 61 页（List of Tables 已经引用到 page 80），是节选版，
而且 p52 原文就写着：

> See LED control registers in the **Functional specification**.

即所有寄存器定义都指向另外两本文档，而这两本我们没有：

- *Switch Functional Specification*
- *PHY and SERDES Functional Specification*

**所以手册能证明"硬件支持 2.5G"，但证明不了"怎么配"。**
真正的 SerDes 速率配置（PLL、lane 速率、2500BASE-X 的完整 PCS 序列）在拿不到的那两本里。

---

## 实测：改了会怎样

### 实验 A：CMODE = 2500BASE-X

```
before: STS=0x0e09  MAC=0x203e   Intel: 1000Mb/s  carrier=1
        ↓  sw_w 9 0x00 0x34b ; sw_w 9 0x01 0x303e
读回  : STS=0x0e0b（CMODE=0xb，bit[9:8] 被硬件改回 2）
after : Intel: Unknown!   carrier=0        ← 链路起不来
```

### 实验 B：CMODE = SGMII（按 cnblogs 文章的 0x34a 写法）

```
        ↓  sw_w 9 0x00 0x34a ; sw_w 9 0x01 0x303e
读回  : STS=0x0e0a（CMODE=0xa，bit[9:8] 仍被改回 2）
after : Intel: 1000Mb/s   carrier=1        ← 链路能起，但只有 1G
dmesg : ixgbe ... NIC Link is Up 1 Gbps
```

SGMII 模式是唯一能建链的，但速率仍锁在 1G。

### 实验 C：SGMII + 强制 SerDes 速率位

```
        ↓  sw_w 9 0x00 0x0e0a
           serdes_w 9 0x2000 0x3140      # SGMII speed = 0b11
           sw_w 9 0x01 0x303e            # MAC 2.5G
读回  : 0x2000 = 0x0100（bit13:12 被清）
after : Intel: 1000Mb/s   carrier=1
```

### 实验 D：只改 CMODE，看 switch 自己怎么报速率

比 A/B/C 更干净的做法 —— 不动 SerDes，只改 MAC 侧模式，然后读 switch 自己的状态位。

```
before : sts10=3593 (0x0e09)  mac10=8254 (0x203e)    Intel 1000Mb/s   link yes
         ↓ sw_w 10 0x01 12350      # 0x303e = FORCE_SPEED|ALTSPEED|SPEED_1000
读回   : mac10=12350 (0x303e)                        ← MAC 写成功
         ↓ sw_w 10 0x00 3595       # 0x0e0b = CMODE 0xb (2500BASE-X)
读回   : sts10=3595 (0x0e0b)                         ← CMODE 写成功
after  : Intel Speed: Unknown!   Link detected: no   ← 链路立刻断
         ↓ sw_w 10 0x01 8254 ; sw_w 10 0x00 3593     # 写回基线
after  : Intel 1000Mb/s  link yes                    ← 立即恢复
```

**这个实验说明三件事**：

1. `CMODE` **确实可写、且真的生效** —— 写 `0xb` 链路断，写回 `0x9` 立刻恢复，
   不是"写了个影子寄存器没人理"。
2. `0x0e0b` 里 bit[9:8] 仍然是 `0b10`（1G）—— **它反映的是 SerDes 实际速率，不是 CMODE 的推论**。
3. 两者合起来 ⇒ **SerDes 物理层仍然只跑 1G**，而 MAC 侧已经按 2500BASE-X 在等，握手必然失败。

换句话说：**`CMODE` 是"告诉 MAC 用什么编码"，bit[9:8] 是"SerDes 实际跑多快"。**
前者能改，后者不能 —— 这就是症结所在。

### 复位尝试

- `0x2000` bit15 置 1 再清 —— 读回 `0x0100`，无效
- `0xf000` 写 `0x8000` 再清 —— 读回 `0x0000`，无效

**恢复**：重跑 `v150-switch-bringup.sh` 即可回到 1G 正常状态。

---

## 为什么 shell 层做不到

| 障碍 | 说明 |
|---|---|
| 速率位全只读 | `PORT_STS` bit[9:8]、`0x2000` bit[13:12]、`PCS_CTL1` bit[6] —— 三处独立的速率编码全部写不进去，硬件只保留模式位 |
| CMODE ≠ 速率 | `CMODE` 能写（实验 D 已证实生效），但它只决定 MAC/PCS 用哪种编码，**决定不了 SerDes 晶体/PLL 的实际速率**。写 `0xb` 的结果是 MAC 按 2.5G 等、SerDes 仍出 1G，直接失链 |
| Intel 侧没有 ethtool 入口 | `ixgbe_set_link_ksettings()` 对背板只接受 `10G + autoneg off`，其它一律 `-EINVAL`。所以连"两边手动对齐到 2.5G"都做不到 |
| 只有 MMD 4 可用 | MMD 1 (PMA/PMD) / MMD 3 (PCS) / MMD 31 (vendor) 在 port 9 上**全部读回 0** |
| 需要完整重配序列 | 2500BASE-X 不只是改一个位，要重配 PLL、SerDes lane、AN 通告格式 |
| 间接 SMI 的代价 | 每次访问都要等 `CMD.BUSY` 清零，长序列容易中途失败且难回滚 |
| 没有硬件文档 | 88E6190X 的 SerDes 编程手册（*PHY and SERDES Functional Specification*）不公开，原厂 Datasheet 只到"支持 2.5G"为止，不含寄存器定义 |

MMD 扫描实测（port 9）：

```
MMD1  0x0000..0x0009  ->  全 0
MMD3  0x0000/0x0001/0x0020/0x0021  ->  全 0
MMD31 0xf000..0xfc02  ->  全 0
MMD4  有内容（见上面的寄存器表）
```

### 关于 cnblogs 那篇 88E6390X 总结

参考资料里有这么一段（配 port 10）：

```
//0xa:P10
//0x34a:
//   bit[3:0] = 0xa  接口配置模式 SGMII
//   bit[6]   = 0x1  EEE Enabled
//   bit[9:8] = 0x3  = 10Gb or 2500Mbps
miiwrite 0xa 0 0x34a
```

按这个思路试过（实验 A / B），确认了 **CMODE=0xa (SGMII) 是能建链的那个**，
但 `bit[9:8]` 在这块芯片上是**只读状态位**，写入会被硬件改回 `0b10`。
文章里的 `0x34a` 更像是**读**到的值，不是能写进去的配置。


`PORT_MAC_CTL` 的 `ALTSPEED`（bit12 = `0x1000`）确实是 2.5G 的标志位：

```c
/* mainline port.c */
case 2500:
    ctrl = MV88E6XXX_PORT_MAC_CTL_SPEED_1000 |
           MV88E6390_PORT_MAC_CTL_ALTSPEED;
```

`0x203e | 0x1000 = 0x303e` 就是 mainline 认为的 "2500 强制模式"。
但 mainline 是在 **DSA 驱动**里配合完整的 phylink PCS 配置用的，
单独写这一个寄存器不够。

---

## 如果将来想做

**先明确一点：Intel 侧不用动。** `NW_MNG_IF_SEL.PHY_SPEED_2_5G` 已经置位，
驱动只报 `2500baseT/Full`（证据链 ①）。所有工作都在 switch 侧。

**唯一现实的路：换成 DSA 驱动 + 拿到 SerDes 编程文档。**

mainline 的 `mv88e6xxx` 明确支持：

```c
/* Support 10, 100, 200, 1000, 2500, 10000 Mbps (e.g. 88E6190X) */
int mv88e6390x_port_set_speed_duplex(struct mv88e6xxx_chip *chip, int port, ...)
{
	if (speed >= 2500 && port < 9)   // 2500/10000 只允许 port 9/10
		return -EOPNOTSUPP;
	...
}
```

我们的 CPU 口正好是 port 9/10，条件满足。

但要注意：mainline 的 `serdes.c` 里**并没有完整实现** 2500BASE-X 的 PCS 初始化
（当前版本只有 lane 管理、统计和 `PORT_MAC_CTL` 的 speed 位设置），
所以 DSA 路线也未必能让链路真的跑到 2.5G，需要在真机上验证。

**万一 DSA 也不行**，剩下唯一的路是拿到 Marvell 的
*PHY and SERDES Functional Specification*，按里面 2500BASE-X 的 PLL/PCS 序列手工重配。
原厂 Datasheet 只到"支持 2.5G"为止，寄存器定义全部指向那本（证据链 ⑤）。

而且 DSA 路线在这台机器上已知有问题（见 README 的"为什么不用 DSA"），
当时卡在 `rzsn/firebox-m270` 遇到的同一批坑上。

**收益评估**：8 个前面板口都是 1G（88E6190X 的 PHY 就是 1G），
所以 CPU 上行 2.5G × 2 = 5G 只在**多个面板口同时打流、总和超过 1G** 时才能受益。
单口转发永远受 1G PHY 限制（实测 920 Mbps 已接近线速）。

具体场景：
- 面板 1/3/4/5 共享 port 9 上行 → 上行 1G 时收敛比 4:1，上行 2.5G 时 1.6:1
- 面板 2/6/7/8 共享 port 10 上行 → 同上
- 所以对"多个 1G 口同时跑满"的用法，5G 上行确实有意义


---

## 保留的寄存器参考值

供以后复查（port 9 = CPU，CMODE 0x9 正常工作时）：

| 寄存器 | 值 | 说明 |
|---|---|---|
| `PORT_STS` (0x00) | `0x0e09` | CMODE=0x9 (1000BASE-X), LINK=1 |
| `PORT_MAC_CTL` (0x01) | `0x203e` | FORCE_SPEED\|SPEED_1000\|FORCE_LINK\|LINK_UP\|FULL |
| `PORT_CTL2` (0x08) | `0x0c80` | 8021Q Secure + MAP_DA |
| MMD4 `0x1000` PCS_CTL1 | `0x2140` | **只读**，bit6=1 → 1000 Mb/s |
| MMD4 `0x1001` PCS_STS | `0x0082` | |
| MMD4 `0x1004` AN_ADV | `0x0001` | |
| MMD4 `0x2000` SGMII_CTL | `0x2140`~`0x3140` | 部分可写 |
| MMD4 `0xf001` | `0x0002` | |
| MMD4 `0xf002` | `0x0003` | |
| MMD4 `0xf010` | `0x0500` | |
| MMD4 `0xf018` | `0x0002` | |
| MMD4 `0xf030` | `0x0200` | |

`PORT_MAC_CTL` 位域（mainline `port.h`）：

```
0x2000 FORCE_SPEED
0x1000 ALTSPEED        ← 2.5G 标志
0x0020 LINK_UP
0x0010 FORCE_LINK
0x0008 DUPLEX_FULL
0x0004 FORCE_DUPLEX
0x0003 SPEED_MASK  (0=10M, 1=100M, 2=1G, 3=10G)
```

---

## 过程中的可复用信息

### 从 Vyatta rootfs 提取文件

```sh
# 列文件
unsquashfs -l vyatta-rootfs.squashfs | grep xxx

# 提取单个文件（注意：直接用 -d 提取有时会失败，-cat 更可靠）
unsquashfs -cat vyatta-rootfs.squashfs "usr/lib/libmarvell-umsd.so.0.0.0" > umsd.so
```

### 反汇编 SDK 找函数指针表

```sh
readelf --dyn-syms --wide umsd.so | grep -i Force
objdump -d --no-show-raw-insn -M intel umsd.so > umsd.dis
readelf -r --wide umsd.so | grep <GOT地址>       # GOT 项 -> 真实函数地址
objdump -s -j .rodata --start-address=X --stop-address=Y umsd.so   # 跳转表
```

### 寄存器访问

```sh
. /usr/local/lib/v150/v150_sw.sh
sw_r 9 0x00          # port register
serdes_r 9 0x1000    # MMD4（CPU 口用 port 本身）
xs_r 3 0x2000        # MMD4（SFP 用 port+0x10）
```

### 两个踩过的坑

**1. `/proc/v150_mdio` 只认十进制**

手动调试时写 `echo "w 16 0 0x9940" > /proc/v150_mdio`，
解析会停在 `x` 上，实际写进去的是 **0** —— 等于把命令字 0 塞给 `SMI_CMD`，
之后所有 `sw_r`/`sw_w` 全部 `BUSY_TIMEOUT`。

写成十进制就正常：

```sh
cmd=$(( 0x9800 | (10 << 5) | 0 ))    # = 39232 = 0x9940
echo "w 16 0 $cmd" > /proc/v150_mdio
cat /proc/v150_mdio                  # w smi=16 reg=0x00 val=0x9940 ok
```

库里的 `smi_w`/`smi_r` 传的都是 `$(( ... ))` 的十进制结果，脚本本身没这个问题。
**手动敲命令时一定要注意。**

**2. `BUSY_TIMEOUT` 多半是上一把的残留**

状态机被写坏后重载模块就能恢复，switch 本身不受影响：

```sh
modprobe -r v150_mdio && modprobe v150_mdio
```
