# Technical notes — how this was figured out, and what did not work

**简体中文** | [English](TECHNICAL-NOTES.en.md)

A record of the dead ends, so nobody has to repeat them.

---

## 1. Chosen approach

**Register-level programming from userspace over a borrowed MDIO bus.**

Alternatives considered:

| Option | Verdict |
|---|---|
| DSA via mainline `mv88e6xxx` | Rejected — two CPU ports, no PHY on X553 Backplane, DSA tagging on a link that will not negotiate properly. `rzsn/firebox-m270` documents the same dead end on essentially identical hardware |
| Register as an MDIO device and use `mdio-tools` / `mvls` | `mvls` reads its data from `devlink` memory regions published by the DSA driver, so it needs DSA first |
| Write a full switchdev driver | Much more kernel work for the same result |
| Vendor SDK / DPDK FAL plugin | Takes the CPU ports away from the kernel; incompatible with running a normal Linux host with VMs and bridges |
| **Borrow `ixgbe-mdio`, drive registers from a shell script** | **Chosen** — zero data-plane cost, tiny kernel surface, survives kernel upgrades |

### Why borrowing the bus works

`ixgbe` in Backplane mode registers an `mdio_bus` named `ixgbe-mdio` (created
because the MAC reports a PHY that physically is not there — `ethtool` shows
`Supported ports: [FIBRE]`, `2500baseT/Full`, `Port: Other`, `PHYAD: 0`, no `phydev`).
Nothing consumes that bus. The kernel module walks
`enp5s0f0 → device_find_child("ixgbe-mdio") → to_mii_bus()` and forwards
`/proc/v150_mdio` reads/writes to it.

This is what makes the whole thing ~150 lines of kernel code with no PCI or
timing work.

---

## 2. Dead ends worth recording

### 2.1 Silent SMI writes (the #1 time sink)

Three separate bugs, all making writes appear to do nothing:

1. **No pre-write `BUSY` poll.** `SMI_DATA` must be loaded while `CMD.BUSY` is 0.
   Writing it early is discarded without any error.
2. **Read errors coerced to 0.** A shell helper doing
   `v=${v#*val=0x}; $((0x$v))` leaves the string untouched on an error line,
   and the arithmetic silently evaluates to 0. Always validate the reply shape.
3. **AN needs advertisement before enable.** Writing `PCS_CTL1` first and
   advertisement second does not stick.

After fixing all three, register writes started working immediately.

### 2.2 2500BASE-X never links

`CMODE = 0xb` + `PORT_MAC = 0x313f` never produces a link on either CPU port.
`PCS_CTL1` on these ports reads `0x2140` and is effectively read-only, so
advertisement / AN-enable / loopback cannot be programmed at all.
The vendor firmware logs `Backplane speed is 2.5G for port 9/10` and
`Backplane tuning is 0x1724`, so 2.5G is achievable in principle — that specific
SerDes tuning is simply not part of this project. Everything here runs at 1 Gbps.

### 2.3 The X553 `NW_MNG_IF_SEL` strap is not the blocker

An early version of this project shipped a small kernel module that patched
`BAR0 + 0x11178` using `(old & ~GENMASK(21,17)) | (2500 ? BIT(20) : BIT(19)) | BIT(25)`,
following the reference code for related hardware.

The original value on this board was `0x00102002`, **already carrying BIT(20)**.
Adding BIT(25) changed nothing about link behaviour. Dead end.

**That code has been removed from the repository.** The conclusion stays:
do not touch the strap, it has nothing to do with links failing to come up.
The real causes were SerDes power state and the 802.1Q mode field (see 2.5 and 3).

### 2.4 The DiagOS page-0xF8 recipe wedges a 6190X

```
page 0xf8, reg 0x08 = 0x0036
page    0, reg 0x14 = 0x8020
```

This is the 6190 **non-X** PHY programming sequence. On a 6190X it permanently
breaks Clause-22 access — every read afterwards returns the command echo
(`(port << 5) | reg`) instead of data. Only a cold power cycle recovers.
The minimal correct copper power-up is 3 writes (see REGISTER-REFERENCE §7).

### 2.5 "Link up, host receives, host cannot transmit"

This was the longest-running symptom. Two independent causes stacked:

**Cause A — wrong 802.1Q mode bit position.** Believing the mode lived in
`PORT_CTL2` bits 13:12 (the value FreeBSD's `e6000swreg.h` carries, which is
correct for older chips) meant every "set the VLAN mode" write actually wrote the
**jumbo frame** field. The 802.1Q mode was never changed.

**Cause B — CPU port mapping reversed.** `enp5s0f0` is switch port **10**, not 9.
For a long stretch, VLAN tags were being applied to the port that was not being
observed, which produced erratic, apparently random results
("1 in 4 packets", "0 of 6 packets").

Diagnostic that finally separated switch-side from NIC-side: **set
`DISCARD_TAGGED` (bit 9, `0x0200`) on `PORT_CTL2` and send tagged frames.**
If they disappear, the tag *is* arriving at the switch and the switch is
classifying frames correctly — the problem is admission/egress, not the NIC.
That single test invalidated the "the X553 is stripping tags" hypothesis.

### 2.6 `AF_PACKET` captures lie about VLAN tags

`ixgbe` strips 802.1Q tags into the receive descriptor. A raw socket sees a
60-byte untagged frame; the VLAN sub-interface receives the traffic perfectly.
Judging tag presence from `tcpdump` / `AF_PACKET` led to a long false conclusion
that tags were being removed. **Only the VLAN interface's `rx_packets` proves it.**

### 2.7 Windows peers stop transmitting

If a Windows host's ARP entry for the peer goes to the failed state, Windows
stops sending **entirely** for that destination. Ping tests then look like a
completely dead link. UDP broadcast to the subnet broadcast address is a reliable
traffic source (`tools/vlan_mon.sh` + a broadcast blast is how the port map was
measured). `ping` with a 22-packet run and a single "destination host unreachable"
reply is a strong signal of this, not of a cable problem.

### 2.8 `PORT_CTL0` EGRESS_MODE is not the egress tagging control

Setting `PORT_CTL0` bits 13:12 to TAGGED (`0x2000`) produced no observable
change. Egress tagging is decided by the **VTU member type** (`01` untagged,
`10` tagged). Do not add this write; it only adds a way to confuse yourself.

### 2.9 `FID = 0` versus `FID = VID`

Using a single shared FID for every VLAN made delivery noticeably less reliable.
Assigning `FID = VID` gives each VLAN an independent forwarding database and
works consistently. (Vendor configuration for the same board also groups the
front ports with distinct FIDs.)

---

## 3. SFP cages: how the sequence was found

Panels 1 and 2 (switch ports 3 and 4) behaved exactly like internal-PHY ports:
`CMODE` refused to change from `0xf`, Clause-22 reads worked, and nothing on the
switch responded at the SerDes-level addresses. The natural conclusion was
"these cages are not wired to the switch".

That conclusion was wrong. Working through the platform's dataplane plugin
(`libfal-mvl.so.1`, a DPDK FAL plugin present in the official OS image) showed a
dedicated SFP path:

```asm
call msdPhyPortPowerDown
cmpl $0x3, 0x54(%rbx)             ; port type 3 == SFP
mov  $0x9140, %r8d
mov  $0x2000, %ecx                ; reg 0x2000
mov  $0x4,    %esi                ; MMD 4
lea  0x10(%rax), %edx             ; phy address = port + 0x10
call msdSetSMIC45PhyReg
```

**`phy address = port + 0x10`** was the missing piece. Probing at that address:

```
port 3, phy 0x13, MMD4 reg 0x2000 = 0x1940    <- PDOWN set
port 4, phy 0x14, MMD4 reg 0x2000 = 0x1940
```

Writing `0x9140` there brings the port up at 1000BASE-X, and traffic flows at
line rate. Two fibre-to-copper modules were tested, one in each cage.

**Lesson:** `CMODE` is a status field. When a port refuses to enter
1000BASE-X, look for something that must be powered up, not for a register to
write. And when a SerDes seems absent, check for an alternate PHY address before
concluding there is no hardware.

---

## 4. Port mapping: how it was measured

Instead of trusting documentation, a watcher polled the link bit
(`PORT_STS` bit 11) of **all eleven switch ports** once per second and printed a
line whenever the set of linked ports changed. A cable was then moved from panel
to panel:

```
12:27:51  link-up: 2   =>  panel 3
12:28:09  link-up: 1   =>  panel 4
12:28:17  link-up: 6   =>  panel 5
12:28:27  link-up: 5   =>  panel 6
12:28:37  link-up: 8   =>  panel 7
```

That produced the swapped-pair mapping. The result also matches the
`sw_port=` table in the vendor's platform configuration, which confirms both.

CPU ports were identified from PCI BDFs (`readlink -f /sys/class/net/*/device`),
not from interface names.

---

## 5. Verification method

**Isolation** is proven with counters, not with hope:

```sh
# on the host, count packets per VLAN interface
tools/vlan_mon.sh 8
```

while the peer blasts UDP broadcast. Expected result: the matching VLAN interface
counts ~68 of 73 frames, every other VLAN interface counts exactly 0.

**Throughput** uses `tools/tcpsink.py` (a deliberately trivial TCP sink) with a
plain `TcpClient` on the peer, 10-second window, measuring goodput.

**Why a trivial sink:** any cleverness in the sink (small blocks, `select`,
buffering) masks line-rate behaviour. The sink writes 256 KiB blocks in a
`while` loop for a fixed duration and reports what it actually sent.

---

## 6. Operational notes

- The bring-up script is **idempotent**; re-running it re-applies all state.
- Concurrent access to `/proc/v150_mdio` from two processes produces garbage
  reads (chip ID comes back as `0x100f` instead of `0x0a01`). Kill any watchers
  before diagnosing.
- `pkill -f <pattern>` will match and kill your own SSH session if the pattern
  appears in the command line. Use a bracket pattern (`pkill -f 'link_watc[h]'`)
  or kill by `/proc/$pid/comm`.
- After a cable replug there is a 10–20 s ARP re-resolution window with packet loss.
- Module load must happen **after** udev has enumerated PCI (i.e. after
  `network.target`, not `network-pre.target`), otherwise `ixgbe` is not bound and
  the MDIO bus does not exist yet.

---

## 7. What is still open

- **2.5 Gbps on the CPU links.** Needs the SerDes tuning the vendor firmware
  applies (`Backplane tuning is 0x1724`). Would remove the 1 Gbps-per-uplink
  ceiling.
- **Per-port netdev.** Would enable per-port `tc`, mirroring and `ethtool`. The
  DSA blockers listed in §1 would have to be solved first.
- **FDB export.** Reading the ATU would make MAC learning visible.
- **SFP hotplug.** SerDes power state persists across a module swap but not
  across reboot; there is no event-driven re-power.
