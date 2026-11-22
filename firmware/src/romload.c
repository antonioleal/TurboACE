/*
 * TurboACE: the ROM at power-up (register-map.md decision 24, section 2.7).
 *
 * The stock Jupiter Ace ROM is not in the bitstream: it comes from /ace.rom on
 * the SD card, checked by size and MD5. Page 0 is it unchanged (-1 TURBO);
 * page 1 is it with the three 4-byte hooks the TurboACE ROM needs (section 5:
 * boot $008E, tape write $1820, tape read $18A7). Pages 2-7, TurboACE's own
 * code, come from the board's flash, where the build puts them; their copies of
 * the stock interrupt path (321 bytes each) are filled in here from /ace.rom,
 * so neither the bitstream nor the flash holds any stock ROM byte.
 */
#include <string.h>
#include "ff.h"
#include "hal.h"
#include "md5.h"
#include "romload.h"

#define ROM_PAGE   8192
static const uint8_t ace_md5[16] = {       /* db6efdfd82cebdfbb493d85b1a5efc3c */
    0xdb, 0x6e, 0xfd, 0xfd, 0x82, 0xce, 0xbd, 0xfb,
    0xb4, 0x93, 0xd8, 0x5b, 0x1a, 0x5e, 0xfc, 0x3c
};

/* page 1 = page 0 with these (must match rom/turboace.asm; the tests check) */
static const struct { uint16_t at; uint8_t code[4]; } hooks[] = {
    { 0x008E, { 0x3E, 0xC2, 0xD3, 0xE3 } },   /* LD A,$C2 / OUT ($E3),A: boot page 2 */
    { 0x1820, { 0x3E, 0xC3, 0xD3, 0xE3 } },   /* LD A,$C3 / OUT ($E3),A: tape write, page 3 */
    { 0x18A7, { 0x3E, 0xC3, 0xD3, 0xE3 } },   /* tape read, page 3 */
};

const char *const rom_status_text[] = {
    "OK", "NO SD CARD", "NO /ACE.ROM ON THE CARD", "/ACE.ROM IS NOT 8192 BYTES",
    "/ACE.ROM IS NOT THE STOCK ROM", "NO TURBOACE ROM IN THE FLASH"
};

/* the stock interrupt path each extension page carries (register-map.md section 5,
 * tools/misc/romcheck.py COPY_RANGES): left out of the flash, filled in from /ace.rom */
static const struct { uint16_t at, n; } copies[] = {
    { 0x0010, 0x10 }, { 0x0038, 0x03 }, { 0x013A, 0x44 }, { 0x0310, 0xDE }, { 0x0859, 0x0C }
};
#define COPY_BYTES (0x10 + 0x03 + 0x44 + 0xDE + 0x0C)  /* 321 */
#define PATCH_0153 0x18                 /* JR Z -> JR: no editor branch in these pages */
#define CHUNK      512

static uint8_t buf[CHUNK];
static uint8_t stock_copy[COPY_BYTES];

/* the copy ranges inside the chunk at off: keep (from /ace.rom) or fill in (pages 2-7) */
static void copies_in_chunk(unsigned off, int fill)
{
    unsigned k = 0;
    for (unsigned i = 0; i < sizeof copies / sizeof copies[0]; k += copies[i].n, i++)
        for (unsigned j = 0; j < copies[i].n; j++) {
            unsigned a = copies[i].at + j;
            if (a < off || a >= off + CHUNK) continue;
            if (fill) buf[a - off] = stock_copy[k + j];
            else stock_copy[k + j] = buf[a - off];
        }
}

enum rom_status rom_load(FATFS *fs)
{
    FIL f;
    UINT got;
    if (f_mount(fs, "", 1) != FR_OK) return ROM_NOCARD;
    if (f_open(&f, "/ace.rom", FA_READ) != FR_OK) return ROM_NOFILE;
    if (f_size(&f) != ROM_PAGE) { f_close(&f); return ROM_BADSIZE; }

    struct md5 m;
    uint8_t digest[16];
    md5_init(&m);
    for (unsigned off = 0; off < ROM_PAGE; off += CHUNK) {
        if (f_read(&f, buf, CHUNK, &got) != FR_OK || got != CHUNK) { f_close(&f); return ROM_BADSIZE; }
        md5_add(&m, buf, CHUNK);
        hal_rom_write(0, off, buf, CHUNK);              /* page 0: unchanged */
        copies_in_chunk(off, 0);
        for (unsigned i = 0; i < sizeof hooks / sizeof hooks[0]; i++)
            for (unsigned j = 0; j < 4; j++)
                if (hooks[i].at + j >= off && hooks[i].at + j < off + CHUNK)
                    buf[hooks[i].at + j - off] = hooks[i].code[j];
        hal_rom_write(1, off, buf, CHUNK);              /* page 1: with the hooks */
    }
    f_close(&f);
    md5_done(&m, digest);
    if (memcmp(digest, ace_md5, 16) != 0) return ROM_BADMD5;

    for (unsigned p = 2; p < 8; p++) {
        if (!hal_flash_open(p)) return ROM_NOEXT;
        for (unsigned off = 0; off < ROM_PAGE; off += CHUNK) {
            hal_flash_read(buf, CHUNK);
            copies_in_chunk(off, 1);
            if (0x0153 >= off && 0x0153 < off + CHUNK) buf[0x0153 - off] = PATCH_0153;
            hal_rom_write(p, off, buf, CHUNK);
        }
    }
    return ROM_OK;
}

/* standalone build: a message on the Ace's text screen (32 x 24 at $2400) */
static void show(const char *line1, const char *line2)
{
    for (int i = 0; i < 768; i++) hal_screen_write(i, ' ');
    const char *lines[2] = { line1, line2 };
    for (int l = 0; l < 2; l++)
        for (int i = 0; lines[l][i] && i < 32; i++) hal_screen_write((10 + 2 * l) * 32 + i, lines[l][i]);
}

void rom_boot(FATFS *fs)
{
    hal_z80_reset(1);
    for (;;) {
        enum rom_status st = rom_load(fs);
        if (st == ROM_OK) {
            hal_rom_ready(1);           /* page 1 at reset; the expansion takes over the ROM */
            hal_z80_reset(0);
            return;
        }
        if (!hal_standalone()) {        /* expansion: the Ace boots its own ROM */
            hal_rom_ready(0);
            hal_z80_reset(0);
            return;
        }
        show("TURBOACE: CANNOT START", rom_status_text[st]);
        for (uint32_t t = hal_ms(); hal_ms() - t < 1000;) {
        }
    }
}
