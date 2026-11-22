# TurboACE FPGA design: simulation tests (Icarus Verilog and GHDL from ../toolchain,
# built by ../download_toolchain.sh).
#
#   make test        run every module testbench in sim/
#   make system      the standalone Ace whole: the real T80 boots the TurboACE ROM
#                    (needs ../rom/build/turboace.rom and the C harness, ../test; a few minutes)
#   make system-slow the same with every T80 output garbled for the first clock after
#                    it changes (T80_SLOW): the two-clock timing of the T80's paths
#                    (turboace_standalone.sdc) is safe only if this passes too
#   make hdmi        the picture through the real HDMI core (hdl-util/hdmi), decoded
#                    back from its TMDS symbols (Verilator, from ../toolchain)
#   make top         the standalone build from power-on to picture: the top level as
#                    built for the board, the firmware loading the ROM, the T80 booting
#                    it, and an HDMI frame decoded and checked (Verilator; a minute or two)
#   make gowin       what Gowin EDA needs before it builds turboace_standalone.gprj:
#                    build/firmware.hex, the soft CPU's program (from ../firmware)
#   make bitstream   the standalone bitstream with Gowin EDA's gw_sh (impl/pnr/, copied
#                    to build/turboace-standalone.fs, where make -C .. program takes it)
#   make powerup     the standalone build's power-up: PicoRV32 runs the real firmware,
#                    which loads the ROM from a simulated SD card and flash
#                    (needs ../firmware/build/sdcpu.bin and ../rom/build/turboace-flash.bin)

IVERILOG ?= ../toolchain/iverilog/bin/iverilog
VVP      ?= ../toolchain/iverilog/bin/vvp
GHDL     ?= ../toolchain/ghdl/bin/ghdl
VERILATOR ?= ../toolchain/verilator/bin/verilator
VFLAGS   := --binary --timing -Wno-fatal -Wno-lint -Wno-style
T80_SRC  := rtl/T80/T80_Reg.vhd rtl/T80/T80_MCode.vhd rtl/T80/T80_ALU.vhd rtl/T80/T80.vhd \
            rtl/T80/T80pa.vhd rtl/T80/t80_core.vhd

.PHONY: test system system-slow powerup hdmi top gowin bitstream clean

test: build/sdram_tb.vvp build/ports_tb.vvp build/mailbox_tb.vvp build/video_tb.vvp build/arbiter_tb.vvp build/cpubus_tb.vvp build/ps2_tb.vvp build/audio_tb.vvp
	$(VVP) -n build/ports_tb.vvp
	$(VVP) -n build/audio_tb.vvp
	$(VVP) -n build/ps2_tb.vvp
	$(VVP) -n build/cpubus_tb.vvp
	$(VVP) -n build/mailbox_tb.vvp
	$(VVP) -n build/arbiter_tb.vvp
	$(VVP) -n build/video_tb.vvp
	$(VVP) -n build/sdram_tb.vvp

build/ports_tb.vvp: sim/ports_tb.v rtl/ports.v rtl/memmap.v
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/ports_tb.v rtl/ports.v rtl/memmap.v

build/mailbox_tb.vvp: sim/mailbox_tb.v rtl/mailbox.v rtl/fifo.v
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/mailbox_tb.v rtl/mailbox.v rtl/fifo.v

build/video_tb.vvp: sim/video_tb.v rtl/video.v
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/video_tb.v rtl/video.v

build/arbiter_tb.vvp: sim/arbiter_tb.v rtl/acetiming.v rtl/arbiter.v rtl/sdram.v sim/sdram_model.v
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/arbiter_tb.v rtl/acetiming.v rtl/arbiter.v rtl/sdram.v sim/sdram_model.v

CPUBUS_SRC := rtl/cpubus.v rtl/memmap.v rtl/ports.v rtl/acetiming.v rtl/arbiter.v rtl/video.v rtl/sdram.v sim/sdram_model.v
build/cpubus_tb.vvp: sim/cpubus_tb.v $(CPUBUS_SRC)
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/cpubus_tb.v $(CPUBUS_SRC)

build/audio_tb.vvp: sim/audio_tb.v rtl/audio.v rtl/ay.sv
	@mkdir -p build
	$(IVERILOG) -g2012 -o $@ sim/audio_tb.v rtl/audio.v rtl/ay.sv

build/ps2_tb.vvp: sim/ps2_tb.v rtl/ps2.v rtl/fifo.v
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/ps2_tb.v rtl/ps2.v rtl/fifo.v

build/sdram_tb.vvp: sim/sdram_tb.v sim/sdram_model.v rtl/sdram.v
	@mkdir -p build
	$(IVERILOG) -g2005 -Wall -o $@ sim/sdram_tb.v sim/sdram_model.v rtl/sdram.v

# the T80 as Verilog, by GHDL, for simulation only (Gowin EDA takes the VHDL)
build/t80.v: $(T80_SRC) sim/fix_t80_netlist.py
	@mkdir -p build/ghdl
	$(GHDL) -a --std=08 -fsynopsys --workdir=build/ghdl $(T80_SRC)
	$(GHDL) synth --std=08 -fsynopsys --workdir=build/ghdl --out=verilog t80_core > $@.tmp
	python3 -I sim/fix_t80_netlist.py $@.tmp $@
	@rm $@.tmp

build/turboace_rom.hex: ../rom/build/turboace.rom
	@mkdir -p build
	python3 -I -c "import sys; open(sys.argv[2],'w').write(''.join('%02x\\n' % b for b in open(sys.argv[1],'rb').read()))" $< $@

build/boot_screen.hex: ../rom/build/turboace.rom ../test/gfxtest
	@mkdir -p build
	BOOTSCREEN=$(abspath $@) ../test/gfxtest $(abspath ../rom/build/turboace.rom) > /dev/null

SYSTEM_SRC := rtl/ace_core.v rtl/cpubus.v rtl/memmap.v rtl/ports.v rtl/mailbox.v rtl/fifo.v \
              rtl/acetiming.v rtl/arbiter.v rtl/video.v rtl/sdram.v sim/sdram_model.v build/t80.v
build/system_tb.vvp: sim/system_tb.v $(SYSTEM_SRC)
	$(IVERILOG) -g2005 -o $@ sim/system_tb.v $(SYSTEM_SRC)

system: build/system_tb.vvp build/turboace_rom.hex build/boot_screen.hex
	$(VVP) -n build/system_tb.vvp

build/system_slow_tb.vvp: sim/system_tb.v $(SYSTEM_SRC)
	$(IVERILOG) -g2005 -DT80_SLOW -o $@ sim/system_tb.v $(SYSTEM_SRC)

system-slow: build/system_slow_tb.vvp build/turboace_rom.hex build/boot_screen.hex
	$(VVP) -n build/system_slow_tb.vvp

# the firmware as words for the soft CPU's block RAM (48K)
build/firmware.hex: ../firmware/build/sdcpu.bin
	@mkdir -p build
	python3 -I -c "import sys; d=open(sys.argv[1],'rb').read(); d+=bytes(-len(d)%4); \
	  w=[int.from_bytes(d[i:i+4],'little') for i in range(0,len(d),4)]; \
	  assert len(w)<=12288, 'firmware over 48K'; w+=[0]*(12288-len(w)); \
	  open(sys.argv[2],'w').write(''.join('%08x\\n'%x for x in w))" $< $@

build/flash.hex: ../rom/build/turboace-flash.bin
	@mkdir -p build
	python3 -I -c "import sys; open(sys.argv[2],'w').write(''.join('%02x\\n' % b for b in open(sys.argv[1],'rb').read()))" $< $@

build/mkcard: sim/mkcard.c
	@mkdir -p build
	gcc -O2 -DFF_USE_MKFS=1 -I../firmware/src -I../firmware/fatfs -I../firmware/test -o $@ \
	    sim/mkcard.c ../firmware/test/diskio_ram.c ../firmware/fatfs/ff.c ../firmware/fatfs/ffunicode.c

build/card.hex: build/mkcard ../rom/build/stock.rom
	./build/mkcard $@ /ace.rom=../rom/build/stock.rom

build/card_bad.hex: build/mkcard ../rom/build/stock.rom
	python3 -I -c "import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[0x1234]^=1; open(sys.argv[2],'wb').write(d)" ../rom/build/stock.rom build/ace_bad.rom
	./build/mkcard $@ /ace.rom=build/ace_bad.rom

POWERUP_SRC := rtl/sdcpu.v rtl/spi_master.v rtl/picorv32.v sim/sdcard_model.v sim/spiflash_model.v \
               $(SYSTEM_SRC)
build/powerup_tb.vvp: sim/powerup_tb.v $(POWERUP_SRC)
	$(IVERILOG) -g2005 -o $@ sim/powerup_tb.v $(POWERUP_SRC)

build/powerup_bad_tb.vvp: sim/powerup_tb.v $(POWERUP_SRC)
	$(IVERILOG) -g2005 -DBADCARD -o $@ sim/powerup_tb.v $(POWERUP_SRC)

powerup: build/powerup_tb.vvp build/powerup_bad_tb.vvp build/firmware.hex build/flash.hex \
         build/card.hex build/card_bad.hex build/turboace_rom.hex
	$(VVP) -n build/powerup_tb.vvp
	$(VVP) -n build/powerup_bad_tb.vvp

# hdl-util/hdmi as Verilator can read it (sim/prep_hdmi_sim.py); rtl/hdmi/ unchanged
build/hdmi_sim/.done: $(wildcard rtl/hdmi/*.sv) sim/prep_hdmi_sim.py
	python3 -I sim/prep_hdmi_sim.py rtl/hdmi build/hdmi_sim
	@touch $@

build/hdmi_vl/hdmi_tb: sim/hdmi_tb.sv rtl/video.v build/hdmi_sim/.done
	$(VERILATOR) $(VFLAGS) -DSTART_X=0 -DSTART_Y=0 --top-module hdmi_tb -Mdir build/hdmi_vl -o hdmi_tb \
	    sim/hdmi_tb.sv rtl/video.v build/hdmi_sim/*.sv > build/hdmi_vl.log 2>&1 || (cat build/hdmi_vl.log; false)

TOP_SRC := rtl/top_standalone.v rtl/gowin.v rtl/ace_core.v rtl/cpubus.v rtl/memmap.v rtl/ports.v \
           rtl/mailbox.v rtl/fifo.v rtl/acetiming.v rtl/arbiter.v rtl/video.v rtl/sdram.v rtl/sdcpu.v \
           rtl/spi_master.v rtl/picorv32.v rtl/ps2.v rtl/audio.v rtl/ay.sv build/t80.v \
           sim/sdram_model.v sim/sdcard_model.v sim/spiflash_model.v
build/top_vl/top_tb: sim/top_tb.sv $(TOP_SRC) build/hdmi_sim/.done
	$(VERILATOR) $(VFLAGS) -DSIM --top-module top_tb -Mdir build/top_vl -o top_tb \
	    sim/top_tb.sv $(TOP_SRC) build/hdmi_sim/*.sv > build/top_vl.log 2>&1 || (grep -E '%Error' build/top_vl.log | head -20; false)

top: build/top_vl/top_tb build/firmware.hex build/flash.hex build/card.hex
	cd build && ./top_vl/top_tb | grep -v '^- '

hdmi: build/hdmi_vl/hdmi_tb
	./build/hdmi_vl/hdmi_tb | grep -v '^- '

../firmware/build/sdcpu.bin:
	$(MAKE) -C ../firmware firmware

gowin: build/firmware.hex
	@echo "ready: open turboace_standalone.gprj in Gowin EDA and run Synthesize and Place & Route"

# the same from the command line (Gowin EDA's gw_sh, in ../toolchain/gowim; no display)
GW_SH ?= ../toolchain/gowim/IDE/bin/gw_sh
bitstream: build/firmware.hex
	env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen $(GW_SH) gowin_build.tcl
	install -m 644 impl/pnr/turboace_standalone.fs build/turboace-standalone.fs   # for make -C .. program

clean:
	rm -rf build
