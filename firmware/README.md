# TurboACE SD soft CPU firmware

C firmware for the small soft CPU inside the FPGA that serves the SD card to the Z80
through ports `$E5`/`$E7` (`register-map.md` §2.6, §2.7).

| Path | Contents |
|------|----------|
| `src/sdproto.c` | the protocol: files, folders, virtual tape player (`.tap`/`.tzx`) |
| `src/keyboard.c` | standalone build: PS/2 scan codes to the Ace key matrix (US and Portuguese, symbolic and positional) |
| `src/config.c` | the settings file `/turboace.cfg` |
| `src/libc.c` | the eight C library functions the soft CPU build needs (`-nostdlib`) |
| `src/romload.c`, `src/md5.c` | power-up: `/ace.rom` from the card (checked by MD5) into ROM pages 0 and 1, TurboACE's pages 2–7 from the board's flash |
| `src/hal.h`, `src/hal_fpga.c` | the FPGA mailbox, SPI, timer, keyboard and reset registers |
| `src/diskio_sd.c` | FatFs disk I/O for an SD card in SPI mode (**not yet run on hardware**) |
| `src/main.c`, `start.S`, `link.ld` | the soft CPU's main loop, start-up and memory layout |
| `fatfs/` | FatFs R0.16 (ChaN, one-clause BSD; see `fatfs/LICENSE.txt`) with our `ffconf.h` |
| `test/` | PC tests: a model of the FPGA mailbox, a RAM disk, `fwtest.c`, `kbtest.c`, `romtest.c` |

    make test ACE_ROM=/path/to/ace.rom          # PC tests (59 SD + 35 keyboard + 19 ROM-loading checks)
    ../download_toolchain.sh                    # once: the RISC-V compiler into ../toolchain
    make firmware                               # RV32IC build, build/sdcpu.bin

The soft CPU runs RV32IC with 48K of block RAM (`src/link.ld`): about 36K of program
and data, and at least 4K left for the stack (the link checks it). `MARCH=rv32i` builds
for a core without compressed instructions, which needs about 51K (`register-map.md`
decision 30).

`romtest` needs your stock ROM (`ACE_ROM`) and the built `../rom/build/turboace.rom`
(`make -C ../rom`); it checks that the pages it loads equal that 64K image byte for byte.

**The board's flash:** `make -C ../rom flash ACE_ROM=/path/to/ace.rom` builds
`../rom/build/turboace-flash.bin` (ROM pages 2–7, without any stock ROM byte); write it to
the flash at `0x500000` (`register-map.md` §2.7) with `make -C .. program-rom` (openFPGALoader).

The ROM is also tested against this firmware end to end in `../test` (`make -C ../test`).

**Licence:** FatFs is one-clause BSD. `src/sdproto.c`'s TZX block walker and LOAD-search
logic follow the Jupiter-IIb emulator's `src/tape_sd.cpp` (GPL v2 or later, derived from
xAce), so treat the firmware as GPL v2+ unless those parts are cleared or rewritten.
