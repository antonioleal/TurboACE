# Standalone carrier: parts list

The standalone build (`register-map.md` decisions 24 and 27) needs no Jupiter Ace and no
adapter board. The Tang Nano 20K already has the HDMI socket, the microSD slot and USB
(power and programming); the carrier adds the PS/2 keyboard. It can be built on a
perfboard or a small PCB.

| Qty | Part | Notes |
|---|---|---|
| 1 | Sipeed Tang Nano 20K | the FPGA module; standalone bitstream |
| 1 | 6-pin mini-DIN (PS/2) female socket, right angle, shielded, PCB mount (Mauser 011-0716) | at the board's USB edge: 1 DATA, 3 GND, 4 +5V, 5 CLK, shield to GND |
| 1 | 4-channel BSS138 bidirectional level-shifter module (2 channels used) | each channel a BSS138 with 10 kΩ pull-ups to 3.3 V and 5 V; soldered on the carrier with its two 6-pin headers. The same circuit can be built from 2 BSS138 (SOT-23) and 4 × 10 kΩ |
| 1 | 100 nF capacitor | across the keyboard's 5 V supply, at the socket |
| 2 | 1×20 female header, 2.54 mm | the module plugs in; rows 20.32 mm apart |
| — | the carrier PCB (`kicad/standalone`), or perfboard | |

Also needed, not on the carrier: a PS/2 keyboard, a microSD card with `/ace.rom`, an
HDMI display, and a USB power supply (5 V, at least 500 mA).

## Wiring

```
PS/2 socket                level shifter (each line: one BSS138)          Tang Nano 20K
pin 5  CLOCK  ──┬── 10k ── +5V        gate ── +3V3                    ┌── 10k ── +3V3
                └──────── drain       source ─────────────────────────┴── FPGA pin 73
pin 1  DATA   ──┬── 10k ── +5V        gate ── +3V3                    ┌── 10k ── +3V3
                └──────── drain       source ─────────────────────────┴── FPGA pin 74
pin 4  +5V    ─────────────────────────────────────────────────────────── 5V pin
pin 3  GND    ─────────────────────────────────────────────────────────── GND
pins 2, 6     not connected
```

- The FPGA drives both pins open-drain: `0` or `Z`, never `1`.
- FPGA pins 73 (clock) and 74 (data): the first two pins of the module's left header,
  at the USB end. Not 52/53, which are the HDMI connector's EDID lines.
- Socket pin numbers are as seen on the socket's datasheet; check them against the
  keyboard plug before soldering.
