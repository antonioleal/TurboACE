/*
 * A card image for the FPGA system test: a freshly formatted 32 MB FAT card (the
 * firmware's own FatFs and its PC RAM disk, firmware/test/diskio_ram.c) with the
 * given files on it, written out as only its non-zero sectors, for sim/sdcard_model.v:
 *
 *   mkcard OUT.hex /name=HOSTFILE ...
 *
 * OUT.hex: the number of sectors listed (a word), then for each its number (a word)
 * and its 512 bytes, one hex byte per line ($readmemh); words little-endian.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ff.h"
#include "diskio.h"
#include "host_fpga.h"

static void word(FILE *f, unsigned long v)
{
    for (int i = 0; i < 4; i++) fprintf(f, "%02lx\n", (v >> (8 * i)) & 0xFF);
}

int main(int argc, char **argv)
{
    static FATFS fs;
    static unsigned char buf[1 << 20];
    if (argc < 2) { fprintf(stderr, "usage: mkcard OUT.hex /name=HOSTFILE ...\n"); return 2; }
    ramdisk_format();
    ramdisk_present(1);
    if (f_mount(&fs, "", 1) != FR_OK) { fprintf(stderr, "mkcard: mount failed\n"); return 1; }
    for (int a = 2; a < argc; a++) {
        char name[256];
        const char *eq = strchr(argv[a], '=');
        if (!eq) { fprintf(stderr, "mkcard: %s is not /name=file\n", argv[a]); return 2; }
        snprintf(name, sizeof name, "%.*s", (int) (eq - argv[a]), argv[a]);
        FILE *h = fopen(eq + 1, "rb");
        if (!h) { fprintf(stderr, "mkcard: cannot read %s\n", eq + 1); return 1; }
        size_t n = fread(buf, 1, sizeof buf, h);
        fclose(h);
        FIL f; UINT w;
        if (f_open(&f, name, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK || f_write(&f, buf, (UINT) n, &w) != FR_OK
            || w != n || f_close(&f) != FR_OK) {
            fprintf(stderr, "mkcard: cannot write %s on the card\n", name);
            return 1;
        }
    }
    f_unmount("");
    /* only the sectors that are not all zero */
    LBA_t sectors;
    disk_ioctl(0, GET_SECTOR_COUNT, &sectors);
    static unsigned char sec[512];
    unsigned long used = 0;
    for (LBA_t s = 0; s < sectors; s++) {
        disk_read(0, sec, s, 1);
        for (int i = 0; i < 512; i++) if (sec[i]) { used++; break; }
    }
    FILE *o = fopen(argv[1], "w");
    if (!o) { fprintf(stderr, "mkcard: cannot write %s\n", argv[1]); return 1; }
    word(o, used);
    for (LBA_t s = 0; s < sectors; s++) {
        disk_read(0, sec, s, 1);
        int any = 0;
        for (int i = 0; i < 512; i++) if (sec[i]) { any = 1; break; }
        if (!any) continue;
        word(o, (unsigned long) s);
        for (int i = 0; i < 512; i++) fprintf(o, "%02x\n", sec[i]);
    }
    fclose(o);
    printf("mkcard: %lu sectors in use\n", used);
    return 0;
}
