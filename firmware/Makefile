# TurboACE SD soft CPU firmware (register-map.md sections 2.6, 2.7)
#
#   make test        build and run the PC tests (protocol + FatFs on a RAM disk)
#   make firmware    build for the soft CPU (RV32I) with the RISC-V compiler in
#                    ../toolchain (fetch it with ../download_toolchain.sh), or another one:
#                    make firmware RISCV=riscv64-unknown-elf-

CC      ?= gcc
RISCV   ?= ../toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
MARCH   ?= rv32ic                      # the soft CPU: RV32I with compressed instructions (decision 30)
FATFS   := fatfs/ff.c fatfs/ffunicode.c
INC     := -Isrc -Ifatfs -Itest
ACE_ROM ?= ../../Jupiter-IIb/ace.rom
TROM    := ../rom/build/turboace.rom

.PHONY: test firmware clean

test: build/fwtest build/kbtest build/romtest
	./build/fwtest
	./build/kbtest
	./build/romtest $(ACE_ROM) $(TROM)

$(TROM):
	$(MAKE) -C ../rom ACE_ROM=$(abspath $(ACE_ROM))

build/romtest: src/romload.c src/md5.c test/romtest.c test/diskio_ram.c $(FATFS) src/*.h test/*.h $(TROM)
	@mkdir -p build
	$(CC) $(CFLAGS) -DFF_USE_MKFS=1 $(INC) -o $@ src/romload.c src/md5.c test/romtest.c test/diskio_ram.c $(FATFS)

build/kbtest: src/keyboard.c src/config.c test/kbtest.c src/keyboard.h src/config.h
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc -o $@ src/keyboard.c src/config.c test/kbtest.c

build/fwtest: src/sdproto.c test/host_fpga.c test/diskio_ram.c test/fwtest.c $(FATFS) src/*.h test/*.h fatfs/*.h
	@mkdir -p build
	$(CC) $(CFLAGS) -DFF_USE_MKFS=1 $(INC) -o $@ src/sdproto.c test/host_fpga.c test/diskio_ram.c test/fwtest.c $(FATFS)

firmware: build/sdcpu.bin

build/sdcpu.elf: src/*.c src/*.S src/*.h src/link.ld $(FATFS)
	@mkdir -p build
	$(RISCV)gcc -march=$(MARCH) -mabi=ilp32 -Os -ffreestanding -nostdlib -fno-tree-loop-distribute-patterns \
	    -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Isrc -Ifatfs \
	    -T src/link.ld -o $@ src/start.S src/main.c src/sdproto.c src/keyboard.c src/config.c src/romload.c src/md5.c src/hal_fpga.c src/diskio_sd.c src/libc.c $(FATFS) -lgcc
	$(RISCV)size $@

build/sdcpu.bin: build/sdcpu.elf
	$(RISCV)objcopy -O binary $< $@

clean:
	rm -rf build
