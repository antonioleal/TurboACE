# TurboACE: programming the Tang Nano 20K with openFPGALoader (register-map.md decision 25).
#
#   make program BUILD=standalone ACE_ROM=/path/to/ace.rom
#                        write the bitstream to the flash, then TurboACE's ROM pages
#   make program-bitstream BUILD=expansion
#                        write only the bitstream to the flash (changing build)
#   make program-rom ACE_ROM=/path/to/ace.rom
#                        write only TurboACE's ROM pages (flash at 0x500000)
#   make load BUILD=standalone
#                        load the bitstream into the FPGA until power-off (for testing)
#
# BUILD is standalone or expansion. BITSTREAM overrides the bitstream file.
# ACE_ROM is needed to build the ROM pages (rom/build/turboace-flash.bin); without it
# an already-built image is written. The stock ROM itself is never written to the board:
# the soft CPU reads /ace.rom from the SD card at power-up.
# FPGALOADER=echo shows the commands without running them.

FPGALOADER ?= openFPGALoader
BOARD      ?= tangnano20k
BUILD      ?= standalone
BITSTREAM  ?= fpga/build/turboace-$(BUILD).fs
ROM_OFFSET := 0x500000
ROM_IMAGE  := rom/build/turboace-flash.bin
ACE_ROM    ?=

# one openFPGALoader at a time on the USB port, bitstream before ROM pages
.NOTPARALLEL:

.PHONY: program program-bitstream program-rom load rom-image tool bitstream-file

program: program-bitstream program-rom

program-bitstream: tool bitstream-file
	$(FPGALOADER) -b $(BOARD) -f $(BITSTREAM)

load: tool bitstream-file
	$(FPGALOADER) -b $(BOARD) $(BITSTREAM)

program-rom: tool rom-image
	$(FPGALOADER) -b $(BOARD) --external-flash -o $(ROM_OFFSET) $(ROM_IMAGE)

rom-image:
ifneq ($(ACE_ROM),)
	$(MAKE) -C rom flash ACE_ROM=$(abspath $(ACE_ROM))
else
	@test -f $(ROM_IMAGE) || { echo "no $(ROM_IMAGE): give ACE_ROM=/path/to/ace.rom to build it"; exit 1; }
endif

bitstream-file:
	@case "$(BUILD)" in standalone|expansion) ;; *) echo "BUILD must be standalone or expansion"; exit 1;; esac
	@test -f $(BITSTREAM) || { echo "no bitstream $(BITSTREAM): build it with Gowin EDA first, or give BITSTREAM=..."; exit 1; }

tool:
	@command -v $(firstword $(FPGALOADER)) >/dev/null || { echo "$(FPGALOADER) not found: install a recent openFPGALoader (https://github.com/trabucayre/openFPGALoader)"; exit 1; }
