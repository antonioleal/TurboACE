# TurboACE — I/O Register Map (DRAFT v0.8)

Status: draft for review. 2026-11-15.

**Compatibility target: original Jupiter Ace software only.**
Mercury_Ace and Jupiter-II are sources of ideas, not compatibility targets
(see `requirements.txt`). Where a design element is borrowed, its origin is noted:

- Mercury_Ace hi-res add-on CPLD: `HiresAddon/CPLD/JAHires003.zip` → `JAHiRes.v`.
- Jupiter-II Expansion: `J-II_EXP.PLD`, `xrom/xrom.z`, schematic sheets 1–2.
- JupiterACE_MiSTer (github.com/antonioleal/JupiterACE_MiSTer, GPL v2+): the MiSTer
  Jupiter Ace core with T80; `rtl/keyboard.v` (PS/2 to the Ace matrix), `rtl/video.v`,
  `rtl/tape.sv`/`tzx.sv`. Ideas for the standalone build.

Values marked **TBD** are placeholders awaiting a decision.

Not part of TurboACE: a serial port.

### Changes in v0.8

- **Implementation: a Sipeed Tang Nano 20K FPGA module** (Gowin GW2AR-18, 8 MB SDRAM in
  the package, HDMI connector, microSD slot) on a small adapter board with bus buffers.
  This replaces the discrete-logic build (§8, decision 9).
- **Video and sound go out over HDMI**: 720×576 at 50 Hz, with the AY sound as HDMI audio.
  Analogue RGB is dropped.
- **SD card storage** on the module's microSD slot. A small soft CPU inside the FPGA runs
  FatFs for the FAT file system; the Z80 sends file-level commands through the new
  ports `$E5` (command/status) and `$E7` (data) (§2.6).
- The colour registers in AY R14/R15 work whatever R7's direction bits say (§4.1).
- SD command set and words defined (§2.6, §5 "Tape hooks", decision 23). The tape hooks
  are placed from the disassembly: page 1 `$1820` and `$18A7`, handlers in ROM page 3.
- The tape hooks are in the ROM with the **cassette path** (`rom/src/sdpage.asm`). The
  harness shows it equal to the stock ROM where the paths rejoin, and in every edge of
  the written signal.
- The tape hooks' **SD path** is in the ROM: `TWRITE`/`TREAD` with the chunked data phase,
  search detection by the `$1A81` return address, error 9 → carry clear, any other error
  → `ERROR 10`, BREAK as the ROM does. It is tested against a model of the soft CPU's
  tape player. `XS_SDERR` keeps the last error code for `SDERR`.
- The words **`SDTAPE`, `TAPE` and `EJECT`** are in the ROM. `TAPE` is `: TAPE 32 WORD (TAPE) ;`;
  the counted name goes to a page-3 routine that sends `TINSERT`. Names longer than 63
  characters, or empty, give `ERROR 10` with `SDERR` 6, and the card is not asked.
- **`DIR`, `CD` and `DELETE`** are in the ROM. `DIR` is a RAM code word: it prints, which
  extension pages cannot, and fetches each entry through `XDCALL` from a page-3 routine
  (`DIRFIRST`/`DIRNEXT` into `XS_DIRBUF`). `CD`/`DELETE` are `32 WORD` colon words like
  `TAPE`, sharing one page-3 routine that sends a counted name with a command.
- **`PGSAVE`, `PGLOAD`, `SCRSAVE` and `SCRLOAD`** are in the ROM: `n 32 WORD` colon words; a
  page-3 routine adds `.PG`/`.SCR`, maps the page (or pages 2n, 2n+1) and moves the bytes
  with `OPENW`/`OPENR`, `WRITE`/`READ` of at most 8192 bytes each, and `CLOSE`. A shorter
  file loads only what it has. The user's windows are restored on every way out.
- **`FONTLOAD` and `SDERR`** are in the ROM, completing the SD words. `FONTLOAD` points
  `CHR_CPU` at the font, reads up to 1 K into the character memory at `$2C00`, and restores
  `CHR_CPU`; the font shown is not changed. `SDERR` gives `XS_SDERR`.
- **The ROM at power-up** (decision 24, §2.7): the soft CPU's firmware loads `/ace.rom`
  from the card into ROM pages 0 and 1 and TurboACE's pages 2–7 from the board's flash,
  then releases the Z80. The flash image (`make -C rom flash`) holds no stock ROM byte:
  each page's 321-byte copy of the stock interrupt path is filled in from `/ace.rom`.

### Changes in v0.7

- **Text overlay in hi-res.** In `MODE` 1 the text page `BG_VIEW` (font `CHR_VIEW`) is
  shown on top of the bitmap, so `."`, the input line and the cursor stay visible (§2.4).
  Text keeps its own per-cell colours.
- **New `XCFG` bit 2 `OPAQUE`** (write-only, reset 0) and word `OPAQUE`: transparent text
  by default; opaque makes non-space cells cover their 8×8 cell in the text PAPER.
- `PSG!` and `PSG@` are renamed **`PLAY!`** and **`PLAY@`**, and `GOVER` is renamed **`FLIP`**.
- `MPAGE` is split into **`PG0`** and **`PG1`** (`p PG0`, `p PG1`): one word per window.
- `VIEW`, `WORK` and `SCREEN` set the text page and the hi-res screen together; `CLS` in
  hi-res clears both the bitmap and the text.

### Changes in v0.6

- **The boot jumper is gone.** Every reset boots through the hook into a 51K Ace
  (`0 TURBO`). The word **`TURBO`** switches modes (§5, "TURBO modes"):
  `1 TURBO` = the full extension, `0 TURBO` = 51K like a 48K RAM pack,
  `-1 TURBO` = a stock Ace that keeps the card's tape (ROM page 1, `$3000` mirror
  but `$3B00–$3BFF`) until reset; `-2 TURBO` = a completely stock Ace (ROM page 0,
  the whole mirror) until reset.
- **New `XCFG` bit 1 `MIRROR`** (write-only, reset 0): `$3000–$3BFF` mirrors `$3C00` as on a stock Ace.
- **New `XCFG` bit 3 `KEEP`** (write-only, reset 0): with `MIRROR`, `$3B00–$3BFF` stay extension RAM (`-1 TURBO`).
- `ROMPAGE` always resets to page 1.

### Changes in v0.5

- **User RAM is paged in two independent 8K windows**, `$C000–$DFFF` and `$E000–$FFFF`,
  each showing any of **64 × 8K** pages (still 512K), so two areas can be mapped at once.
- **New page port `$E1`** (§2.5): write `w0pppppp`, read with the window on A15.
  `$E3` command `101` (`RAMPAGE`) is now reserved.
- **A hi-res screen occupies two pages**: screen n = pages 2n and 2n+1. Mapped at
  `$C000`/`$E000`, the layout seen by the CPU is unchanged (§2.4).
- `MPAGE` takes a window: `p w MPAGE`.

### Changes in v0.4

- **TurboACE is built from discrete logic** (74-series, SRAM, ROM, AY); no CPLD or FPGA.
- **Sprites are dropped**: port `$E7`, registers `$10–$16` and `$40–$7F` are now reserved.
- **Graphics words follow the ZX Spectrum set**: `PLOT` `DRAW` `CIRCLE` `POINT`
  `INVERSE` `FLIP` `CLS`, plus `PAINT`. `DRAW` draws lines and, with its angle, arcs; there is no `LINE` or `ARC` (§7).
- `CLS` is a superset of the stock word, like `PLOT`.
- **Video output is analogue RGB**; HDMI is dropped.
- **`ATTR`** added: reads the colour of a hi-res 8×1 cell or a text cell.
- **The `$E1`/`$E5` register file is gone.** `XCFG` moves to `$E3` command `111`,
  whose read also returns the TurboACE ID (§2.3). `$E1–$EF` other than `$E3` are reserved.
- **`HSCROLL` is dropped** (`XREG $03` is now reserved, and the `SCROLL` word is gone).
  Hi-res line `y` is always fetched from offset `y * 32`.

### Changes in v0.3 (sprites, now dropped in v0.4)

- 16 hardware sprites with collision detection.

### Changes from v0.2

- **The hi-res screen now lives in the paged user RAM.** It no longer uses the BG pages.
  - One 16K RAM page holds a full screen: a linear bitmap plus 8×1 colour.
  - `BG_VIEW` selects the RAM page shown in hi-res.
  - There can be up to 32 hi-res screens.
- `SUBLINE` (`$E3` cmd `111`) is gone; that command is now reserved. Hi-res
  scrolling moved to `HSCROLL` (`XREG $03`), itself dropped in v0.4.
- Hi-res colour is written explicitly. The hardware latch now applies to text mode only.

### Changes from v0.1

- The "`MODE` write resets the page registers" quirk is dropped.
- Hi-res is a direct bitmap only. The CHR-RAM hi-res path and `XCFG.BITMAP` are gone.
- The user-RAM window is now **16K at `$C000–$FFFF`, 32 pages** (still 512K).
  Base RAM is now **36K**.
- `ROMPAGE` bit 3 (Mercury's ACE81 disable) is gone.

---

## 1. I/O port overview

| Port | Dir | Function | Origin |
|------|-----|----------|--------|
| even (`A0=0`, conventionally `$FE`) | R/W | Stock Ace keyboard / beeper / tape | stock Ace, unchanged |
| **`$E3`** | R/W | **Control port** (§2) | command format from Mercury |
| `$E1` | R/W | **`PAGE`** — user-RAM page for window 0 or 1 (§2.5) | new in v0.5 |
| `$E5` | R/W | **`SDCMD`** — SD card command (write) / status (read) (§2.6) | new in v0.8 |
| `$E7` | R/W | **`SDDATA`** — SD card command arguments and file data (§2.6) | new in v0.8 |
| `$E9`, `$EB`, `$ED`, `$EF` | — | reserved | — |
| `$F1–$FF` odd, used as `$FD` / `$FF` | R/W | AY-3-8910: `$FD` register select, `$FF` value | Jupiter-II Expansion |

Decoding:

- `$E1`, `$E3`, `$E5` and `$E7`: TurboACE decodes the **full low byte** `A7–A0`. The rest of `$E1–$EF` is reserved and not decoded.
- AY: partially decoded as on Jupiter-II (`IORQ·A7·A6·A5·A4·A0`, `BC1 = WR xor A1`,
  `BDIR = WR`). The whole odd `$F1–$FF` range therefore belongs to the AY.
  The AY is implemented in the FPGA and runs as if clocked at 3.25 MHz; its sound goes out as HDMI audio.
- Emulator: Jupiter-IIb's `MachineIn` and `MachineOut` (`src/machine.cpp`) already
  receive the full 16-bit port, with A on A15–A8 for `IN A,(n)`. The `is_uart_port()`
  branch (`(port & $F1) == $E1`) is replaced by the TurboACE handlers for `$E1–$EF`.

---

## 2. Port `$E3` — Control port

### 2.1 Write

```
LD  A, cccddddd      ; ccc = command (D7–D5), ddddd = parameter (D4–D0)
OUT ($E3), A
```

### 2.2 Read

```
LD  A, ccc00000      ; command selector
IN  A, ($E3)         ; result in A
```

- **The selector comes from address lines A15–A13**, not from the data bus.
  - This works because `IN A,(n)` puts A on A15–A8.
  - With `IN r,(C)`, the selector is the top three bits of B.
  - The emulator handler and the schematic decode both take it from the high address byte.
- Unused high bits of the result read as 0, except for `XCFG` (`111`), whose bits 7–1 are the ID.

### 2.3 Commands

| ccc | Name | Write param | Read result | Reset |
|-----|------|-------------|-------------|-------|
| `000` | `BG_CPU` | BG-RAM page (0–31) seen by the CPU at `$2000–$27FF` | `000ppppp` | 0 |
| `001` | `BG_VIEW` | BG-RAM page (0–31) shown by video. **Hi-res: also screen n shown, i.e. 8K pages 2n and 2n+1, with text page n overlaid** (§2.4) | `000ppppp` | 0 |
| `010` | `CHR_CPU` | CHR-RAM page (0–31) seen by the CPU at `$2800–$2FFF` | `000ppppp` | 0 |
| `011` | `CHR_VIEW` | CHR-RAM page (0–31) used by video for text (both modes) | `000ppppp` | 0 |
| `100` | `MODE` | bit 0: 0 = text 32×24, 1 = hi-res 256×192 bitmap; bits 4–1 reserved (write 0) | `0000000m` | 0 (text) |
| `101` | — | reserved (`RAMPAGE` until v0.4; user-RAM paging is now port `$E1`, §2.5) | `00000000` | — |
| `110` | `ROMPAGE` | bits 2–0: 8K ROM page at `$0000–$1FFF`; bits 4–3 reserved (write 0) | `00000ppp` | 1 (§5) |
| `111` | `XCFG` | bit 0 `ATTR`: 1 = the BG window `$2000–$27FF` addresses colour RAM (§4.2, text mode); bit 1 `MIRROR`: 1 = `$3000–$3BFF` mirrors `$3C00–$3FFF` as on a stock Ace (write-only; set by `-1` and `-2 TURBO`, §5); bit 2 `OPAQUE`: 1 = hi-res text overlay opaque (write-only, §2.4); bit 3 `KEEP`: with `MIRROR`, `$3B00–$3BFF` stay extension RAM, the SD code's state (write-only; set by `-1 TURBO`, §5); bit 4 reserved (write 0) | `1010100a`: bits 7–1 = ID `$A8`, bit 0 = `ATTR` | 0 |

Every register is independent. **Writing `MODE` changes only the mode.**

**Detecting TurboACE.** `LD A,$E0 / IN A,($E3) / AND $FE / CP $A8`: Z = TurboACE present.
A stock Ace has nothing at `$E3`, so the read gives `$FF` or bus noise, not `$A8`/`$A9`.

**Hardware.** `XCFG` is a few register bits in the FPGA beside the other `$E3`
registers; the read path returns the fixed ID bits through the same selector.

### 2.5 Port `$E1` — user-RAM pages (`PAGE`)

User RAM (512K) is 64 pages of 8K. Two windows each show one page, independently:

| Window | Addresses |
|--------|-----------|
| 0 | `$C000–$DFFF` |
| 1 | `$E000–$FFFF` |

```
LD  A, w0pppppp      ; w = window (D7), p = page 0–63 (D5–D0); D6 reserved (write 0)
OUT ($E1), A

LD  A, w0000000      ; window selector on A15 (as for $E3)
IN  A, ($E1)         ; 00pppppp
```

- **Reset:** window 0 = page 0, window 1 = page 1, so `$C000–$FFFF` is linear 16K at power-up.
- **The same page in both windows** is allowed; both addresses then reach the same RAM.
- **A 16K block** (for example a hi-res screen, §2.4) is pages 2n and 2n+1 in windows 0 and 1.
- **Hardware:** two 6-bit registers in the FPGA; the selected one supplies address bits
  18–13 of the user RAM in the SDRAM.

### 2.6 Ports `$E5` / `$E7` — SD card

The microSD card is handled by a small soft CPU inside the FPGA, running FatFs. The Z80
never sees sectors or the FAT: it sends **file-level commands**. One file and one tape
can be open at a time.

| Port | Write | Read |
|------|-------|------|
| `$E5` `SDCMD` | command code (starts the command) | status, below |
| `$E7` `SDDATA` | the next argument byte | the next result or data byte |

**Status (`$E5` read):**

| Bit | Name | Meaning |
|-----|------|---------|
| 7 | `BUSY` | the soft CPU is working on the command |
| 6 | `ERROR` | the last command failed; the next `$E7` read is the error code |
| 5 | `CARD` | a card is present and mounted |
| 4 | `TAPE` | a tape file is in the virtual player |
| 0 | `DATA` | a result or data byte is waiting on `$E7` |

**Protocol:**

1. Write the arguments to `$E7`.
2. Write the command to `$E5`.
3. Poll `$E5` until `BUSY` = 0.
4. Read the results from `$E7`.

Writing a command discards any unread result.

**Data phase.** Commands that move file or tape data (`READ`, `WRITE`, `TREAD`,
`TWRITE`) have a data phase after the command has completed:

- data moves through `$E7` in **chunks of at most 512 bytes**;
- after each chunk, and after the last byte, the Z80 waits for `BUSY` = 0;
- an `ERROR` can appear after any chunk, for example a full card while writing, or a
  bad checksum after a tape block's last byte.

This keeps a block of any size (a saved dictionary can be tens of K) within the soft
CPU's buffer, and gives it time to write each chunk to the card.

**Argument formats:**

- **Names** are counted strings: a length byte, then up to 63 characters. The card is
  mounted automatically on first use and after a card change.
- **Numbers** are little-endian.

**File system commands:**

| Code | Command | Arguments | Results |
|------|---------|-----------|---------|
| `$01` | `MOUNT` | — | — (re-reads the card) |
| `$02` | `DIRFIRST` | pattern (name, e.g. `*.TAP`; empty = all) | first entry |
| `$03` | `DIRNEXT` | — | next entry |
| `$04` | `CHDIR` | name (`..` and `/` allowed) | — |
| `$05` | `DELETE` | name | — |
| `$06` | `FREE` | — | free space in K (4 bytes) |

Folders are listed before files. A directory entry is a flags byte (b0 folder; `$FF` = no more entries), the size (4
bytes), then the name.

**File commands** (one file open at a time):

| Code | Command | Arguments | Results |
|------|---------|-----------|---------|
| `$10` | `OPENR` | name | size (4 bytes) |
| `$11` | `OPENW` | name (created, or replaced) | — |
| `$12` | `READ` | count (2 bytes, ≤ 8192) | actual count (2 bytes); the data in the data phase |
| `$13` | `WRITE` | count (2 bytes, ≤ 8192) | — ; the data in the data phase |
| `$14` | `CLOSE` | — | — |

**Flush after every write.** The soft CPU flushes the file to the card (FatFs `f_sync`)
before it clears `BUSY` on every `WRITE`, and on every `TWRITE`.

- **Safe at any time:** once `BUSY` is clear, everything written so far is on the card,
  with the file's size and directory entry up to date.
- **Never closed?** A program that stops, crashes or is reset without `CLOSE`, or a card
  pulled or powered off, can lose at worst the unfinished file. That is any data whose
  `WRITE` had not finished. Other files and the file system stay intact.
- **Opening replaces:** `OPENR` or `OPENW` while a file is open closes that file first,
  so a forgotten `CLOSE` never leaves two files half-written.
- **Cost:** each flush rewrites the directory entry and FAT sectors, so many small
  `WRITE`s are slower and wear the card more. Words should write in large blocks; a
  page is one 8192-byte `WRITE`.

**Virtual tape player.** These commands give the stock tape words the behaviour of the
Jupiter-IIb emulator, so programs and tape files behave the same on both:

| Code | Command | Arguments | Results |
|------|---------|-----------|---------|
| `$20` | `TINSERT` | name (tries `name`, `name.TAP`, `name.TZX`) | — (the tape is at its start). Not found: error 2, and the tape already in the player stays |
| `$21` | `TEJECT` | — | — |
| `$22` | `TREAD` | flag (`$00` header, `$FF` data), length (2 bytes), search (1 = a `LOAD` looking for a header, 2 = the same with no name: start from the tape's beginning) | the block's data in the data phase; flag and length checked at once (error 9), the checksum after the last byte (error 9) |
| `$23` | `TWRITE` | flag (`$00` header, `$FF` data), length (2 bytes) | — ; the block's data in the data phase, then written with its length and checksum |

- **`TREAD`** returns the next block on the tape.
  - A block with the wrong flag, length or checksum gives error 9.
  - In a header search, going once round the tape without the ROM accepting a header
    gives error 10, which the ROM reports as its own `ERROR 10`. With no tape, a search
    gives error 10; a plain read (no search) at the end of the tape, or with no tape,
    gives error 9 (no block), as the Jupiter-IIb emulator does.
- **`TWRITE`** appends the block, with its length and checksum, to the tape in the
  player (`.tzx`: as standard data blocks, 10h, 1000 ms pause). With no tape in the
  player, a header block names a new file `name.tap` from the header's name, as the
  emulator makes it (letters, digits, `-` and `_` kept, others `_`), replaced if it exists, and the data block follows it there. The new file is not put in
    the player.
- **Files:** `.TAP` (blocks of 2-byte length, data, XOR checksum) and `.TZX` (the same
  blocks in TZX data blocks) are read. `.TAP` is written.
- **Folder:** the current folder starts at `/programs` (created if missing), as on the
  Jupiter-IIb emulator's card.

**Error codes:**

| Code | Meaning |
|------|---------|
| 1 | no card |
| 2 | not found |
| 3 | card full |
| 4 | write-protected or read-only |
| 5 | I/O error |
| 6 | bad name |
| 7 | no file open |
| 8 | too large (count over 8192) |
| 9 | bad tape block (flag, length or checksum) |
| 10 | end of tape (once round) |


### 2.7 Inside the FPGA: the SD soft CPU's interface

The soft CPU (firmware in `firmware/`, FatFs) sees the mailbox and an SPI master as
registers (`firmware/src/hal.h`):

| Address | Register | Use |
|---------|----------|-----|
| `$1000_0000` | `MB_STATUS` | W: b6 `ERROR`, b5 `CARD`, b4 `TAPE`; the write clears `BUSY` |
| `$1000_0004` | `MB_EVENTS` | R: b0 command written, b1 data-phase count reached; W: 1s clear |
| `$1000_0008` | `MB_CMD` | R: the last command byte |
| `$1000_000C` | `MB_ARG` | R: next byte the Z80 wrote to `$E7` (b8: empty) |
| `$1000_0010` | `MB_ARGCNT` | R: bytes waiting |
| `$1000_0014` | `MB_RES` | W: a byte for the Z80 to read on `$E7` |
| `$1000_0018` | `MB_RESCLR` | W: empty the result FIFO |
| `$1000_001C` | `MB_XFER` | W: `$E7` accesses before the FPGA sets `BUSY` again (0 off) |
| `$1000_0020` | `MB_ARGCLR` | W: empty the argument FIFO |
| `$2000_0000`–`8` | `SPI_DATA`/`STAT`/`CTRL` | SPI master: byte, busy, CS and fast clock |
| `$3000_0000` | `TIMER_MS` | milliseconds since reset |
| `$4000_0000` | `KBD_DATA` | standalone: R next byte from the PS/2 keyboard (b8: none) |
| `$4000_0004` | `KBD_SEND` | standalone: W a byte to the keyboard (R b8: sender busy) |
| `$4000_0008` / `$4000_000C` | `KBD_ROWS03` / `KBD_ROWS47` | standalone: W the Ace matrix, rows 0–3 / 4–7, a byte each (bit set = pressed); port `$FE` reads it |
| `$4000_0010` | `SYS_CTRL` | W b0 holds the Z80 in reset (standalone: the T80; expansion: the Ace's `/RESET`); b1 ROM ready: the FPGA answers the Ace's ROM reads (expansion: drives `/ROMCS`). 1 at power-up (b0 set, b1 clear) |
| `$4000_0014` | `SYS_INFO` | R b0: 1 = standalone bitstream, 0 = expansion |
| `$5000_0000` / `$5000_0004` | `ROM_ADDR` / `ROM_DATA` | W the ROM address (page × 8192 + offset, 0–65535), then bytes; the address steps by one per byte |
| `$5000_0008` / `$5000_000C` | `FLASH_ADDR` / `FLASH_DATA` | W a byte address in the board's flash, then R bytes; the address steps by one per read |
| `$5000_0010` / `$5000_0014` | `SCREEN_ADDR` / `SCREEN_DATA` | standalone: W an offset in the text screen (`$2400`, 0–767), then character codes |

- **Flash layout** (`make -C rom flash` builds it, 49,200 bytes, written at `$50_0000`):
  ROM pages 2–7, each after an 8-byte tag `"TACE"`, page, 0, 0, 0. Each page's copy of the
  stock interrupt path (§5 "Copy ranges", 321 bytes) is left as zeros; the firmware fills
  it from `/ace.rom` and patches `$0153` to `$18`, so the flash holds no stock ROM byte.
  A missing or wrong tag means no TurboACE ROM.

- **The FPGA sets `BUSY` itself** when the Z80 writes a command (and then empties the
  result FIFO), and when the `MB_XFER` count reaches 0. The Z80 can therefore never see
  `BUSY` clear before the firmware has handled the chunk.
- FIFOs: 1024 bytes each way. Program and data: 48K of block RAM, RV32IC (decision 30).
- **In the FPGA design:** `fpga/rtl/mailbox.v` (with `fifo.v`). It is tested against a
  model written from `firmware/test/host_fpga.c`, the mailbox the firmware's own tests
  use, so the firmware and the hardware agree on every register. A new command or event
  wins over the soft CPU's write in the same clock.

### 2.4 Hi-res bitmap (`MODE` = 1)

A hi-res screen occupies **two 8K user-RAM pages**: screen n (0–31) is pages **2n and
2n+1**, one 16K-aligned block. Addresses below are as seen with page 2n in window 0
(`$C000`) and page 2n+1 in window 1 (`$E000`), which is how the graphics words map it.

| Offset in screen | Page | Window address | Size | Contents |
|------------------|------|----------------|------|----------|
| `$0000–$17FF` | 2n | `$C000–$D7FF` | 6K | Bitmap, linear: line `y` at `y*32`, MSB = leftmost pixel |
| `$1800–$2FFF` | 2n / 2n+1 | `$D800–$EFFF` | 6K | Colour: one PAPER:INK byte (IRGB:IRGB) per bitmap byte, at bitmap offset + `$1800` |
| `$3000–$3FFF` | 2n+1 | `$F000–$FFFF` | 4K | free (user data) |

- **Display.** Video shows screen `BG_VIEW` (pages 2·`BG_VIEW` and 2·`BG_VIEW`+1).
  - Line `y` (0 = top) is fetched from offset `y * 32`, with its colour `$1800` above.
  - There is no hardware scroll.
- **Text overlay.** Text page `BG_VIEW`, drawn with font `CHR_VIEW` and its colour RAM
  (§4.2), is shown on top of the bitmap. Text printed by the stock ROM (`."`, `.`, the
  input line, the cursor) is therefore visible in hi-res. For each pixel:

  | Text pixel | `OPAQUE` | Character | Colour shown |
  |------------|----------|-----------|--------------|
  | INK | either | any | the cell's text INK |
  | PAPER | 0 (default) | any | the bitmap pixel, in its 8×1 colour |
  | PAPER | 1 | not a space (code ≠ 32) | the cell's text PAPER |
  | PAPER | 1 | space (code 32) | the bitmap pixel, in its 8×1 colour |

  Each pixel takes its colour from one layer, so text causes no colour clash with
  the picture. A screen of spaces (after `CLS`) is fully transparent.
- **Overlay hardware.** In the FPGA, the video generator reads the text (BG, CHR and
  colour RAM) and the bitmap for each line and mixes them per pixel: a 2-way pixel
  select, a colour select and, for `OPAQUE`, a compare against code 32.
- **CPU access to pixel `(x, y)`**:
  - map page 2n at `$C000` and page 2n+1 at `$E000` (port `$E1`)
  - byte = `$C000 + y*32 + (x >> 3)`
  - bit = `7 - (x & 7)`
  - colour byte = that address + `$1800`

  No port access is needed inside drawing loops.
- **Shadow screen.** Draw and print into one screen (`WORK`: hi-res screen and `BG_CPU`)
  while `BG_VIEW` shows another, then switch `BG_VIEW`.
- **Up to 32 hi-res screens.** Any even/odd page pair can be one, at the cost of user RAM.
- **Text pages and hi-res screens share numbers.** Hi-res screen n is overlaid with text
  page n. All 32 text pages and 32 character sets stay available.
- **Colour is explicit.** The CPU writes colour bytes directly, and the graphics
  words (`PLOT`, `DRAW`, …) write the current R14 INK/PAPER for each byte they touch.
  The automatic colour latch (§4.2) colours text only, in both modes.
- **Hardware note.** Video and the Z80 share the FPGA's SDRAM (and block RAM). The
  controller is far faster than the 3.25 MHz bus, so it serves both without ever
  holding the Z80 with `/WAIT`. The picture goes out as HDMI at 720×576, 50 Hz:
  256×192 doubled to 512×384, centred, with the border colour around it. The HDMI
  frame is not locked to the Ace's own 50 Hz frame; programs keep timing themselves
  from the Ace's interrupt (`FRAMES`), which is unchanged.
- **In the FPGA design:** `fpga/rtl/video.v`. CEA-861 video code 17 (864 × 625 at
  27 MHz, sync negative); the picture's top-left corner at (104, 96). Each Ace line is
  fetched (up to 160 bytes: code, colour, glyph, and in hi-res the bitmap and its colour)
  into a line buffer while the line before it is shown, 64 µs ahead. Colours are IRGB
  with each channel off, half (`$80`) or full (`$FF`): colour bit plus intensity bit,
  as in Jupiter-IIb and JupiterACE_MiSTer.

---

## 3. Memory map as seen by the CPU

| Range | Size | Contents | Paged by |
|-------|------|----------|----------|
| `$0000–$1FFF` | 8K | ROM, 8 × 8K pages | `$E3` cmd `110` |
| `$2000–$23FF` | 1K | BG-RAM window (CPU-priority mirror; may glitch display) | cmd `000` |
| `$2400–$27FF` | 1K | BG-RAM window (video-priority, adds WAIT) | cmd `000` |
| `$2800–$2BFF` / `$2C00–$2FFF` | 1K | CHR-RAM window, **write-only** (same mirror rule) | cmd `010` |
| `$3000–$3BFF` | 3K | **RAM, fully decoded**: the extension words (§5). With `XCFG.MIRROR` = 1 (`-2 TURBO`), mirrors of `$3C00–$3FFF` as on a stock Ace; with `KEEP` as well (`-1 TURBO`), `$3B00–$3BFF` stay extension RAM | `XCFG.MIRROR`, `KEEP` |
| `$3C00–$3FFF` | 1K | stock Ace work RAM (on the Ace motherboard) | — |
| `$4000–$BFFF` | 32K | **RAM supplied by TurboACE, never paged** | — |
| `$C000–$DFFF` | 8K | user-RAM window 0: any of 64 × 8K = **512K** | port `$E1` |
| `$E000–$FFFF` | 8K | user-RAM window 1: any of the same 64 pages. A page pair 2n/2n+1 in windows 0/1 can hold a hi-res screen (§2.4) | port `$E1` |

### Inside the FPGA: the SDRAM layout

Everything TurboACE stores is in the module's 8 MB SDRAM (`fpga/rtl/memmap.v`):

| SDRAM | Size | Holds | CPU addresses |
|-------|------|-------|---------------|
| `$000000` | 512K | user RAM, 64 pages × 8K | `$C000–$FFFF` through windows 0/1 |
| `$080000` | 32K | fixed RAM | `$4000–$BFFF` |
| `$088000` | 3K | extension RAM | `$3000–$3BFF` |
| `$089000` | 1K | work RAM (standalone build) | `$3C00–$3FFF`, and `$3000–$3BFF` with `MIRROR` |
| `$090000` | 64K | ROM, 8 pages × 8K | `$0000–$1FFF`, page `ROMPAGE` |
| `$0A0000` | 32K | text (BG) RAM, 32 pages × 1K | `$2000–$27FF`, page `BG_CPU` |
| `$0A8000` | 32K | colour RAM, 32 pages × 1K | the same window with `XCFG.ATTR`; every BG write also writes PAPER:INK here |
| `$0B0000` | 32K | character RAM, 32 pages × 1K | `$2800–$2FFF` (write-only), page `CHR_CPU` |

### RAM totals

| | `1 TURBO` | `0 TURBO` (power-up) | `-1` and `-2 TURBO` |
|---|---|---|---|
| RAM for FORTH (dictionary + stacks) | **36K**: `$3C00–$BFFF` plus the extension's 3K | 49K: `$3C00–$FFFF` | 49K: `$3C00–$FFFF` |
| Paged RAM | 512K through the two windows | pages 0/1 are the top 16K of the 49K | as `0 TURBO` |
| `$3000–$3BFF` | extension (RAM) | extension (RAM) | mirrors `$3C00` (stock) |

`0 TURBO`, `-1 TURBO` and `-2 TURBO` are "51K" machines in the usual Ace sense: 3K stock plus a 48K pack.

RAM on the TurboACE board: 3K + 32K fixed, plus 512K paged.

Video RAM pools:

- BG-RAM: 32 × 1K (text mode).
- CHR-RAM: 32 × 1K (text mode).
- Colour RAM: 32 × 1K, parallel to BG-RAM (text mode, §4.2).
- Hi-res screens: in user RAM, two 8K pages each (§2.4).

### Consequences

- **`$3000–$3BFF` is real RAM** (except in `-1` and `-2 TURBO`), following Jupiter-II, which decodes
  2K at `$3000–$37FF` (Jupiter-IIb `machine.h`, `z80.h`).
  - It holds the extension words and the paged-ROM call stubs (§5).
  - Cost: software that writes the system variables through a mirror breaks in
    `0 TURBO` and `1 TURBO`. Run it after `-2 TURBO`, which restores the whole stock mirror
    (`-1 TURBO` restores all but its last 256 bytes).
  - The stock ROM itself does not appear to use the mirror: tracing its machine code
    from the reset and interrupt entries finds no access to `$3000–$3BFF`. A byte scan
    of the whole ROM finds two candidate operands (`$1733`, `$1DA8`), probably data;
    not yet confirmed.
- **Host requirement.** TurboACE supplies all RAM above `$3FFF`, so the host is a
  stock 3K Ace with **no external RAM pack**. Two devices answering the same
  addresses would fight on the bus.
- **48K RAM-pack software** sees linear RAM at power-up, because the windows reset to pages 0 and 1.
- **`RAMTOP` depends on the `TURBO` mode.** The machine stack (Z80 SP) starts at `RAMTOP`.
  This is verified: the reset code at `$002F` does `LD ($3C18),HL` / `LD SP,HL` after
  the RAM test at `$0028`. The stack must not live in the paged window.
  - With RAM up to `$FFFF`, the test wraps and sets `RAMTOP` = `$0000`, so the stack
    starts at the top of memory.
  - **`0 TURBO` (power-up), `-1` and `-2 TURBO`:** `RAMTOP` is what the stock RAM test
    found (`$0000`, the top of memory). The boot page remembers it.
  - **`1 TURBO`:** `RAMTOP` is set to **`$C000`**. FORTH gets 36K of unpaged
    space, and `PG0`/`PG1` are safe while `$C000–$FFFF` holds data only.

---

## 4. Colour (Jupiter-IIb keywords)

### 4.1 Colour registers

The colour registers sit in the AY's I/O ports, using the Jupiter-II Expansion layout.

| AY reg | Bits | Meaning | Reset |
|--------|------|---------|-------|
| R7 | b7, b6 | Port B and Port A direction; **must be 1 (output)** | set to 1 by ROM init |
| R14 (Port A) | b7–4 PAPER, b3–0 INK | IRGB, I = bit 3 | INK = white, PAPER = black |
| R15 (Port B) | b7–4 BORDER | IRGB | black |
| R15 (Port B) | b3–0 | unused (ignored) | — |

The colour codes and words come from Jupiter-IIb:

- Words: `INK`, `PAPER`, `BORDER`, `DARK` (clears bit 3).
- Colours: `BLACK`=0, `GREY`=8, `BLUE`=9, `GREEN`=10, `CYAN`=11, `RED`=12,
  `PURPLE`=13, `YELLOW`=14, `WHITE`=15.

**R7 direction bits.** On a real AY, R7 b6/b7 = 0 would turn the ports into inputs
and lose the colours. TurboACE's AY is in the FPGA, and R14/R15 keep working as colour
registers whatever R7 says, so sound code cannot disturb the colours. TurboACE's own
words still write R7 b7–b6 = `11`.

### 4.2 Colour RAM

The mechanism comes from Jupiter-II, extended to 32 pages.

- **Write.** Every CPU write to the BG-RAM window also writes the current R14 value
  (PAPER:INK) into colour RAM, at the same `BG_CPU` page and offset.
- **Display.** Video reads colour RAM at the same page and offset as the BG byte it fetches.
- **Text mode.** Colour is per character cell, and shadow pages keep their own colours.
- **Hi-res.** The bitmap's colour is stored explicitly in the screen's RAM pages,
  **per 8×1 pixel byte** (§2.4). The latch still colours the text overlay.
- **Reset defaults.** INK = white and PAPER = black, so unmodified Ace software
  looks exactly as on a monochrome Ace.
- **Direct access.** When `XCFG.ATTR` = 1 (§2.3), the BG window at `$2000–$27FF`
  addresses colour RAM instead. The CPU can then read and write attributes
  directly, for fast fills and read-back.

---

## 5. ROM pages

| Page | Contents (proposed) |
|------|---------------------|
| 0 | **Stock Jupiter Ace ROM, byte-identical**: used after `-2 TURBO` |
| 1 | Stock ROM with **4 bytes changed** at `$008E–$0091` (the boot hook) and, with the SD card, two tape hooks at `$1820` and `$18A7` (§5). The reset page, used in `0`, `1` and `-1 TURBO` |
| 2 | **Boot page**: TurboACE setup code at `$0092`, plus extension code |
| 3 | **SD page**: tape-hook handlers at fixed addresses (§5 "Tape hooks") and the SD card words |
| 4–6 | TurboACE extension code (TBD split) |
| 7 | reserved / diagnostics (TBD) |

### TURBO modes (no boot jumper)

Every reset starts in ROM page 1, boots through the hook (below) and ends in **`0 TURBO`**.
The word `TURBO` (`n TURBO`) then switches:

| `n` | Mode | ROM | `$3000–$3BFF` | Words linked | `RAMTOP` |
|-----|------|-----|---------------|--------------|----------|
| > 0 (`1 TURBO`) | TurboACE | page 1 | extension RAM | all extension words | `$C000` |
| 0 (power-up) | 51K Ace, like a 48K RAM pack | page 1 | extension RAM | `TURBO` and the SD words `SDTAPE` `TAPE` `EJECT` `DIR` `CD` `DELETE` `SDERR` | as found at reset |
| -1 (`-1 TURBO`) | stock Ace with the card's tape, until reset | page 1 (stock + tape hooks) | **mirrors `$3C00`**, but `$3B00–$3BFF` (`XCFG.KEEP`) | none (`$3C47` = `$1FFF`) | as found at reset |
| < -1 (`-2 TURBO`) | completely stock Ace, until reset | **page 0** | **mirrors `$3C00`** | none (`$3C47` = `$1FFF`) | as found at reset |

- **Linking.** `TURBO` is the first extension word and links straight to the stock
  chain. The `FORTH` link (`$3C47`) points at `SDERR`, the last word, in `0` and
  `1 TURBO`; `0 TURBO` (and the boot) rewrite two link fields in RAM (`XLINKS0`):
  `SDTAPE` links to `TURBO` instead of `OPAQUE`, and `SDERR` to `DELETE` instead of
  `FONTLOAD`, so the chain is `SDERR DELETE CD DIR EJECT TAPE SDTAPE TURBO` and the stock
  words (`TAPE` to `DELETE` are consecutive already). `1 TURBO` puts them back
  (`XLINKS1`). No word moves, so compiled addresses stay valid. Words defined by the
  user chain through `FORTH`, so they stay visible in every mode.
- **`1 TURBO`** gives `ERROR 1` (the ROM's "not enough memory") if the Forth data stack
  (`SPARE`) is within 256 bytes of `$C000`: the dictionary must leave room below the
  windows for the stack.
- **`0`, `-1` and `-2 TURBO`** restore the stock look: text mode, text page and font 0,
  `ATTR` off, windows on pages 0/1, sound off, white INK on black PAPER and BORDER.
- **`-1` and `-2 TURBO`** then set `$3C47` = `$1FFF`, and, from ROM page 2 (the
  extension's RAM disappears when the mirror switches on), set `XCFG` and leave through
  `$0099` (`OUT ($E3),A`) into `QUIT`: `-2 TURBO` (`HSTOCK`) with `MIRROR` and page 0;
  `-1 TURBO` (`HSTOCK1`) with `MIRROR` + `KEEP` and page 1, so the tape hooks stay and
  their state at `$3B00–$3BFF` (`SDTAPE`, `SDERR`, the transfer counters and name buffer)
  is not mirrored over the dictionary. The tape in the player stays (the soft CPU
  holds it). Only a reset brings the extension back.
- **All modes end like `QUIT`**: the return stack is reset and the rest of the input
  line is not run. The data stack and the dictionary are kept. Use `TURBO` at the
  prompt or as the last word of a program.
- **Hardware stays live in every mode.** Software writing ports `$E1`/`$E3` can still
  remap memory, as before.

### Tape hooks (SD card as a tape)

The stock tape words (`SAVE`, `LOAD`, `BSAVE`, `BLOAD`, `VERIFY`, `BVERIFY`) do all their
tape I/O through two ROM routines:

| Routine | Address | On entry | Called from |
|---------|---------|----------|-------------|
| block write | `$1820` | HL = address, DE = length | 4 places (`$1A66`, `$1A6F`, `$1A7E`, `$1AED`) |
| block read | `$18A7` | HL = address, DE = length, C = flag (`$00` header, `$FF` data), carry set = load, clear = verify | the same routines |

ROM page 1 gets a **page-flip hook at each entry**, into **ROM page 3** (the SD page).
Page 2 can't be used, because its code already reaches the landing addresses below.

**Facts from the disassembly** (stock ROM):

- **Block write `$1820`:**
  - inputs: HL = address, DE = length, **C = flag** (`BIT 7,C` at `$182C` selects the
    leader length);
  - A is not an input: it is first written at `$1836` (`XOR A`);
  - callers: `SAVE`'s header at `$1A66` (C = `$00`) and its data at `$1A6F` (C = `$FF`),
    plus `$1A7E`/`$1AED` for the other words.
- **Block read `$18A7`:**
  - inputs: HL, DE, C = flag, and the **carry** (set = load, clear = verify), saved
    with `EX AF,AF'` at `$18B2`;
  - A's entry value is never used.
- **Shared exit `$1892`:** both routines push `$1892`. It restores IY, checks the SPACE
  row for BREAK (`JP NC,$04F0`), runs `EI`, and returns the result flags with
  `EX AF,AF'` / `RET` at `$18A5`/`$18A6`. The carry set means success.
- **`LOAD`'s header search:** it reads headers at `$1A7E` with the carry set. The return
  address `$1A81` retries on failure (`JR NC,$1A76`). It then compares the wanted header
  at `$2301` with the one read at `$231A`, and after a mismatch reads the next header
  (`JR NZ,$1A76` at `$1AB2`). **A return address of `$1A81` therefore marks a header
  search.**
- **Exits:** `$1AB6` is `RST $20` / `DB 10` (`ERROR 10`), and `$04F0` is `RST $20` /
  `DB 3` (BREAK).
- **No branch lands inside the bytes replaced below.** A scan at every byte alignment
  found only `$18D9`, which is the operand of `CALL $18FC`.

**Page 1 patches** (4 bytes each, `LD A,$C3` / `OUT ($E3),A`):

| Address | Replaces | Next fetch |
|---------|----------|------------|
| `$1820–$1823` | `PUSH IY` / `PUSH HL` / the first byte of `POP IY` | `$1824` in page 3 |
| `$18A7–$18AA` | `DI` / `PUSH IY` / `PUSH HL` (whole instructions) | `$18AB` in page 3 |

The hook changes A but not the flags, so the read routine's carry argument survives.

**Page 3 fixed addresses** (none overlap the interrupt copy ranges, §5):

| Page 3 address | Contents | Purpose |
|----------------|----------|---------|
| `$04EC–$04EF` | `LD A,$C1` / `OUT ($E3),A` | BREAK: continue at `$04F0` (`ERROR 3`) in page 1 |
| `$1824–$1826` | `JP TWRITE_HOOK` | entry from the block-write hook |
| `$1828–$182B` | `LD A,$C1` / `OUT ($E3),A` | cassette write: continue at `$182C` in page 1 |
| `$18A2–$18A5` | `LD A,$C1` / `OUT ($E3),A` | SD done: continue at `$18A6` (`RET`) in page 1, to the caller |
| `$18A7–$18AA` | `LD A,$C1` / `OUT ($E3),A` | cassette read: continue at `$18AB` in page 1 |
| `$18AB–$18AD` | `JP TREAD_HOOK` | entry from the block-read hook |
| `$1AB2–$1AB5` | `LD A,$C1` / `OUT ($E3),A` | end of tape: continue at `$1AB6` (`ERROR 10`) in page 1 |

**Handlers in page 3:**

- **`TWRITE_HOOK`:**
  - `SDTAPE` off: repeat `PUSH IY` / `PUSH HL` / `POP IY` / `LD HL,$1892` / `PUSH HL` /
    `LD HL,$E000` (`$1820–$182B`), then `JP $1828`. Execution continues at `$182C` in
    page 1, as if the hook were not there.
  - `SDTAPE` on: send `TWRITE` (flag C, length DE), then the bytes at HL in the data
    phase. Then `EI` and `JP $18A2`, which returns to the caller. Any error (for example
    a full card) leaves through `ERROR 10`.
- **`TREAD_HOOK`:**
  - `SDTAPE` off: `PUSH AF` around the flag test (keeps the carry), then repeat `DI` /
    `PUSH IY` / `PUSH HL` and `JP $18A7`. Execution continues at `$18AB` in page 1.
  - `SDTAPE` on: send `TREAD` with flag C and length DE. "search" is set when the return
    address on the stack is `$1A81`. Then:
    - **load** (carry set): store the bytes at HL;
    - **verify** (carry clear): compare them with memory;
    - **success:** carry set. A verify mismatch, or error 9 (a block with the wrong flag,
      length or checksum), gives carry clear, as a bad cassette block does, so `LOAD`'s
      search moves on. Then `EI` and `JP $18A2`;
    - **any other error** (end of tape, no tape, no card, I/O): drop the return address,
      `EI`, `JP $1AB2` (`ERROR 10`). A missing card therefore can't make `LOAD` retry
      for ever.
- **BREAK in SD mode:** after each block, the handlers test SPACE as `$1892` does
  (`LD A,$7F` / `IN A,($FE)` / `RRA`). If it is pressed they `JP $04EC`, with the
  caller's return address still stacked, as the ROM does.
- **Both handlers keep IX and IY unchanged** and leave AF' alone.

**Modes:**

- In `0 TURBO` and `1 TURBO` the hooks are live. `0 TURBO` keeps the `SDTAPE` setting, so
  a 51K Ace can load old programs from the card.
- `-1 TURBO` keeps page 1, so the hooks stay live too: with `SDTAPE` on, the tape words
  use the card and the tape chosen before the switch.
- `-2 TURBO` runs the stock page 0, so it always uses the real cassette.

ROM page 1 becomes "stock + 12 bytes": the boot hook plus two tape hooks. `romcheck`
checks exactly those bytes, and the page-3 fixed addresses.

**Possible addition** (not decided):

- With no tape in the player, a `LOAD name` header search could open `name.TAP` by
  itself, taking the wanted name from `$2302` (10 characters after the type byte at
  `$2301`). Today the Jupiter-IIb emulator gives `ERROR 10` there instead, so this
  would be a change on both.

### Calling into pages 2–6

Paging `$0000–$1FFF` swaps out the code under the PC, so the switch is made by a
stub in unpaged RAM (`$3000–$3BFF`). Interrupts stay **enabled** throughout:

1. `OUT` the target page
2. `CALL` the routine
3. `OUT` page 1
4. return to FORTH

**Every extension page (2–7) starts with a copy of the stock ROM's low area:**

- The `RST` entry points and the IM 1 handler at `$0038`, plus every stock routine
  the handler calls, byte-identical and at the same addresses.
- An interrupt therefore finds a working handler whichever page is mapped, and
  `FRAMES` stays exact even during long routines such as `PAINT` and `CIRCLE`.

#### Copy ranges (verified against the stock ROM image)

The ROM image is `ace.rom` from the Mercury_Ace repo, 8192 bytes,
SHA-1 `597ba8a15a292688333c84dc9fd35172abe5e7e6`. It was traced with `tools/misc/z80trace.py`.

| Range | Bytes | What | Needed for |
|-------|-------|------|------------|
| `$0010–$001F` | 16 | `RST $10` (push DE to the Forth stack) and `RST $18` (pop DE) | extension code using the Forth stack |
| `$0038–$003A` | 3 | IM 1 vector: `JP $013A` | interrupts |
| `$013A–$017D` | 68 | interrupt handler: saves registers, short delay, `FRAMES` (`$3C2B`) += 1, `CALL $0310`, editor branch (see below), restores registers, `EI`, `RET` | interrupts |
| `$0310–$0375` | 102 | keyboard scan and debounce (`$0310` → `$0336`, updates the key state at `$3C26`) | interrupts |
| `$0376–$03ED` | 120 | key-code tables: unshifted, SHIFT and SYMBOL SHIFT (data read by `$0370`; the base is chosen at `$033B` as `$57`, `$2F` or `$7F`) | interrupts |
| `$0859–$0864` | 12 | tails of `RST $18` / `RST $10` | extension code using the Forth stack |

Total **321 bytes**, at fixed addresses. Everything else in each extension page is free.

**The editor branch is not copied.** The handler also runs the line editor:
`$0155–$0175` calls `$0196`, `$01E6` (a jump table via `JP (HL)`), `$0282` and `$0807`,
about 370 bytes in total. That branch runs only while bit 0 of the keyboard-state flags at `$3C28` is 1.
- The bit is set by the line-input routine at `$0594` and cleared on ENTER at `$02D0`.
- During line input the foreground code is in page 1, so an extension page can never
  be mapped while the bit is set.
- As a belt-and-braces measure, extension pages patch the branch at `$0153` from
  `JR Z,$0176` (`28 21`) to `JR $0176` (`18 21`). The editor branch then becomes
  unreachable, and this is the only deviation from the stock bytes.

**Rules for extension code** (any stock routine not listed above is absent while its page is mapped):
- `RST $10` / `RST $18` may be used.
- **No `RST $08`** (print) and **no `RST $20`** (error, which goes to `$00AD`).
  Errors are returned to the stub, which raises them after switching back to page 1.
- Calls to any other stock routine (`$0000–$1FFF`) are forbidden. Extension code
  carries its own copies or returns to page 1.
- Free space in each extension page: `$0000–$000F`, `$0020–$0037`, `$003B–$0139`,
  `$017E–$030F`, `$03EE–$0858` and `$0865–$1FFF`: 7,871 bytes (about 7.7K).
  In page 2 (the boot page), `$0092–$009A` is also reserved for the boot hook's entry and exit.

### Where the extension code lives

- The stubs and the extension words live in **`$3000–$3BFF`** (3K, unpaged).
- At boot, the setup code in page 2 copies them there and links them into the
  FORTH vocabulary via `$3C47`, as `xrom.z` does.
- **Headers live in RAM; large code stays in ROM pages 2–6.**
  `FIND` walks the dictionary with page 1 mapped, so headers must be in unpaged RAM.
  - Word header: name, link, name-length and code field, about 10 bytes.
  - **Small words are complete in RAM.** These are colon words (`COUNT`, `+!`, `?`,
    `DEPTH`, `HEX`, which are lists of stock code-field addresses run by the page-1
    interpreter, so they cannot be dispatched) and short code words (colour, `$E3`,
    PSG, `CMOVE`, `FILL`).
  - **Large routines get an 8-byte stub:** `LD A,page` / `LD HL,routine` / `JP XDISPATCH`.
  - `XDISPATCH`, shared by all stubs, selects the page, calls the routine and restores
    page 1. A returned error (carry set, A = code) is stored in a RAM byte that
    follows an `RST $20` in RAM, and that `RST $20` is then executed. Errors therefore
    take the stock path, including the Jupiter-IIb emulator's trap at `$0020`.
  - Constants such as the colours are about 14 bytes each.
- **Name clashes with stock words.** The stock ROM already has `PLOT`, `LINE`, `CLS`,
  `BEEP`, `VIS` and `INVIS`.
  - Saved programs call stock words by address, so a shadowing word only affects
    source that is typed in or loaded.
  - `PLOT` is a **superset**: in MODE 0 it jumps into the stock code at `$0B4C`;
    in MODE 1 it plots in hi-res with the same `x y n` arguments.
  - `CLS` is a **superset** too: in MODE 0 it jumps into the stock code at `$0A1F`
    (`CALL $0A24 / JP (IY)`, which loads DE itself); in MODE 1 it clears the work page.
  - `LINE` (part of the interpreter) is never shadowed: `DRAW` draws lines and arcs.
  - Spectrum `OVER` clashes with the stack word `OVER`, so the graphics word is `FLIP`
    (named `GOVER` until v0.7).
  - `rom/` checks the shadow list at build time (`tools/misc/romcheck.py`).
- **Budget.** About 50 words (graphics, screen/memory, colour, sound,
  utilities) take about 1.0–1.2K. The rest of the 3K (about 1.8K) holds extension
  state (for example the plot position and the drawing variables) and room for future words.
- **Frozen addresses.** Compiled FORTH stores absolute word addresses, so a program
  `SAVE`d to tape that uses `PLOT` contains `PLOT`'s address.
  - The `$3000` area is therefore laid out like a jump table, fixed from the first release.
  - Each word's header and stub keep their address in every later ROM version.
  - New words are appended at the end, and none are ever moved or removed.
- **Rejected alternatives:** full code in RAM (does not fit: the graphics code is about
  4–6K); words in the user dictionary (`SAVE` would copy them into every program, and
  `FORGET` could delete them); headers in a ROM page (invisible to `FIND`).

### Boot hook (page-flip trampoline)

At `$008E` the stock reset sequence has finished: RAM test, system variables, character set.
The stock bytes there are `ED 56 18 09` (`IM 1` / `JR $009B`, the jump to `QUIT`).
Page 1 replaces exactly those 4 bytes:

```
; ROM page 1 (stock ROM + 4 bytes)
008E: 3E C2      LD  A,$C2       ; $E3 cmd 110 (ROMPAGE) = page 2
0090: D3 E3      OUT ($E3),A     ; page 2 mapped; the next fetch comes from page 2
```

```
; ROM page 2 (boot page)
0092:            ...TurboACE setup...
                 IM  1           ; replaces the stock IM 1 the patch overwrote
0097: 3E C1      LD  A,$C1       ; $E3 cmd 110 = page 1
0099: D3 E3      OUT ($E3),A     ; page 1 mapped; the next fetch is $009B in page 1
```

- **Fixed layout in page 2.** `$0092` is the entry point and `$0097–$009A` the exit sequence.
  The setup code itself does not fit in `$0093–$0096`: its first instruction at `$0092`
  is a `JP` to the setup routine elsewhere in page 2. That routine ends with `IM 1`
  and `JP $0097`.
- **Return to `QUIT`.** `$009B` in page 1 is `QUIT`: `LD SP,($3C18)`, `EI`, `JP $04F2`
  (verified in the ROM image). `QUIT` loads the stack from `RAMTOP` (`$3C18`), which
  is why `TURBO` can move the stack by changing `RAMTOP` and jumping there.
- **Second exit.** `$0099` alone (`OUT ($E3),A`) is also an entry: `-2 TURBO` arrives
  there with `A` = page 0 and continues at `QUIT` in the stock ROM, `-1 TURBO` with
  `A` = page 1.
- **Interrupts are off throughout.** Reset starts with `DI`, and the first `EI` is in
  `QUIT`, so the page flips cannot be interrupted.
- **No free space is needed in the stock ROM.** It has none: the only zero run,
  `$010F–$0119`, is system-variable data copied by reset.
- **Setup duties:**
  - copy the extension words and stubs to `$3000` and link `TURBO` alone via `$3C47` (`0 TURBO`);
  - leave `RAMTOP` as the RAM test set it, and remember it for `0 TURBO`;
  - windows 0/1 on pages 0/1;
  - AY: R7 b7–b6 = `11`, R14 = white INK / black PAPER, R15 = black BORDER;
  - `XCFG` = 0.

---

## 6. Extended registers (removed in v0.4)

The indexed register file at `$E1`/`$E5` existed for the sprites. Its only remaining
register, `XCFG`, is now `$E3` command `111` (§2.3), and the ID is read there too.
`$E5` is reserved; `$E1` is the user-RAM page port since v0.5 (§2.5).

---

## 7. Forth words mapped onto registers (sketch, names TBD)

| Word | Action |
|------|--------|
| `n TURBO` | `1`: full extension, stack below `$C000`; `0` (power-up): 51K Ace, `TURBO` and the SD words visible; `-1`: stock Ace keeping the card's tape (ROM page 1, `$3000` mirror but `$3B00–$3BFF`) until reset; `-2` and below: completely stock Ace (ROM page 0, the whole mirror) until reset. Ends like `QUIT` (§5) |
| `n MODE` | `$E3` cmd `100`. `0 MODE` = text, `1 MODE` = hi-res bitmap. |
| `n SCREEN` | 0–31: `VIEW` and `WORK` together. Shows and writes text page n and hi-res screen n (pages 2n, 2n+1); the graphics words map the screen while drawing and restore both windows |
| `n VIEW` / `n WORK` | Shadow screen. `VIEW`: `BG_VIEW` (text page n, and in hi-res screen n with text page n overlaid). `WORK`: `BG_CPU` (text page n for printing) and hi-res screen n for the graphics words |
| `n FONT` | 0–31: sets `CHR_CPU` and `CHR_VIEW` together |
| `p PG0` / `p PG1` | 8K page p (0–63) into window 0 (`$C000–$DFFF`) / window 1 (`$E000–$FFFF`): port `$E1` |
| `n ROMPAGE` | `$E3` cmd `110` (mainly for the ROM itself) |
| `INK` `PAPER` `BORDER` and the colour constants, `DARK` | AY R14 / R15 |
| `PLAY!` `PLAY@` | AY `$FD` / `$FF` |
| `x y n PLOT` | superset of stock `PLOT`. MODE 0: stock 64×48 blocks. MODE 1: 256×192 pixel, origin bottom-left; n = 0 unplot, 1 plot, 2 move, 3 invert. Sets the position for `DRAW` |
| `dx dy a DRAW` | Spectrum `DRAW x,y,a`: from the last position to position + `(dx, dy)`, turning through `a` degrees (integer; taken modulo 360 keeping its sign). `a` = 0: straight line; `a` > 0: anticlockwise arc; `a` < 0: clockwise. Arcs are chords every 5° plus a last chord to the exact end point; a radius over about 5,600 pixels gives a straight line. Uses the `INVERSE`/`FLIP` mode. The end point (clamped to the screen) becomes the new position |
| `x y r CIRCLE` | Spectrum `CIRCLE`: centre and radius; each pixel drawn once |
| `x y POINT` | Spectrum `POINT`: 1 if the pixel is INK, else 0 (0 off screen) |
| `f INVERSE` / `f FLIP` | Spectrum `INVERSE` / `OVER` for `DRAW`, `CIRCLE` and `PAINT`: neither = plot, `INVERSE` = unplot, `FLIP` = invert, both = move only |
| `x y ATTR` | Spectrum `ATTR`: the PAPER:INK colour byte. MODE 1: of the 8×1 cell holding pixel `(x, y)`. MODE 0: of the character cell at column `x` 0–31, line `y` 0–23 from the top (read via `XCFG.ATTR`). 0 if out of range |
| `CLS` | superset of stock `CLS`. MODE 1: clears the work screen to the current PAPER:INK (position 0,0), then the text with the stock `CLS` |
| `f SDTAPE` / `TAPE name` / `EJECT` | SD card as the tape for the stock tape words (§5 "Tape hooks") |
| `DIR` / `CD name` / `DELETE name` / `SDERR` | SD card folder, files and last error (§2.6) |
| `p PGSAVE name` / `p PGLOAD name` | save / load 8K RAM page p as `name.PG` |
| `n SCRSAVE name` / `n SCRLOAD name` | save / load hi-res screen n (bitmap + colour, 12K) as `name.SCR` |
| `n FONTLOAD name` | load a 1K character set into font n from `name.FNT` |
| `f OPAQUE` | hi-res text overlay: `0` transparent (default), non-zero opaque (`XCFG.OPAQUE`) |
| `x y PAINT` | flood fill (4-connected) from `(x, y)`, hi-res only. Plot or `FLIP`: the PAPER area becomes INK; `INVERSE`: the INK area becomes PAPER; both: nothing. Touched bytes get the current PAPER:INK. Pending spans use the free RAM between the Forth data stack and `RAMTOP`; if it runs out, `ERROR 1` (part of the area stays filled). About 1.4 s for a full screen; areas broken up by many small gaps (noise) take up to about 8 s |
| `addr n byte FILL` | memory fill (Jupiter-II word, unchanged name) |
| `.S` `'` `2*` `2/` `0<>` `GR` | programming words, in RAM (decision 28) |
| `CASE` `OF` `ENDOF` `ENDCASE` | compiler words, built like the ROM's `IF` (decision 28) |
| `n RND` / `n RAND` | random numbers (decision 28) |
| `PI` `FSQRT` `FSIN` `FCOS` `FTAN` `FABS` `F<` `F>` `F0<` `F0=` | floating point (decision 29) |
| `2DUP` `2DROP` `2SWAP` `2OVER` `2ROT` `D.` `D.R` `D-` `D=` `D0=` `DABS` `S->D` | double-cell words (decision 28) |

---

## 8. Decisions

### Decided

1. **512K paged RAM**, as 64 × 8K pages in two independent windows, `$C000–$DFFF` and
   `$E000–$FFFF`, selected through port `$E1` (§2.5).
2. **32K fixed RAM at `$4000–$BFFF` and 3K at `$3000–$3BFF`** come from TurboACE.
   Base RAM is 36K. The host is a stock 3K Ace with no RAM pack.
3. **Colour** lives in AY R14/R15 only.
4. **Hi-res** is a direct bitmap only, held in two user-RAM pages (2n, 2n+1):
   6K bitmap, 6K 8×1 colour, 4K free. Up to 32 screens.
5. **Video timing** is 50 Hz PAL only, with stock Ace timing:
   312 lines × 208 T-states = 64,896 T-states per frame, about 50.08 Hz at 3.25 MHz.
   The emulator starts from Jupiter-IIb's "Jupiter Ace" machine timing.
6. **Compatibility** covers original Jupiter Ace software only; Mercury_Ace and
   Jupiter-II software are not targets.
7. **No serial port. SD card storage is in** (since v0.8, decision 22).
8. **CPU speed** is the stock 3.25 MHz. "Turbo" is only part of the name; there is no speed-up mode.
9. **No sprites** (dropped in v0.4). TurboACE is implemented on a **Sipeed Tang Nano 20K
   FPGA module** (since v0.8; it was discrete logic before), on an adapter board with
   3.3V/5V bus buffers. The FPGA answers the Z80 bus in logic, holds all RAM and the
   ROM in its 8 MB SDRAM and block RAM, and generates video and sound.
10. **Paged-ROM calls** keep interrupts enabled. Every extension page carries a copy
    of the stock ROM interrupt path and the Forth stack `RST`s: 321 bytes at fixed
    addresses, with one patched byte at `$0153` (§5).
11. **Boot hook** is a page-flip trampoline. Page 1 = stock ROM + 4 bytes at `$008E`
    (`LD A,$C2` / `OUT ($E3),A`). Page 2 is the boot page, entered at `$0092`, which
    returns through `$0097–$009A` into `QUIT` at `$009B` (§5).

12. **Extension words:** headers and stubs in the 3K at `$3000` (2,740 bytes used of 2,816),
    code in ROM pages 2–6 via a shared dispatcher. Addresses are frozen like a
    jump table, and new words are only appended (§5).

13. **Fill naming:** `FILL` is the memory fill, keeping its Jupiter-II name (`addr n byte FILL`).
    The graphics flood fill is **`PAINT`** (`x y PAINT`).

14. **Graphics words** follow the ZX Spectrum: `PLOT` `DRAW` `CIRCLE` `POINT` `INVERSE`
    `FLIP` `CLS`, plus `PAINT`. `DRAW` draws lines (no graphics `LINE`) and arcs with Spectrum's third argument
    (`dx dy a DRAW`, `a` in degrees); there is no separate `ARC`.
    `PLOT` and `CLS` are supersets of the stock words (§5, §7).
15. **No hardware scroll:** `HSCROLL` and the `SCROLL` word are dropped.
16. **Video and sound go out over HDMI** (since v0.8): 720×576 at 50 Hz, with the AY
    sound as HDMI audio. Analogue RGB is dropped.
    - **In the FPGA design** (`fpga/rtl/top_standalone.v`): hdl-util/hdmi, video code 17;
      sound 48 kHz, 16 bits (`audio.v`: the AY and the beeper, averaged per sample,
      silence 0). One PLL gives 54 MHz (system), 135 MHz (TMDS) and 27 MHz (pixel), so
      the pixel clock is exactly half the system clock. The pixel and the HDMI side's
      reset cross from 54 MHz to 27 MHz on the 54 MHz edge where the pixel clock falls
      and are taken where it rises, and reset ends at a fixed pixel-clock phase: no two
      clock domains meet at one edge, and every pixel lands in place, checked by
      decoding the HDMI core's TMDS symbols (`make -C fpga hdmi`, `make -C fpga top`).
17. **`ATTR`** reads the colour (`x y ATTR`, §7).
18. **No extended register file.** `XCFG` (the `ATTR` bit) is `$E3` command `111`, and
    reading it returns the ID `1010100a` (§2.3). About 1 chip instead of 5–7.
19. **Two 8K user-RAM windows** with 6-bit page numbers through port `$E1` (§2.5), so two
    memory areas can be mapped independently. `$E3` command `101` is reserved.
20. **No boot jumper:** the machine always boots into `0 TURBO` (51K, like a 48K RAM pack),
    and the word `TURBO` selects `1` (full extension), `0`, `-1` or `-2` (stock Ace until
    reset; decision 32). `XCFG` bit 1 is `MIRROR`, bit 3 `KEEP` (§5).
21. **Text overlay in hi-res:** text page `BG_VIEW` is shown over the bitmap with its own
    colours; transparent by default, opaque with `XCFG` bit 2 (`OPAQUE`, word `OPAQUE`).
22. **SD card** on the module's microSD slot (since v0.8). A small soft CPU inside the FPGA
    (e.g. a RISC-V core such as PicoRV32) runs **FatFs** for the FAT file system, so
    cards are readable on a PC. The Z80 sends file-level commands through `$E5`/`$E7`.
    Uses, in order: program files in the emulators' tape-file format (`.TAP`), a
    directory listing, saving and loading RAM pages, screens and fonts; Forth blocks
    later. Stock `LOAD`/`SAVE` and the real tape port are unchanged.
23. **SD card words and protocol** (§2.6, §5 "Tape hooks"). The stock tape words use the
    card through a virtual tape player that behaves like the Jupiter-IIb emulator's
    (`SDTAPE`, `TAPE`, `EJECT`). New words handle files: `DIR`, `CD`, `DELETE`,
    `PGSAVE`/`PGLOAD`, `SCRSAVE`/`SCRLOAD`, `FONTLOAD`, `SDERR`. Failures give
    `ERROR 10`, like a tape error; `SDERR` gives the reason.
24. **Two bitstreams from one HDL tree** (the same modules, two top levels):
    - **Expansion:** the FPGA on the adapter board, driving the real Ace's bus.
    - **Standalone Ace:** no real computer. A Z80 core in the FPGA at 3.25 MHz, with the
      Ace's keyboard port `$FE`, beeper and 50 Hz interrupt; a **PS/2 keyboard**; tape
      through the SD card only (`SDTAPE` always on, no cassette); the Ace's own internal
      RAM is not there, so open item 1 does not apply.
    - **ROM at power-up, both builds:** the soft CPU loads the stock ROM from **`/ace.rom`** on the card at power-up,
      with the Z80 held in reset. It checks the MD5 (`db6efdfd82cebdfbb493d85b1a5efc3c`,
      8,192 bytes), makes page 0 from it and page 1 with the 12-byte hooks; pages 2–7 are
      TurboACE's own, from the board's flash. Neither the bitstream nor the flash contains
      any stock ROM byte: the 321-byte copy of the stock interrupt path in each of pages
      2–7 is filled in from `/ace.rom`.
    - **Switching** between the two builds means re-flashing the board (openFPGALoader,
      decision 25).
    - **If it fails** (no card, no file, not 8,192 bytes, wrong MD5, no TurboACE pages in
      the flash): the **standalone** build writes `TURBOACE: CANNOT START` and the reason
      on its screen and tries again every second, so inserting the card is enough. The
      **expansion** leaves `/ROMCS` alone and releases the Ace, which boots its own ROM
      as a stock machine (TurboACE's words are then absent until the next power-up).
    - **In the firmware:** `firmware/src/romload.c`, `md5.c`; tested in `firmware/test/romtest.c`
      against `rom/build/turboace.rom`, byte for byte.
25. **Standalone Z80 core: T80** (Daniel Wallner; the MiSTer-maintained version), the
    synchronous variant with a clock enable, stepping at exactly 3.25 MHz.
    - **Toolchain:** Gowin EDA (mixed VHDL/Verilog), for both bitstreams.
    - **Programming: openFPGALoader** (open source, Apache 2.0), through the module's USB
      port: `-b tangnano20k -f <bitstream>` writes a bitstream to the flash, and
      `--external-flash -o 0x500000 rom/build/turboace-flash.bin` writes TurboACE's ROM
      pages. A recent build is needed (distribution packages may predate the 20K). The
      top-level `Makefile` runs them: `make program`, `program-bitstream`, `program-rom`,
      `load`.
    - **Video contention reproduced:** as on the stock Ace, a CPU access to the
      video-priority copies (`$2400–$27FF` screen, `$2C00–$2FFF` characters) during the
      picture holds the Z80 with `WAIT` until that line's picture ends (lines 0–191, the
      first 128 T-states of each 208), so timing-sensitive software runs as on a real Ace.
      The CPU-priority copies (`$2000–$23FF`, `$2800–$2BFF`) never wait.
    - **Frame** (as the stock Ace, from JupiterACE_MiSTer): 312 lines of 208 T-states
      (64,896 T, 50.08 Hz); INT low for 8 lines from T-state 154 of line 248. The
      3.25 MHz T-state enable is 13 clocks in 216 of the 54 MHz system clock, exact on
      average. `fpga/rtl/acetiming.v`, tested in simulation.
    - **No other wait states** (`fpga/rtl/cpubus.v`): a read is started as early as the
      Z80 shows it (an opcode fetch from M1 at T1's start) and is in time for when the Z80
      takes the byte; writes are posted, and a BG write's colour byte waits in a one-byte
      buffer until the next opcode fetch has been served, so it never delays a read. In
      simulation, with video fetching hi-res meanwhile, no ordinary read got a wait state.
    - **SDRAM sharing:** `fpga/rtl/arbiter.v` serves the CPU first; in simulation a CPU
      request waits at most 19 clocks (350 ns) while video keeps more than twice the
      throughput a line needs.
    - **Licence (checked):** BSD 3-clause style, Copyright (c) 2001-2002 Daniel Wallner,
      with changes by MikeJ and Sorgelig (2018, version 350) under the same terms, as read
      in the MiSTer version's sources (`T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`,
      `T80_Reg.vhd`, `T80pa.vhd`). Keep the notice in the sources; the standalone
      bitstream's documentation must reproduce it, so `THIRD-PARTY.md` carries it and
      ships with the bitstreams. No endorsement by the authors may be implied. It mixes
      freely with the GPL firmware (open item 5). The MiSTer top level is `T80pa`, with
      clock enables `CEN_p`/`CEN_n` and `WAIT_n`, which suits the 3.25 MHz step.
    - **Verification:** ZEXDOC/ZEXALL in simulation, and the TurboACE ROM run in lockstep
      on T80 and on the harness's Z80 core, comparing bus cycles and T-states.
    - **Simulated whole** (`make -C fpga system`): GHDL turns T80 into Verilog
      (`fpga/sim/fix_t80_netlist.py` restores an assignment GHDL 5.1.1 drops and starts the
      registers at 0, as the FPGA's flip-flops do), and the real TurboACE ROM boots on it
      through the bus, ports, SDRAM and video, in 193,905 T-states; the screen and all the
      system variables equal the C harness's after the same boot, and the 50 Hz interrupt
      counts FRAMES.
    - **Found that way:** T80pa's interrupt-cycle register has no reset and starts at 0 on
      the FPGA, so the first two opcode fetches after power-up also drive IORQ low. The
      bus treats every cycle with MREQ low as memory (a real interrupt acknowledge has
      MREQ high), so this does no harm.
26. **Standalone keyboard (PS/2):**
    - **Hardware:** a PS/2 receiver with a small FIFO, a sender (for the LEDs), and a 40-bit
      matrix register answering port `$FE` (bits 0–4 ANDed over the rows selected by
      A8–A15; matrix as in the ROM's tables at `$0376`).
    - **Translation in the soft CPU's firmware:** scan-code set 2 (`E0`, `F0`); the whole
      matrix is recomputed from the keys held after every event.
    - **Two modes, Scroll Lock toggles them** (its LED shows positional): **symbolic**
      (power-up: the character on the PC keycap, e.g. PC `=` → SYMBOL SHIFT + L, PC Shift
      held back) and **positional** (for games: Shift = SHIFT, Ctrl = SYMBOL SHIFT).
    - **Special keys, both modes:** Backspace = DELETE (SHIFT + 0), arrows Left / Up /
      Down / Right = SHIFT + 5 / 6 / 7 / 8, Esc = BREAK (SHIFT + SPACE), Caps Lock = CAPS
      LOCK (SHIFT + 2, LED follows), Tab = DELETE LINE (SHIFT + 1), F4 = INVERSE VIDEO
      on/off (SHIFT + 4), F9 = GRAPHICS on/off (SHIFT + 9), Ctrl+Alt+Del = reset the Ace.
      From the ROM's editor: SHIFT + 5/6/7/8 give codes `$01`/`$07`/`$09`/`$03`, handled
      at `$0204` (left), `$0247` (left 32 = up), `$0295` (right 32 = down), `$0211` (right);
      SHIFT + 3 just types `3` (there is no separate TRUE VIDEO code: SHIFT + 4 toggles).
    - **PC layouts: US and Portuguese**, chosen (with the starting mode) in a settings file
      on the card, `/turboace.cfg`, read at power-up; US if it is missing. Format: lines
      `keyboard = us | pt` and `keymode = symbolic | positional`, `#` comments, not
      case-sensitive; anything else is ignored. Portuguese dead keys (´ ` ~ ^) type at
      once; ç, º, ª, «, », £, §, € have no Ace key and type nothing.
    - **In the firmware:** `firmware/src/keyboard.c`, `config.c`. Both layouts type all 95
      printable ASCII characters, checked through the ROM's own keyboard routine.
27. **Standalone carrier (PS/2 keyboard hardware):** the standalone build has no adapter
    board; a small carrier holds the Tang Nano 20K, a PS/2 socket and a level shifter
    (parts in `hardware/standalone-carrier.md`).
    - **Why a shifter:** the keyboard runs at 5 V with open-collector clock and data lines
      pulled up to 5 V (some keyboards have their own 5 V pull-ups), and the FPGA's pins
      are 3.3 V and not 5 V tolerant. Both lines are bidirectional (keys in, LED commands
      out), so a resistor divider will not do.
    - **The shifter:** two channels of a BSS138 bidirectional level shifter, 10 kΩ
      pull-ups on each side (to 5 V and to 3.3 V).
    - **Wiring:** PS/2 6-pin mini-DIN socket pin 5 (clock) and pin 1 (data) to the 5 V side;
      the 3.3 V side to two FPGA pins (`ps2_clk`, `ps2_dat`); pin 4 (+5 V) from the Tang
      Nano's 5 V pin (USB), pin 3 to GND. A keyboard draws about 50–100 mA (PS/2 allows
      up to 275 mA).
    - **FPGA side:** both pins open-drain, only ever driven `0` or left `Z`. The two pin
      numbers: 73 (clock) and 74 (data), the first two pins of the left header at the
      USB end, with no on-board function (`fpga/tang_nano_20k_standalone.cst`). Not 52
      and 53 (the first choice): those are the HDMI connector's EDID lines, the
      monitor's I2C bus, where PS/2 traffic would look like I2C starts and stops.
      `fpga/rtl/ps2.v`, tested against a model keyboard.
    - The expansion build does not need it (it uses the Ace's own keyboard).
28. **Programming words** (from the user's own Forth library, rewritten for the ROM):
    `.S` `'` `2*` `2/` `0<>` `CASE` `OF` `ENDOF` `ENDCASE` `RND` `RAND` `GR`, and the
    double-cell words `2DUP` `2DROP` `2SWAP` `2OVER` `2ROT` `D.` `D.R` `D-` `D=` `D0=`
    `DABS` `S->D`. All in the RAM at `$3000` (791 bytes at first; `RND`'s body later moved to ROM page 4, decision 29).
    - **`CASE` `OF` `ENDOF` `ENDCASE`** are compiler words laid out like the ROM's own `IF`:
      code field `$1108`, the run-time part's code field as the first cell, then the
      compile-time cells; each run-time part is preceded by its operand count and an
      offset to the byte before the word's name, so `LIST` and `EDIT` show them. Standard
      semantics: the value stays on the stack for the default words, and `ENDCASE`
      drops it (no `OTHERWISE` needed). Wrong nesting gives `ERROR 5`.
    - **`.S`** is the cells the ROM compiles for
      `15419 @ HERE 12 + OVER OVER - IF DO I @ . 2 +LOOP ELSE DROP DROP THEN`.
    - **`'`** gives the parameter field (Forth-79, as the library's version); an unknown
      word gives `ERROR 13`.
    - **`RND`:** seed' = ((seed + 1) × 75 mod 65537) − 1, a full cycle of 65,536;
      result = seed' × n / 65536. `0 RAND` seeds from `FRAMES`.
    - **`D.R`** clamps the padding at 0, so a number wider than the field prints whole.
    - **`GR`** writes the character set at `$2C00` (the font chosen for writing, `CHR_CPU`).
    - The rest of the library (strings, arrays, floating-point functions, the time and
      word-inspection words) is left for a library of tape files on the SD card.
    - **Tested by typing them into the real ROM** in the harness (Forth sessions: the
      whole machine from reset with the 50 Hz interrupt, keys through the PS/2
      translation), including `LIST` of a `CASE` word, and `RND` against the formula
      for a full cycle.
29. **Floating-point words:** `PI` `FSQRT` `FSIN` `FCOS` `FTAN` `FABS` `F<` `F>` `F0<`
    `F0=`, from the user's library but rewritten:
    - **Format** (read from the ROM): two cells, on top [sign + exponent (excess `$40`)]
      [BCD digits 1–2], under it [digits 3–6]; value 0.d1…d6 × 10^(exponent − `$40`).
      `F0<`, `F0=` and `FABS` work on those bits in machine code.
    - **`FSQRT`:** a first guess from the exponent (ROM page 4, `src/mathpage.asm`) within
      a factor of 2, then 5 Newton steps: all six digits. Negative gives `ERROR 8`.
    - **`FSIN`:** the sign taken out, x reduced to 0–2π with `INT` (|x| up to about
      200,000), then to −π/2…π/2, then the Taylor series to x^13. `FCOS` x = `FSIN`
      (x + π/2); `FTAN` = `FSIN` / `FCOS`.
    - The colon words are the cells the ROM compiles for their source, produced by
      `tools/misc/acecomp.py` from a harness session (the source is in the comments).
    - **Room:** `RND`'s body moved to ROM page 4 to make space; the extension RAM now
      holds 2,740 of its 2,816 bytes (76 free). Further words need stubs to ROM pages.
    - **Tested** against C's maths library, typed into the ROM: square roots of odd and
      even exponents, and sine, cosine and tangent at a range of angles.
30. **Soft CPU: RV32IC, 48K of block RAM** (measured with GCC 15.2, `-Os`, all of the
    firmware: SD protocol, FatFs with long names and exFAT, keyboard, settings, ROM
    loader):
    - **RV32IC** (with compressed instructions): 30,172 bytes of code and 6,349 of data,
      36,521 in all. **RV32I:** 46,905, which leaves too little of 48K for the stack.
    - **Stack:** the deepest call chains (`rom_load` → `f_open` → path lookup;
      `sdp_command` → `f_getcwd`) are about 2K; 4K is kept free, and the link fails if
      the firmware leaves less.
    - **Savings made:** the ROM loader works in 512-byte chunks instead of an 8K page
      buffer (the Z80 is held in reset, so pages written before the MD5 is checked do no
      harm), and one FatFs work area (`sdp_fs`) serves power-up, the settings file and
      the SD protocol.
    - The rest of the GW2AR-18's block RAM (about 100 KB in all) stays for the FIFOs,
      video and the FPGA's own needs; ROM pages and user RAM are in the SDRAM.
    - **Build:** `./download_toolchain.sh` once, then `make -C firmware firmware`
      (`MARCH=rv32i` for a core without compressed instructions, which then needs more
      RAM). `src/libc.c` gives the eight C library functions the firmware uses.
31. **Reused cores** (each goes into `THIRD-PARTY.md` with its notice as it comes into the
    design):
    - **Soft CPU: PicoRV32** (YosysHQ, ISC licence) with `COMPRESSED_ISA = 1` (RV32IC,
      decision 30): about 1,000 logic cells, about 4 clocks per instruction, a simple
      valid/ready memory interface.
    - **HDMI: hdl-util/hdmi** (Sameer Puri, MIT or Apache 2.0): sound in HDMI data
      packets; NESTang (GPL-3.0) uses it on the Tang Nano 20K with sound. 720×576 at
      50 Hz (video code 17) is in its table and must be tested on the board. Gowin's DVI
      transmitter has no sound.
    - **SDRAM controller: our own**, simple (start-up sequence, refresh, one access at a
      time): the Z80's speed needs nothing more, and it avoids GPL or licensed IP.
      Written: `fpga/rtl/sdram.v`, tested in simulation (Icarus Verilog) against a model
      of the chip that checks its start-up and timing rules: 20,000 random byte writes
      and reads over the 8 MB, byte lanes, refresh while idle (`make -C fpga test`).
    - **AY sound: `ay.sv` from JupiterACE_MiSTer** (the user's own core, GPL v2+): made
      for a 3.25 MHz Ace; the user may relicense it.
    - **In the design** (`fpga/rtl/`): `picorv32.v`, `hdmi/` and `ay.sv`, all unchanged;
      the standalone build simulated whole from power-on to an HDMI frame (`make -C fpga
      top`): the firmware loads the ROM from a FAT card, the T80 boots it, and every
      pixel of a decoded frame equals the screen in the SDRAM.
    - **Built with Gowin EDA** (`make -C fpga bitstream`): 43% of the logic, 36 of 46
      block RAMs, timing met at 54 MHz. The T80 is slower than one 54 MHz clock, so
      its outputs are taken two clocks after each of its clock enables and its paths
      timed as two clocks; `make -C fpga system-slow` checks that this is safe.
    - **Licences:** all permissive except `ay.sv`; with the firmware (open item 5) these
      decide whether the project is GPL.
    - **HDMI licensing:** development and hobby use are fine; selling devices with HDMI
      output (not plain DVI, which has no sound) needs the maker to be an HDMI Adopter.

32. **The card in the stock modes** (since v0.9). `0 TURBO` (power-up) links `TURBO` and
    the SD words `SDTAPE` `TAPE` `EJECT` `DIR` `CD` `DELETE` `SDERR` (two link fields
    rewritten; no memory used), so a 51K Ace loads old programs from the card at once.
    `-1 TURBO` is a stock Ace that keeps the card's tape: ROM page 1 (stock + the tape
    hooks, 12 bytes), the `$3000` mirror except `$3B00–$3BFF` (`XCFG` bit 3 `KEEP`), which
    hold the SD code's state; no words added, no dictionary used. `-2 TURBO` (and below)
    is the completely stock Ace (page 0, byte-identical, the whole mirror, the real
    cassette), what `-1 TURBO` was before. Both stay one-way until reset. On the
    standalone build, which has no cassette, `-1 TURBO` is the stock Ace with a tape;
    `-2 TURBO` has none.
    - Words in the dictionary for `-1 TURBO` were considered and dropped: the SD code's
      state at `$3B00` would be mirrored over the dictionary, and `0 TURBO` already gives
      the words with no memory.
    - Tests: `test/gfxtest.c` (the modes, the links, a Forth session that saves in
      `0 TURBO`, chooses the tape, switches to `-1 TURBO`, loads, runs and appends with the
      real SD firmware); `fpga/sim/ports_tb.v` (the `KEEP` decoding).
    - Stock behaviour seen in the tests: after a dictionary `LOAD`, `$3C39` is 0, and a
      later `SAVE` or error makes the ROM's end-of-definition code (`$0F36`) store a
      word length through it, at `$0000` (ROM: no effect). The harness ignores exactly
      that store. Whether a real Ace with a cassette behaves the same is not checked.

### Open

1. **The Ace's internal video RAM** (`$2000–$2FFF`) still answers CPU reads: the edge
   connector has `/ROMCS` but no line to disable that RAM. The FPGA can follow every
   write, but CPU reads of text pages, fonts or colour RAM other than the internal
   ones need a motherboard modification, or a rule that only page 0 is CPU-readable.
2. **Edge-connector details** to check against the Ace schematic: the `/ROMCS` polarity
   and drive, and driving `/WAIT` open-drain.
3. **Power:** the module's current against the Ace's 5V supply; the adapter board may
   need its own regulator from the Ace's 9V line, or USB power.
4. **Beeper over HDMI:** the FPGA could also reproduce the Ace's own beeper in the HDMI
   audio by watching the port accesses that drive the speaker (to be checked).
5. **Firmware licence:** `firmware/src/sdproto.c`'s TZX block walker and LOAD-search
   logic follow Jupiter-IIb's `src/tape_sd.cpp` closely, and that file is GPL v2+
   (derived from xAce). Treat the firmware as GPL v2+ unless those parts are cleared or
   rewritten. FatFs itself is under ChaN's one-clause BSD licence. (The hook
   placement is finalised in §5 "Tape hooks".)
6. **Module facts to confirm** from the Sipeed and Gowin datasheets: usable GPIO count
   (about 34 is assumed; the bus needs 32–33), I/O voltage, and current draw.
7. **`/ace.rom` missing or wrong** (decision 24): implemented as described there. To
   check on the hardware: that the Ace's own reset can be held from the adapter board
   (open item 2), and that the Ace boots cleanly on its ROM when `/ROMCS` is left alone.

Next deliverables: the adapter-board schematic, PCB and BoM (KiCad; the PS/2 carrier too), the FPGA design (Verilog), the
soft-CPU firmware (C, FatFs), the rest of the ROM source (`rom/`), and the Jupiter-IIb
emulator changes.
