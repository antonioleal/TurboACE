# Standalone board (KiCad 10)

The carrier for the standalone build: the Tang Nano 20K plugged into two female
headers, the PS/2 keyboard socket at the board's edge, and the level shifter between the keyboard's 5 V and the FPGA's 3.3 V. KiCad project,
schematic, PCB (footprints placed, outline and design rules set, routed by hand) and
the BoM generated from the schematic. Parts and wiring: ../../hardware/standalone-carrier.md.

Drawn: `standalone.kicad_sch`, `standalone.kicad_pcb`, `standalone.kicad_pro`
(KiCad 10), with `standalone-bom.csv` and `standalone-schematic.pdf`. Made by
`generate.py` (see ../README.md); all its checks pass: the netlist equals the table,
ERC 0, DRC 0 with schematic parity; routed by hand (0 unconnected).

## The board

- 54.04 × 60 mm, flush with the module's ends so the USB-C and HDMI plugs and the
  microSD card (under the USB end) stay reachable; 2 layers.
- The module U1 (locked) on its two sockets, the USB end on the left; its outline on
  F.Fab and its courtyard keep the space under it free. The level shifter module U2
  below U1's J6 row, turned half round so its LV row is the one nearer U1, LV1 at the
  USB end, the HV row below; mounted labelled side up (its BSS138s toward the carrier), as in
  `gebildet-photo.png` (the seller's photo the footprint follows); J3, the PS/2 socket, at the USB edge below U1, its front face on the edge so the keyboard plugs in beside the USB cable (low enough for its shield tab to clear U1's pins), C1 next to it; M3 holes in the corners, clear of the modules.
- Rules: clearance 0.2 mm, tracks 0.25 mm; net class Power (+5V, +3V3, GND) 0.5 mm.
- To route: PS2_CLK/PS2_DAT (U1.1/U1.2 to U2 LV1/LV2), KBD_CLK/KBD_DAT (U2 HV1/HV2 to
  J3 pins 5 (CLK) and 1 (DATA)), +5V from U1.21 to U2 HV, C1 and J3 pin 4, +3V3 from
  U1.19 (or U1.36) to U2 LV, GND from U1.20/U1.22 to U2's two GNDs, C1, J3 pin 3 and its
  three shield tabs. A GND pour on the bottom layer
  suits it.

What it is based on:


## The module (from Sipeed's v3921 dimension drawing and v3923 schematic)

- Board 54.04 × 22.55 mm; two rows of 20 pins, 2.54 mm pitch, **20.32 mm apart**
  (centre to centre); the first pin about 2.6 mm from the USB end.
- Left header (module J6), pin 1 at the USB end: FPGA 73, 74, 75, 85, 77, 15, 16, 27,
  28, 25, 26, 29, 30, 31, 17, 20, 19, 18, 3V3, GND.
- Right header (module J5), pin 1 at the USB end: 5V, GND, 76, 80, 42, 41, 56, 54, 51,
  48, 55, 49, 86, 79, GND, 3V3, 72, 71, 53, 52.
- Seen from above with the USB end on the left, the left header is the bottom row.
- PS/2: clock FPGA 73 (J6 pin 1), data FPGA 74 (J6 pin 2); nothing else on the module
  is wired to them. 52/53 are avoided: they are the HDMI connector's EDID lines.
- The microSD slot is on the module's underside at the USB end, the card going in and
  out at the USB edge: keep that part of the carrier free of tall parts and the card's
  path clear.
- (The v3920 bottom render labels some USB-end pins differently; the schematic and the
  pinout image agree, and are what this uses.)

## Contents

| Ref | Part | Footprint |
|---|---|---|
| U1 | Sipeed Tang Nano 20K (pins 1-20: left header J6, 21-40: right header J5) | `TurboACE:TangNano20K` (kicad/lib), locked |
| J1, J2 | 1×20 female header, 2.54 mm, for the module: BoM only (U1's footprint has the pads) | (`Connector_PinSocket_2.54mm:PinSocket_1x20_P2.54mm_Vertical`) |
| J3 | PS/2 socket: 6-pin mini-DIN female, right angle, shielded, Mauser 011-0716 (pins as the Same Sky MD-60S); 1 DATA, 3 GND, 4 +5V, 5 CLK, shield to GND; front face on the USB edge | `TurboACE:MiniDIN6_PS2_Female` (kicad/lib) |
| U2 | Gebildet 4-channel BSS138 level shifter (SparkFun BOB-12009 circuit), soldered on its two 6-pin headers, labelled side up: channel 1 clock, 2 data, 3-4 unused; LV +3V3, HV +5V; 10 kΩ pull-ups on the module | `TurboACE:LevelShifter_BSS138_4ch_Gebildet` (kicad/lib) |
| C1 | 100 nF ceramic, leaded, 5 mm lead spacing: +5V to GND near J3 | `Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm` |
| H1–H4 | M3 mounting holes, clear of the USB/microSD end | `MountingHole:MountingHole_3.2mm_M3` |

Nets: +5V (U1.21), GND (U1.20, U1.22, U1.35), +3V3 (U1.19, U1.36), PS2_CLK (U1.1,
IO73), PS2_DAT (U1.2, IO74) to U2 LV1/LV2, KBD_CLK, KBD_DAT from U2 HV1/HV2 to J3; U2 LV +3V3, HV +5V;
every other module pin no-connect.
