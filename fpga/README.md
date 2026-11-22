# TurboACE FPGA design

Verilog for the Tang Nano 20K (GW2AR-18), built with Gowin EDA (`register-map.md`
decisions 24, 25, 31). Being written; simulated with Icarus Verilog.

| Path | Contents |
|------|----------|
| `rtl/ports.v` | the Z80's I/O ports: `$E3` (control), `$E1` (user-RAM windows), the AY's registers and the colours, the SD ports' strobes |
| `rtl/memmap.v` | where each CPU address goes: region, SDRAM address, read-only / write-only, colour-RAM writes, video-priority copies |
| `rtl/mailbox.v`, `rtl/fifo.v` | the SD mailbox between the Z80's `$E5`/`$E7` and the soft CPU, with 1K FIFOs each way |
| `rtl/video.v` | the picture: 720×576 at 50 Hz, the 256×192 picture doubled and centred with the border; text, hi-res and the text overlay (with `OPAQUE`), fetched a line ahead into line buffers |
| `rtl/ace_core.v` | the standalone Ace: T80, bus, ports, SD mailbox, frame timing, video and SDRAM together, with the Ace's own keyboard / EAR / speaker port |
| `rtl/T80/` | the T80 Z80 core (VHDL, BSD-style licence; `TURBOACE.md` says where it comes from) and `t80_core.vhd`, a wrapper with plain port names |
| `rtl/top_standalone.v` | the standalone build's top level for the Tang Nano 20K: the Ace, the soft CPU, PS/2, sound and HDMI |
| `rtl/gowin.v` | the Gowin parts behind wrappers (one PLL for 54 / 135 / 27 MHz, the SDRAM clock output, the TMDS buffers), with simulation models (`-DSIM`); the PLL settings to confirm in Gowin's IP generator |
| `turboace_standalone.gprj`, `turboace_standalone.sdc`, `impl/project_process_config.json` | the Gowin EDA project for the standalone build: files, clocks, settings (VHDL-2008 for T80, the flash's MSPI pins as ordinary I/O) |
| `gowin_build.tcl` | the build script `make bitstream` runs in Gowin's `gw_sh` |
| `rtl/gowin_defines.vh` | `GW_IDE` for hdl-util's serializer (Gowin's `OSER10`), first in the project's file list |
| `tang_nano_20k_standalone.cst` | the pins (from Sipeed's examples and NESTang); set "Use MSPI as regular IO" for the flash |
| `rtl/ps2.v` | the PS/2 keyboard port: frames in, LED commands out |
| `rtl/audio.v`, `rtl/ay.sv` | the sound: the AY (`ay.sv`, from JupiterACE_MiSTer, unchanged) and the beeper, at 48 kHz for HDMI |
| `rtl/hdmi/` | hdl-util/hdmi, unchanged (MIT or Apache 2.0) |
| `rtl/sdcpu.v` | the soft CPU: PicoRV32 (RV32IC) with the firmware in 48K of block RAM and the registers of `firmware/src/hal.h`: mailbox, SD card SPI, timer, keyboard and system, ROM / flash / screen |
| `rtl/picorv32.v` | PicoRV32 (ISC licence; `../THIRD-PARTY.md`), unchanged |
| `rtl/spi_master.v` | SPI master, mode 0, for the SD card and the board's flash |
| `rtl/cpubus.v` | the Z80's bus cycles turned into SDRAM accesses and I/O strobes: reads (opcode fetches from M1), posted writes with a one-byte buffer for the colour byte, the WAIT contention; no extra wait states otherwise |
| `rtl/acetiming.v` | the Ace's own frame (standalone build): the 3.25 MHz T-state enable (13 in 216 of 54 MHz), 208 T a line, 312 lines, INT, and the picture time for the WAIT contention |
| `rtl/arbiter.v` | shares the SDRAM between the CPU (first) and the video fetches |
| `rtl/sdram.v` | controller for the module's 64 Mbit SDRAM: byte requests, one access at a time, refresh, JEDEC start-up |
| `sim/sdram_model.v` | a model of that SDRAM that keeps the data and checks the start-up and timing rules |
| `sim/sdram_tb.v` | test of the controller against the model |
| `sim/ports_tb.v` | test of the ports and the memory map against `register-map.md` |
| `sim/video_tb.v` | test of the picture: every pixel of whole frames against a reference computed straight from `register-map.md` 2.4, and the sync timing |
| `sim/system_tb.v` | the standalone Ace whole (`make system`): the real T80, through GHDL, boots the TurboACE ROM; the screen and system variables must equal the C harness's, and the 50 Hz interrupt must count |
| `sim/fix_t80_netlist.py` | fixes GHDL's Verilog of the T80 for simulation: registers start at 0, and an assignment GHDL 5.1.1 drops is put back |
| `sim/top_tb.sv` | the standalone build from power-on to picture (`make top`, Verilator): the top level as built for the board, the firmware loading the ROM, the T80 booting it, and one HDMI frame decoded from the core's TMDS symbols, every pixel checked |
| `sim/hdmi_tb.sv` | the picture through the real HDMI core (`make hdmi`, Verilator): two frames decoded and checked |
| `sim/prep_hdmi_sim.py` | a copy of hdl-util/hdmi that Verilator can read (two casts written with `$rtoi`) |
| `sim/ps2_tb.v`, `sim/audio_tb.v` | tests of the PS/2 port (model keyboard) and the sound (rates, levels, tone frequencies) |
| `sim/powerup_tb.v` | the standalone build's power-up (`make powerup`): the real firmware on PicoRV32 loads the ROM from a simulated SD card and flash; and with a wrong `/ace.rom`, the Z80 stays held and the screen says why |
| `sim/sdcard_model.v`, `sim/mkcard.c` | a microSD card in SPI mode, and its image: a FAT card with the given files, made with the firmware's own FatFs |
| `sim/spiflash_model.v` | the board's SPI flash (read command) holding TurboACE's ROM pages |
| `sim/cpubus_tb.v` | test of the bus with everything behind it (ports, arbiter, SDRAM, frame timing, video fetching meanwhile), the Z80 a bus model with the datasheet's cycle timing |
| `sim/arbiter_tb.v` | test of the frame timing, and of the arbiter with the SDRAM controller and model: a CPU-like and a video-like port, every read checked, the CPU's waiting time and video's throughput |
| `sim/mailbox_tb.v` | test of the mailbox: random operations from both sides against a model written from `firmware/test/host_fpga.c`, the mailbox the firmware is tested with |

    ../download_toolchain.sh     # once: builds Icarus Verilog, GHDL and Verilator into ../toolchain
    make test                    # the module tests
    make system-slow             # the same, with the T80's outputs garbled for a clock
    make system                  # the whole standalone Ace boots the ROM (a few minutes)
    make powerup                 # the firmware loads the ROM at power-up (about 10 minutes)
    make hdmi                    # the picture through the real HDMI core (seconds)
    make top                     # the whole board from power-on to picture (about a minute)

Building the standalone bitstream (Gowin EDA in ../toolchain/gowim):

    make bitstream               # about a minute: synthesis, place and route (gw_sh,
                                 # gowin_build.tcl), copied to build/turboace-standalone.fs
    make system-slow             # the check behind the T80's timing (below)

Or open `turboace_standalone.gprj` in the Gowin IDE (`make gowin` first). The first
build: 43% of the logic, 20% of the registers, 36 of 46 block RAMs, 7 of 8 global
clocks; timing met on every clock (54 MHz closes at 55.6 MHz). Reports in `impl/pnr/`.

Timing (`turboace_standalone.sdc`): the T80 takes about 21 ns from its microcode block
RAM to its registers, more than one 54 MHz clock. Its registers change only on its
clock enables (8 or more clocks apart), so its paths are timed as two clocks, and the
rest of the design takes the T80's outputs into a register (`t_held` in `ace_core.v`)
two clocks after each enable. `make system-slow` boots the ROM with every T80 output
garbled for the first clock after it changes, as it could be on the chip, and must pass
bit-exact (without `t_held`, it showed spurious memory writes). The audio clock is
declared asynchronous to the pixel clock (hdl-util crosses the samples itself).

Still to confirm on the board: the rPLL settings in `rtl/gowin.v` (Gowin's IP
generator), and that the 27 MHz pixel clock keeps its edges aligned with 54 MHz.
Then write the bitstream and TurboACE's ROM pages with `make -C .. program`.
