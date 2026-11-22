/*
 * Tests for the ROM at power-up (romload.c, md5.c) on a PC.
 * Usage: romtest ACE_ROM TURBOACE_ROM
 *   ACE_ROM       the stock Jupiter Ace ROM (8K), put on the RAM disk as /ace.rom
 *   TURBOACE_ROM  rom/build/turboace.rom (64K): its pages 2-7 stand in for the
 *                 board's flash, and the whole 64K is what the loader must make
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "ff.h"
#include "hal.h"
#include "md5.h"
#include "romload.h"
#include "host_fpga.h"

static int failures, checks;
static void check(int ok, const char *what)
{
    checks++;
    if (!ok) { failures++; printf("  FAIL %s\n", what); }
}

/* ---- the hardware romload.c uses ---- */
static uint8_t rom[8][8192], flash[8][8192];
static int flash_ok = 1, standalone, z80_reset = 1, rom_ready, screen_writes;
static char screen[768];
static int insert_after = -1;           /* put /ace.rom on the card after this many screen messages */
static uint8_t stock[8192];
static FATFS card_fs;                  /* the work area main.c shares with the SD protocol */

uint32_t hal_ms(void)                   /* a standalone retry loop must end in the tests */
{
    static uint32_t t;
    if ((t += 7) > 70000000u) { printf("  FAIL rom_boot never got going (retried for ever)\n"); exit(1); }
    return t;
}
void hal_z80_reset(int on) { z80_reset = on; }
void hal_rom_ready(int on) { rom_ready = on; }
int  hal_standalone(void) { return standalone; }
void hal_rom_write(unsigned page, unsigned offset, const uint8_t *p, unsigned n) { memcpy(rom[page] + offset, p, n); }
static unsigned flash_page, flash_pos;
int  hal_flash_open(unsigned page) { flash_page = page; flash_pos = 0; return flash_ok; }
void hal_flash_read(uint8_t *p, unsigned n) { memcpy(p, flash[flash_page] + flash_pos, n); flash_pos += n; }

static void put_file(const char *path, const void *p, UINT n)
{
    FIL f; UINT w;
    f_open(&f, path, FA_WRITE | FA_CREATE_ALWAYS);
    f_write(&f, p, n, &w);
    f_close(&f);
}

void hal_screen_write(unsigned offset, int c)
{
    screen[offset] = (char) c;
    if (offset == 767 && ++screen_writes == insert_after) {
        static FATFS fs;                /* the user puts the card right */
        f_mount(&fs, "", 1);
        put_file("/ace.rom", stock, 8192);
    }
}

static int load_file(const char *path, void *buf, long n)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    long got = (long) fread(buf, 1, (size_t) n, f);
    fclose(f);
    return got == n;
}

static void md5_hex(const char *s, char *out)
{
    struct md5 m; uint8_t d[16];
    md5_init(&m); md5_add(&m, s, (unsigned) strlen(s)); md5_done(&m, d);
    for (int i = 0; i < 16; i++) sprintf(out + 2 * i, "%02x", d[i]);
}

int main(int argc, char **argv)
{
    static uint8_t built[65536];
    setvbuf(stdout, NULL, _IONBF, 0);
    char hex[40], msg[200];
    if (argc < 3 || !load_file(argv[1], stock, 8192) || !load_file(argv[2], built, 65536)) {
        printf("usage: romtest ACE_ROM TURBOACE_ROM (files not readable)\n");
        return 2;
    }
    static const int ranges[][2] = { {0x0010,0x0020}, {0x0038,0x003B}, {0x013A,0x017E},
                                     {0x0310,0x03EE}, {0x0859,0x0865} };
    for (int p = 2; p < 8; p++) {       /* the flash as the build makes it: no stock bytes */
        memcpy(flash[p], built + p * 8192, 8192);
        for (int r = 0; r < 5; r++) memset(flash[p] + ranges[r][0], 0, ranges[r][1] - ranges[r][0]);
    }
    {
        int stock_in_flash = 0;
        for (int p = 2; p < 8; p++)
            for (int a = 0; a + 16 <= 8192; a += 16)
                if (!memcmp(flash[p] + a, stock + a, 16) && memcmp(stock + a, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0", 16)
                    && memcmp(stock + a, "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF", 16))
                    stock_in_flash++;
        check(stock_in_flash == 0, "the flash image holds no 16-byte run of the stock ROM at its own address");
    }

    printf("md5 (RFC 1321 test suite)\n");
    static const char *const v[][2] = {
        { "", "d41d8cd98f00b204e9800998ecf8427e" },
        { "abc", "900150983cd24fb0d6963f7d28e17f72" },
        { "message digest", "f96b697d7cb7938d525a2f31aaf161d0" },
        { "abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b" },
        { "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
          "57edf4a22be3c955ac49da2e2107b67a" },
    };
    for (int i = 0; i < 5; i++) {
        md5_hex(v[i][0], hex);
        snprintf(msg, sizeof msg, "MD5(\"%.20s...\") = %s", v[i][0], v[i][1]);
        check(!strcmp(hex, v[i][1]), msg);
    }

    printf("loading /ace.rom\n");
    ramdisk_format();
    ramdisk_present(0);
    check(rom_load(&card_fs) == ROM_NOCARD, "no card: NO SD CARD");
    ramdisk_present(1);
    check(rom_load(&card_fs) == ROM_NOFILE, "empty card: NO /ACE.ROM");
    put_file("/ace.rom", stock, 100);
    check(rom_load(&card_fs) == ROM_BADSIZE, "a 100-byte /ace.rom: not 8192 bytes");
    stock[0x1234] ^= 1;
    put_file("/ace.rom", stock, 8192);
    stock[0x1234] ^= 1;
    check(rom_load(&card_fs) == ROM_BADMD5, "one byte different: not the stock ROM (MD5)");
    put_file("/ace.rom", stock, 8192);
    flash_ok = 0;
    int st = rom_load(&card_fs);
    snprintf(msg, sizeof msg, "flash without TurboACE's pages: NO TURBOACE ROM (got %s)", rom_status_text[st]);
    check(st == ROM_NOEXT, msg);
    flash_ok = 1;
    memset(rom, 0, sizeof rom);
    check(rom_load(&card_fs) == ROM_OK, "the stock ROM: OK");
    check(!memcmp(rom[0], stock, 8192), "page 0 = /ace.rom, unchanged");
    int diff = 0;
    for (int a = 0; a < 8192; a++) diff += rom[1][a] != stock[a];
    snprintf(msg, sizeof msg, "page 1 = /ace.rom with the hooks (%d bytes differ)", diff);
    check(diff == 12, msg);
    check(!memcmp(rom, built, 65536), "all 64K = rom/build/turboace.rom, byte for byte (hooks match the ROM source)");

    {
        int fit = 1;
        for (int k = ROM_OK; k <= ROM_NOEXT; k++) if (strlen(rom_status_text[k]) > 32) fit = 0;
        check(fit, "every reason fits a 32-character screen line");
    }

    printf("power-up\n");
    standalone = 0;
    ramdisk_format();
    rom_ready = 1; z80_reset = 1;
    rom_boot(&card_fs);
    check(!z80_reset && !rom_ready, "expansion, no /ace.rom: Z80 released on the Ace's own ROM");
    put_file("/ace.rom", stock, 8192);
    z80_reset = 1;
    rom_boot(&card_fs);
    check(!z80_reset && rom_ready, "expansion with /ace.rom: ROM ready, Z80 released");

    standalone = 1;
    ramdisk_format();
    insert_after = 2;
    z80_reset = 1; rom_ready = 0; screen_writes = 0;
    rom_boot(&card_fs);
    check(screen_writes == 2 && !z80_reset && rom_ready,
          "standalone, no /ace.rom: message, new tries, starts once the file is there");
    check(strstr(screen + 10 * 32, "TURBOACE: CANNOT START") == screen + 10 * 32
          && !strncmp(screen + 12 * 32, "NO /ACE.ROM ON THE CARD", 23),
          "the message on the screen says why");

    printf("%d checks, %s\n", checks, failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
