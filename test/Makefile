# TurboACE graphics test harness (DRAW, CIRCLE, PAINT, ATTR).
#
#   make                 build rom first (../rom), then run the tests
#   make JIIB=/path/to/Jupiter-IIb/src
#   PROFILE=1 ./gfxtest   T-states per address for one PAINT, into profile.txt
#
# The Z80 core (z80ops.c, cbops.c, edops.c, GPL v2+) is compiled from the
# Jupiter-IIb tree; it is not copied into this project.

JIIB    ?= ../../Jupiter-IIb/src
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-label
BUILD   := ../rom/build
ACE_ROM ?= ../../Jupiter-IIb/ace.rom

.PHONY: test clean rom

test: gfxtest
	./gfxtest $(BUILD)/turboace.rom

rom:
	$(MAKE) -C ../rom ACE_ROM=$(abspath $(ACE_ROM))

# syms.h is regenerated on every run so it always matches the ROM just built
syms.h: rom
	python3 -I symsh.py $(BUILD)/turboace.sym HDRAW HCIRCLE HATTR HPAINT SINTAB HSTOCK HSTOCK1 BOOT_SETUP TURBO_NLF SDTAPE_NLF SDERR_NLF DELETE_NLF XDICT_LAST_NLF XDICT_IMAGE XDICT_LEN XD_ERRCODE XS_RAMTOP0 XS_XCFG XS_SDTAPE XS_SDERR XS_SEED XTAPE_CF XCD_CF XDELETE_CF XPGSAVE_CF XPGLOAD_CF XSCRSAVE_CF XSCRLOAD_CF XFONTLOAD_CF XS_WORKPG XS_PLOTX XS_PLOTY XS_GFLAGS > $@

FW      := ../firmware
FWSRC   := $(FW)/src/keyboard.c $(FW)/src/sdproto.c $(FW)/test/host_fpga.c $(FW)/test/diskio_ram.c $(FW)/fatfs/ff.c $(FW)/fatfs/ffunicode.c

gfxtest: gfxtest.c z80core.c z80core.h syms.h $(JIIB)/z80ops.c $(FWSRC)
	$(CC) $(CFLAGS) -DFF_USE_MKFS=1 -I. -I$(JIIB) -I$(FW)/src -I$(FW)/fatfs -I$(FW)/test -o $@ gfxtest.c z80core.c $(FWSRC) -lm

clean:
	rm -f gfxtest syms.h
