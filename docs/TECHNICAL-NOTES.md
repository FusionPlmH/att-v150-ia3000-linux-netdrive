# 技术笔记 —— 怎么想明白的，以及哪些路走不通

把死路记录下来，省得别人再走一遍。

---

## 1. 选定的方案

**用户态通过借来的 MDIO 总线直接编程寄存器。**

考虑过的替代方案：

| 方案 | 结论 |
|---|---|
| 走 mainline `mv88e6xxx` 的 DSA | 放弃 —— 两个 CPU 口、X553 Backplane 没有 PHY、DSA tag 要压在一条协商不好的链路上。`rzsn/firebox-m270` 在几乎相同的硬件上记录了同样的死局 |
| 把它注册成 MDIO 设备然后用 `mdio-tools` / `mvls` | `mvls` 从 DSA 驱动发布的 `devlink` 内存区读数据，所以还是得先有 DSA |
| 写一个完整的 switchdev 驱动 | 内核工作量翻几倍，结果一样 |
| 厂商 SDK / DPDK FAL 插件 | 会把 CPU 口从内核手里拿走，就不能当普通 Linux 主机跑虚拟机了 |
| **借 `ixgbe-mdio`，用 shell 脚本打寄存器** | **选它** —— 数据面零开销、内核改动极小、内核升级不受影响 |

### 为什么"借总线"能成立

`ixgbe` 在 Backplane 模式下会注册一条名为 `ixgbe-mdio` 的 `mdio_bus`
（因为 MAC 声称存在一个物理上并不存在的 PHY —— `ethtool` 显示
`Supported ports: [FIBRE]`、`2500baseT/Full`、`Port: Other`、`PHYAD: 0`，没有 `phydev`）。
这条总线没有被任何东西消费。内核模块沿
`enp5s0f0 → device_find_child("ixgbe-mdio") → to_mii_bus()` 走过去，
把 `/proc/v150_mdio` 的读写转发给它。

这就是为什么整个内核侧只有约 150 行，且完全不涉及 PCI 访问和时序。

---

## 2. 值得记录的弯路

### 2.1 静默的 SMI 写（头号时间黑洞）

三个独立的 bug，症状都是"写下去没反应"：

1. **写之前没有轮询 `BUSY`。** `SMI_DATA` 必须在 `CMD.BUSY` 为 0 的时候装载。
   提前写会被丢弃，而且不报错。
2. **读错误被当成 0。** 一个 shell 辅助函数做
   `v=${v#*val=0x}; $((0x$v))`，遇到错误行时字符串原样保留，
   算术表达式静默算出 0。必须校验返回格式。
3. **自协商要先写通告再使能。** 先写 `PCS_CTL1`、后写通告，是写不进去的。

三个都修完之后，寄存器写照常工作了。

### 2.2 2500BASE-X 从来建不起链路

`CMODE = 0xb` + `PORT_MAC = 0x313f` 在两个 CPU 口上都建不起链路。
这两个口的 `PCS_CTL1` 读回 `0x2140`，实际是只读的，
所以通告 / 使能自协商 / 环回统统没法编程。
官方固件日志里有 `Backplane speed is 2.5G for port 9/10` 和
`Backplane tuning is 0x1724`，说明 2.5G 在原理上可行 ——
但那套特定的 SerDes tuning 不在本项目范围内。这里所有东西都跑在 1 Gbps。

### 2.3 X553 的 `NW_MNG_IF_SEL` strap 不是卡点

一开始写过一个小的内核模块去改 `BAR0 + 0x11178`，做法是
`(old & ~GENMASK(21,17)) | (2500 ? BIT(20) : BIT(19)) | BIT(25)`（相近硬件参考代码的写法）。
这块板子上的原始值是 `0x00102002`，**本来就已经置了 BIT(20)**。
加上 BIT(25) 之后链路行为没有任何变化 —— 这个方向是死的。

**所以那段代码已经从仓库里删掉了。** 结论留在这里：不要去动 strap，
它跟"链路起不来"无关。真正的原因是 SerDes 上电和 802.1Q 模式（见 2.5 和 3）。

### 2.4 DiagOS 的 page-0xF8 配方会把 6190X 弄坏

```
page 0xf8, reg 0x08 = 0x0036
page    0, reg 0x14 = 0x8020
```

这是 6190 **非 X** 的 PHY 编程序列。在 6190X 上它会永久破坏 Clause-22 访问 ——
之后每次读都返回命令回显（`(port << 5) | reg`）而不是数据。
只有冷断电才能恢复。正确的铜口上电只需要 3 次写（见 REGISTER-REFERENCE 第 7 节）。

### 2.5 "链路 up、主机能收、主机不能发"

这是持续最久的症状。两个独立原因叠加在一起：

**原因 A —— 802.1Q 模式的位位置搞错了。** 当时相信这个模式在
`PORT_CTL2` 的 bit13:12（FreeBSD `e6000swreg.h` 里带的值，对老芯片是对的），
于是每一次"设置 VLAN 模式"的写其实都写进了**巨帧**字段。
802.1Q 模式从头到尾都没被改过。

**原因 B —— CPU 口映射反了。** `enp5s0f0` 是 switch port **10**，不是 9。
有很长一段时间，VLAN tag 都打在了没被观测的那个口上，
于是结果显得飘忽不定（"4 个包通 1 个"、"6 个包通 0 个"）。

最终把"交换机侧"和"网卡侧"分开的诊断是：**在 `PORT_CTL2` 上置
`DISCARD_TAGGED`（bit 9，`0x0200`），然后打 tag 流量。**
如果这些帧消失了，说明 tag **确实到达了交换机**、交换机也确实在正确分类 ——
问题在准入/出口，不在网卡。这一个测试直接否掉了"X553 在剥 tag"的假设。

### 2.6 `AF_PACKET` 抓包对 VLAN tag 会骗人

`ixgbe` 会把 802.1Q tag 剥进接收描述符。原始套接字看到的是 60 字节无 tag 帧，
而 VLAN 子接口收得完完整整。
靠 `tcpdump` / `AF_PACKET` 判断 tag 是否存在，会导致长时间的误判
"tag 被剥掉了"。**只有 VLAN 接口的 `rx_packets` 才能证明。**

### 2.7 Windows 对端会完全停止发包

如果 Windows 主机对某个目的地的 ARP 表项进入 failed 状态，
它会**彻底停止**向该目的地发包。这时候 ping 测试看起来就像链路完全死了。
用 UDP 广播打到子网广播地址是可靠的流量源
（端口映射就是靠 `tools/vlan_mon.sh` + 一波广播测出来的）。
`ping` 跑 22 个包只收到一个 "destination host unreachable" ——
这是该状态的强烈信号，不是线缆问题。

### 2.8 `PORT_CTL0` 的 EGRESS_MODE 不是出口打 tag 的开关

把 `PORT_CTL0` 的 bit13:12 设成 TAGGED（`0x2000`）没有任何可观察变化。
出口是否打 tag 由 **VTU 成员类型**决定（`01` untagged，`10` tagged）。
别加这个写操作，它只会多一个让你困惑的地方。

### 2.9 `FID = 0` 与 `FID = VID`

所有 VLAN 共用一张 FID 时，投递的可靠性明显变差。
给 `FID = VID` 之后，每个 VLAN 有独立的转发表，表现稳定
（同一块板子的厂商配置里，前面板端口也是按不同的 FID 分组的）。

---

## 3. SFP 笼子：序列是怎么找到的

面板 1 和 2（switch port 3 和 4）的行为和内部 PHY 口一模一样：
`CMODE` 死活不肯从 `0xf` 变，Clause-22 读得通，
而交换机在 SerDes 那一层地址上什么都不应答。
很自然的结论是"这两个笼子没接到交换机上"。

这个结论是错的。翻平台自己的 dataplane 插件
（`libfal-mvl.so.1`，官方 OS 镜像里带的 DPDK FAL 插件）之后，
发现了一条专门的 SFP 通路：

```asm
call msdPhyPortPowerDown
cmpl $0x3, 0x54(%rbx)             ; port type 3 == SFP
mov  $0x9140, %r8d
mov  $0x2000, %ecx                ; reg 0x2000
mov  $0x4,    %esi                ; MMD 4
lea  0x10(%rax), %edx             ; phy address = port + 0x10
call msdSetSMIC45PhyReg
```

**`phy address = port + 0x10`** 就是缺的那一块。按这个地址去探：

```
port 3, phy 0x13, MMD4 reg 0x2000 = 0x1940    <- PDOWN 置位
port 4, phy 0x14, MMD4 reg 0x2000 = 0x1940
```

往那里写 `0x9140`，端口就以 1000BASE-X 起来了，流量跑满线速。
两个光转电模块都测过，一个笼子一个。

**教训：** `CMODE` 是状态字段。当某个端口拒绝进入 1000BASE-X 时，
去找"需要被上电的东西"，而不是找一个能写的寄存器。
还有：当一个 SerDes 看起来不存在时，在得出"没有硬件"的结论之前，
先试试别的 PHY 地址。

---

## 4. 端口映射是怎么测的

不靠文档，而是用一个监视器每秒轮询**全部 11 个** switch port 的链路位
（`PORT_STS` bit 11），只要"已连链路的端口集合"发生变化就打印一行。
然后一根线一个口地插：

```
12:27:51  link-up: 2   =>  panel 3
12:28:09  link-up: 1   =>  panel 4
12:28:17  link-up: 6   =>  panel 5
12:28:27  link-up: 5   =>  panel 6
12:28:37  link-up: 8   =>  panel 7
```

这样就得到了"成对互换"的映射。结果和厂商平台配置里的 `sw_port=` 表也吻合，
两边互相印证。

CPU 口是靠 PCI BDF（`readlink -f /sys/class/net/*/device`）确定的，
不是靠网口名字。

---

## 5. 验证方法

**隔离性**用计数器证明，不靠"应该没问题"：

```sh
# 在主机上统计每个 VLAN 接口的收包数
tools/vlan_mon.sh 8
```

同时让对端打 UDP 广播。期望结果：对应的 VLAN 接口收到 73 个里的约 68 个，
其余每个 VLAN 接口**精确为 0**。

**吞吐**用 `tools/tcpsink.py`（一个刻意写得很笨的 TCP 接收端）
配对的普通 `TcpClient`，取 10 秒窗口，测有效吞吐。

**为什么要故意写得笨：** 接收端里任何"聪明"的东西（小块读写、`select`、
缓冲）都会掩盖线速行为。这个接收端就是一个 `while` 循环里写 256 KiB 块，
到时间就停，然后报它实际发出去了多少。

---

## 6. 运维注意事项

- bring-up 脚本是**幂等**的；重复执行就是重新套一遍状态。
- 两个进程同时访问 `/proc/v150_mdio` 会产生乱码读数
  （芯片 ID 会读成 `0x100f` 而不是 `0x0a01`）。排查前先杀掉所有监视器。
- `pkill -f <模式>` 会把你自己的 SSH 会话一起杀掉（如果模式出现在你的命令行里）。
  用括号技巧（`pkill -f 'link_watc[h]'`）或者按 `/proc/$pid/comm` 来杀。
- 重插网线之后有 10–20 秒的 ARP 重新解析窗口，会有丢包。
- 模块加载必须在 udev 枚举完 PCI **之后**（即 `network.target` 之后，
  而不是 `network-pre.target`），否则 `ixgbe` 还没绑定，MDIO 总线还不存在。

---

## 7. 还没解决的

- **CPU 链路上的 2.5 Gbps。** 需要厂商固件施加的那套 SerDes tuning
  （`Backplane tuning is 0x1724`）。解决之后就能去掉"每条上行 1 Gbps"的天花板。
- **每端口独立 netdev。** 有了它才能做单口 `tc`、镜像和 `ethtool`。
  前提是先解决第 1 节里列出的那些 DSA 障碍。
- **FDB 导出。** 能读 ATU 就可以看到 MAC 学习表。
- **SFP 热插拔。** SerDes 的上电状态能跨模块更换保持，但跨重启不保持；
  也没有事件驱动的重新上电。
