# att-v150-ia3000-linux-netdrive

**简体中文** | [English](README.en.md)

Bringing up the **Marvell 88E6190X** switch and all **8 front-panel ports** of the
**Silicom IA3000 / AT&T ATT-V150** uCPE appliance on a normal Linux kernel
(developed and verified on Proxmox VE 9, kernel `7.0.2-6-pve`, x86_64).

**No DSA, no vendor SDK, no kernel switch driver.** A ~150-line kernel module
borrows the MDIO bus that `ixgbe` already registers, and a POSIX shell script
programs the switch through it. Forwarding happens entirely in silicon.

> Status: all 8 front-panel ports work, each on its own VLAN, at full 1 GbE line rate.

> **Just want the ports working?** Start with
> [Step 0: check the machine matches](#step-0-check-the-machine-matches), then jump
> straight to [Three steps](#three-steps). Everything in between is background.

---

## What you end up with

All eight front-panel ports working, each on its own VLAN sub-interface:

```
$ sudo v150-status.sh
----- module -----
  /proc/v150_mdio       present
  switch id             0x0a01  88E6190X rev 1 ok     <- chip is reachable

----- uplinks -----
  enp5s0f0     switch port 10   carrier=1 speed=1000
  enp5s0f1     switch port  9   carrier=1 speed=1000

----- switch ports -----
  PORT   LNK  SPEED  CMODE  PVID
  1      0    -      0xf    4      <- panel 4, nothing plugged in
  3      1    1G     0x9    1      <- panel 1, SFP module present
  9      1    1G     0x9    100    <- CPU uplink
  ...
```

Put an IP on `enp5s0f1.3` and panel 3 is usable. The eight ports are isolated
from each other by default (one VLAN each).

---

## Step 0: check the machine matches

**This repository works on exactly one machine.** Spend 30 seconds confirming
that — every port mapping and register timing below was measured on this board.

```sh
lspci -nn | grep -i 15c2
```

You must see **two** `8086:15c2` (X553 Backplane):

```
05:00.0 Ethernet controller: Intel Corporation Ethernet Connection X553 Backplane [8086:15c2]
05:00.1 Ethernet controller: Intel Corporation Ethernet Connection X553 Backplane [8086:15c2]
```

```sh
cat /sys/class/dmi/id/product_name
```

Should print `80500-0150-G02` (Silicom IA3000 / AT&T ATT-V150).

**You also need:**

| Item | Requirement | Check it |
|---|---|---|
| OS | x86_64, Debian 12+ or Proxmox VE 8/9 | `cat /etc/os-release` |
| Kernel headers | matching the running kernel | `test -e /lib/modules/$(uname -r)/build && echo ok` |
| Privileges | root | `id -u` prints `0` |
| Management link | **must not** go through the eight ports being taken over | — |

Missing headers:

```sh
apt install pve-headers-$(uname -r)      # Proxmox VE
apt install linux-headers-$(uname -r)    # Debian
```

On VyOS use [vyos/setup.sh](#vyos), not `install.sh`.

---

## Three steps

### Step 1: install

```sh
git clone https://github.com/FusionPlmH/att-v150-ia3000-linux-netdrive
cd att-v150-ia3000-linux-netdrive
sudo ./install.sh
```

Without cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/att-v150-ia3000-linux-netdrive/main/get.sh | sudo bash
```

Add `--dry-run` to see the plan first.

**What it does:**

| Step | Detail |
|---|---|
| Detect the distribution | Proxmox VE / Debian / VyOS |
| Check kernel headers | tries `pve-headers-$(uname -r)` / `linux-headers-$(uname -r)` |
| **Auto-detect both X553 uplinks** | by PCI device ID `8086:15c2`, then decides which function is switch port 9 vs 10 |
| Build the module | direct build, or DKMS with `--dkms` |
| Install module + modprobe options | `/lib/modules/$(uname -r)/extra/`, `/etc/modprobe.d/v150_mdio.conf` |
| Load and verify the chip | reads back `0x0a01` to confirm it is an 88E6190X |
| Install bring-up + service | `/usr/local/sbin/`, `/etc/systemd/system/`, enabled at boot |
| Create host VLAN interfaces | `enp5s0f1.1` … `enp5s0f0.8`, **created and brought up, never addressed** |

**At the end you should see** (last few lines):

```
   + systemctl restart v150-switch.service
● v150-switch.service
     Active: active (exited)
```

and earlier, `chip id` must read `0x0a01  (88E6190X) OK`.
**If the chip ID cannot be read** the module never reached MDIO — see
[If the install fails](#if-the-install-fails).

### Step 2: confirm the eight ports

```sh
sudo v150-status.sh
```

In the `switch ports` table the eight front-panel ports must have `PVID` = `1`..`8`
(panel number = VLAN):

```
  PORT   LNK  SPEED  CMODE  PVID
  1      0    -      0xf    4      <- panel 4
  2      0    -      0xf    3      <- panel 3
  3      1    1G     0x9    1      <- panel 1 (SFP)
  4      0    -      0xf    2      <- panel 2 (SFP)
```

`LNK=0` is not an error — it just means nothing is plugged in. Panels 1/2 are
SFP, and `CMODE=0xf` is normal when no module is inserted.

### Step 3: plug a cable in

Plug a cable into **panel 3** (copper) with a peer machine on the other end:

```sh
# panel 3 -> VLAN 3 -> enp5s0f1.3  (see "Port map")
sudo ip addr add 192.168.50.1/24 dev enp5s0f1.3
sudo ip link set enp5s0f1.3 up

# peer runs 192.168.50.2/24, then
ping -c 3 192.168.50.2
```

**If that pings, you are done** — panel → switch → VLAN → uplink → host, the whole
path. Same for any other panel; the VLAN id is the panel number.

**Not sure which panel the cable went into?** You can tell without any IP:

```sh
for i in enp5s0f1.{1,3,4,5} enp5s0f0.{2,6,7,8}; do
  printf '%-16s %s\n' "$i" "$(cat /sys/class/net/$i/statistics/rx_packets 2>/dev/null || echo -)"
done
sleep 8
# run it again - whichever counter moved is the panel you used
```

(In the repo directory, `sudo ./tools/vlan_mon.sh 8` does this for you and
highlights the active interface.)

> Do **not** use `tcpdump -i enp5s0f0` to look for VLAN tags — `ixgbe` strips
> the tag into the descriptor and you will never see it. Watch the VLAN
> sub-interface's `rx_packets` instead.

---

## After the install

Three commands are on PATH:

| Command | Purpose |
|---|---|
| `sudo v150-status.sh` | read-only health report, safe to run any time |
| `sudo v150-vlans.sh create\|delete\|show` | create / delete / inspect the eight host VLAN sub-interfaces |
| `sudo v150-switch-bringup.sh` | re-program the switch (systemd runs this at boot) |

Configuration lives in `/etc/default/v150-switch`. If a kernel upgrade renames
the interfaces, just re-run `sudo ./install.sh`.

Uninstall: `sudo ./install.sh --uninstall` (keeps `/etc/default/v150-switch`).

---

## More documentation

| Document | Read it when |
|---|---|
| [docs/REGISTER-REFERENCE.md](docs/REGISTER-REFERENCE.md) | you need the 88E6190X register / bit-field reference (bilingual) |
| [docs/TECHNICAL-NOTES.md](docs/TECHNICAL-NOTES.md) | you want the dead ends and why they were dead ends (bilingual) |
| [docs/BACKPLANE-2.5G.md](docs/BACKPLANE-2.5G.md) | why the 2.5G backplane never comes up — evidence chain, vendor datasheet cross-check, four on-hardware experiments (Chinese) |
| "Why not DSA" / "How it works" below | you intend to change the code or port it to another board |

---

## Why not DSA

The obvious approach is to register the 88E6190X as an MDIO device and let the
mainline `mv88e6xxx` DSA driver take over. That is what
[`rzsn/firebox-m270`](https://github.com/rzsn/firebox-m270) tries on very
similar hardware (WatchGuard M270: same Atom C3000 + X553 Backplane + 88E6190),
and it gets stuck:

- the 8 ports enumerate and report 1G, but **no packets flow**
- `Link detected: no` on the CPU port
- `mv88e6xxx` refuses multiple conduits; the CPU port never gets link registration

The same dead end applies here. DSA on this board has to fight:

1. **Two CPU ports** (switch ports 9 and 10) — `mv88e6xxx` wants a single conduit.
2. **X553 Backplane has no PHY.** `ethtool` reports
   `Supported ports: [FIBRE]`, `2500baseT/Full`, `Port: Other`, `PHYAD: 0`,
   and no `phydev`. `dsa_slave_create()` has nothing sensible to attach to.
3. **DSA tagging** adds 4–8 bytes on the CPU link and needs the CPU port to be
   in a specific frame mode.

So instead:

| Layer | What it is | Responsibility |
|---|---|---|
| Kernel | `v150_mdio.ko` (~150 lines) | **Transport only.** Walks `enp5s0f0` → `ixgbe-mdio` bus → `mdiobus_read/write`, exports `/proc/v150_mdio` |
| Userspace | `scripts/v150-switch-bringup.sh` + `scripts/v150_sw.sh` (POSIX sh) | **All switch logic**: SMI protocol, PHY/SerDes power-up, VTU entries, port modes |
| Boot | `systemd/v150-switch.service` (oneshot) | Runs the script once at boot |

The kernel module knows nothing about the 88E6190X. It does not create netdevs,
does not bridge, does not touch switchdev. Linux just sees two ordinary
`ixgbe` NICs plus 802.1Q VLAN sub-interfaces.

**Trade-offs** (accepted):

- No per-port netdev → cannot apply `tc` shaping, `ethtool`, or port mirroring per physical port
- Hardware FDB is not exported
- VLAN config is a static table; re-run the script after changing it
- No SFP hotplug detection

**Benefits:**

- Zero data-plane cost — all forwarding is hardware
- Survives kernel upgrades (no dependence on DSA internals)
- Sidesteps both DSA blockers above
- Fully readable/diffable configuration; debugging means reading registers

---

## Hardware

Silicom `80500-0150-G02` — Intel Atom C3000 (Denverton) uCPE.

```
Panel 1 (SFP) ── switch port 3 ─┐
Panel 2 (SFP) ── switch port 4 ─┤
Panel 3       ── switch port 2 ─┤
Panel 4       ── switch port 1 ─┤   Marvell 88E6190X
Panel 5       ── switch port 6 ─┤   MDIO address 0x10
Panel 6       ── switch port 5 ─┤   chip ID reads 0x0a01 (rev 1)
Panel 7 (PoE) ── switch port 8 ─┤
Panel 8 (PoE) ── switch port 7 ─┘
                switch port 9   ─── PCI 05:00.1 ─── enp5s0f1 ┐
                switch port 10  ─── PCI 05:00.0 ─── enp5s0f0 ┼ Intel X553 Backplane
                switch port 0   ─── RGMII ──────── bmc0      ┘
i210 (PCI 03:00.0) ─── enp3s0   (independent management NIC)
```

Notes:

- Front-panel ports are mapped to switch ports **in swapped pairs**, not sequentially.
- PoE is on panels 7 and 8.
- Switch port 0 (XMII/RGMII) is wired to the BMC and is deliberately left alone.
- The 88E6190X has only three SerDes: port 0, port 9 and port 10. Ports 3 and 4
  use a separate Clause-45 PHY behind the SFP cages (see below).

---

## How it works

### Indirect SMI access

The switch is reached over the MDIO bus at SMI address `0x10`, using the
standard Marvell indirect register protocol:

```
SMI_CMD  = 0x00        SMI_DATA = 0x01
cmd = BUSY(0x8000) | MODE_22(0x1000) | OP | (dev << 5) | reg
OP_22_READ  = 0x0800
OP_22_WRITE = 0x0400
dev:  port N = N,  Global1 = 0x1b,  Global2 = 0x1c
```

**Every write must wait for `CMD.BUSY == 0` *before* writing the data register.**
Otherwise the write is silently discarded — this is the single most common cause
of "my writes do nothing".

`sw_r()` must also treat any read error as failure, never as `0`.

### Bus borrowing (why the kernel module is tiny)

`ixgbe` in Backplane mode registers an `mdio_bus` named `ixgbe-mdio` (it is
created because the MAC advertises a PHY that does not exist). Nothing uses it.
`v150_mdio.ko` locates it and forwards `/proc/v150_mdio` requests to it:

```c
dev_get_by_name(&init_net, "enp5s0f0")
  -> device_find_child(dev, "ixgbe-mdio", ...)
  -> to_mii_bus(bus)
  -> mdiobus_read(bus, smi_addr, reg) / mdiobus_write(...)
```

`/proc/v150_mdio` accepts exactly two commands:

```
r <smi> <reg>          -> "val=0x...."   (or "ERR...")
w <smi> <reg> <value>  -> "ok"
```

This avoids writing an I2C/GPIO bit-banger and avoids touching PCI BARs.

---

## Install details

You do not need this section if the three steps above worked.

**There are no dependencies beyond kernel headers and a toolchain** — no
`mv88e6xxx`, no DSA, no switchdev.

### Manual

```sh
# 1. build and load the MDIO bridge
make
cp -f kernel/v150_mdio.ko /lib/modules/$(uname -r)/extra/
depmod -a && modprobe v150_mdio
ls -l /proc/v150_mdio

# 2. install and run the bring-up
install -m755 scripts/v150-switch-bringup.sh /usr/local/sbin/
install -m755 scripts/v150-status.sh         /usr/local/sbin/
install -m755 scripts/v150-vlans.sh          /usr/local/sbin/
install -m644 scripts/v150_sw.sh             /usr/local/lib/v150/
install -m644 systemd/v150-switch.service    /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now v150-switch.service
```

### What the status report shows

`sudo v150-status.sh` prints five sections:

| Section | What to look at |
|---|---|
| `module` | is `/proc/v150_mdio` present, which netdev the module bound to, is the chip ID right |
| `uplinks` | carrier and speed of both X553 — must be 1000 |
| `switch ports` | LNK / SPEED / CMODE / PVID of all ten ports |
| `host VLAN interfaces` | are the eight sub-interfaces there, do they have addresses |
| `service` | is the systemd unit active / enabled |

### Where the netdev names come from

`install.sh` finds the two X553 uplinks by PCI device ID `8086:15c2` and writes
the result to `/etc/default/v150-switch`:

```sh
V150_CPU_IF0=enp5s0f0     # switch port 10
V150_CPU_IF1=enp5s0f1     # switch port  9
```

Every script (`v150-switch-bringup.sh` / `v150-vlans.sh` / `v150-status.sh` /
`vlan_mon.sh`) resolves them in this order:

```
environment variable  >  /etc/default/v150-switch  >  built-in enp5s0f0/enp5s0f1
```

So if a kernel upgrade renames the interfaces, just re-run `sudo ./install.sh` —
no script edits needed. To try other names ad hoc:

```sh
sudo V150_CPU_IF0=eno1 V150_CPU_IF1=eno2 ./scripts/v150-status.sh
```

> The built-in defaults `enp5s0f0` / `enp5s0f1` are PCI `05:00.0` / `05:00.1`.
> Those bus addresses are fixed on the IA3000; only the kernel naming scheme varies.

### VyOS

VyOS rewrites `/usr` and `/etc` on image upgrade but keeps `/config`, so there is
a dedicated script:

```sh
sudo ./vyos/setup.sh                 # builds locally if headers exist, else use --ko
sudo ./vyos/setup.sh --ko /path/v150_mdio.ko
```

It puts everything under `/config/scripts/v150/` and installs a
`/config/scripts/vyos-postconfig-bootup.script` hook that re-installs the module
for the running kernel and re-programs the switch on every boot.

> **Implementation note.** This project needs a kernel module, and VyOS normally
> ships neither a compiler nor headers for its running kernel. So on VyOS there
> are only two paths: install matching headers, or build the `.ko` for the same
> kernel version elsewhere and copy it over. That is a different trade-off from
> a pure-userspace approach that pokes `/dev/mem` directly — that needs no build
> step, but has to handle PCI BARs and timing itself.

### Two gotchas that cost hours

> - `install -m644` once produced a **0-byte `.ko`** (`md5 d41d8cd9...`), which
>   makes `modprobe` fail with `Invalid parameters`. The installer uses `cp -f` instead.
> - Do **not** use `Before=network-pre.target`. At that point udev has not
>   enumerated PCI yet, `ixgbe` is not bound, and the module cannot find the MDIO
>   bus. `After=network.target` works.

---

## Port map

Verified by polling all eleven switch ports' link bits while moving a cable
panel by panel:

| Panel | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Type | **SFP** | **SFP** | RJ45 | RJ45 | RJ45 | RJ45 | RJ45 PoE | RJ45 PoE |
| switch port | **3** | **4** | **2** | **1** | **6** | **5** | **8** | **7** |
| VLAN | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| uplink | CPU 9 | CPU 10 | CPU 9 | CPU 9 | CPU 9 | CPU 10 | CPU 10 | CPU 10 |

CPU-port to Linux interface mapping — **this is easy to get backwards**:

| Linux | PCI BDF | switch port |
|---|---|---|
| `enp5s0f1` | `0000:05:00.1` | **9** |
| `enp5s0f0` | `0000:05:00.0` | **10** |

Always confirm with `readlink -f /sys/class/net/enp5s0f0/device`.
Multi-port PCIe functions are **not** ordered the way you expect.
Getting this wrong makes every VLAN test fail in a way that looks like a
switch bug (one direction "works", the other silently black-holes).

---

## VLAN layout

One VLAN per front-panel port, id = panel number, 4 + 4 split across the two uplinks:

```
VLAN 1  panel 1  sw3 (SFP)  untagged -> CPU 9   tagged
VLAN 2  panel 2  sw4 (SFP)  untagged -> CPU 10  tagged
VLAN 3  panel 3  sw2        untagged -> CPU 9   tagged
VLAN 4  panel 4  sw1        untagged -> CPU 9   tagged
VLAN 5  panel 5  sw6        untagged -> CPU 9   tagged
VLAN 6  panel 6  sw5        untagged -> CPU 10  tagged
VLAN 7  panel 7  sw8        untagged -> CPU 10  tagged
VLAN 8  panel 8  sw7        untagged -> CPU 10  tagged
VLAN 100 CPU 9 + CPU 10, both untagged (plain L2 path for the host)
```

Per VLAN: one VTU entry with the front port `01` (untagged member), the matching
CPU port `10` (tagged member), everything else `11` (discard); `FID = VID`;
front port `PVID = panel number`; all ports `PORT_CTL2 = Secure`.

Concrete VTU bitmaps (`DATA1` covers ports 0–7, `DATA2` bit1:0/3:2/5:4 = ports 8/9/10):

```
VID 1:   D1=0xff7f D2=0x003b      VID 5:   D1=0xdfff D2=0x003b
VID 2:   D1=0xfdff D2=0x002f      VID 6:   D1=0xf7ff D2=0x002f
VID 3:   D1=0xffdf D2=0x003b      VID 7:   D1=0xffff D2=0x002b
VID 4:   D1=0xfff7 D2=0x003b      VID 8:   D1=0x7fff D2=0x002f
VID 100: D1=0xffff D2=0x0017
```

Host side:

```sh
# panels 1, 3, 4, 5 -> enp5s0f1 (switch port 9)
for v in 1 3 4 5; do
  ip link add link enp5s0f1 name enp5s0f1.$v type vlan id $v
  ip link set enp5s0f1.$v up
done

# panels 2, 6, 7, 8 -> enp5s0f0 (switch port 10)
for v in 2 6 7 8; do
  ip link add link enp5s0f0 name enp5s0f0.$v type vlan id $v
  ip link set enp5s0f0.$v up
done
```

Persist them in `/etc/network/interfaces` (or your distro's equivalent), or attach
each VLAN interface to its own bridge for a software-router / VM setup.

---

## The five things you must get right

| # | Item | Why it matters |
|---|---|---|
| 1 | Wait for `CMD.BUSY == 0` **before** writing `SMI_DATA` | Otherwise the write is silently dropped. Every "write does nothing" case traced back to this |
| 2 | Power up the front-panel copper PHYs | Cold state is `BMCR = 0x1940` (PDOWN set). Write `0x1340` |
| 3 | **Power up the SFP SerDes explicitly** | Without it the port stays `CMODE=0xf`, `LINK=0` forever — looks like dead hardware. See below |
| 4 | Clear `PORT_CTL2` bits 13:12 on the CPU ports | Leaving the JUMBO field set (`0x2000`/`0x1000`) makes **CPU↔CPU completely dead**, and asymmetrically — one direction passes, the other black-holes. Extremely misleading |
| 5 | Use 802.1Q **Secure** mode with a VTU entry per VID | In Secure mode a VID with no VTU entry is dropped. Egress tagging is decided by the VTU member type, not by `PORT_CTL0` |

---

## SFP cages need explicit SerDes power-up

Panels 1 and 2 (switch ports 3 and 4) sit behind a Clause-45 PHY/SerDes that is
**powered down at reset**. Since `CMODE` is a read-only status field, the port
cannot be switched to 1000BASE-X by writing it — you have to power the SerDes up
and let the port follow.

The sequence was recovered by inspecting the vendor's dataplane plugin
(`libfal-mvl.so.1`, a DPDK FAL plugin shipped in the official OS image):

```asm
call msdPhyPortPowerDown          ; power the port's PHY up/down (powerDown = !enable)
cmpl $0x3, 0x54(%rbx)             ; only proceed when port type == 3  (SFP)
mov  $0x9140, %r8d                ; data
mov  $0x2000, %ecx                ; register 0x2000 = SGMII / SerDes control
mov  $0x4,    %esi                ; MMD 4 = PCS / PHY-XS
lea  0x10(%rax), %edx             ; ***** phyAddr = port + 0x10 *****
call msdSetSMIC45PhyReg           ; Clause-45 write
```

Register-level equivalent:

```
Clause-45, MMD 4, PHY address = port + 0x10, register 0x2000, value 0x9140
```

```sh
xs_w 3 0x2000 0x9140      # SFP 1
xs_w 4 0x2000 0x9140      # SFP 2
```

### The trap: the C45 PHY address is `port + 0x10`, not `port`

| Port | PHY addr | MMD4 reg 0x2000 | Meaning |
|---|---|---|---|
| sw3 | `0x03` (wrong) | `0x0000` | nothing answers — easily mistaken for "no SerDes present" |
| sw3 | **`0x13`** (right) | **`0x1940`** | PDOWN = 1, powered down |
| sw4 | **`0x14`** (right) | **`0x1940`** | same |

`0x1940` is the same bit pattern the copper PHYs report at cold boot (PDOWN).
The vendor value `0x9140` clears PDOWN and sets bit 15.

After the write the port transforms itself:

```
before:  sw3 STS=0x100f  LINK=0  CMODE=0xf   (internal-PHY mode)
after :  sw3 STS=0xde09  LINK=1  CMODE=0x9   (1000BASE-X)
```

**`CMODE` is read-only — do not try to write it.** Writing `0x9` always reads back
`0xf`, even with the port disabled. It only changes as a consequence of SerDes
power state. Chasing this the wrong way led to the (wrong) conclusion that the
SFP cages were not wired at all.

SerDes power state **persists**: unplugging a module drops `LINK` but `CMODE`
stays `0x9`, so re-inserting a module needs no re-run. A full reboot does.

---

## Measured results

Throughput: single TCP stream, 10 s, host → peer. Latency: 1400-byte ICMP.

| Panel | Type | Uplink | Throughput | Latency | Loss |
|---|---|---|---|---|---|
| 1 | SFP (fibre→copper module) | CPU 9 | **921.5 Mbps** | 0–3 ms | 0% |
| 2 | SFP (fibre→copper module) | CPU 10 | **922.4 Mbps** | 0–3 ms | 0% |
| 3 | RJ45 | CPU 9 | **901.9 Mbps** | 0–5 ms | 0% |
| 7 | RJ45 PoE | CPU 10 | **925.6 Mbps** | 0–2 ms | 0% |
| 8 | RJ45 PoE | CPU 10 | **920.0 Mbps** | 0–2 ms | 0% |

1 GbE practical ceiling is ~940 Mbps, so all tested ports are at line rate.

**VLAN isolation is enforced in hardware.** With a peer generating UDP broadcast
on one panel, only that panel's VLAN interface counts packets; the other seven
VLAN interfaces receive exactly zero.

---

---

## If the install fails

### `chip id` cannot be read / is not `0x0a01`

```
   ! could not read the chip id over the indirect SMI protocol
```

Check in this order:

1. `ls -l /proc/v150_mdio` — did the module load?
2. `dmesg | grep v150` — does the module complain it cannot find `ixgbe-mdio`?
3. `ip -br link | grep -E 'enp|eth'` — what are the two X553 interfaces called?
4. If the names are not `enp5s0f0`/`enp5s0f1`: `sudo ./install.sh --cpu-if0 <n> --cpu-if1 <m>`

### `no X553 Backplane (8086:15c2) netdev found`

`lspci -nn | grep 15c2` shows them but `ip link` does not — the driver is not bound:

```sh
lspci -nnk -s 05:00.0        # look at "Kernel driver in use:"
modprobe ixgbe
```

### `no kernel build tree at /lib/modules/.../build`

Kernel headers are missing:

```sh
apt install pve-headers-$(uname -r)      # PVE
apt install linux-headers-$(uname -r)    # Debian
```

On PVE, if `pve-headers` will not install, align the versions with
`apt update && apt full-upgrade` first.

### Networking died right after the install

`install.sh` only creates VLAN sub-interfaces. It assigns no addresses and
changes no routes, so it should not be able to break management access. If it
did:

```sh
# recover in place, no reboot needed
sudo v150-vlans.sh delete
sudo systemctl stop v150-switch

# or start over
sudo ./install.sh --uninstall
```

### `install -m644` produced a zero-byte .ko

Rare, but on some filesystems `install` misbehaves. Pass the module explicitly:

```sh
make && sudo ./install.sh --ko ./kernel/v150_mdio.ko
```

---

## Troubleshooting

> This section is about problems **after** a successful install. If you cannot
> install at all, see the previous section.

### Link is up but no traffic passes

Check, in this order:

1. `sw_r <port> 0x08` — is `PORT_CTL2` bits 11:10 set to `0x0c00` (Secure)?
2. Is there a VTU entry for the VID, with this port as `01` and the CPU port as `10`?
3. Is the port's `PVID` (`0x07`) the expected VID?
4. On the CPU port, are bits 13:12 of `PORT_CTL2` **clear**?
5. Are you reading the right CPU port? (see [Port map](#port-map))

### "My register writes do nothing"

You are almost certainly writing `SMI_DATA` before `CMD.BUSY` clears.
`tools/v150_sw.sh` handles this; ad-hoc snippets often do not.

### Port shows `CMODE=0xf`, `LINK=0`, and nothing helps

For ports 3/4 that is the expected un-powered SFP state — see above.
For ports 1/2/5/6/7/8, the copper PHY needs `BMCR` power-down cleared.

### Determining whether a frame is really tagged

Two useful tricks, both used to solve this port:

1. **Use `DISCARD_TAGGED` as a tag probe.** Set bit 9 of `PORT_CTL2` (`0x0200`)
   and send tagged frames. If they are dropped, the tag *is* reaching the switch —
   the problem is elsewhere.
2. **Do not trust `AF_PACKET` captures for VLAN tags.** `ixgbe` strips 802.1Q tags
   into the receive descriptor; a raw socket sees a 60-byte untagged frame while
   the VLAN sub-interface happily receives it. **Only `rx_packets` on the VLAN
   interface proves the tag survived.**

### Generating traffic from a Windows peer

Do not rely on `ping`. Once Windows' ARP entry goes to the failed state it stops
transmitting **entirely**, which looks exactly like a dead link. Use UDP broadcast:

```powershell
$u = New-Object System.Net.Sockets.UdpClient
$u.EnableBroadcast = $true
$ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('192.168.50.255'), 9999)
$b = [System.Text.Encoding]::ASCII.GetBytes('TEST')
1..80 | % { [void]$u.Send($b, $b.Length, $ep); Start-Sleep -Milliseconds 100 }
$u.Close()
```

`tools/vlan_mon.sh` prints per-VLAN `rx_packets`/`rx_bytes` deltas and marks the
active VLAN — the fastest way to find out which panel the cable is really in.

### Small-packet latency jitter

Some USB Ethernet adapters enable selective suspend and EEE, giving 300–700 ms
pings on 32-byte packets while 1400-byte packets stay at 1–2 ms. Compare the two
packet sizes before blaming the switch.

---

## Known limitations

- **1 Gbps per uplink.** Panels 1/3/4/5 share CPU port 9's 1 Gbps; panels
  2/6/7/8 share CPU port 10's. A single port reaches ~920 Mbps; four ports
  saturating at once will contend.
- **2.5 Gbps not achieved.** The vendor firmware logs
  `Backplane speed is 2.5G for port 9/10` and `Backplane tuning is 0x1724`,
  so the hardware supports it, but the matching SerDes tuning sequence is not
  implemented here. Currently both uplinks run 1000BASE-X.
- No per-port netdev (no per-port `tc`, mirroring, or `ethtool`).
- Hardware FDB not exported.
- No SFP hotplug handling; SerDes state persists across module swap but not reboot.
- Ports are hard-coded for this board layout.

---

## Repository layout

```
install.sh                    one-shot installer (PVE / Debian), --dry-run / --uninstall
uninstall.sh                  same as install.sh --uninstall
get.sh                        curl | sudo bash helper
Makefile                      make / make clean
dkms.conf                     DKMS support (used by --dkms)

kernel/
  Makefile                    obj-m := v150_mdio.o
  v150_mdio.c                 the /proc/v150_mdio MDIO bridge (only C code here)
systemd/
  v150-switch.service         oneshot unit, reads /etc/default/v150-switch

scripts/
  v150_sw.sh                  register library: SMI / C45 / C22 / VTU / SFP (C45 at port+0x10)
  v150-switch-bringup.sh      this board's bring-up sequence (everything else is the library)
  v150-vlans.sh               create / delete / show host VLAN sub-interfaces
  v150-status.sh              read-only health report

vyos/
  setup.sh                    VyOS installer (persists under /config)

tools/
  c2c.py                      raw frame sender / sniffer (VLAN-aware; essential for tag debugging)
  tcpsink.py                  TCP throughput sink
  vlan_mon.sh                 per-VLAN rx counters (find which panel the cable is in)
  port_watch.sh               all-port link + netdev change logger (used to measure the port map)

docs/
  REGISTER-REFERENCE.md       register/bitfield reference (Chinese)
  REGISTER-REFERENCE.en.md    same, English
  TECHNICAL-NOTES.md          what was tried, what failed, and why (Chinese)
  TECHNICAL-NOTES.en.md       same, English
  BACKPLANE-2.5G.md           full investigation of the dead 2.5G backplane (Chinese)
```

---

## References

- [FreeBSD wiki: NetworkFirewalls/AttV150](https://wiki.freebsd.org/NetworkFirewalls/AttV150) — `e6000sw` hints for this board
- [FreeBSD `sys/dev/etherswitch/e6000sw/`](https://cgit.freebsd.org/src/plain/sys/dev/etherswitch/e6000sw/e6000sw.c) — register constants and port bring-up order
- [Linux `drivers/net/dsa/mv88e6xxx/port.h`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/net/dsa/mv88e6xxx/port.h) — authoritative bitfield definitions
- [Silicom uBMC](https://github.com/silicom-ltd/uBMC) — BMC side of this platform
- [`wkz/mdio-tools` issue #35](https://github.com/wkz/mdio-tools/issues/35) — same board, MDIO address and vendor platform-config discussion
- [`rzsn/firebox-m270`](https://github.com/rzsn/firebox-m270) — same silicon, DSA attempt
- [`FusionPlmH/vep1400-linux-non_dsa-driver`](https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver) — non-DSA approach on related hardware

---

## License

MIT — see [LICENSE](LICENSE).

Register values and sequences in this repository were obtained by observation of
the hardware and by inspecting publicly available kernel sources. No vendor
confidential material is included.
