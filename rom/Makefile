# TurboACE ROM build.  Run from this directory.
#
#   make ACE_ROM=/path/to/ace.rom          build build/turboace.rom (64K, pages 0-7)
#   make check ACE_ROM=/path/to/ace.rom    build, then run the static checks
#   make equates ACE_ROM=/path/to/ace.rom  regenerate inc/ace_words.inc
#   make flash ACE_ROM=/path/to/ace.rom    build/turboace-flash.bin: pages 2-7 for the
#                                          board's flash at $500000 (no stock ROM in it)
#
# Needs: sjasmplus (1.20.x), python3, and the stock Jupiter Ace ROM image
# (8192 bytes, SHA-1 below), which is not part of this project.

ASM      ?= ../tools/sjasmplus/sjasmplus
PYTHON   ?= python3
ACE_ROM  ?= ace.rom
ACE_SHA1 := 597ba8a15a292688333c84dc9fd35172abe5e7e6
TOOLS    := ../tools/misc

SOURCES  := turboace.asm $(wildcard inc/*.inc) $(wildcard src/*.asm)
PAGES    := $(foreach n,0 1 2 3 4 5 6 7,build/page$(n).bin)

.PHONY: all check equates flash clean

all: build/turboace.rom

build/stock.rom: $(ACE_ROM)
	@mkdir -p build
	@$(PYTHON) -I -c "import hashlib,sys; d=open(sys.argv[1],'rb').read(); \
	  sys.exit(0 if hashlib.sha1(d).hexdigest()=='$(ACE_SHA1)' else \
	  'ACE_ROM is not the stock Jupiter Ace ROM (SHA-1 mismatch)')" "$(ACE_ROM)"
	cp "$(ACE_ROM)" $@

build/turboace.rom: build/stock.rom $(SOURCES)
	$(ASM) --nologo -I. --sym=build/turboace.sym --lst=build/turboace.lst turboace.asm
	cat $(PAGES) > $@
	@echo "built $@ ($$(wc -c < $@) bytes)"

# Pages 2-7, each after an 8-byte tag "TACE", page, 0, 0, 0 (firmware/src/hal_fpga.c).
# The copies of the stock interrupt path in each page (tools/misc/romcheck.py COPY_RANGES)
# are left as zeros: the firmware fills them from /ace.rom, so no stock ROM byte is
# in the flash.
flash: build/turboace-flash.bin

build/turboace-flash.bin: build/turboace.rom
	@$(PYTHON) -I -c "import sys; sys.path.insert(0,sys.argv[3]); from romcheck import COPY_RANGES; \
	  r=open(sys.argv[1],'rb').read(); out=b''; \
	  exec('for p in range(2,8):\n pg=bytearray(r[p*8192:(p+1)*8192])\n for s,e in COPY_RANGES: pg[s:e]=bytes(e-s)\n out+=b\'TACE\'+bytes([p,0,0,0])+pg'); \
	  open(sys.argv[2],'wb').write(out)" build/turboace.rom $@ $(TOOLS)
	@echo "built $@ ($$(wc -c < $@) bytes): write it to the board's flash at 0x500000"

check: build/turboace.rom
	$(PYTHON) -I $(TOOLS)/romcheck.py build

equates: build/stock.rom
	$(PYTHON) -I $(TOOLS)/acedict.py build/stock.rom > inc/ace_words.inc

clean:
	rm -rf build
