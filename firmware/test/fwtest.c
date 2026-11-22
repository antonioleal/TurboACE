/*
 * Tests for the SD soft CPU firmware on a PC: the protocol is driven from the
 * Z80's side, byte by byte, as the TurboACE ROM does it; files are checked on
 * the RAM disk through FatFs directly.
 */
#include <stdio.h>
#include <string.h>
#include "ff.h"
#include "host_fpga.h"

static int failures, checks;
static void check(int ok, const char *what)
{
    checks++;
    if (!ok) { failures++; printf("  FAIL %s\n", what); }
}

/* ---- the Z80's side, as the ROM does it ---- */
static int last_status;

static int wait_busy(void)              /* 0, or the error code */
{
    int s;
    long n = 0;
    while ((s = z80_in(0xE5)) & 0x80) {
        if (++n > 1000000) return 99;   /* the firmware never answered */
    }
    last_status = s;
    return s & 0x40 ? z80_in(0xE7) : 0;
}

static void put(int b) { z80_out(0xE7, b); }
static void put16(int v) { put(v & 0xFF); put(v >> 8); }
static int get(void) { return z80_in(0xE7); }
static void put_name(const char *s) { put((int) strlen(s)); while (*s) put((unsigned char) *s++); }

static int command(int c) { z80_out(0xE5, c); return wait_busy(); }

static int send_data(const unsigned char *p, int n)    /* data phase out */
{
    for (int i = 0; i < n; i++) {
        put(p[i]);
        if ((i + 1) % 512 == 0 || i + 1 == n) {
            int e = wait_busy();
            if (e) return e;
        }
    }
    return 0;
}

static int recv_data(unsigned char *p, int n)          /* data phase in */
{
    for (int i = 0; i < n; i++) {
        p[i] = (unsigned char) get();
        if ((i + 1) % 512 == 0 || i + 1 == n) {
            int e = wait_busy();
            if (e) return e;
        }
    }
    return 0;
}

static long file_bytes(const char *path, unsigned char *buf, long max)
{
    FIL f;
    UINT got;
    if (f_open(&f, path, FA_READ) != FR_OK) return -1;
    f_read(&f, buf, (UINT) max, &got);
    f_close(&f);
    return (long) got;
}

static void make_file(const char *path, const void *data, UINT n)
{
    FIL f;
    UINT w;
    f_open(&f, path, FA_WRITE | FA_CREATE_ALWAYS);
    f_write(&f, data, n, &w);
    f_close(&f);
}

/* ---- tests ---- */
static void test_files(void)
{
    static unsigned char data[3000], back[3000];
    char msg[160];
    int e;
    for (int i = 0; i < 3000; i++) data[i] = (unsigned char) (i * 7 + 3);
    printf("files\n");

    put(0);
    e = command(0x02);                  /* DIRFIRST: mounts, makes /programs */
    FILINFO fi;
    check(e == 0 && (last_status & 0x20) && f_stat("/programs", &fi) == FR_OK && (fi.fattrib & AM_DIR),
          "first command mounts the card (CARD set) and makes /programs");
    check(get() == 0xFF, "a new card's /programs is empty");

    put_name("DATA.BIN");
    e = command(0x11);
    put16(1300);
    check(!e && !command(0x13) && !send_data(data, 1300), "OPENW, WRITE 1300 bytes (3 chunks)");
    check(file_bytes("/programs/DATA.BIN", back, 3000) == 1300 && !memcmp(back, data, 1300),
          "flushed after the WRITE: the file holds the 1300 bytes before any CLOSE");
    put16(700);
    check(!command(0x13) && !send_data(data + 1300, 700) && !command(0x14), "second WRITE of 700, CLOSE");
    check(file_bytes("/programs/DATA.BIN", back, 3000) == 2000 && !memcmp(back, data, 2000),
          "DATA.BIN = the 2000 bytes written");

    put_name("DATA.BIN");
    e = command(0x10);
    long size = get() | get() << 8 | (long) get() << 16 | (long) get() << 24;
    check(!e && size == 2000, "OPENR gives the size, 2000");
    memset(back, 0, sizeof back);
    put16(1500);
    e = command(0x12);
    int n = get() | get() << 8;
    check(!e && n == 1500 && !recv_data(back, n) && !memcmp(back, data, 1500), "READ 1500: count 1500, then the data");
    put16(1500);
    e = command(0x12);
    n = get() | get() << 8;
    check(!e && n == 500 && !recv_data(back, n) && !memcmp(back, data + 1500, 500), "READ 1500 near the end: 500");
    put16(100);
    e = command(0x12);
    n = get() | get() << 8;
    check(!e && n == 0, "READ at the end: count 0");
    check(!command(0x14), "CLOSE");
    put16(10);
    check(command(0x12) == 7, "READ with no file open: error 7");
    put16(9000);
    put_name("X");                      /* (an OPENW must be first) */
    command(0x11);
    put16(9000);
    check(command(0x13) == 8, "WRITE of 9000 bytes: error 8");
    command(0x14);
    put_name("NOPE.BIN");
    check(command(0x10) == 2 && (last_status & 0x40), "OPENR of a missing file: ERROR, code 2");
    put_name("A.BIN");
    command(0x11);
    put_name("B.BIN");
    command(0x11);                      /* opening closes A.BIN */
    put16(5);
    command(0x13);
    send_data(data, 5);
    command(0x14);
    check(file_bytes("/programs/A.BIN", back, 10) == 0 && file_bytes("/programs/B.BIN", back, 10) == 5,
          "OPENW while a file is open closes it first");
    snprintf(msg, sizeof msg, "no FIFO overruns (%ld)", fpga_overflows);
    check(fpga_overflows == 0, msg);
}

static void read_entry(int *flags, long *size, char *name)
{
    *flags = get();
    if (*flags == 0xFF) { name[0] = 0; return; }
    *size = get() | get() << 8 | (long) get() << 16 | (long) get() << 24;
    int n = get();
    for (int i = 0; i < n; i++) name[i] = (char) get();
    name[n] = 0;
}

static void test_dirs(void)
{
    int fl;
    long sz;
    char nm[80], list[400] = "", t[100];
    printf("folders\n");
    f_mkdir("/programs/DEMOS");
    f_mkdir("/programs/ZFOLDER");
    make_file("/programs/DEMOS/WAVES.TAP", "123456789", 9);
    put(0);
    int e = command(0x02);
    while (!e) {
        read_entry(&fl, &sz, nm);
        if (fl == 0xFF) break;
        snprintf(t, sizeof t, "%s%s%s ", nm, fl & 1 ? "/" : "", "");
        strcat(list, t);
        e = command(0x03);
    }
    check(!e && strstr(list, "DEMOS/ ZFOLDER/ ") == list,
          "DIR lists the folders first");
    check(strstr(list, "DATA.BIN") && strstr(list, "A.BIN") && strstr(list, "B.BIN"), "then the files");
    put_name("DEMOS");
    check(!command(0x04), "CHDIR DEMOS");
    put(0);
    e = command(0x02);
    read_entry(&fl, &sz, nm);
    check(!e && fl == 0 && sz == 9 && !strcmp(nm, "WAVES.TAP"), "DIR in DEMOS: WAVES.TAP, 9 bytes");
    check(!command(0x03) && get() == 0xFF, "then the end");
    put_name("..");
    check(!command(0x04), "CHDIR ..");
    put_name("NOPE");
    check(command(0x04) == 2, "CHDIR NOPE: error 2");
    put_name("A.BIN");
    FILINFO fi;
    check(!command(0x05) && f_stat("/programs/A.BIN", &fi) == FR_NO_FILE, "DELETE A.BIN");
    put_name("A.BIN");
    check(command(0x05) == 2, "DELETE A.BIN again: error 2");
    e = command(0x06);
    long k = get() | get() << 8 | (long) get() << 16 | (long) get() << 24;
    check(!e && k > 20000 && k < 33000, "FREE: about 32 MB free, in K");
    put_name("/");
    check(!command(0x04), "CHDIR /");
    put(0);
    e = command(0x02);
    read_entry(&fl, &sz, nm);
    check(!e && fl == 1 && !strcmp(nm, "programs"), "DIR at the top: programs/");
    put_name("programs");
    command(0x04);
}

static int tread(int flag, int len, int search, unsigned char *dst, int verify_only)
{
    put(flag); put16(len); put(search);
    int e = command(0x22);
    if (e) return e;
    (void) verify_only;
    if (len == 0) return 0;
    return recv_data(dst, len);
}

static int twrite(int flag, const unsigned char *p, int len)
{
    put(flag); put16(len);
    int e = command(0x23);
    if (e) return e;
    if (len == 0) return wait_busy();
    return send_data(p, len);
}

static void make_header(unsigned char *h, const char *name)
{
    memset(h, ' ', 25);
    h[0] = 0x00;
    memcpy(h + 1, name, strlen(name));
}

static void test_tape(void)
{
    static unsigned char hdr[25], data[1200], back[1300], file[3000];
    printf("tape\n");
    for (int i = 0; i < 1200; i++) data[i] = (unsigned char) (i * 13 + 1);
    make_header(hdr, "MYPROG");

    check(!twrite(0x00, hdr, 25) && !twrite(0xFF, data, 1200), "SAVE with no tape: header and data blocks");
    long n = file_bytes("/programs/MYPROG.tap", file, sizeof file);
    unsigned char ch = 0, cd = 0;
    for (int i = 0; i < 25; i++) ch ^= hdr[i];
    for (int i = 0; i < 1200; i++) cd ^= data[i];
    check(n == 2 + 25 + 1 + 2 + 1200 + 1 && file[0] == 26 && file[1] == 0 && !memcmp(file + 2, hdr, 25)
          && file[27] == ch && file[28] == (1201 & 0xFF) && file[29] == (1201 >> 8)
          && !memcmp(file + 30, data, 1200) && file[1230] == cd,
          "MYPROG.tap: length, header, checksum, length, data, checksum (as the emulator writes)");
    check(!(last_status & 0x10), "the new file is not put in the player");

    make_header(hdr, "MY PROG!");
    twrite(0x00, hdr, 25);
    twrite(0xFF, data, 10);
    FILINFO fi;
    check(f_stat("/programs/MY PROG_.tap", &fi) == FR_OK, "header name \"MY PROG!\" makes MY PROG_.tap, as the emulator does");

    put_name("NOTHERE");
    check(command(0x20) == 2, "TINSERT of a missing tape: error 2");
    put_name("MYPROG");
    check(!command(0x20) && (last_status & 0x10), "TINSERT MYPROG finds MYPROG.tap; TAPE set");

    make_header(hdr, "MYPROG");
    memset(back, 0, sizeof back);
    check(!tread(0x00, 25, 1, back, 0) && !memcmp(back, hdr, 25), "header search: the header");
    check(!tread(0xFF, 1200, 0, back, 0) && !memcmp(back, data, 1200), "then the data block (3 chunks)");
    check(!tread(0x00, 25, 1, back, 0), "a new search wraps round to the header");
    check(tread(0x00, 25, 1, back, 0) == 9, "the search meets the data block: error 9 (LOAD tries again)");
    check(tread(0x00, 25, 1, back, 0) == 10, "once round: error 10");
    check(tread(0xFF, 1199, 0, back, 0) == 9, "data of the wrong length: error 9");
    check(tread(0xFF, 10, 0, back, 0) == 9 && tread(0xFF, 10, 0, back, 0) == 9,
          "past the end, a plain read gets error 9 (no ERROR 10)");

    /* a corrupted byte: the checksum fails after the data */
    long len = file_bytes("/programs/MYPROG.tap", file, sizeof file);
    file[600] ^= 1;
    make_file("/programs/MYPROG.tap", file, (UINT) len);
    put_name("MYPROG"); command(0x20);
    tread(0x00, 25, 1, back, 0);
    check(tread(0xFF, 1200, 0, back, 0) == 9, "a corrupted byte: error 9 after the data (bad checksum)");

    /* aborting a read half way: the next command works */
    put_name("MYPROG"); command(0x20);
    put(0x00); put16(25); put(1);
    command(0x22);
    get(); get(); get();                /* 3 of 25 bytes, then a new command */
    put_name("MYPROG");
    check(!command(0x20) && !tread(0x00, 25, 1, back, 0), "a read abandoned half way: the next commands work");

    /* SAVE with the tape in: appended to it */
    long before = file_bytes("/programs/MYPROG.tap", file, sizeof file);
    make_header(hdr, "SECOND");
    twrite(0x00, hdr, 25);
    twrite(0xFF, data, 20);
    long after = file_bytes("/programs/MYPROG.tap", file, sizeof file);
    check(after == before + 28 + 23 && !memcmp(file + before + 2, hdr, 25), "SAVE with a tape in: appended to it");

    /* MYPROG.tap now holds MYPROG then SECOND. Load MYPROG (header, data): the tape
     * is at SECOND's header. A LOAD without a name starts again from the beginning. */
    unsigned char first[25];
    make_header(first, "MYPROG");
    put_name("MYPROG"); command(0x20);
    tread(0x00, 25, 1, back, 0);
    tread(0xFF, 1200, 0, back, 0);      /* the data (its checksum was spoilt above) */
    memset(back, 0, 25);
    check(!tread(0x00, 25, 2, back, 0) && !memcmp(back, first, 25),
          "LOAD without a name (search 2): from the tape's beginning, MYPROG not SECOND");
    put_name("MYPROG"); command(0x20);
    tread(0x00, 25, 1, back, 0);
    tread(0xFF, 1200, 0, back, 0);
    check(!tread(0x00, 25, 1, back, 0) && !memcmp(back, hdr, 25),
          "while a LOAD with a name (search 1) goes on from there: SECOND");

    check(!command(0x21) && !(last_status & 0x10), "TEJECT: TAPE clear");
    check(tread(0x00, 25, 1, back, 0) == 10, "no tape, LOAD: error 10");
    check(tread(0xFF, 10, 0, back, 0) == 9, "no tape, a plain read: error 9");
    check(twrite(0xFF, data, 5) == 7, "a data block with no header before it: error 7");
}

static void test_tzx(void)
{
    static unsigned char t[200], back[100], hdr[25];
    printf("tzx\n");
    make_header(hdr, "TZXPROG");
    int n = 0;
    memcpy(t, "ZXTape!\x1A\x01\x14", 10); n = 10;
    t[n++] = 0x30; t[n++] = 3; t[n++] = 'h'; t[n++] = 'i'; t[n++] = '!';   /* text: skipped */
    unsigned char c = 0;
    for (int i = 0; i < 25; i++) c ^= hdr[i];
    t[n++] = 0x10; t[n++] = 0xE8; t[n++] = 0x03; t[n++] = 27; t[n++] = 0; t[n++] = 0x00;
    memcpy(t + n, hdr, 25); n += 25; t[n++] = c;
    t[n++] = 0x10; t[n++] = 0xE8; t[n++] = 0x03; t[n++] = 5; t[n++] = 0; t[n++] = 0xFF;
    t[n++] = 1; t[n++] = 2; t[n++] = 3; t[n++] = 1 ^ 2 ^ 3;
    make_file("/programs/GAME.TZX", t, (UINT) n);
    put_name("GAME");
    check(!command(0x20), "TINSERT GAME finds GAME.TZX");
    check(!tread(0x00, 25, 1, back, 0) && !memcmp(back, hdr, 25), "TZX: header, past a text block");
    check(!tread(0xFF, 3, 0, back, 0) && back[0] == 1 && back[2] == 3, "TZX: data block");
    unsigned char d[4] = { 9, 8, 7, 6 };
    make_header(hdr, "ADDED");
    twrite(0x00, hdr, 25);
    twrite(0xFF, d, 4);
    unsigned char f[300];
    long len = file_bytes("/programs/GAME.TZX", f, sizeof f);
    check(len == n + 6 + 25 + 1 + 6 + 4 + 1 && f[n] == 0x10 && f[n + 1] == 0xE8 && f[n + 5] == 0x00
          && f[n + 6 + 25 + 1] == 0x10 && f[n + 6 + 25 + 1 + 5] == 0xFF,
          "SAVE onto a TZX tape: standard data blocks (10h, 1000 ms) with the flag byte");
    command(0x21);
}

static void test_card(void)
{
    printf("card\n");
    ramdisk_present(0);
    check(command(0x01) == 1 && !(last_status & 0x20), "no card: MOUNT gives error 1, CARD clear");
    put(0);
    check(command(0x02) == 1, "no card: DIRFIRST gives error 1");
    ramdisk_present(1);
    check(!command(0x01) && (last_status & 0x20), "card back: MOUNT works, CARD set");
    put(0);
    check(!command(0x02), "and DIR works again");
    check(command(0x7F) == 6, "an unknown command: error 6");
}

int main(void)
{
    ramdisk_format();
    fpga_reset();
    test_files();
    test_dirs();
    test_tape();
    test_tzx();
    test_card();
    printf("%d checks, %s\n", checks, failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
