# att-v150-ia3000-linux-netdrive

[English](README.en.md) | **简体中文**

在普通 Linux 内核上点亮 **Silicom IA3000 / AT&T ATT-V150** uCPE 的 **Marvell 88E6190X**
交换芯片和全部 **8 个前面板网口**（开发和验证环境：Proxmox VE 9，内核 `7.0.2-6-pve`，x86_64）。

**不用 DSA，不用厂商 SDK，不写内核交换机驱动。** 一个约 150 行的内核模块借用 `ixgbe`
已经注册好的 MDIO 总线，一个 POSIX shell 脚本通过它配置交换芯片。转发全部由硬件完成。

> 当前状态：8 个前面板口全部可用，一口一个 VLAN，全部跑满 1 GbE 线速。

> **只想快点亮？** 先看 [第 0 步：确认机器对得上](#第-0-步确认机器对得上)，
> 然后直接跳到 [三步点亮](#三步点亮)。中间那些原理不用读。

---

## 你会得到什么

8 个前面板口全部可用，每个口对应一个独立的 VLAN 子接口：

```
$ sudo v150-status.sh
----- module -----
  /proc/v150_mdio       present
  switch id             0x0a01  88E6190X rev 1 ok     ← 芯片接通了

----- uplinks -----
  enp5s0f0     switch port 10   carrier=1 speed=1000
  enp5s0f1     switch port  9   carrier=1 speed=1000

----- switch ports -----
  PORT   LNK  SPEED  CMODE  PVID
  1      0    -      0xf    4      ← 面板 4，没插线
  3      1    1G     0x9    1      ← 面板 1，SFP 有模块
  9      1    1G     0x9    100    ← CPU 上行
  ...
```

给 `enp5s0f1.3` 配个 IP，面板 3 就能用了 —— 8 个口默认互相隔离（一口一 VLAN）。

---

## 第 0 步：确认机器对得上

**这个仓库只对一种机器有效。** 先花 30 秒确认，对不上就别往下走 ——
下面每个端口映射、每个寄存器时序都是在这一台机器上实测出来的。

```sh
lspci -nn | grep -i 15c2
```

必须看到**两个** `8086:15c2`（X553 Backplane）：

```
05:00.0 Ethernet controller: Intel Corporation Ethernet Connection X553 Backplane [8086:15c2]
05:00.1 Ethernet controller: Intel Corporation Ethernet Connection X553 Backplane [8086:15c2]
```

```sh
cat /sys/class/dmi/id/product_name
```

应该是 `80500-0150-G02`（Silicom IA3000 / AT&T ATT-V150）。

**还需要：**

| 项 | 要求 | 自己检查 |
|---|---|---|
| 系统 | x86_64，Debian 12+ 或 Proxmox VE 8/9 | `cat /etc/os-release` |
| 内核头文件 | 匹配当前运行内核 | `test -e /lib/modules/$(uname -r)/build && echo ok` |
| 权限 | root | `id -u` 输出 `0` |
| 管理网络 | **不能**走要被接管的这 8 个口 | — |

头文件缺失：

```sh
apt install pve-headers-$(uname -r)      # Proxmox VE
apt install linux-headers-$(uname -r)    # Debian
```

VyOS 用 [vyos/setup.sh](#vyos)，不要用 `install.sh`。

---

## 三步点亮

### 第 1 步：装

```sh
git clone https://github.com/FusionPlmH/att-v150-ia3000-linux-netdrive
cd att-v150-ia3000-linux-netdrive
sudo ./install.sh
```

不想克隆：

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/att-v150-ia3000-linux-netdrive/main/get.sh | sudo bash
```

想先看它打算干什么：加 `--dry-run`。

**它做的事**：

| 步骤 | 说明 |
|---|---|
| 识别发行版 | Proxmox VE / Debian / VyOS |
| 检查内核头文件 | 缺的话尝试 `pve-headers-$(uname -r)` / `linux-headers-$(uname -r)` |
| **自动识别两个 X553 上行** | 按 PCI 设备 ID `8086:15c2` 找，按功能号判断哪个是 switch port 9 / 10 |
| 编译模块 | 直接编译，或 `--dkms` 走 DKMS |
| 安装模块 + modprobe 配置 | `/lib/modules/$(uname -r)/extra/`、`/etc/modprobe.d/v150_mdio.conf` |
| 装载并验证芯片 | 读 `0x0a01` 确认是 88E6190X |
| 安装 bring-up 与服务 | `/usr/local/sbin/`、`/etc/systemd/system/`，开机自启 |
| 创建主机侧 VLAN 接口 | `enp5s0f1.1` … `enp5s0f0.8`，**只建不配地址** |

**装完应该看到**（最后几行）：

```
   + systemctl restart v150-switch.service
● v150-switch.service
     Active: active (exited)
```

以及前面的 `chip id` 那行是 `0x0a01  (88E6190X) OK`。
**芯片 ID 读不出来**说明模块没接上 MDIO —— 看 [装不上怎么办](#装不上怎么办)。

### 第 2 步：确认 8 个口都在

```sh
sudo v150-status.sh
```

看 `switch ports` 表，8 个前面板口的 `PVID` 必须是 `1`~`8`（面板号 = VLAN）：

```
  PORT   LNK  SPEED  CMODE  PVID
  1      0    -      0xf    4      ← 面板 4
  2      0    -      0xf    3      ← 面板 3
  3      1    1G     0x9    1      ← 面板 1（SFP）
  4      0    -      0xf    2      ← 面板 2（SFP）
```

`LNK=0` 不是错误 —— 没插线就是 0。面板 1/2 是 SFP，没插模块时 `CMODE=0xf` 也正常。

### 第 3 步：插一根线验证

把网线插到**面板 3**（电口），对端接另一台机器：

```sh
# 面板 3 -> VLAN 3 -> enp5s0f1.3（对照见"端口映射"）
sudo ip addr add 192.168.50.1/24 dev enp5s0f1.3
sudo ip link set enp5s0f1.3 up

# 对端机器配 192.168.50.2/24，然后
ping -c 3 192.168.50.2
```

**通了就成功了** —— 面板 → 交换芯片 → VLAN → 上行 → 主机，整条链路都对。
换别的面板同理，VLAN 号 = 面板号。

**不知道线插在哪个面板？** 不配 IP 也能确认，看哪个子接口在收包：

```sh
for i in enp5s0f1.{1,3,4,5} enp5s0f0.{2,6,7,8}; do
  printf '%-16s %s\n' "$i" "$(cat /sys/class/net/$i/statistics/rx_packets 2>/dev/null || echo -)"
done
sleep 8
# 再跑一次，数字涨了的那个就是
```

（在仓库目录里的话，`sudo ./tools/vlan_mon.sh 8` 会自动做这件事并标出活跃的接口。）

> ⚠️ 不要用 `tcpdump -i enp5s0f0` 判断有没有 tag —— `ixgbe` 会把 VLAN tag
> 剥进描述符，抓包看不到。只看 VLAN 子接口的 `rx_packets`。

---

## 装完之后

三个命令都进了 PATH：

| 命令 | 作用 |
|---|---|
| `sudo v150-status.sh` | 只读健康报告，任何时候都能跑 |
| `sudo v150-vlans.sh create\|delete\|show` | 建 / 删 / 看主机侧 8 个 VLAN 子接口 |
| `sudo v150-switch-bringup.sh` | 重新给交换芯片编程（开机由 systemd 自动跑） |

配置在 `/etc/default/v150-switch`。内核升级导致网口改名时，重跑 `sudo ./install.sh` 就行。

卸载：`sudo ./install.sh --uninstall`（保留 `/etc/default/v150-switch`）

---

## 详细文档

| 文档 | 看它做什么 |
|---|---|
| [docs/REGISTER-REFERENCE.md](docs/REGISTER-REFERENCE.md) | 88E6190X 的寄存器 / 位域速查（中英双语） |
| [docs/TECHNICAL-NOTES.md](docs/TECHNICAL-NOTES.md) | 走过的弯路和原因（中英双语） |
| 本文下面的"为什么不用 DSA"/"工作原理" | 想改代码或换机器时看 |

---

## 为什么不用 DSA

最直觉的做法是把 88E6190X 注册成 MDIO 设备，让 mainline 的 `mv88e6xxx` DSA 驱动接管。
[`rzsn/firebox-m270`](https://github.com/rzsn/firebox-m270) 在几乎相同的硬件上
（WatchGuard M270：同样 Atom C3000 + X553 Backplane + 88E6190）就是这么做的，
结果卡在：

- 8 个端口能枚举出来、能协商 1G，但 **数据一个包都不通**
- CPU 口 `Link detected: no`
- `mv88e6xxx` 不接受多个 conduit，CPU 口永远注册不上链路

这块板子上 DSA 要同时对付三件事：

1. **两个 CPU 口**（switch port 9 和 10）—— `mv88e6xxx` 只想要一条 conduit
2. **X553 Backplane 没有 PHY**。`ethtool` 显示
   `Supported ports: [FIBRE]`、`2500baseT/Full`、`Port: Other`、`PHYAD: 0`，
   而且没有 `phydev`。`dsa_slave_create()` 没有合理的东西可以挂
3. **DSA tag** 会在 CPU 链路上额外占 4–8 字节，还要求 CPU 口处在特定的 frame mode

所以改成：

| 层 | 内容 | 职责 |
|---|---|---|
| 内核 | `v150_mdio.ko`（约 150 行） | **只做搬运**：`enp5s0f0` → `ixgbe-mdio` 总线 → `mdiobus_read/write`，导出 `/proc/v150_mdio` |
| 用户态 | `scripts/v150-switch-bringup.sh` + `scripts/v150_sw.sh`（POSIX sh） | **全部交换机逻辑**：SMI 协议、PHY/SerDes 上电、VTU 表项、端口模式 |
| 启动 | `systemd/v150-switch.service`（oneshot） | 开机跑一次 |

内核模块完全不懂 88E6190X。它不创建 netdev、不做 bridge、不碰 switchdev。
Linux 只看到两张普通的 `ixgbe` 网卡，加上 802.1Q VLAN 子接口。

**付出的代价**（已接受）：

- 没有每端口独立 netdev → 不能对单个物理口做 `tc` 限速、`ethtool`、端口镜像
- 硬件 FDB 没有导出
- VLAN 是静态表，改配置要重跑脚本
- 不感知 SFP 热插拔

**换来的好处**：

- 数据面零开销 —— 转发全在硬件
- 内核升级不受影响（不依赖 DSA 内部实现）
- 绕开了上面两个 DSA 死点
- 配置全部可读、可 diff；排错就是读寄存器

---

## 硬件

Silicom `80500-0150-G02` —— Intel Atom C3000 (Denverton) uCPE。

```
Panel 1 (SFP) ── switch port 3 ─┐
Panel 2 (SFP) ── switch port 4 ─┤
Panel 3       ── switch port 2 ─┤
Panel 4       ── switch port 1 ─┤   Marvell 88E6190X
Panel 5       ── switch port 6 ─┤   MDIO 地址 0x10
Panel 6       ── switch port 5 ─┤   芯片 ID 读回 0x0a01（rev 1）
Panel 7 (PoE) ── switch port 8 ─┤
Panel 8 (PoE) ── switch port 7 ─┘
                switch port 9   ─── PCI 05:00.1 ─── enp5s0f1 ┐
                switch port 10  ─── PCI 05:00.0 ─── enp5s0f0 ┼ Intel X553 Backplane
                switch port 0   ─── RGMII ──────── bmc0      ┘
i210 (PCI 03:00.0) ─── enp3s0   （独立管理网卡）
```

要点：

- 前面板口到 switch port 是 **成对互换** 的，不是顺序映射
- PoE 在面板 7、8
- switch port 0（XMII/RGMII）接 BMC，本方案刻意不动它
- 88E6190X 只有三条 SerDes：port 0、port 9、port 10。端口 3、4 走的是 SFP 笼子后面
  独立的 Clause-45 PHY（见下文）

---

## 工作原理

### 间接 SMI 访问

交换芯片挂在 MDIO 总线的 SMI 地址 `0x10`，用 Marvell 标准的间接寄存器协议：

```
SMI_CMD  = 0x00        SMI_DATA = 0x01
cmd = BUSY(0x8000) | MODE_22(0x1000) | OP | (dev << 5) | reg
OP_22_READ  = 0x0800
OP_22_WRITE = 0x0400
dev:  端口 N = N，Global1 = 0x1b，Global2 = 0x1c
```

**每次写之前都必须先等 `CMD.BUSY == 0`，然后才写数据寄存器。**
否则写命令会被静默丢弃 —— 这是"我写的寄存器没反应"的头号原因。

`sw_r()` 也必须把任何读错误当成失败，绝不能当成 `0`。

### 借用总线（为什么内核模块这么小）

`ixgbe` 在 Backplane 模式下会注册一条名为 `ixgbe-mdio` 的 `mdio_bus`
（因为 MAC 声称有一个实际不存在的 PHY）。这条总线没有别的东西在用。
`v150_mdio.ko` 找到它，把 `/proc/v150_mdio` 的请求转过去：

```c
dev_get_by_name(&init_net, "enp5s0f0")
  -> device_find_child(dev, "ixgbe-mdio", ...)
  -> to_mii_bus(bus)
  -> mdiobus_read(bus, smi_addr, reg) / mdiobus_write(...)
```

`/proc/v150_mdio` 只接受两条命令：

```
r <smi> <reg>          -> "val=0x...."   （或 "ERR..."）
w <smi> <reg> <value>  -> "ok"
```

这样就完全不用写 I2C/GPIO 时序，也不用碰 PCI BAR。

---

## 安装细节

上面三步跑通了就不用读这一节。这里是要点补充和手动安装路径。

**除了内核头文件和编译工具链，什么依赖都没有** —— 不需要 `mv88e6xxx`、
不需要 DSA、不需要 switchdev。

### 手动安装

如果不想用脚本：

```sh
# 1. 编译并加载 MDIO 桥
make
cp -f kernel/v150_mdio.ko /lib/modules/$(uname -r)/extra/
depmod -a && modprobe v150_mdio
ls -l /proc/v150_mdio

# 2. 安装并运行 bring-up
install -m755 scripts/v150-switch-bringup.sh /usr/local/sbin/
install -m644 systemd/v150-switch.service    /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now v150-switch.service
```

### 检查状态细节

`sudo v150-status.sh` 输出的每一段：

| 段 | 看什么 |
|---|---|
| `module` | `/proc/v150_mdio` 在不在、模块用的哪个 netdev、芯片 ID 对不对 |
| `uplinks` | 两个 X553 的 carrier 和速率 —— 必须是 1000 |
| `switch ports` | 10 个口的 LNK/SPEED/CMODE/PVID |
| `host VLAN interfaces` | 8 个子接口在不在、有没有配地址 |
| `service` | systemd 单元 active/enabled |

### 网口名从哪来

`install.sh` 按 PCI 设备 ID `8086:15c2` 自动认出两个 X553 上行，
把结果写进 `/etc/default/v150-switch`：

```sh
V150_CPU_IF0=enp5s0f0     # switch port 10
V150_CPU_IF1=enp5s0f1     # switch port  9
```

所有脚本（`v150-switch-bringup.sh` / `v150-vlans.sh` / `v150-status.sh` /
`vlan_mon.sh`）都按这个顺序取值：

```
命令行环境变量  >  /etc/default/v150-switch  >  内置默认 enp5s0f0/enp5s0f1
```

所以内核升级后网口改名了，只要重跑一次 `sudo ./install.sh` 就行，不用改脚本。
临时试别的名字：

```sh
sudo V150_CPU_IF0=eno1 V150_CPU_IF1=eno2 v150-status.sh
```

> 内置默认 `enp5s0f0` / `enp5s0f1` 对应 PCI `05:00.0` / `05:00.1`。
> 在 IA3000 上这两个地址是固定的，变的是内核的命名规则。

### VyOS

VyOS 会把 `/usr` 和 `/etc` 在镜像升级时重写，而 `/config` 保留，
所以用单独的脚本：

```sh
sudo ./vyos/setup.sh                 # 头文件在就本地编译；否则用 --ko
sudo ./vyos/setup.sh --ko /path/v150_mdio.ko
```

它把所有东西放到 `/config/scripts/v150/`，并安装一个
`/config/scripts/vyos-postconfig-bootup.script` 开机钩子，
每次启动都把模块重新装到当前内核的 `/lib/modules/` 下再配置交换芯片。

> **注意实现差异**：本项目需要内核模块，而 VyOS 通常没有编译器、也没有对应内核
> 版本的头文件。所以 VyOS 上只有两条路 —— 本机装匹配的头文件，或者在别的机器上
> 编译好同版本内核的 `.ko` 传过去。这和"纯用户态直接打 `/dev/mem`"的方案不同，
> 后者不需要编译，但需要自己处理 PCI BAR 和时序。

### 两个花了很久的坑

> - `install -m644` 曾经装出 **0 字节的 `.ko`**（`md5 d41d8cd9...`），
>   导致 `modprobe` 报 `Invalid parameters`。安装脚本改用 `cp -f` 并校验
> - 绝对不要用 `Before=network-pre.target`。那个时间点 udev 还没枚举 PCI，
>   `ixgbe` 没绑定，模块找不到 MDIO 总线。`After=network.target` 才行

---

## 端口映射

用一个监视器同时盯着全部 11 个 switch port 的 link 位，然后一根线一个口地插，
逐个记录变化，得到下表：

| 面板 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| 类型 | **SFP** | **SFP** | RJ45 | RJ45 | RJ45 | RJ45 | RJ45 PoE | RJ45 PoE |
| switch port | **3** | **4** | **2** | **1** | **6** | **5** | **8** | **7** |
| VLAN | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| 上行 | CPU 9 | CPU 10 | CPU 9 | CPU 9 | CPU 9 | CPU 10 | CPU 10 | CPU 10 |

CPU 口到 Linux 网口的映射 —— **这个特别容易搞反**：

| Linux | PCI BDF | switch port |
|---|---|---|
| `enp5s0f1` | `0000:05:00.1` | **9** |
| `enp5s0f0` | `0000:05:00.0` | **10** |

永远用 `readlink -f /sys/class/net/enp5s0f0/device` 核对。
多个 PCIe 功能的编号顺序 **不是** 你想当然的那个顺序。
搞反的后果是所有 VLAN 测试都失败，而且表现出"一个方向通、另一个方向黑洞"的样子，
看起来完全像交换芯片的 bug。

---

## VLAN 规划

一个前面板口一个 VLAN，id = 面板号，4 + 4 分摊到两条上行：

```
VLAN 1  面板 1  sw3 (SFP)  untagged -> CPU 9  tagged
VLAN 2  面板 2  sw4 (SFP)  untagged -> CPU 10 tagged
VLAN 3  面板 3  sw2        untagged -> CPU 9  tagged
VLAN 4  面板 4  sw1        untagged -> CPU 9  tagged
VLAN 5  面板 5  sw6        untagged -> CPU 9  tagged
VLAN 6  面板 6  sw5        untagged -> CPU 10 tagged
VLAN 7  面板 7  sw8        untagged -> CPU 10 tagged
VLAN 8  面板 8  sw7        untagged -> CPU 10 tagged
VLAN 100 只含 CPU 9 + CPU 10，两者都 untagged（主机侧普通 L2 通路）
```

每个 VLAN 一条 VTU 表项：前面板口 `01`（untagged 成员）、对应的 CPU 口 `10`
（tagged 成员）、其余全 `11`（丢弃）；`FID = VID`；前面板口 `PVID = 面板号`；
所有端口 `PORT_CTL2 = Secure`。

具体 VTU 位图（`DATA1` 管 port 0–7，`DATA2` 的 bit1:0/3:2/5:4 = port 8/9/10）：

```
VID 1:   D1=0xff7f D2=0x003b      VID 5:   D1=0xdfff D2=0x003b
VID 2:   D1=0xfdff D2=0x002f      VID 6:   D1=0xf7ff D2=0x002f
VID 3:   D1=0xffdf D2=0x003b      VID 7:   D1=0xffff D2=0x002b
VID 4:   D1=0xfff7 D2=0x003b      VID 8:   D1=0x7fff D2=0x002f
VID 100: D1=0xffff D2=0x0017
```

主机侧：

```sh
# 面板 1、3、4、5 -> enp5s0f1（switch port 9）
for v in 1 3 4 5; do
  ip link add link enp5s0f1 name enp5s0f1.$v type vlan id $v
  ip link set enp5s0f1.$v up
done

# 面板 2、6、7、8 -> enp5s0f0（switch port 10）
for v in 2 6 7 8; do
  ip link add link enp5s0f0 name enp5s0f0.$v type vlan id $v
  ip link set enp5s0f0.$v up
done
```

持久化写进 `/etc/network/interfaces`（或你发行版对应的配置），
或者把每个 VLAN 接口挂到各自的 bridge 上做软路由 / 虚拟机网络。

---

## 五件必须做对的事

| # | 事项 | 为什么 |
|---|---|---|
| 1 | 写 `SMI_DATA` **之前** 先等 `CMD.BUSY == 0` | 否则写命令被静默丢弃。所有"写不进去"都是这个 |
| 2 | 前面板铜口 PHY 要显式上电 | 冷启动是 `BMCR = 0x1940`（PDOWN 置位），写 `0x1340` |
| 3 | **SFP 的 SerDes 要显式上电** | 不做的话端口永远停在 `CMODE=0xf`、`LINK=0`，看起来就像硬件是坏的。见下文 |
| 4 | CPU 口 `PORT_CTL2` 的 bit13:12 必须清零 | 留着 jumbo 位（`0x2000`/`0x1000`）会让 **CPU↔CPU 完全不通**，而且是单向的 —— 一个方向通、另一个方向黑洞，极具误导性 |
| 5 | 802.1Q 用 **Secure** 模式，并且每个 VID 都要有 VTU 表项 | Secure 模式下 VID 不在表里就丢弃。出口是否带 tag 由 VTU 成员类型决定，不是 `PORT_CTL0` |

---

## SFP 笼子必须显式给 SerDes 上电

面板 1、2（switch port 3、4）后面有一个 Clause-45 PHY/SerDes，**复位后处于下电状态**。
而 `CMODE` 是只读状态字段，所以不能靠写它把端口切成 1000BASE-X ——
必须先把 SerDes 上电，让端口自己跟过去。

这段序列是通过查看官方 OS 镜像里的 dataplane 插件
（`libfal-mvl.so.1`，一个 DPDK FAL 插件）得到的：

```asm
call msdPhyPortPowerDown          ; 给该口 PHY 上/下电（powerDown = !enable）
cmpl $0x3, 0x54(%rbx)             ; 只有 port type == 3（SFP）才继续
mov  $0x9140, %r8d                ; 数据
mov  $0x2000, %ecx                ; 寄存器 0x2000 = SGMII / SerDes 控制
mov  $0x4,    %esi                ; MMD 4 = PCS / PHY-XS
lea  0x10(%rax), %edx             ; ***** PHY 地址 = port + 0x10 *****
call msdSetSMIC45PhyReg           ; Clause-45 写
```

寄存器级等价操作：

```
Clause-45，MMD 4，PHY 地址 = 端口号 + 0x10，寄存器 0x2000，值 0x9140
```

```sh
xs_w 3 0x2000 0x9140      # SFP 1
xs_w 4 0x2000 0x9140      # SFP 2
```

### 最大的坑：C45 的 PHY 地址是 `port + 0x10`，不是 `port`

| 端口 | PHY 地址 | MMD4 寄存器 0x2000 | 含义 |
|---|---|---|---|
| sw3 | `0x03`（错） | `0x0000` | 什么都不应答 —— 很容易误判成"没有 SerDes" |
| sw3 | **`0x13`**（对） | **`0x1940`** | PDOWN = 1，下电 |
| sw4 | **`0x14`**（对） | **`0x1940`** | 同上 |

`0x1940` 和冷启动时铜口 PHY 报的位模式一样（PDOWN）。官方值 `0x9140`
就是清 PDOWN、置 bit 15。

写完之后端口会自己变身：

```
写前:  sw3 STS=0x100f  LINK=0  CMODE=0xf   （内部 PHY 模式）
写后:  sw3 STS=0xde09  LINK=1  CMODE=0x9   （1000BASE-X）
```

**`CMODE` 是只读的，不要试图写它。** 写 `0x9` 永远读回 `0xf`，
把端口置 Disabled 也一样。它只能作为 SerDes 电源状态改变的 **结果** 而变化。
往错的方向追这个问题，最后得出的是"这两个 SFP 笼子根本没接线"的错误结论。

SerDes 上电状态是 **保持** 的：拔掉模块 `LINK` 会掉，但 `CMODE` 仍然是 `0x9`，
所以重新插模块不用重跑脚本；整机重启才需要。

---

## 实测数据

吞吐：单条 TCP 流，10 秒，主机 → 对端。延迟：1400 字节 ICMP。

| 面板 | 类型 | 上行 | 吞吐 | 延迟 | 丢包 |
|---|---|---|---|---|---|
| 1 | SFP（光转电模块） | CPU 9 | **921.5 Mbps** | 0–3 ms | 0% |
| 2 | SFP（光转电模块） | CPU 10 | **922.4 Mbps** | 0–3 ms | 0% |
| 3 | RJ45 | CPU 9 | **901.9 Mbps** | 0–5 ms | 0% |
| 7 | RJ45 PoE | CPU 10 | **925.6 Mbps** | 0–2 ms | 0% |
| 8 | RJ45 PoE | CPU 10 | **920.0 Mbps** | 0–2 ms | 0% |

1 GbE 的实用上限大约 940 Mbps，所以测过的口全部在线速。

**VLAN 隔离是硬件强制的。** 对端在某一个面板上打 UDP 广播时，
只有该面板对应的 VLAN 接口计数在涨，其余 7 个 VLAN 接口收到的包数 **精确为 0**。

---

## 装不上怎么办

### `chip id` 读不出来 / 不是 `0x0a01`

```
   ! could not read the chip id over the indirect SMI protocol
```

按顺序查：

1. `ls -l /proc/v150_mdio` —— 模块加载了吗？
2. `dmesg | grep v150` —— 模块报错说找不到 `ixgbe-mdio` 吗？
3. `ip -br link | grep -E 'enp|eth'` —— 两个 X553 网口叫什么名字？
4. 名字不是 `enp5s0f0`/`enp5s0f1` 的话：`sudo ./install.sh --cpu-if0 <名> --cpu-if1 <名>`

### `no X553 Backplane (8086:15c2) netdev found`

`lspci -nn | grep 15c2` 有但 `ip link` 里没有 → 驱动没绑上：

```sh
lspci -nnk -s 05:00.0        # 看 "Kernel driver in use:"
modprobe ixgbe
```

### `no kernel build tree at /lib/modules/.../build`

缺内核头文件：

```sh
apt install pve-headers-$(uname -r)      # PVE
apt install linux-headers-$(uname -r)    # Debian
```

PVE 上如果 `pve-headers` 装不上，先 `apt update && apt full-upgrade` 对齐版本。

### 装完网络断了

`install.sh` 只创建 VLAN 子接口，**不配 IP、不改路由**，理论上碰不到管理网络。
如果真断了：

```sh
# 现场恢复（不用重启）
sudo v150-vlans.sh delete
sudo systemctl stop v150-switch

# 或者直接拔掉重来
sudo ./install.sh --uninstall
```

### `install -m644` 装出 0 字节的 .ko

极少数文件系统上 `install` 会出问题。用 `--ko` 手工指定：

```sh
make && sudo ./install.sh --ko ./kernel/v150_mdio.ko
```

---

## 排错

> 这一段是**装好之后**跑起来的问题。装都装不上的看上一节。

### 链路 up，但数据不通

按这个顺序查：

1. `sw_r <port> 0x08` —— `PORT_CTL2` 的 bit11:10 是不是 `0x0c00`（Secure）？
2. 这个 VID 有 VTU 表项吗？本口是 `01`、CPU 口是 `10` 吗？
3. 本口的 `PVID`（`0x07`）是不是期望的 VID？
4. CPU 口的 `PORT_CTL2` bit13:12 是不是 **清零** 了？
5. 你读的是正确的那个 CPU 口吗？（见 [端口映射](#端口映射)）

### "我写的寄存器没反应"

几乎一定是你在 `CMD.BUSY` 清零之前就写了 `SMI_DATA`。
`tools/v150_sw.sh` 处理了这件事，临时拼的命令通常没有。

### 端口显示 `CMODE=0xf`、`LINK=0`，怎么弄都不行

端口 3/4 那就是 SFP 未上电的正常状态 —— 见上一节。
端口 1/2/5/6/7/8 则需要清掉铜口 PHY 的 `BMCR` 掉电位。

### 判断一帧到底有没有带 tag

两个很实用的手法，都是靠它们才把这个口弄通的：

1. **拿 `DISCARD_TAGGED` 当 tag 探针。** 把 `PORT_CTL2` 的 bit 9（`0x0200`）
   打开再打 tag 流量。如果被丢弃，就证明 **tag 确实到达了交换机** ——
   问题在准入/出口，不在网卡
2. **不要用 `AF_PACKET` 抓包判断 tag。** `ixgbe` 会把 802.1Q tag 剥进接收描述符，
   原始套接字看到的是 60 字节无 tag 帧，而 VLAN 子接口照样收得到。
   **只有 VLAN 接口的 `rx_packets` 才能证明 tag 存活**

### 从 Windows 侧造流量

不要依赖 `ping`。Windows 的 ARP 表项一旦进入 failed 状态，
它就会对那个目的地 **完全停止发包**，看起来跟链路死了完全一样。
改用 UDP 广播：

```powershell
$u = New-Object System.Net.Sockets.UdpClient
$u.EnableBroadcast = $true
$ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('192.168.50.255'), 9999)
$b = [System.Text.Encoding]::ASCII.GetBytes('TEST')
1..80 | % { [void]$u.Send($b, $b.Length, $ep); Start-Sleep -Milliseconds 100 }
$u.Close()
```

`tools/vlan_mon.sh` 会打印每个 VLAN 接口的 `rx_packets`/`rx_bytes` 增量并标出活跃的那个 ——
这是确认"线到底插在哪个面板"最快的办法。

### 小包延迟抖动

有些 USB 网卡开了 selective suspend 和 EEE，32 字节小包会抖到 300–700 ms，
而 1400 字节包只有 1–2 ms。先对比两种包长的结果，再怀疑交换机。

---

## 已知限制

- **每条上行 1 Gbps。** 面板 1/3/4/5 共享 CPU 口 9 的 1 Gbps；
  面板 2/6/7/8 共享 CPU 口 10 的。单口能到 ~920 Mbps，
  同组四个口同时打满会互相抢
- **2.5 Gbps 未实现。** 官方固件日志里有
  `Backplane speed is 2.5G for port 9/10` 和 `Backplane tuning is 0x1724`，
  说明硬件支持，但本方案没有实现对应的 SerDes tuning。
  目前两条上行都跑 1000BASE-X
- 没有每端口独立 netdev（不能做单口 `tc`、镜像、`ethtool`）
- 硬件 FDB 未导出
- 不处理 SFP 热插拔；SerDes 状态能跨模块更换保持，但跨重启不保持
- 端口映射是按这块板子硬编码的

---

## 仓库结构

```
install.sh                    一键安装（PVE / Debian），自带 --dry-run / --uninstall
uninstall.sh                  等价于 install.sh --uninstall
get.sh                        curl | sudo bash 用的下载器
Makefile                      make / make clean
dkms.conf                     DKMS 支持（--dkms 时使用）

kernel/
  Makefile                    obj-m := v150_mdio.o
  v150_mdio.c                 /proc/v150_mdio 的 MDIO 桥（唯一的 C 代码）
systemd/
  v150-switch.service         oneshot unit，读 /etc/default/v150-switch

scripts/
  v150_sw.sh                  寄存器库：SMI / C45 / C22 / VTU / SFP(C45 port+0x10)
  v150-switch-bringup.sh      本板 bring-up 时序（其余全交给上面的库）
  v150-vlans.sh               创建 / 删除 / 查看主机侧 VLAN 子接口
  v150-status.sh              健康检查报告（只读）

vyos/
  setup.sh                    VyOS 专用安装器（持久化到 /config）

tools/
  c2c.py                      原始帧收发器（识别 VLAN，排查 tag 问题必备）
  tcpsink.py                  TCP 吞吐对端
  vlan_mon.sh                 每 VLAN 收包计数（确认线在哪个面板）
  port_watch.sh               全端口 link + netdev 变化记录（测端口映射用）

docs/
  REGISTER-REFERENCE.md       寄存器 / 位域参考（中文）
  REGISTER-REFERENCE.en.md    同上，英文
  TECHNICAL-NOTES.md          走过的弯路和原因（中文）
  TECHNICAL-NOTES.en.md       同上，英文
```

---

## 参考资料

- [FreeBSD wiki: NetworkFirewalls/AttV150](https://wiki.freebsd.org/NetworkFirewalls/AttV150) —— 这块板子的 `e6000sw` hints
- [FreeBSD `sys/dev/etherswitch/e6000sw/`](https://cgit.freebsd.org/src/plain/sys/dev/etherswitch/e6000sw/e6000sw.c) —— 寄存器常量和端口 bring-up 顺序
- [Linux `drivers/net/dsa/mv88e6xxx/port.h`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/net/dsa/mv88e6xxx/port.h) —— 权威的位域定义
- [Silicom uBMC](https://github.com/silicom-ltd/uBMC) —— 这个平台的 BMC 侧
- [`wkz/mdio-tools` issue #35](https://github.com/wkz/mdio-tools/issues/35) —— 同款机器，MDIO 地址和厂商 platform 配置的讨论
- [`rzsn/firebox-m270`](https://github.com/rzsn/firebox-m270) —— 同样芯片，DSA 尝试
- [`FusionPlmH/vep1400-linux-non_dsa-driver`](https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver) —— 相近硬件上的非 DSA 路线

---

## 许可

MIT —— 见 [LICENSE](LICENSE)。

本仓库里的寄存器值和序列，来自对硬件的实测观察以及对公开内核源码的阅读。
不包含任何厂商保密资料。
