# TurboACE: what is where

TurboACE is a hardware expansion for the Jupiter Ace, built on a Tang Nano 20K FPGA
module, with a second build that is a whole Jupiter Ace inside the FPGA. This index
lists the folders and main files. `README.md` is the user's guide; `requirements.txt`
says what the project must do; `register-map.md` records how and why.

## Top folder

| File | What it is |
|---|---|
| `README.md` | the user's guide: what TurboACE does, the two builds, the new Forth words, the PS/2 wiring |
| `requirements.txt` | the requirements |
| `register-map.md` | the design reference: memory map, I/O ports, video and SD protocols, and the numbered design decisions with their reasons |
| `THIRD-PARTY.md` | the reused code and its licences |
| `Makefile` | programs the Tang Nano 20K with openFPGALoader: `make program`, `make load` (listed at its top) |
| `build.sh` | builds everything into `release/`: the files written into the FPGA module |
| `download_toolchain.sh` | fetches and builds the tools into `toolchain/` |
| `clean.sh` | deletes what the builds make (`-n` lists it first; `--toolchain` also the downloaded tools); keeps KiCad's local history and per-user files |
| `INDEX.md` | this file |

## Folders

### `rom/`: the TurboACE ROM (Z80 assembler, sjasmplus)
The ROM pages added to the stock Jupiter Ace ROM: graphics, colour, paged RAM, the SD
card words and the new Forth words. The stock ROM itself is not here: it is loaded from
`/ace.rom` on the SD card.
- `turboace.asm`: the main file; builds every page
- `src/`: `boot.asm` (start-up), `xdict.asm` (the new dictionary words), `gfx.asm`
  (PLOT, DRAW, CIRCLE, PAINT…), `sdpage.asm` (SD card and virtual tape), `mathpage.asm`
  (floating-point words), `lowcopy.asm` (code copied to RAM)
- `inc/`: hardware equates (`hw.inc`), the stock ROM's words and internals, the sine table
- `README.md`: how the ROM is built and laid out

### `firmware/`: the soft CPU's program (C, RV32IC)
Runs on the PicoRV32 inside the FPGA: loads the stock ROM from the SD card, serves the
Z80's file commands with FatFs, and translates the PS/2 keyboard.
- `src/`: `main.c`, `romload.c` (ROM loading, MD5 check), `sdproto.c` (the Z80's SD
  commands), `keyboard.c` (PS/2 to the Ace's keyboard matrix), `config.c`
  (`/turboace.cfg`), `diskio_sd.c` (the card for FatFs), `hal_fpga.c`, `start.S`, `link.ld`
- `fatfs/`: FatFs (ChaN), unchanged
- `test/`: the firmware's logic run on the PC with a RAM disk

### `fpga/`: the FPGA design (Verilog) and its simulation tests
- `rtl/`: the design. `top_standalone.v` (the standalone build's top level),
  `ace_core.v` (the Jupiter Ace: Z80 bus, memory map, ports, video, SDRAM),
  `cpubus.v`, `memmap.v`, `ports.v`, `video.v`, `sdram.v`, `arbiter.v`, `acetiming.v`,
  `mailbox.v`, `fifo.v`, `sdcpu.v` (the soft CPU system), `spi_master.v`, `ps2.v`,
  `audio.v`, `gowin.v` (the Gowin primitives). Reused, unchanged: `T80/` (the Z80),
  `picorv32.v`, `hdmi/` (hdl-util/hdmi), `ay.sv`
- `sim/`: testbenches and models (SDRAM, SD card, SPI flash); `system_tb.v` boots the
  ROM on the real T80, `top_tb.sv` simulates the whole board from power-on to an HDMI frame
- `turboace_standalone.gprj`, `.sdc`, `impl/project_process_config.json`,
  `gowin_build.tcl`: the Gowin EDA project, timing constraints, settings and build script
- `tang_nano_20k_standalone.cst`: the pins
- `Makefile`: `make test`, `make system`, `make top`, `make bitstream`… (listed at its top)
- `README.md`: every file and test in detail

### `kicad/`: the boards (KiCad 10)
`lib/` holds TurboACE's own KiCad parts (the Tang Nano 20K symbol and footprint), and
`kigen.py` the generator the boards are made with. One folder per build, each with a
schematic, a PCB (placed, routed by hand) and a BoM:
`expansion/` (the adapter board on a real Ace) and `standalone/` (the PS/2 carrier).
See `kicad/README.md`.

### `hardware/`
- `standalone-carrier.md`: the standalone build's PS/2 carrier, parts and wiring

### `test/`: the ROM tested on the PC
A small Jupiter Ace emulator harness: `gfxtest.c` boots the ROM, types Forth and checks
the screen and memory; `z80core.c` is its Z80; `symsh.py` helps with symbols.

### `release/`: the build output (from `build.sh`, not in git)
One folder per build, each with what is written into the Tang Nano 20K and a
`LOAD.txt` with the commands:
- `standalone/`: `turboace-standalone.fs` (the bitstream, with the soft CPU's firmware
  inside) and `turboace-flash.bin` (TurboACE's ROM pages)
- `expansion/`: `turboace-flash.bin`; its bitstream joins it when that build exists

At the top: the firmware alone (`sdcpu.bin`, `sdcpu.elf`), checksums and licence notes.

### `tools/`: tools kept in git
| Path | What it is | Used for |
|---|---|---|
| `sjasmplus/` | sjasmplus 1.20.3, Z80 assembler (source; built here by `build.sh` or `make -C tools/sjasmplus`) | the ROM |
| `misc/acedict.py` | the stock ROM's dictionary as equates (`rom/inc/ace_words.inc`) | the ROM |
| `misc/acecomp.py` | compiled Forth words as assembler | the ROM |
| `misc/romcheck.py` | static checks on the built ROM (`make -C rom check`) | the ROM |
| `misc/sintab.py` | the sine table (`rom/inc/sintab.inc`) | the ROM |
| `misc/z80dis.py`, `misc/z80trace.py` | disassembler, code tracer | studying the stock ROM |

### `toolchain/`: downloaded tools (not in git; `./clean.sh --toolchain` empties it)
| Folder | Tool | Used for |
|---|---|---|
| `xpack-riscv-none-elf-gcc-15.2.0-1/` | xPack RISC-V GCC 15.2.0 | the firmware |
| `iverilog/` | Icarus Verilog 12 | most FPGA simulations |
| `ghdl/` | GHDL 5.1 | turns the T80's VHDL into Verilog for simulation |
| `verilator/` | Verilator 5.052 | the HDMI and whole-board simulations |
| `kicad/` | KiCad 10.0.8, the official AppImage (`kicad-cli`, KiCad's Python with `pcbnew`, the libraries) | the boards (`kicad/`): opening, generating, checking |
| `gowim/` | Gowin EDA, Education edition (downloaded by hand) | synthesis, place and route, bitstreams |

`download_toolchain.sh` installs all but Gowin EDA (KiCad's AppImage is downloaded, or
copied with `KICAD_APPIMAGE=/path/to/it`). Installed system-wide, not here:
openFPGALoader (programs the board).
