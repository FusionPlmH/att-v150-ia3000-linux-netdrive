# Register reference — Marvell 88E6190X

**简体中文** | [English](REGISTER-REFERENCE.en.md)

Everything here was verified on real hardware (chip ID `0x0a01`, rev 1) unless
marked otherwise. Bitfield names follow the Linux `mv88e6xxx` driver, which is
authoritative for this family.

> `PORT_CTL2` bit positions differ between old Marvell chips (6095/6097) and the
> 6190X. FreeBSD's `e6000swreg.h` carries the **old-chip** offsets for the
> 802.1Q mode. Using those on a 6190X silently writes the wrong field.
> The values below are for **6190X / 6390X**.

---

## 1. Indirect SMI protocol

The switch sits on the MDIO bus at SMI address `0x10`.

```
SMI_CMD   = 0x00
SMI_DATA  = 0x01

cmd = BUSY(0x8000) | MODE_22(0x1000) | OP | (dev << 5) | reg

OP_22_READ  = 0x0800
OP_22_WRITE = 0x0400

dev encoding:
    port N     -> N
    Global 1   -> 0x1b
    Global 2   -> 0x1c
```

**Critical sequencing**

```
read:   wait BUSY==0 ; CMD = read-cmd  ; wait BUSY==0 ; DATA = result
write:  wait BUSY==0 ; DATA = value   ; CMD = write-cmd ; wait BUSY==0
```

The data register must be loaded **before** issuing the command, and only after
`BUSY` has cleared. Skipping the pre-write `BUSY` poll causes the write to be
dropped with no error indication.

Reads that fail must be reported as errors, never coerced to `0` — a naive
`${v#*val=0x}` leaves the error string intact and `$((0x$v))` silently yields 0.

---

## 2. Per-port registers

Base offset `0x00` on 6190X (old chips used `0x10`).

| Offset | Name | Notes |
|---|---|---|
| `0x00` | `PORT_STS` | bit11 LINK, bit10 DUPLEX, bits9:8 SPEED, **bits3:0 CMODE (read-only)** |
| `0x01` | `PORT_MAC` / `PSC_CONTROL` | CPU ports use `0x203e` |
| `0x02` | Flow control | |
| `0x03` | `PORT_SWITCH_ID` | reads `0x0a01` |
| `0x04` | `PORT_CTL0` | bits1:0 state, bits13:12 EGRESS_MODE |
| `0x05` | `PORT_CTL1` | trunk/FID high bits |
| `0x06` | `PORT_BASE_VLAN` | port map (`VLANMAP`) |
| `0x07` | `PORT_DEFAULT_VLAN` | PVID + priority, mask `0x0fff` |
| `0x08` | `PORT_CTL2` | see below |
| `0x09` | Egress rate control 1 | reads `0x0001` |
| `0x0a` | Egress rate control 2 | reads `0x8000` |
| `0x0b` | `PORT_ASSOC_VECTOR` | reads back only its own port bit |

### `PORT_STS` (0x00)

```
0x100f  no link, CMODE = 0xf (internal PHY)
0x1009  no link, CMODE = 0x9 (1000BASE-X)
0xde09  link up, 1G, full duplex, CMODE = 0x9   <- SFP after SerDes power-up
0x1e09  link up, 1G, full duplex, CMODE = 0x9   <- CPU port
0x0e07  link up, CMODE = 0x7 (RGMII, BMC port)
```

CMODE values:

| Value | Mode |
|---|---|
| `0x7` | RGMII |
| `0x8` | 100BASE-X |
| `0x9` | 1000BASE-X |
| `0xa` | SGMII |
| `0xb` | 2500BASE-X |
| `0xf` | internal PHY |

### `PORT_MAC` (0x01)

`0x203e` = speed 1000 + forced duplex + full duplex + forced link + link up +
forced speed (IPG 13), i.e. forced 1G full-duplex. Used on the CPU ports.

The 2500 variant (`0x313f`) never produces a working link on this board.

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

Factory value for ports 1–8 is `0x100f` (EGRESS_MODE = UNTAGGED, forwarding,
plus `0x000c` in the low bits). The bring-up script normalises to Forwarding only.

Setting `EGRESS_MODE = TAGGED` was tested and produced **no** observable change —
egress tagging is decided by the VTU member type.

### `PORT_CTL2` (0x08) — the one that bites

```c
#define MV88E6XXX_PORT_CTL2_IGNORE_FCS          0x8000
#define MV88E6XXX_PORT_CTL2_VTU_PRI_OVERRIDE    0x4000
#define MV88E6XXX_PORT_CTL2_SA_PRIO_OVERRIDE    0x2000
#define MV88E6XXX_PORT_CTL2_DA_PRIO_OVERRIDE    0x1000

#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_MASK     0x3000   /* bits 13:12 */
#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_1522     0x0000
#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_2048     0x1000
#define MV88E6XXX_PORT_CTL2_JUMBO_MODE_10240    0x2000

#define MV88E6XXX_PORT_CTL2_8021Q_MODE_MASK     0x0c00   /* bits 11:10 ***** */
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

Factory default is **`0x2c80`** = Secure (`0x0c00`) + JUMBO_10240 (`0x2000`) + MAP_DA (`0x0080`).
So the chip powers up **already in Secure mode** — an important detail when
debugging "why did my VLANs appear to work when I disabled 802.1Q?"

Bit-by-bit verification performed on hardware (single bit written at a time):

| Written | Untagged ingress | Tagged VID 200 ingress | Conclusion |
|---|---|---|---|
| `0x0000` / `0x1000` / `0x2000` / `0x3000` / `0x4000` / `0x8000` / `0xc000` | pass | **pass** | bits 15:12 have **no** effect on VLAN admission |
| `0x0100` | **drop** | pass | bit 8 = DiscardUntagged confirmed |
| `0x0200` | pass | **drop** | bit 9 = DiscardTagged confirmed |
| any other single low bit | pass | pass | no effect |

**Consequences**

- Writing `0x3000` or `0x2000` to "set the 802.1Q mode" writes the **jumbo** field.
- On the CPU ports the jumbo field must end up **clear**. `0x0c00` (JUMBO 2048)
  or `0x2000` (JUMBO 10240) makes CPU↔CPU traffic die, and asymmetrically.
- Use `0x0c00` for Secure and leave `0x3000` alone.

### `PORT_ASSOC_VECTOR` (0x0b)

Reads back only the bit for its own port (`0x0200` on port 9, `0x0400` on port 10,
`0x0008` on port 3, `0x0010` on port 4). Useful for confirming the port index
you think you are talking to.

---

## 3. VTU (VLAN table)

Registers live on **Global 1** (base `0x1b`).

| Offset | Name |
|---|---|
| `0x01` | `VTU_FID` companion / priority |
| `0x02` | `VTU_FID` (12 bits) |
| `0x05` | `VTU_OP` |
| `0x06` | `VTU_VID` |
| `0x07` | `VTU_DATA`  (ports 0–7) |
| `0x08` | `VTU_DATA2` (ports 8, 9, 10) |

`VTU_OP` bits:

```
BUSY     0x8000
LOAD     (3 << 12) = 0x3000
FLUSH    (1 << 12) = 0x1000
GET_NEXT (4 << 12) = 0x4000
```

`VTU_VID` bit 12 = `VTU_VID_VALID`.

### Member encoding — 2 bits per port

| Value | Meaning |
|---|---|
| `01` | untagged member (egress strips the tag) |
| `10` | tagged member (egress inserts the tag) |
| `11` | discard |
| `00` | not a member |

### Bit layout

- ports 0–7 → `VTU_DATA`, port *n* at bits `2n+1 : 2n`
- port 8 → `VTU_DATA2` bits 1:0
- port 9 → `VTU_DATA2` bits 3:2
- port 10 → `VTU_DATA2` bits 5:4

**Overflow trap:** `1 << (2*8)` = `1 << 16` overflows a 16-bit shell arithmetic
result and quietly corrupts `VTU_DATA`. Port 8 must go through `VTU_DATA2`.
A helper that switches on `port >= 8` avoids this entirely (see `vtu_member()`
in the bring-up script).

### Load sequence

```sh
wait VTU_OP.BUSY == 0
VTU_VID  = vid | 0x1000        # VALID
VTU_FID  = fid
VTU_DATA = data1
VTU_DATA2= data2
VTU_OP   = 0x3000 | 0x8000     # LOAD | BUSY
wait VTU_OP.BUSY == 0
```

### Reading the table back

```sh
VTU_VID = start            # e.g. 0
VTU_OP  = 0x8000 | 0x4000  # BUSY | GET_NEXT
wait busy
vid = VTU_VID & 0xfff
```

`GET_NEXT` returns the entry **after** the VID you loaded. Reading `0x1ff8` or
`0x0fff` means end of table. If the returned VID equals the one you asked for,
the table is exhausted (or you did not advance).

### Confirmed table contents produced by this project

```
VID 1:   FID 1  D1=0xff7f D2=0x003b     (port 3 untagged, port 9 tagged)
VID 2:   FID 2  D1=0xfdff D2=0x002f     (port 4 untagged, port 10 tagged)
VID 3:   FID 3  D1=0xffdf D2=0x003b
VID 4:   FID 4  D1=0xfff7 D2=0x003b
VID 5:   FID 5  D1=0xdfff D2=0x003b
VID 6:   FID 6  D1=0xf7ff D2=0x002f
VID 7:   FID 7  D1=0xffff D2=0x002b     (port 8 lives in D2)
VID 8:   FID 8  D1=0x7fff D2=0x002f
VID 100: FID 100 D1=0xffff D2=0x0017    (ports 9 + 10 untagged)
```

`FID = VID` gives each VLAN an independent forwarding database. `FID = 0`
(a single shared FDB) was tried and made delivery less reliable.

---

## 4. Global 2 — indirect Clause-45 / Clause-22 access

Registers on **Global 2** (base `0x1c`):

| Offset | Name |
|---|---|
| `0x18` | `G2_CMD` |
| `0x19` | `G2_DATA` |

Mode bits inside `G2_CMD`:

```
MODE_22 = 0x1000
MODE_45 = 0x0000     <- easy to invert
```

### Clause-45 read

```sh
wait busy
G2_DATA = regaddr
G2_CMD  = 0x8000 | (phy << 5) | mmd
wait busy
G2_CMD  = 0x8000 | 0x0c00 | (phy << 5) | mmd
wait busy
result = G2_DATA
```

### Clause-45 write

```sh
wait busy
G2_DATA = regaddr
G2_CMD  = 0x8000 | (phy << 5) | mmd
wait busy
G2_DATA = value
G2_CMD  = 0x8000 | 0x0400 | (phy << 5) | mmd
wait busy
```

### Clause-22 (front-panel copper PHYs)

```sh
read:  G2_CMD = 0x8000 | 0x1000 | 0x0800 | (phy << 5) | reg
write: G2_DATA = value ; G2_CMD = 0x8000 | 0x1000 | 0x0400 | (phy << 5) | reg
```

---

## 5. CPU port SerDes (MMD 4)

Register set, on the CPU ports (9, 10), addressed with `phy = port`:

| Register | Name | Observed |
|---|---|---|
| `0x1000` | `PCS_CTL1` | reads `0x2140`, effectively **read-only** (fixed 1000BASE-X, full duplex, AN off) |
| `0x1001` | `PCS_BMSR` | status |
| `0x1004` | `PCS_AN_ADV` | advertisement, write `0x00e0` |
| `0x1005` | `PCS_LPA` | link partner ability |
| `0x2000` | `SGMII_CTL` | |

Because `PCS_CTL1` cannot be modified, **MAC loopback self-test and AN enable
are impossible on these ports**. The port nonetheless links at 1G; the sequence
that works is:

```sh
PORT_STS  CMODE := 0x9              # 1000BASE-X
PORT_CTL0 state := Forwarding
PVID             := 100
PORT_MAC         := 0x203e
serdes_w port 0x1004 0x00e0         # advertise first
serdes_w port 0x1000 <read-modify-write, clear bits 15/14/11, set 12/9>
```

2500BASE-X (`CMODE = 0xb`, `PORT_MAC = 0x313f`) never links.

---

## 6. SFP cage SerDes (MMD 4, PHY address = port + 0x10)

The SFP cages on switch ports 3 and 4 have their own Clause-45 PHY at
**`phy = port + 0x10`**, powered down at reset.

| Register | Meaning | Cold value |
|---|---|---|
| `0x2000` | SGMII / SerDes control | **`0x1940`** → PDOWN set |
| `0x1000` | `PCS_CTL1` | `0x0000` |
| `0x1001` | `PCS_BMSR` | `0x0000` |

Power-up: write **`0x9140`** to `0x2000`. Reads back `0x1140` (bit 15 not sticky),
which is normal.

```
before:  sw3 STS=0x100f  LINK=0  CMODE=0xf
after :  sw3 STS=0xde09  LINK=1  CMODE=0x9
```

### Distinguishing internal-PHY ports from SerDes ports

| Port class | C22 read (`phy = port`) | C45 MMD4 at `phy = port + 0x10` |
|---|---|---|
| Internal PHY (1,2,5,6,7,8 and also 3,4) | answers, `BMCR=0x1140`, `BMSR=0x7949` | ports 3/4: `0x1940` |
| Real SerDes (9,10) | `0xffff` (no PHY) | `0x0000` |

Ports 3 and 4 answer C22 exactly like the copper ports, which is why they look
like "just another internal-PHY port" until you know about the `+0x10` C45 PHY.

---

## 7. Front-panel copper PHYs (ports 1, 2, 5, 6, 7, 8)

Clause-22, `phy address = port number`.

| Register | Cold value | After power-up |
|---|---|---|
| `0x00` BMCR | `0x1940` (PDOWN = 1) | `0x1340` / `0x1140` |
| `0x01` BMSR | `0x7949` | `0x7949` (or `0x796d` with link) |

Power-up sequence:

```sh
phy_w port 0x16 0x0000     # page register = reg 22 -> page 0
phy_w port 0x09 0x0200     # advertise 1000BASE-T full duplex
phy_w port 0x00 0x1340     # clear PDOWN, enable AN, restart AN
```

> **Do not** apply the DiagOS `page 0xF8` sequence
> (`page 0xf8, reg 0x08 = 0x0036; page 0, reg 0x14 = 0x8020`).
> That is the 6190 **non-X** programming recipe and it wedges Clause-22 access on
> a 6190X — every subsequent read returns the command echo
> (`(port<<5)|reg`). Only a cold power cycle recovers.

---

## 8. Register values that must NOT be changed

| Location | Value | Why |
|---|---|---|
| Switch port 0 | leave disabled | XMII/RGMII to the BMC. Changing it can cut the only management path |
| `PORT_CTL2` bits 13:12 on CPU ports | must be `00` | jumbo mode breaks CPU↔CPU forwarding, asymmetrically |
| `PORT_MAC` on CPU ports | `0x203e` | forced 1G full duplex is what actually brings the link up |

---

## 9. Quick sanity readings

```
sw_r 0  0x03   -> 0x0a01      chip present, 88E6190X rev 1
sw_r 9  0x00   -> 0x1e09      CPU port up, 1G, 1000BASE-X
sw_r 10 0x00   -> 0x0e09      CPU port up, 1G, 1000BASE-X
sw_r 3  0x00   -> 0xde09      SFP 1 up, 1G, 1000BASE-X
sw_r 7  0x08   -> 0x2c00      Secure, jumbo clear, MAP_DA clear
sw_r 9  0x08   -> 0x0c00      Secure, jumbo cleared by the script
```
