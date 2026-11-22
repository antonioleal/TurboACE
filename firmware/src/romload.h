/* TurboACE: the ROM at power-up, from /ace.rom on the SD card (romload.c). */
#ifndef ROMLOAD_H
#define ROMLOAD_H

#include "ff.h"

enum rom_status { ROM_OK, ROM_NOCARD, ROM_NOFILE, ROM_BADSIZE, ROM_BADMD5, ROM_NOEXT };

/* one attempt: page 0 = /ace.rom, page 1 = it with the hooks, pages 2-7 from
 * the board's flash, 512 bytes at a time. The Z80 must be held in reset
 * meanwhile (the pages are written before the MD5 is known). fs: a FatFs work
 * area to mount the card with. */
enum rom_status rom_load(FATFS *fs);

/* the whole power-up: load, then release the Z80. Standalone build: until it
 * works, a message on the screen and a new try every second. Expansion: on
 * failure the Z80 runs without TurboACE's ROM (the Ace's own). */
void rom_boot(FATFS *fs);

extern const char *const rom_status_text[];

#endif
