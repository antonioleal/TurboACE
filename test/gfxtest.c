/* =============================================================================
 * TurboACE test harness: runs the graphics routines (ROM page 2), the boot
 * page and the TURBO word from the built ROM (rom/build/turboace.rom) on a Z80
 * core, and compares the results with reference models written from the spec
 * (register-map.md sections 5 and 7).
 *
 * The Z80 core is Ian Collier's xz80 as used by Jupiter-IIb (src/z80ops.c,
 * GPL v2+). It is NOT copied into this project: the Makefile compiles it from
 * the Jupiter-IIb tree (JIIB=...). Only this driver is TurboACE code.
 *
 * Machine model (just what the graphics routines touch):
 *   $0000-$1FFF  ROM page 2 (writes are counted as errors)
 *   $2000-$BFFF  flat RAM (state at $3B00, Forth stack, Z80 stack)
 *   $C000-$DFFF  window 0, $E000-$FFFF window 1: each shows one of 64 8K pages
 *   $E1          page port: write w0pppppp, read with the window on A15
 *   $E3          control port: any access by graphics code is an error
 *   $FD/$FF      AY register select / value (R14 = PAPER:INK)
 * No interrupts are raised: the copied interrupt path is checked statically by
 * tools/misc/romcheck.py.
 *
 * Checks for every call: carry clear, IX/IY preserved, Forth stack consumed
 * exactly, user RAMPAGE restored, no ROM writes, only the work page changed,
 * bitmap and colour bytes identical to the reference, PLOT position as specified.
 * Plus geometric checks independent of the reference algorithm.
 * =============================================================================
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <math.h>

#include "syms.h"                       /* generated from rom/build/turboace.sym */
#include "ff.h"                          /* the firmware's FatFs, to look at the card */
#include "host_fpga.h"                  /* the firmware behind the FPGA mailbox */
#include "keyboard.h"                   /* the firmware's PS/2 keyboard translation */
static int kb_on;                       /* port $FE keys come from keyboard.c */
static int fw_on;                       /* $E5/$E7 go to the real firmware */

/* ---- machine ----------------------------------------------------------------- */
unsigned char mem[65536];               /* $2000-$BFFF (lower 8K unused: ROM) */
static unsigned char rom[8][8192];      /* the 8 ROM pages */
static int rompage = 2;                 /* graphics routines live in page 2 */
unsigned char ram[64 * 8192];           /* 64 x 8K user-RAM pages */
int win[2];                             /* page shown in window 0 / 1 */
static int ay_reg;
static unsigned char ay_r14;            /* graphics tests: R14 as read */
static int allow_ctrl;                  /* TURBO/boot tests: model $E3 and AY writes */
static int creg[8];                     /* $E3 registers by command (parameter bits) */
/* tape port $FE (any even port): MIC (OUT bit 3) is recorded with its T-state;
 * EAR (IN bit 5) plays back a recording; keys read as not pressed */
extern unsigned long tstates;
static int tape_on;
static int break_key;                   /* SPACE held: IN $FE bit 0 = 0 */

/* ---- model of the soft CPU's virtual tape player (register-map.md 2.6) ---- */
#define SDT_MAXB 16
struct tblock { int flag, len; unsigned char data[2048]; int bad_sum; };
static struct {
  int on, inserted, nblocks, pos, searching, origin, wrapped;
  struct tblock b[SDT_MAXB];
  unsigned char args[16]; int nargs;
  unsigned char args2[80];              /* the same argument bytes, longer (names) */
  int err, err_pending;                 /* last command failed; code not yet read */
  unsigned char out[8200]; int nout, outpos;      /* read data phase */
  int wr_left, wr_block;                /* write data phase */
  struct tblock *wr_target;
  long cmds;                            /* commands received */
  int wfile;                            /* card file a SAVE with no tape writes to, or -1 */
  char lastname[70];                    /* last name received by TINSERT */
  int last_search;                      /* TREAD's search argument */
} sdm;

/* card files (a .TAP is a list of blocks) and folders */
struct tfile { char name[70]; char dir[80]; long fake_size; int nblocks; struct tblock b[SDT_MAXB];
               int raw; long rawlen; unsigned char rawdata[16384]; };
static struct tfile cardf[6];
static int ncardf;
static char cwd[80] = "/programs";
static char folders[4][80];
static int nfolders;
static int no_card, card_full;
static int open_f = -1, open_mode;      /* the open file: 1 read, 2 write */
static long open_pos;
static int wr_raw = -1;
/* the directory listing being read by DIRNEXT */
static unsigned char dirent[16][80];
static int ndirent, dirpos;

static int card_find(const char *name)
{
  for (int k = 0; k < ncardf; k++)
    if (!strcasecmp(cardf[k].dir, cwd) && !strcasecmp(cardf[k].name, name)) return k;
  return -1;
}

static long file_size(struct tfile *f)    /* .TAP: 2-byte length, data, checksum */
{
  if (f->fake_size) return f->fake_size;
  if (f->raw) return f->rawlen;
  long n = 0;
  for (int k = 0; k < f->nblocks; k++) n += 2 + f->b[k].len + 1;
  return n;
}

static void dir_add(int flags, long size, const char *name)
{
  unsigned char *e = dirent[ndirent++];
  int n = (int)strlen(name);
  e[0] = flags;
  for (int k = 0; k < 4; k++) e[1 + k] = (unsigned char)(size >> (8 * k));
  e[5] = n;
  memcpy(e + 6, name, n);
}

static const char *base_name(const char *path) { const char *p = strrchr(path, '/'); return p ? p + 1 : path; }
static void parent_of(const char *path, char *out)
{
  strcpy(out, path);
  char *p = strrchr(out, '/');
  if (p && p != out) *p = 0; else strcpy(out, "/");
}

static void sdm_fail(int code) { sdm.err = code; sdm.err_pending = 1; }

static void sdm_command(int cmd)
{
  sdm.cmds++;
  sdm.err = sdm.err_pending = 0;
  sdm.nout = sdm.outpos = 0;
  sdm.wr_left = 0;
  if (no_card) { sdm.nargs = 0; sdm_fail(1); return; }
  if (cmd == 0x02 || cmd == 0x03) {      /* DIRFIRST pattern / DIRNEXT */
    sdm.nargs = 0;
    if (cmd == 0x02) {
      ndirent = dirpos = 0;
      for (int k = 0; k < nfolders; k++) {
        char par[80]; parent_of(folders[k], par);
        if (!strcasecmp(par, cwd)) dir_add(1, 0, base_name(folders[k]));
      }
      for (int k = 0; k < ncardf; k++)
        if (!strcasecmp(cardf[k].dir, cwd)) dir_add(0, file_size(&cardf[k]), cardf[k].name);
    }
    if (dirpos < ndirent) { memcpy(sdm.out, dirent[dirpos], 6 + dirent[dirpos][5]); sdm.nout = 6 + dirent[dirpos][5]; dirpos++; }
    else { sdm.out[0] = 0xFF; sdm.nout = 1; }
    return;
  }
  if (cmd >= 0x10 && cmd <= 0x14) {      /* OPENR OPENW READ WRITE CLOSE */
    int len = sdm.nargs ? sdm.args2[0] : 0;
    int count = sdm.args[0] | sdm.args[1] << 8;
    char nm[80]; memcpy(nm, sdm.args2 + 1, len); nm[len] = 0;
    sdm.nargs = 0;
    if (cmd == 0x10 || cmd == 0x11) {
      open_mode = 0; open_f = -1;          /* opening closes a file left open */
      strcpy(sdm.lastname, nm);
      int f = card_find(nm);
      if (cmd == 0x10) {
        if (f < 0 || !cardf[f].raw) { sdm_fail(2); return; }
        long n = cardf[f].rawlen;
        for (int k = 0; k < 4; k++) sdm.out[k] = (unsigned char)(n >> (8 * k));
        sdm.nout = 4;
        open_f = f; open_mode = 1; open_pos = 0;
      } else {
        if (f < 0) { if (ncardf == 6) { sdm_fail(3); return; } f = ncardf++; }
        memset(&cardf[f], 0, sizeof cardf[f]);
        strcpy(cardf[f].name, nm); strcpy(cardf[f].dir, cwd);
        cardf[f].raw = 1;
        open_f = f; open_mode = 2;
      }
    } else if (cmd == 0x12) {
      if (open_mode != 1) { sdm_fail(7); return; }
      if (count > 8192) { sdm_fail(8); return; }
      long n = cardf[open_f].rawlen - open_pos;
      if (n > count) n = count;
      sdm.out[0] = n & 255; sdm.out[1] = n >> 8;
      memcpy(sdm.out + 2, cardf[open_f].rawdata + open_pos, n);
      sdm.nout = 2 + n;
      open_pos += n;
    } else if (cmd == 0x13) {
      if (open_mode != 2) { sdm_fail(7); return; }
      if (count > 8192) { sdm_fail(8); return; }
      if (card_full) { sdm_fail(3); return; }
      wr_raw = open_f;
      sdm.wr_left = count;
    } else {
      open_mode = 0; open_f = -1;
    }
    return;
  }
  if (cmd == 0x04 || cmd == 0x05) {      /* CHDIR name / DELETE name */
    int len = sdm.nargs ? sdm.args2[0] : 0;
    char nm[80]; memcpy(nm, sdm.args2 + 1, len); nm[len] = 0;
    strcpy(sdm.lastname, nm);
    sdm.nargs = 0;
    if (cmd == 0x04) {
      if (!strcmp(nm, "/")) { strcpy(cwd, "/"); return; }
      if (!strcmp(nm, "..")) { char p[80]; parent_of(cwd, p); strcpy(cwd, p); return; }
      char path[160];
      snprintf(path, sizeof path, "%s%s%s", cwd, strcmp(cwd, "/") ? "/" : "", nm);
      for (int k = 0; k < nfolders; k++)
        if (!strcasecmp(folders[k], path)) { strcpy(cwd, folders[k]); return; }
      sdm_fail(2);
    } else {
      int f = card_find(nm);
      if (f < 0) { sdm_fail(2); return; }
      cardf[f] = cardf[--ncardf];
    }
    return;
  }
  if (cmd == 0x22) {                     /* TREAD flag, len, search */
    int flag = sdm.args[0], len = sdm.args[1] | sdm.args[2] << 8, search = sdm.args[3];
    sdm.nargs = 0;
    if (!sdm.inserted || !sdm.nblocks) { sdm_fail(10); return; }
    sdm.last_search = search;
    if (!search) sdm.searching = 0;
    else if (!sdm.searching) {
      sdm.searching = 1;
      if (search == 2) sdm.pos = 0;     /* LOAD without a name: from the start */
      sdm.origin = sdm.pos; sdm.wrapped = 0;
    }
    if (sdm.searching && sdm.wrapped && sdm.pos == sdm.origin) { sdm.searching = 0; sdm_fail(10); return; }
    struct tblock *t = &sdm.b[sdm.pos];
    if (++sdm.pos == sdm.nblocks) { sdm.pos = 0; sdm.wrapped = 1; }
    if (t->flag != flag || t->len != len) { sdm_fail(9); return; }
    memcpy(sdm.out, t->data, len);
    sdm.nout = len;
    sdm.wr_block = t->bad_sum ? -9 : 0;  /* checksum reported at the end */
    if (len == 0 && t->bad_sum) sdm_fail(9);
  } else if (cmd == 0x23) {              /* TWRITE flag, len; data follows */
    int flag = sdm.args[0], len = sdm.args[1] | sdm.args[2] << 8;
    sdm.nargs = 0;
    struct tblock *t;
    if (sdm.inserted) {                  /* append to the tape in the player */
      if (sdm.nblocks == SDT_MAXB) { sdm_fail(3); return; }
      t = &sdm.b[sdm.nblocks++];
    } else {                             /* no tape: a header names a new file */
      if (flag == 0x00) {
        if (ncardf == 4) { sdm_fail(3); return; }
        sdm.wfile = ncardf++;
        cardf[sdm.wfile].nblocks = 0;
        cardf[sdm.wfile].name[0] = 0;
        cardf[sdm.wfile].fake_size = 0;
        strcpy(cardf[sdm.wfile].dir, cwd);
      } else if (sdm.wfile < 0) { sdm_fail(7); return; }
      t = &cardf[sdm.wfile].b[cardf[sdm.wfile].nblocks++];
    }
    t->flag = flag; t->len = len; t->bad_sum = 0;
    sdm.wr_block = -1;
    sdm.wr_target = t;
    sdm.wr_left = len;
    sdm.outpos = 0;
  } else if (cmd == 0x20) {              /* TINSERT name: name, name.TAP, name.TZX */
    int len = sdm.nargs ? sdm.args2[0] : 0;
    memcpy(sdm.lastname, sdm.args2 + 1, len); sdm.lastname[len] = 0;
    sdm.nargs = 0;
    const char *ext[] = {"", ".TAP", ".TZX"};
    for (int e = 0; e < 3; e++) {
      char nm[80]; snprintf(nm, sizeof nm, "%s%s", sdm.lastname, ext[e]);
      int f = card_find(nm);
      if (f >= 0) {
        sdm.inserted = 1; sdm.nblocks = cardf[f].nblocks;
        memcpy(sdm.b, cardf[f].b, sizeof sdm.b);
        sdm.pos = 0; sdm.searching = 0;
        return;
      }
    }
    sdm_fail(2);
  } else if (cmd == 0x21) {              /* TEJECT */
    sdm.nargs = 0;
    sdm.inserted = 0; sdm.nblocks = 0;
  } else {
    sdm.nargs = 0;
    sdm_fail(6);
  }
}

static int sdm_in(int port)
{
  if (port == 0xE5)
    return (sdm.err_pending || sdm.err ? 0x40 : 0) | 0x20 | (sdm.inserted ? 0x10 : 0)
         | (sdm.outpos < sdm.nout ? 1 : 0);
  if (sdm.err_pending) { sdm.err_pending = 0; int e = sdm.err; sdm.err = 0; return e; }
  if (sdm.outpos < sdm.nout) {
    int v = sdm.out[sdm.outpos++];
    if (sdm.outpos == sdm.nout && sdm.wr_block == -9) sdm_fail(9);   /* bad checksum */
    return v;
  }
  return 0xFF;
}

static void sdm_out(int port, int v)
{
  if (port == 0xE5) { sdm_command(v); return; }
  if (sdm.wr_left && wr_raw >= 0) {      /* WRITE data phase */
    struct tfile *f = &cardf[wr_raw];
    if (f->rawlen < (long)sizeof f->rawdata) f->rawdata[f->rawlen++] = v;
    if (!--sdm.wr_left) wr_raw = -1;
    return;
  }
  if (sdm.wr_left) {
    struct tblock *t = sdm.wr_target;
    t->data[t->len - sdm.wr_left] = v;
    sdm.wr_left--;
    if (!sdm.wr_left && !sdm.inserted && t->flag == 0x00 && sdm.wfile >= 0) {
      char *nm = cardf[sdm.wfile].name;  /* name.TAP from the header's name field */
      int n = 0;
      for (int k = 1; k <= 10 && k < t->len; k++) if (t->data[k] != ' ') nm[n++] = t->data[k];
      strcpy(nm + n, ".TAP");
      for (int k = 0; k < ncardf; k++)   /* replaces an existing file of that name */
        if (k != sdm.wfile && !strcasecmp(cardf[k].name, nm)) {
          cardf[k] = cardf[sdm.wfile]; ncardf--; sdm.wfile = k; break;
        }
    }
    return;
  }
  if (sdm.nargs < 80) {
    if (sdm.nargs < 16) sdm.args[sdm.nargs] = v;
    sdm.args2[sdm.nargs++] = v;
  }
}
#define TAPE_MAX 200000
static unsigned long rec_t[TAPE_MAX], play_t[TAPE_MAX];
static unsigned char rec_v[TAPE_MAX], play_v[TAPE_MAX];
static int rec_n, play_n;
static unsigned long play_start;
static int ear_level(void)
{
  if (!play_n || tstates < play_start) return 0;
  unsigned long p = tstates - play_start;
  int lo = 0, hi = play_n - 1, v = 0;
  while (lo <= hi) {                     /* last edge at or before p */
    int mid = (lo + hi) / 2;
    if (play_t[mid] <= p) { v = play_v[mid]; lo = mid + 1; } else hi = mid - 1;
  }
  return v;
}
static unsigned char ay[16];
static int model_chr;                   /* $2800-$2FFF writes go to font creg[2] */
static unsigned char chr[32][1024];
static long rom_writes, bad_ports;
unsigned long tstates;
int ram_paging = 0, ram_latch_pending = 0;
void ram_latch(unsigned char r) { (void)r; }

static int ace_mirror;                  /* Forth sessions: $2000-$2FFF as on the Ace */
static void ty_update(void);

/* XCFG MIRROR: $3000-$3BFF mirror $3C00-$3FFF; with KEEP, $3B00-$3BFF stay (-1 TURBO) */
static unsigned short mirror3(unsigned short a)
{
  if ((creg[7] & 2) && a >= 0x3000 && a < 0x3C00 && !((creg[7] & 8) && a >= 0x3B00))
    a = 0x3C00 | (a & 0x3FF);
  return a;
}

unsigned char rd(unsigned short a)
{
  if (ace_mirror && a >= 0x2000 && a < 0x3000) a |= 0x0400;
  a = mirror3(a);
  if (a >= 0xE000) return ram[win[1] * 8192 + (a - 0xE000)];
  if (a >= 0xC000) return ram[win[0] * 8192 + (a - 0xC000)];
  if (a < 0x2000) return rom[rompage][a];
  return mem[a];
}
void wr(unsigned short a, unsigned char v)
{
  if (ace_mirror && a >= 0x2000 && a < 0x3000) a |= 0x0400;
  a = mirror3(a);
  /* The stock ROM's end of a definition ($0F36) stores the word length through $3C39,
     which a dictionary LOAD leaves at 0: a later SAVE or error then writes $0000-$0001,
     into ROM, where it does nothing on the Ace. Not counted as a ROM write. */
  extern unsigned short zpc_now;
  if (a < 2 && (zpc_now == 0x0F41 || zpc_now == 0x0F43)) return;
  if (a < 0x2000) { if (v != rom[rompage][a]) { rom_writes++; if (getenv("ROMW")) fprintf(stderr, "ROM write $%04X=%02X page %d pc $%04X\n", a, v, rompage, zpc_now); } }   /* xz80 writes back after BIT n,(HL) */
  else if (model_chr && a >= 0x2800 && a < 0x3000) chr[creg[2] & 31][a & 0x3FF] = v;
  else if (a >= 0xE000) ram[win[1] * 8192 + (a - 0xE000)] = v;
  else if (a >= 0xC000) ram[win[0] * 8192 + (a - 0xC000)] = v;
  else mem[a] = v;
}

unsigned int in(int h, int l)
{
  if (fw_on && (l == 0xE5 || l == 0xE7)) return z80_in(l);
  if (sdm.on && (l == 0xE5 || l == 0xE7)) return sdm_in(l);
  if (kb_on && !(l & 1)) {               /* the Ace matrix: rows selected by A8-A15 low */
    uint8_t rows[8];
    int keys = 0;
    ty_update();
    kbd_matrix(rows);
    for (int r = 0; r < 8; r++) if (!(h >> r & 1)) keys |= rows[r];
    return 0xE0 | (~keys & 0x1F);
  }
  if (tape_on && !(l & 1)) return (break_key ? 0xDE : 0xDF) | (ear_level() << 5);
  if (l == 0xE1) return win[(h >> 7) & 1];
  if (l == 0xFF && allow_ctrl) return ay[ay_reg];
  if (l == 0xFF) return ay_reg == 14 ? ay_r14 : 0xFF;
  if (l == 0xE3 && allow_ctrl) {
    int sel = (h >> 5) & 7;
    if (sel == 7) return 0xA8 | (creg[7] & 1);       /* XCFG: ID + ATTR */
    return creg[sel];
  }
  bad_ports++;
  return 0xFF;
}

unsigned int out(int h, int l, int a)
{
  (void)h;
  if (fw_on && (l == 0xE5 || l == 0xE7)) { z80_out(l, a); return 0; }
  if (sdm.on && (l == 0xE5 || l == 0xE7)) { sdm_out(l, a); return 0; }
  if (tape_on && !(l & 1)) {
    if (rec_n < TAPE_MAX) { rec_t[rec_n] = tstates; rec_v[rec_n] = (a >> 3) & 1; rec_n++; }
    return 0;
  }
  if (l == 0xE1) win[(a >> 7) & 1] = a & 63;
  else if (l == 0xFD) ay_reg = a & 15;
  else if (l == 0xFF && allow_ctrl) ay[ay_reg] = a;
  else if (l == 0xE3 && allow_ctrl) {
    int cmd = (a >> 5) & 7;
    creg[cmd] = a & 31;
    if (cmd == 6) rompage = a & 7;
  }
  else bad_ports++;
  return 0;
}

/* ED traps of the Jupiter-IIb core: never reached by TurboACE code */
#include "tape.h"
int tape_load_p(unsigned char *m, unsigned short d, unsigned short n,
                unsigned char fl, int b, unsigned short r)
{ (void)m; (void)d; (void)n; (void)fl; (void)b; (void)r; bad_ports++; return 0; }
void tape_save_p(unsigned char *m, unsigned short n) { (void)m; (void)n; bad_ports++; }
void save_dictionary_out_p(unsigned char c) { (void)c; bad_ports++; }
void spool_error_p(unsigned char c) { (void)c; bad_ports++; }

#define ZSTACK   0x8000
#define FSTACK   0x6000                 /* Forth data stack (grows up) */
#define SV_SPARE 0x3C3B

#include "z80core.h"

/* ---- Forth stack ------------------------------------------------------------- */
static void fpush(int v)
{
  unsigned short p = mem[SV_SPARE] | mem[SV_SPARE + 1] << 8;
  mem[p] = v & 255;
  mem[p + 1] = (v >> 8) & 255;
  p += 2;
  mem[SV_SPARE] = p & 255;
  mem[SV_SPARE + 1] = p >> 8;
}
static unsigned short fsp(void) { return mem[SV_SPARE] | mem[SV_SPARE + 1] << 8; }

/* ---- reference model -------------------------------------------------------- */
#define W 256
#define H 192
#define WORKPG 3                        /* screen 3 = 8K pages 6 and 7 */
#define USERPG0 11                      /* the user's pages: not adjacent, not 6/7 */
#define USERPG1 40
#define scr (ram + WORKPG * 16384)      /* the work screen, 16K contiguous */
#define COLOUR 0x5A

static unsigned char ref[16384];        /* expected work page */
static long ref_pixels;                 /* PIXEL calls that hit the screen */

static void ref_pixel(int x, int y, int mode)
{
  if (mode == 2 || x < 0 || x >= W || y < 0 || y >= H) return;
  int ofs = (191 - y) * 32 + (x >> 3);
  unsigned char m = 0x80 >> (x & 7);
  if (mode == 0) ref[ofs] &= ~m;
  else if (mode == 1) ref[ofs] |= m;
  else ref[ofs] ^= m;
  ref[ofs + 0x1800] = COLOUR;
  ref_pixels++;
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

/* Spec: Bresenham from (x0, y0), start pixel excluded, no clamping */
static void ref_line(int x0, int y0, int dx, int dy, int mode)
{
  int adx = abs(dx), ady = abs(dy), sx = dx < 0 ? -1 : 1, sy = dy < 0 ? -1 : 1;
  int maj, min, msx, msy, nsx, nsy;
  if (adx >= ady) { maj = adx; min = ady; msx = sx; msy = 0; nsx = 0; nsy = sy; }
  else            { maj = ady; min = adx; msx = 0; msy = sy; nsx = sx; nsy = 0; }
  int err = maj >> 1, x = x0, y = y0;
  for (int n = maj; n; n--) {
    x += msx; y += msy;
    err -= min;
    if (err < 0) { err += maj; x += nsx; y += nsy; }
    ref_pixel(x, y, mode);
  }
}

/* ---- DRAW with an angle: the same integer method as gfx.asm -------------- */
static int sintab(int i) { return (short)(rom[2][SINTAB + 2 * i] | rom[2][SINTAB + 2 * i + 1] << 8); }

static int sin_hd(int h)
{
  if (h < 0) return -sin_hd(-h);
  while (h >= 720) h -= 720;
  int neg = 0;
  if (h >= 360) { h -= 360; neg = 1; }
  int v = sintab(h >= 181 ? 360 - h : h);
  return neg ? -v : v;
}
static int cos_hd(int h) { return sin_hd((short)(h + 180)); }

static int fits16(long v) { return v >= -32768 && v <= 32767; }
static int chkmag(int v) { return v >= 22528 || v <= -22529; }   /* 1 = too big */

/* returns 0 if the arc set-up gives up (radius too large): straight line */
static int arc_setup(int sx, int sy, int dx, int dy, int a,
                     int *v0x, int *v0y, long *cx32, long *cy32)
{
  int sh = sin_hd(a), ch = cos_hd(a);
  if (sh == 0) return 0;
  long q = (2L * dy * ch) / sh;
  if (q > 32767 || q < -32767) return 0;
  if (!fits16(2L * dx) || !fits16(q - 2L * dx)) return 0;
  *v0x = (int)(q - 2L * dx);
  if (chkmag(*v0x)) return 0;
  q = (2L * dx * ch) / sh;
  if (q > 32767 || q < -32767) return 0;
  if (!fits16(2L * dy) || !fits16(2L * dy + q)) return 0;
  *v0y = (int)(-(2L * dy + q));
  if (chkmag(*v0y)) return 0;
  *cx32 = (long)(int)(4 * sx - *v0x) * 16384 + 32768;
  *cy32 = (long)(int)(4 * sy - *v0y) * 16384 + 32768;
  return 1;
}

static void ref_drawa(int *px, int *py, int dx, int dy, int a, int mode)
{
  int lx = *px, ly = *py, ex = (short)(lx + dx), ey = (short)(ly + dy);
  a = a % 360;
  int v0x, v0y;
  long cx32, cy32;
  if (a && arc_setup(lx, ly, dx, dy, a, &v0x, &v0y, &cx32, &cy32)) {
    int step = a > 0 ? 10 : -10, end = 2 * abs(a);
    for (int th = step; abs(th) < end; th += step) {
      int tc = cos_hd(th), ts = sin_hd(th);
      int x = (int)((long)((long)v0x * tc - (long)v0y * ts + cx32) >> 16);
      int y = (int)((long)((long)v0x * ts + (long)v0y * tc + cy32) >> 16);
      ref_line(lx, ly, x - lx, y - ly, mode);
      lx = x; ly = y;
    }
  }
  ref_line(lx, ly, ex - lx, ey - ly, mode);
  *px = clampi(ex, 0, 255);
  *py = clampi(ey, 0, 191);
}


static void ref_quad(int cx, int cy, int a, int b, int mode)
{
  ref_pixel(cx + a, cy + b, mode); ref_pixel(cx - a, cy + b, mode);
  ref_pixel(cx - a, cy - b, mode); ref_pixel(cx + a, cy - b, mode);
}

/* Spec: midpoint circle, every pixel once */
static void ref_circle(int cx, int cy, int r, int mode)
{
  if (r < 0) return;
  if (r == 0) { ref_pixel(cx, cy, mode); return; }
  int x = r, y = 0, d = 1 - r;
  ref_pixel(cx + r, cy, mode); ref_pixel(cx - r, cy, mode);
  ref_pixel(cx, cy + r, mode); ref_pixel(cx, cy - r, mode);
  for (;;) {
    y++;
    if (d < 0) d += 2 * y + 1;
    else { x--; d += 2 * (y - x) + 1; }
    if (y > x) break;
    ref_quad(cx, cy, x, y, mode);
    if (x != y) ref_quad(cx, cy, y, x, mode);
  }
}

/* ---- harness ----------------------------------------------------------------- */
static int failures, checks;
static void check(int cond, const char *what)
{
  checks++;
  if (!cond) { failures++; printf("  FAIL %s\n", what); }
}

static int getpix(const unsigned char *pg, int x, int y)
{
  return pg[(191 - y) * 32 + (x >> 3)] >> (7 - (x & 7)) & 1;
}

static void setup_screen(unsigned char fill)
{
  static int seeded;
  if (!seeded) {                        /* other pages hold a pattern that must survive */
    for (long k = 0; k < (long)sizeof ram; k++) ram[k] = (unsigned char)((k >> 13) * 31 + k * 7);
    seeded = 1;
  }
  memset(scr, fill, 0x1800);
  memset(scr + 0x1800, 0, 0x2800);
  memcpy(ref, scr, sizeof ref);
}

static void set_gflags(int inverse, int gover)
{
  mem[XS_GFLAGS] = (inverse ? 1 : 0) | (gover ? 2 : 0);
}
static int draw_mode(void) { return (mem[XS_GFLAGS] & 3) ^ 1; }

/* call a routine with nargs Forth arguments already pushed */
static int expect_error;                /* 0, or the error code a call must return */
static struct result last;

static void run(const char *name, unsigned short entry, int nargs)
{
  unsigned char other[64][64];          /* sample of every page except the screen's two */
  char msg[160];
  for (int p = 0; p < 64; p++) memcpy(other[p], ram + p * 8192 + 0x0F00, 64);
  unsigned short sp0 = fsp();
  win[0] = USERPG0;
  win[1] = USERPG1;
  ay_r14 = COLOUR;
  rom_writes = bad_ports = 0;
  struct result R = z80_call(entry);
  last = R;
  snprintf(msg, sizeof msg, "%s: returns (no timeout)", name); check(!R.timeout, msg);
  if (expect_error) {
    snprintf(msg, sizeof msg, "%s: ERROR %d returned (carry %d, A = %d)", name, expect_error,
             R.carry, R.a);
    check(R.carry && R.a == expect_error, msg);
  } else {
    snprintf(msg, sizeof msg, "%s: carry clear", name);        check(!R.carry, msg);
  }
  snprintf(msg, sizeof msg, "%s: IX/IY preserved", name);      check(R.ix_ok && R.iy_ok, msg);
  snprintf(msg, sizeof msg, "%s: Z80 stack balanced", name);   check(R.sp_ok, msg);
  snprintf(msg, sizeof msg, "%s: Forth stack -%d", name, nargs);
  check(fsp() == sp0 - 2 * nargs, msg);
  snprintf(msg, sizeof msg, "%s: user's pages restored in both windows", name);
  check(win[0] == USERPG0 && win[1] == USERPG1, msg);
  snprintf(msg, sizeof msg, "%s: no ROM writes, only the page and AY ports", name);
  check(!rom_writes && !bad_ports, msg);
  int same = 1;
  for (int p = 0; p < 64; p++)
    if (p / 2 != WORKPG && memcmp(other[p], ram + p * 8192 + 0x0F00, 64)) same = 0;
  snprintf(msg, sizeof msg, "%s: other RAM pages untouched", name); check(same, msg);
}

static void compare(const char *name)
{
  char msg[200];
  int bad = -1;
  for (int k = 0; k < 16384; k++)
    if (scr[k] != ref[k]) { bad = k; break; }
  if (bad < 0) { check(1, name); return; }
  snprintf(msg, sizeof msg, "%s: work page differs from reference at +$%04X "
           "(got $%02X, want $%02X)", name, bad, scr[bad], ref[bad]);
  check(0, msg);
}

static void do_drawa(int dx, int dy, int a, int *px, int *py)
{
  char name[96];
  snprintf(name, sizeof name, "DRAW %d,%d,%d from %d,%d mode %d", dx, dy, a, *px, *py,
           draw_mode());
  mem[XS_PLOTX] = *px;
  mem[XS_PLOTY] = *py;
  fpush(dx); fpush(dy); fpush(a);
  run(name, HDRAW, 3);
  ref_drawa(px, py, dx, dy, a, draw_mode());
  compare(name);
  char msg[160];
  snprintf(msg, sizeof msg, "%s: position -> %d,%d", name, *px, *py);
  check(mem[XS_PLOTX] == *px && mem[XS_PLOTY] == *py, msg);
}

static void do_circle(int cx, int cy, int r)
{
  char name[96];
  snprintf(name, sizeof name, "CIRCLE %d,%d r %d mode %d", cx, cy, r, draw_mode());
  mem[XS_PLOTX] = 17;                   /* CIRCLE must not move the position */
  mem[XS_PLOTY] = 23;
  fpush(cx); fpush(cy); fpush(r);
  run(name, HCIRCLE, 3);
  ref_circle(cx, cy, r, draw_mode());
  compare(name);
  char msg[160];
  snprintf(msg, sizeof msg, "%s: position unchanged", name);
  check(mem[XS_PLOTX] == 17 && mem[XS_PLOTY] == 23, msg);
}

static void do_draw(int dx, int dy, int *px, int *py) { do_drawa(dx, dy, 0, px, py); }

static long count_pixels(const unsigned char *pg)
{
  long n = 0;
  for (int k = 0; k < 0x1800; k++) n += __builtin_popcount(pg[k]);
  return n;
}

/* geometry, independent of the reference: every pixel within 1/2 of the ideal
 * line on the minor axis, end point set, start point clear, one pixel per
 * major-axis step */
static void geo_line(int x0, int y0, int dx, int dy)
{
  char msg[160];
  int maj = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
  int worst = 0;
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++)
      if (getpix(scr, x, y)) {
        double dev = abs(dx) >= abs(dy)
          ? fabs((y - y0) - (double)dy * (x - x0) / dx)
          : fabs((x - x0) - (double)dx * (y - y0) / dy);
        if (dev > 0.5 + 1e-9) worst = 1;
      }
  snprintf(msg, sizeof msg, "geometry DRAW %d,%d from %d,%d: pixels within 1/2 of the line, "
           "%d pixels, end set, start clear", dx, dy, x0, y0, maj);
  check(!worst && count_pixels(scr) == maj
        && (maj == 0 || (getpix(scr, x0 + dx, y0 + dy)
                         && !getpix(scr, x0, y0))), msg);
}

/* geometry: every pixel within 1 of the radius, 8-fold symmetric, 4 axis points */
static void geo_circle(int cx, int cy, int r)
{
  char msg[160];
  int ok = 1;
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++)
      if (getpix(scr, x, y)) {
        int a = x - cx, b = y - cy;
        if (fabs(sqrt((double)a * a + (double)b * b) - r) >= 1.0) ok = 0;
        int sym[8][2] = {{a,b},{-a,b},{a,-b},{-a,-b},{b,a},{-b,a},{b,-a},{-b,-a}};
        for (int s = 0; s < 8; s++) {
          int sx = cx + sym[s][0], sy = cy + sym[s][1];
          if (sx >= 0 && sx < W && sy >= 0 && sy < H && !getpix(scr, sx, sy)) ok = 0;
        }
      }
  ok = ok && getpix(scr, cx + r, cy) && getpix(scr, cx - r, cy)
          && getpix(scr, cx, cy + r) && getpix(scr, cx, cy - r);
  snprintf(msg, sizeof msg, "geometry CIRCLE %d,%d r %d: |distance - r| < 1, 8-fold symmetric, "
           "axis points set", cx, cy, r);
  check(ok, msg);
}

/* ---- DRAW arcs --------------------------------------------------------------- */

/* geometry, in floating point and independent of the method: every pixel lies
 * near the true arc (chord sagitta + rounding), the end point is set, and the
 * pixel at the middle of the arc is set (the arc bulges the right way) */
static void geo_arc(int x0, int y0, int dx, int dy, int a)
{
  char msg[200];
  double h = a * M_PI / 360.0;          /* a/2 in radians */
  double k = cos(h) / (2 * sin(h));
  double cx = x0 + dx / 2.0 - dy * k, cy = y0 + dy / 2.0 + dx * k;
  double R = hypot(x0 - cx, y0 - cy);
  double tol = 1.0 + R * (1 - cos(2.5 * M_PI / 180)) + 0.75;
  int ok = 1, far = 0;
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++)
      if (getpix(scr, x, y) && fabs(hypot(x - cx, y - cy) - R) > tol) { ok = 0; far++; }
  double t = a * M_PI / 360.0;          /* rotate S - C by a/2 */
  double mx = cx + (x0 - cx) * cos(t) - (y0 - cy) * sin(t);
  double my = cy + (x0 - cx) * sin(t) + (y0 - cy) * cos(t);
  int mid = 0;
  for (int yy = (int)floor(my) - 1; yy <= (int)ceil(my) + 1; yy++)
    for (int xx = (int)floor(mx) - 1; xx <= (int)ceil(mx) + 1; xx++)
      if (xx >= 0 && xx < W && yy >= 0 && yy < H && getpix(scr, xx, yy)
          && hypot(xx - mx, yy - my) < 1.6) mid = 1;
  snprintf(msg, sizeof msg, "geometry DRAW %d,%d,%d from %d,%d: on the arc (R %.1f, tol %.2f, "
           "%d off), end set, middle (%.1f,%.1f) set", dx, dy, a, x0, y0, R, tol, far, mx, my);
  check(ok && mid && getpix(scr, x0 + dx, y0 + dy), msg);
}

static void test_arcs(void)
{
  int f0, x, y;
  printf("DRAW with an angle: arcs in every direction, both senses\n");
  f0 = failures;
  set_gflags(0, 0);
  static const int arcs[][3] = {
    {100,0,180}, {100,0,-180}, {0,100,90}, {0,-100,90}, {-100,0,45}, {80,60,120},
    {-80,60,-120}, {60,-80,270}, {-60,-80,-270}, {50,0,359}, {50,0,-359}, {120,40,30},
    {120,40,1}, {120,40,-1}, {10,5,200}, {1,1,180}, {3,0,90}, {150,0,10}};
  for (size_t k = 0; k < sizeof arcs / sizeof arcs[0]; k++) {
    setup_screen(0);
    int a = arcs[k][2], dx = arcs[k][0], dy = arcs[k][1];
    int sx = 128 - dx / 2, sy = 96 - dy / 2;
    x = sx; y = sy;
    do_drawa(dx, dy, a, &x, &y);
    /* geometry only where the whole circle is small enough to be checked */
    double h = a * M_PI / 360.0, R = hypot(dx, dy) / (2 * fabs(sin(h)));
    if (R < 400 && hypot(dx, dy) > 4) geo_arc(sx, sy, dx, dy, a);
  }
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("DRAW with an angle: reduction, degenerate and huge cases\n");
  f0 = failures;
  static const int odd[][3] = {
    {100,0,360}, {100,0,720}, {100,0,540}, {100,0,-540}, {0,0,90}, {0,0,-300},
    {200,150,2}, {30000,0,1}, {-300,200,170}, {255,191,-90}, {500,-400,100}};
  for (size_t k = 0; k < sizeof odd / sizeof odd[0]; k++) {
    setup_screen(0);
    x = 20; y = 30;
    do_drawa(odd[k][0], odd[k][1], odd[k][2], &x, &y);
  }
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("DRAW with an angle: 200 chained random arcs, all modes\n");
  f0 = failures;
  setup_screen(0);
  x = 128; y = 96;
  for (int k = 0; k < 200; k++) {
    set_gflags(rand() % 4 == 0, rand() % 3 == 0);
    do_drawa(rand() % 401 - 200, rand() % 301 - 150, rand() % 1441 - 720, &x, &y);
  }
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("DRAW with an angle: a FLIP arc drawn twice disappears\n");
  f0 = failures;
  setup_screen(0x33);
  set_gflags(0, 1);
  x = 60; y = 50; do_drawa(130, 90, 150, &x, &y);
  x = 60; y = 50; do_drawa(130, 90, 150, &x, &y);
  {
    int restored = 1;
    for (int k = 0; k < 0x1800; k++) if (scr[k] != 0x33) restored = 0;
    check(restored, "FLIP arc drawn twice restores the bitmap");
  }
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- PAINT ---------------------------------------------------------------- */

static void put_both(int x, int y, int v)  /* set up a pixel on screen and in ref */
{
  int ofs = (191 - y) * 32 + (x >> 3);
  unsigned char m = 0x80 >> (x & 7);
  if (v) { scr[ofs] |= m; ref[ofs] |= m; }
  else   { scr[ofs] &= ~m; ref[ofs] &= ~m; }
}

static int refpix(int x, int y) { return getpix(ref, x, y); }

/* reference: breadth-first 4-connected fill, independent of the scanline method */
static long ref_paint(int x, int y, int mode)
{
  static int qx[W * H], qy[W * H];
  if (mode == 2 || x < 0 || x >= W || y < 0 || y >= H) return 0;
  int tgt = mode == 0;                  /* INVERSE fills INK, otherwise PAPER */
  if (refpix(x, y) != tgt) return 0;
  long head = 0, tail = 0, n = 0;
  qx[tail] = x; qy[tail++] = y;
  ref_pixel(x, y, 3);                   /* flip + colour */
  while (head < tail) {
    int cx = qx[head], cy = qy[head++];
    n++;
    static const int d[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
    for (int k = 0; k < 4; k++) {
      int nx = cx + d[k][0], ny = cy + d[k][1];
      if (nx >= 0 && nx < W && ny >= 0 && ny < H && refpix(nx, ny) == tgt) {
        ref_pixel(nx, ny, 3);
        qx[tail] = nx; qy[tail++] = ny;
      }
    }
  }
  return n;
}

static void do_paint(int x, int y, const char *what)
{
  char name[128];
  snprintf(name, sizeof name, "PAINT %d,%d mode %d (%s)", x, y, draw_mode(), what);
  mem[XS_PLOTX] = 17;
  mem[XS_PLOTY] = 23;
  fpush(x); fpush(y);
  unsigned long t0 = tstates;
  run(name, HPAINT, 2);
  unsigned long t = tstates - t0;
  long n = ref_paint(x, y, draw_mode());
  compare(name);
  char msg[160];
  snprintf(msg, sizeof msg, "%s: position unchanged", name);
  check(mem[XS_PLOTX] == 17 && mem[XS_PLOTY] == 23, msg);
  if (n > 20000)
    printf("  info %s: %ld pixels, %lu T-states (%.2f s at 3.25 MHz)\n",
           name, n, t, t / 3.25e6);
}

static void test_paint(void)
{
  int f0;
  printf("PAINT: whole screen, shapes, both kinds of seed\n");
  f0 = failures;
  set_gflags(0, 0);
  setup_screen(0);
  do_paint(128, 96, "empty screen");
  setup_screen(0);
  do_paint(0, 0, "empty screen, corner seed");
  set_gflags(1, 0);
  setup_screen(0xFF);
  do_paint(255, 191, "INVERSE, full screen");
  set_gflags(0, 0);

  /* nested rectangles and a ring: fill one band only */
  setup_screen(0);
  for (int k = 0; k < 4; k++) {
    int x0 = 20 + 25 * k, y0 = 10 + 20 * k, x1 = 235 - 25 * k, y1 = 181 - 20 * k;
    for (int x = x0; x <= x1; x++) { put_both(x, y0, 1); put_both(x, y1, 1); }
    for (int y = y0; y <= y1; y++) { put_both(x0, y, 1); put_both(x1, y, 1); }
  }
  do_paint(60, 40, "band between rectangles 1 and 2");
  do_paint(128, 96, "innermost rectangle");
  do_paint(5, 5, "outside");

  /* comb with teeth from both sides: many spans and seeds */
  setup_screen(0);
  for (int x = 4; x < 252; x += 4)
    for (int y = 0; y < 180; y++) put_both(x, x % 8 ? y : 191 - y, 1);
  do_paint(2, 100, "serpentine comb");

  /* circle outline drawn by the reference circle, then filled inside */
  setup_screen(0);
  ref_circle(128, 96, 70, 1);
  memcpy(scr, ref, sizeof ref);
  do_paint(128, 96, "inside a CIRCLE");

  /* seeds that must do nothing */
  setup_screen(0x55);
  do_paint(1, 50, "seed on INK pixel, plot mode");
  do_paint(-1, 50, "seed off screen (x < 0)");
  do_paint(50, 192, "seed off screen (y = 192)");
  set_gflags(1, 1);
  do_paint(0, 50, "INVERSE + FLIP");
  set_gflags(0, 1);
  setup_screen(0);
  do_paint(9, 9, "FLIP fills like plot");
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("PAINT: 120 random noise screens, random seeds and modes\n");
  f0 = failures;
  for (int k = 0; k < 120; k++) {
    int density = 20 + rand() % 45;     /* percent INK */
    setup_screen(0);
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) put_both(x, y, rand() % 100 < density);
    set_gflags(rand() % 3 == 0, rand() % 4 == 0);
    char what[32];
    snprintf(what, sizeof what, "noise %d%%", density);
    do_paint(rand() % W, rand() % H, what);
  }
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("PAINT: out of memory gives ERROR 1, keeps a partial fill\n");
  f0 = failures;
  setup_screen(0);
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++) put_both(x, y, rand() % 100 < 25);
  put_both(128, 96, 0);
  unsigned char before[16384];
  memcpy(before, scr, sizeof before);
  mem[SV_SPARE] = (0x8000 - 0x0100) & 255;   /* only 256 bytes between the stacks */
  mem[SV_SPARE + 1] = (0x8000 - 0x0100) >> 8;
  fpush(128); fpush(96);
  expect_error = 1;
  run("PAINT on 25% noise, stacks 256 bytes apart", HPAINT, 2);
  expect_error = 0;
  ref_paint(128, 96, 1);                 /* the full fill: the partial one is inside it */
  {
    int inside = 1, changed = 0;
    for (int k = 0; k < 0x1800; k++) {
      unsigned char diff = scr[k] ^ before[k];
      changed |= diff != 0;
      if (diff & ~(ref[k] ^ before[k])) inside = 0;
    }
    check(changed && inside, "partial fill is part of the full fill");
  }
  mem[SV_SPARE] = FSTACK & 255;
  mem[SV_SPARE + 1] = FSTACK >> 8;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- boot page and TURBO ----------------------------------------------------- */

static int m16(int a) { return mem[a] | mem[a + 1] << 8; }
static void s16(int a, int v) { mem[a] = v & 255; mem[a + 1] = (v >> 8) & 255; }

#define SV_RAMTOP 0x3C18
#define SV_FLINK  0x3C47
#define QUIT_ADDR 0x009B
#define ERR_ADDR  0x0020                /* RST $20: the stock error entry */

static void messy_state(void)           /* everything a 1 TURBO session may change */
{
  for (int c = 0; c < 6; c++) creg[c] = 5 + c;
  creg[4] = 1;                          /* hi-res */
  creg[7] = 1;                          /* ATTR */
  win[0] = 9; win[1] = 33;
  for (int k = 0; k < 14; k++) ay[k] = 0x11 * k;
  ay[7] = 0xF0; ay[14] = 0x5A; ay[15] = 0x30;
  s16(SV_RAMTOP, 0xC000);
  s16(SV_FLINK, XDICT_LAST_NLF);
}

/* run TURBO's code with n on the Forth stack; returns where it stopped */
static struct result turbo(int n)
{
  rompage = 1;                          /* the interpreter runs in page 1 */
  fpush(n);
  stop_at[0] = QUIT_ADDR; stop_at[1] = ERR_ADDR;
  struct result R = z80_call(m16(TURBO_NLF + 1));
  stop_at[0] = stop_at[1] = 0;
  return R;
}

static int stock_look(void)
{
  return creg[0] == 0 && creg[1] == 0 && creg[2] == 0 && creg[3] == 0 && creg[4] == 0
      && (creg[7] & 1) == 0 && win[0] == 0 && win[1] == 1
      && ay[7] == 0xFF && ay[14] == 0x0F && ay[15] == 0x00;
}

/* the names on the extension chain from $3C47 down to the stock $1FFF, space-separated;
   returns how many */
#define ZERO_TURBO_CHAIN "SDERR DELETE CD DIR EJECT TAPE SDTAPE TURBO"
static int chain_names(char *out, int size)
{
  int n = 0, len = 0, p = m16(SV_FLINK);
  out[0] = 0;
  while (p != 0x1FFF && n < 200) {
    int ln = mem[p] & 0x3F;
    for (int k = 0; k < ln && len < size - 2; k++) out[len++] = (char)(mem[p - 2 - ln + k] & 0x7F);
    if (len < size - 1) out[len++] = ' ';
    n++;
    p = m16(p - 2);
  }
  if (len) len--;
  out[len] = 0;
  return n;
}

static void test_turbo(void)
{
  int f0 = failures;
  char msg[160];
  printf("Boot page: installs the extension, 0 TURBO state, returns to QUIT\n");
  allow_ctrl = 1;
  memset(mem + 0x2000, 0, 0xA000);
  s16(SV_RAMTOP, 0x0000);               /* what the stock RAM test finds with 64K */
  s16(SV_FLINK, 0x1FFF);
  s16(SV_SPARE, FSTACK);
  messy_state();
  s16(SV_RAMTOP, 0x0000);
  s16(SV_FLINK, 0x1FFF);
  rompage = 2;                          /* the hook at $008E has just switched */
  stop_at[0] = QUIT_ADDR;
  struct result R = z80_call(BOOT_SETUP);
  stop_at[0] = 0;
  check(R.pc == QUIT_ADDR && rompage == 1, "boot: ends at QUIT ($009B) in ROM page 1");
  {                                     /* the image, with 0 TURBO's two links */
    static unsigned char want[0x0C00];
    memcpy(want, rom[2] + XDICT_IMAGE, XDICT_LEN);
    want[SDTAPE_NLF - 2 - 0x3000] = TURBO_NLF & 255; want[SDTAPE_NLF - 1 - 0x3000] = TURBO_NLF >> 8;
    want[SDERR_NLF - 2 - 0x3000] = DELETE_NLF & 255; want[SDERR_NLF - 1 - 0x3000] = DELETE_NLF >> 8;
    check(!memcmp(mem + 0x3000, want, XDICT_LEN), "boot: extension copied to $3000 (SDTAPE and SDERR relinked)");
  }
  check(m16(SV_FLINK) == XDICT_LAST_NLF, "boot: FORTH link at SDERR, the last word");
  chain_names(msg, sizeof msg);
  check(!strcmp(msg, ZERO_TURBO_CHAIN), "boot (0 TURBO): the chain is TURBO and the SD words, then $1FFF");
  if (strcmp(msg, ZERO_TURBO_CHAIN)) printf("    chain: %s\n", msg);
  check(m16(SV_RAMTOP) == 0 && m16(XS_RAMTOP0) == 0, "boot: RAMTOP left as found, and remembered");
  check(win[0] == 0 && win[1] == 1 && creg[7] == 0 && ay[7] == 0xFF && ay[14] == 0x0F
        && ay[15] == 0, "boot: windows 0/1, XCFG 0, sound off, white on black");
  check(!rom_writes && !bad_ports, "boot: no ROM writes, no unknown ports");

  printf("TURBO: 1, 0, -1 and -2\n");
  s16(SV_SPARE, FSTACK);
  R = turbo(1);
  check(R.pc == QUIT_ADDR && rompage == 1, "1 TURBO: ends at QUIT in page 1");
  check(m16(SV_FLINK) == XDICT_LAST_NLF, "1 TURBO: FORTH link at the last word");
  {
    static char ch[1024];
    int nw = chain_names(ch, sizeof ch);
    char m2[200];
    snprintf(m2, sizeof m2, "1 TURBO: all %d extension words linked, from SDERR FONTLOAD to TURBO", nw);
    check(nw == 86 && !strncmp(ch, "SDERR FONTLOAD SCRLOAD ", 23) && strstr(ch, " PGSAVE DELETE CD DIR EJECT TAPE SDTAPE OPAQUE ")
          && !strcmp(ch + strlen(ch) - 11, "COUNT TURBO"), m2);
  }
  check(m16(SV_RAMTOP) == 0xC000, "1 TURBO: RAMTOP = $C000 (QUIT moves the stack)");
  check(m16(SV_SPARE) == FSTACK, "1 TURBO: argument consumed, data stack kept");

  s16(SV_FLINK, TURBO_NLF); s16(SV_RAMTOP, 0);
  s16(SV_SPARE, 0xBEFF);
  R = turbo(7);
  check(R.pc == QUIT_ADDR && m16(SV_RAMTOP) == 0xC000,
        "7 TURBO = 1 TURBO; data stack at $BEFF still fits");
  s16(SV_FLINK, TURBO_NLF); s16(SV_RAMTOP, 0);
  s16(SV_SPARE, 0xBF00);
  mem[XD_ERRCODE] = 0;
  R = turbo(1);
  snprintf(msg, sizeof msg, "1 TURBO with the data stack at $BF00: ERROR 1 (stopped at $%04X, "
           "code %d)", R.pc, mem[XD_ERRCODE]);
  check(R.pc == ERR_ADDR && mem[XD_ERRCODE] == 1, msg);
  check(m16(SV_FLINK) == TURBO_NLF && m16(SV_RAMTOP) == 0, "1 TURBO refused: nothing changed");
  s16(SV_SPARE, FSTACK);

  messy_state();
  R = turbo(0);
  check(R.pc == QUIT_ADDR && rompage == 1, "0 TURBO: ends at QUIT in page 1");
  chain_names(msg, sizeof msg);
  check(m16(SV_FLINK) == XDICT_LAST_NLF && !strcmp(msg, ZERO_TURBO_CHAIN), "0 TURBO: TURBO and the SD words linked");
  check(m16(SV_RAMTOP) == 0, "0 TURBO: RAMTOP back to the value found at reset");
  check(stock_look(), "0 TURBO: text, page/font 0, ATTR off, windows 0/1, sound off, white on black");

  /* -1: page 1 and MIRROR + KEEP (through HSTOCK1); -2 and -5: page 0 and MIRROR (HSTOCK) */
  static const struct { int n, stop, page, xcfg; const char *name; } neg[] = {
    { -1, HSTOCK1, 1, 10, "-1 TURBO" }, { -2, HSTOCK, 0, 2, "-2 TURBO" }, { -5, HSTOCK, 0, 2, "-5 TURBO" } };
  for (int t = 0; t < 3; t++) {
    int seen_page2 = 0;
    char m2[200];
    messy_state();
    creg[7] = 1;                        /* ATTR, as messy_state */
    mem[XS_SDTAPE] = 1; mem[XS_SDERR] = 3;
    stop_at[2] = neg[t].stop;           /* pass through: just note we got there */
    rompage = 1;
    fpush(neg[t].n);
    stop_at[0] = QUIT_ADDR; stop_at[1] = ERR_ADDR;
    R = z80_call(m16(TURBO_NLF + 1));
    if (R.pc == neg[t].stop && rompage == 2) {
      seen_page2 = 1;
      stop_at[2] = 0;
      R = z80_call(neg[t].stop);        /* continue from there */
    }
    stop_at[0] = stop_at[1] = stop_at[2] = 0;
    snprintf(m2, sizeof m2, "%s: reaches %s in ROM page 2 through the dispatcher", neg[t].name, neg[t].n == -1 ? "HSTOCK1" : "HSTOCK");
    check(seen_page2, m2);
    snprintf(m2, sizeof m2, "%s: ends at QUIT in ROM page %d (%s)", neg[t].name, neg[t].page,
             neg[t].page ? "stock + tape hooks" : "byte-identical stock");
    check(R.pc == QUIT_ADDR && rompage == neg[t].page, m2);
    snprintf(m2, sizeof m2, "%s: XCFG = %s, ATTR off (XCFG %d)", neg[t].name,
             neg[t].xcfg == 10 ? "MIRROR + KEEP" : "MIRROR", creg[7]);
    check(creg[7] == neg[t].xcfg, m2);
    snprintf(m2, sizeof m2, "%s: FORTH link back to the stock $1FFF, RAMTOP as found at reset", neg[t].name);
    check(m16(SV_FLINK) == 0x1FFF && m16(SV_RAMTOP) == 0, m2);
    /* through the mirror: $3047, $3447 and $3847 are $3C47; $3B79 is the SD state (KEEP) or $3F79 */
    snprintf(m2, sizeof m2, "%s: $3047, $3447 and $3847 read $3C47 through the mirror", neg[t].name);
    check(rd(0x3047) == mem[0x3C47] && rd(0x3447) == mem[0x3C47] && rd(0x3847) == mem[0x3C47]
          && rd(0x3448) == mem[0x3C48], m2);
    snprintf(m2, sizeof m2, "%s: $3B79 is %s", neg[t].name,
             neg[t].n == -1 ? "still SDTAPE (on), $3B7A SDERR (3)" : "the mirror of $3F79");
    check(neg[t].n == -1 ? rd(XS_SDTAPE) == 1 && rd(XS_SDERR) == 3 : rd(XS_SDTAPE) == mem[0x3F79], m2);
    creg[7] = 0;
    mem[XS_SDTAPE] = 0; mem[XS_SDERR] = 0;
    snprintf(m2, sizeof m2, "%s: stock look as for 0 TURBO", neg[t].name);
    check(stock_look(), m2);
    s16(SV_FLINK, XDICT_LAST_NLF);
  }
  s16(SV_SPARE, FSTACK);
  R = turbo(1);                         /* back to the full chain, for the tests that follow */
  {
    int nw = chain_names(msg, sizeof msg);
    check(R.pc == QUIT_ADDR && nw == 86, "1 TURBO after 0 TURBO: the full chain again (SDTAPE, SDERR relinked)");
  }
  s16(SV_RAMTOP, 0);
  check(!rom_writes && !bad_ports, "TURBO: no ROM writes, no unknown ports");
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- RAM-resident words (run after the boot test put the extension at $3000) -- */

static int word_nlf(const char *name)   /* walk the extension chain for a name */
{
  int nlf = XDICT_LAST_NLF;
  while (nlf >= 0x3000 && nlf < 0x3B00) {
    int ln = mem[nlf] & 0x3F, ok = ln == (int)strlen(name);
    for (int k = 0; ok && k < ln; k++) ok = (mem[nlf - 2 - ln + k] & 0x7F) == name[k];
    if (ok) return nlf;
    nlf = m16(nlf - 2);
  }
  return 0;
}

#define NEXT_ADDR 0x04C8                /* IY: a code word that returns does JP (IY) */
#define CLS_CODE  0x0A1F                /* stock CLS machine code */

static struct result run_word(const char *name, int nargs, const int *args)
{
  int nlf = word_nlf(name);
  struct result R = {0};
  char msg[64];
  snprintf(msg, sizeof msg, "word %s found in the extension", name);
  check(nlf != 0, msg);
  if (!nlf) return R;
  for (int k = 0; k < nargs; k++) fpush(args[k]);
  rompage = 1;
  stop_at[0] = NEXT_ADDR; stop_at[1] = ERR_ADDR; stop_at[2] = CLS_CODE; stop_at[3] = QUIT_ADDR;
  R = z80_call(m16(nlf + 1));
  stop_at[0] = stop_at[1] = stop_at[2] = stop_at[3] = 0;
  return R;
}

static void test_words(void)
{
  int f0 = failures, a[2];
  struct result R;
  printf("Overlay words: OPAQUE, SCREEN/WORK/VIEW, CLS in both modes, ATTR keeps OPAQUE\n");
  allow_ctrl = 1;
  memset(creg, 0, sizeof creg);
  mem[XS_XCFG] = 0;
  s16(SV_SPARE, FSTACK);
  rom_writes = bad_ports = 0;

  a[0] = 1; R = run_word("OPAQUE", 1, a);
  check(R.pc == NEXT_ADDR && creg[7] == 4 && mem[XS_XCFG] == 4, "1 OPAQUE: XCFG = OPAQUE, copy kept");
  /* text-mode ATTR maps colour RAM for one read, then restores XCFG from the copy */
  creg[4] = 0;
  a[0] = 3; a[1] = 2; R = run_word("ATTR", 2, a);
  check(R.pc == NEXT_ADDR && creg[7] == 4, "text ATTR: XCFG restored with OPAQUE still on");
  s16(SV_SPARE, FSTACK);
  a[0] = 0; R = run_word("OPAQUE", 1, a);
  check(R.pc == NEXT_ADDR && creg[7] == 0 && mem[XS_XCFG] == 0, "0 OPAQUE: transparent again");

  win[0] = 0; win[1] = 1;
  a[0] = 37; R = run_word("PG0", 1, a);
  check(R.pc == NEXT_ADDR && win[0] == 37 && win[1] == 1, "37 PG0: page 37 in window 0, window 1 unchanged");
  a[0] = 62; R = run_word("PG1", 1, a);
  check(R.pc == NEXT_ADDR && win[0] == 37 && win[1] == 62, "62 PG1: page 62 in window 1, window 0 unchanged");
  a[0] = 64 + 5; R = run_word("PG1", 1, a);
  check(win[1] == 5 && win[0] == 37, "69 PG1: page number taken modulo 64");
  check(m16(SV_SPARE) == FSTACK, "PG0/PG1: arguments consumed");

  a[0] = 5; R = run_word("SCREEN", 1, a);
  check(R.pc == NEXT_ADDR && creg[0] == 5 && creg[1] == 5 && mem[XS_WORKPG] == 5,
        "5 SCREEN: text page 5 written and shown, hi-res screen 5 drawn");
  a[0] = 3; R = run_word("WORK", 1, a);
  check(creg[0] == 3 && creg[1] == 5 && mem[XS_WORKPG] == 3, "3 WORK: writes page 3, still shows 5");
  a[0] = 7; R = run_word("VIEW", 1, a);
  check(creg[0] == 3 && creg[1] == 7 && mem[XS_WORKPG] == 3, "7 VIEW: shows 7, still writes 3");
  check(m16(SV_SPARE) == FSTACK, "screen words: arguments consumed");

  /* CLS in hi-res: the bitmap of the work screen, then the stock CLS for the text */
  memset(ram + 3 * 16384, 0x5A, 16384);
  ay[14] = 0x1E;
  creg[4] = 1;
  R = run_word("CLS", 0, a);
  {
    int clear = 1;
    for (int k = 0; k < 0x1800; k++)
      if (ram[3 * 16384 + k] != 0 || ram[3 * 16384 + 0x1800 + k] != 0x1E) clear = 0;
    check(R.pc == CLS_CODE && rompage == 1, "hi-res CLS: continues into the stock CLS (text overlay)");
    check(clear, "hi-res CLS: work screen 3 cleared to the current PAPER:INK first");
  }
  memset(ram + 3 * 16384, 0x5A, 16384);
  creg[4] = 0;
  R = run_word("CLS", 0, a);
  check(R.pc == CLS_CODE && ram[3 * 16384] == 0x5A, "text CLS: straight to the stock CLS, bitmap untouched");
  check(!rom_writes && !bad_ports, "overlay words: no ROM writes, no unknown ports");
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- tape hooks: the hooked page 1 (+ page 3) against the stock ROM ----------- */

#define TAPE_WRITE 0x1820
#define TAPE_READ  0x18A7

static void set_regs(int af, int bc, int de, int hl)
{
  memset(&zin, 0, sizeof zin);
  zin.AF = af; zin.BC = bc; zin.DE = de; zin.HL = hl;
  zin.AF1 = 0x1111; zin.BC1 = 0x2222; zin.DE1 = 0x3333; zin.HL1 = 0x4444;
  zin.IX = IX_SENT; zin.IY = IY_SENT; zin.IFF1 = 1;
  zin_valid = 1;
}

/* run from entry in ROM page `page` until `stop`; returns the result, stack copied */
static struct result run_to(int page, int entry, int stop, unsigned char *stack)
{
  rompage = page;
  stop_at[0] = stop;
  struct result R = z80_call(entry);
  stop_at[0] = 0;
  memcpy(stack, mem + 0x7F00, 0x100);
  return R;
}

static int regs_equal(struct result *A, struct result *B, int ignore_a1)
{
  struct zregs a = A->r, b = B->r;
  if (ignore_a1) { a.AF1 &= 0x00FF; b.AF1 &= 0x00FF; }
  return a.AF == b.AF && a.BC == b.BC && a.DE == b.DE && a.HL == b.HL && a.AF1 == b.AF1
      && a.BC1 == b.BC1 && a.DE1 == b.DE1 && a.HL1 == b.HL1 && a.IX == b.IX && a.IY == b.IY
      && a.SP == b.SP && a.IFF1 == b.IFF1;
}

/* write a block from `src` and record the MIC edges; returns the carry */
static int tape_write(int page, int flag, int src, int len)
{
  rec_n = 0;
  set_regs(0x5A00, flag, len, src);
  rompage = page;
  struct result R = z80_call(TAPE_WRITE);
  check(R.pc == STOP_ADDR && !R.timeout, "tape write returns to its caller");
  return R.carry;
}

/* play the recording made last into a block read; returns the carry */
static int tape_read(int page, int flag, int dst, int len, int load)
{
  play_n = rec_n;
  for (int k = 0; k < rec_n; k++) { play_t[k] = rec_t[k] - rec_t[0] + 2000; play_v[k] = rec_v[k]; }
  set_regs(0x5A00 | (load ? 1 : 0), flag, len, dst);
  play_start = tstates;
  rompage = page;
  struct result R = z80_call(TAPE_READ);
  check(R.pc == STOP_ADDR && !R.timeout, "tape read returns to its caller");
  play_n = 0;
  return R.carry;
}

static void test_tape_hooks(void)
{
  int f0 = failures;
  char msg[160];
  unsigned char st1[256], st2[256];
  struct result A, B;
  printf("Tape hooks, cassette path: hooked ROM = stock ROM\n");
  allow_ctrl = 1;
  tape_on = 1;
  rom_writes = bad_ports = 0;
  mem[XS_SDTAPE] = 0;

  /* 1. registers, flags, stack and interrupt state where the paths rejoin */
  for (int flag = 0; flag <= 0xFF; flag += 0xFF) {
    set_regs(0x5AD7, 0x9900 | flag, 25, 0x4800);
    A = run_to(0, TAPE_WRITE, 0x1837, st1);
    set_regs(0x5AD7, 0x9900 | flag, 25, 0x4800);
    B = run_to(1, TAPE_WRITE, 0x1837, st2);
    snprintf(msg, sizeof msg, "block write (flag $%02X) at $1837: all registers, flags, stack and DI "
             "equal to stock", flag);
    check(A.pc == 0x1837 && B.pc == 0x1837 && rompage == 1 && regs_equal(&A, &B, 0)
          && !memcmp(st1, st2, 256), msg);
  }
  for (int load = 0; load <= 1; load++) {
    set_regs(0x5AC6 | load, 0x0000, 25, 0x5000);
    A = run_to(0, TAPE_READ, 0x18B3, st1);
    set_regs(0x5AC6 | load, 0x0000, 25, 0x5000);
    B = run_to(1, TAPE_READ, 0x18B3, st2);
    snprintf(msg, sizeof msg, "block read (%s) at $18B3: equal to stock except A' (the hook's "
             "A, never used); the carry argument kept", load ? "load" : "verify");
    check(A.pc == 0x18B3 && B.pc == 0x18B3 && rompage == 1 && regs_equal(&A, &B, 1)
          && (B.r.AF1 & 1) == load && !memcmp(st1, st2, 256), msg);
  }

  /* 2. the tape signal written: edge for edge, the same intervals as stock */
  static unsigned long t1[TAPE_MAX];
  static unsigned char v1[TAPE_MAX];
  for (int k = 0; k < 25; k++) mem[0x4800 + k] = (unsigned char)(k * 37 + 11);
  for (int flag = 0; flag <= 0xFF; flag += 0xFF) {
    int len = flag ? 300 : 25;
    for (int k = 25; k < len; k++) mem[0x4800 + k] = (unsigned char)(k * 13 + 7);
    tape_write(0, flag, 0x4800, len);
    int n1 = rec_n;
    memcpy(t1, rec_t, sizeof rec_t); memcpy(v1, rec_v, sizeof rec_v);
    tape_write(1, flag, 0x4800, len);
    int same = n1 == rec_n && n1 > 1000;
    for (int k = 1; same && k < n1; k++)
      same = (t1[k] - t1[k - 1]) == (rec_t[k] - rec_t[k - 1]) && v1[k] == rec_v[k];
    snprintf(msg, sizeof msg, "%s block of %d bytes: %d MIC edges, identical levels and timing",
             flag ? "data" : "header", len, n1);
    check(same, msg);
  }

  /* 3. loopback: read back what the hooked write recorded, load and verify */
  for (int k = 0; k < 300; k++) mem[0x4800 + k] = (unsigned char)(k * 29 + 3);
  tape_write(1, 0xFF, 0x4800, 300);
  memset(mem + 0x5000, 0, 300);
  int ok = tape_read(1, 0xFF, 0x5000, 300, 1);
  check(ok && !memcmp(mem + 0x4800, mem + 0x5000, 300) && rompage == 1,
        "hooked read loads the block written (carry set, data equal)");
  check(tape_read(1, 0xFF, 0x5000, 300, 0), "hooked VERIFY of the same data: carry set");
  mem[0x5000 + 123] ^= 1;
  check(!tape_read(1, 0xFF, 0x5000, 300, 0), "hooked VERIFY against changed memory: carry clear");
  mem[0x5000 + 123] ^= 1;
  check(!tape_read(1, 0x00, 0x5000, 300, 1), "hooked read asking for a header gets a data block: carry clear");
  memset(mem + 0x5000, 0, 300);
  check(tape_read(0, 0xFF, 0x5000, 300, 1) && !memcmp(mem + 0x4800, mem + 0x5000, 300),
        "stock read loads the hooked write's block too");
  tape_write(0, 0xFF, 0x4800, 300);
  memset(mem + 0x5000, 0, 300);
  check(tape_read(1, 0xFF, 0x5000, 300, 1) && !memcmp(mem + 0x4800, mem + 0x5000, 300),
        "hooked read loads the stock write's block");
  check(!rom_writes, "tape hooks: no ROM writes");

  zin_valid = 0;
  tape_on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- tape hooks, SD path: the virtual tape player ------------------------- */

#define LOAD_SEARCH 0x1A81
#define ERROR10_AT  0x1AB6
#define BREAK_AT    0x04F0

static struct result tcall(int entry, int af, int flag, int len, int addr, int ret)
{
  set_regs(af, flag, len, addr);
  rompage = 1;
  call_ret = ret;
  stop_at[0] = ERROR10_AT; stop_at[1] = BREAK_AT;
  struct result R = z80_call(entry);
  stop_at[0] = stop_at[1] = 0;
  call_ret = 0;
  return R;
}

static void put_block(int flag, int len, int seed)
{
  struct tblock *t = &sdm.b[sdm.nblocks++];
  t->flag = flag; t->len = len; t->bad_sum = 0;
  for (int k = 0; k < len; k++) t->data[k] = (unsigned char)(k * seed + flag + 1);
}

static void test_tape_sd(void)
{
  int f0 = failures;
  char msg[160];
  struct result R;
  printf("Tape hooks, SD path: the virtual tape player\n");
  allow_ctrl = 1;
  tape_on = 1;                          /* any cassette activity would be recorded */
  memset(&sdm, 0, sizeof sdm);
  sdm.on = 1; sdm.wfile = -1; ncardf = 0;
  rom_writes = bad_ports = 0;
  mem[XS_SDTAPE] = 1;
  mem[XS_SDERR] = 0;

  /* SAVE-like writes: header then data, onto a fresh tape */
  for (int k = 0; k < 25; k++) mem[0x4800 + k] = (unsigned char)(k + 'A');
  for (int k = 0; k < 1300; k++) mem[0x4900 + k] = (unsigned char)(k * 7 + 3);
  rec_n = 0;
  R = tcall(TAPE_WRITE, 0x0000, 0x00, 25, 0x4800, 0);
  check(R.pc == STOP_ADDR && rompage == 1 && R.r.IFF1 && R.ix_ok && R.iy_ok && R.sp_ok,
        "SD write (header): returns to the caller in page 1, EI, IX/IY/SP intact");
  R = tcall(TAPE_WRITE, 0x0000, 0xFF, 1300, 0x4900, 0);
  check(R.pc == STOP_ADDR && R.sp_ok, "SD write (data, 1300 bytes: three 512-byte chunks)");
  {
    int f = card_find("BCDEFGHIJK.TAP");
    struct tfile *t = f >= 0 ? &cardf[f] : NULL;
    check(t && t->nblocks == 2 && t->b[0].flag == 0 && t->b[0].len == 25
          && !memcmp(t->b[0].data, mem + 0x4800, 25) && t->b[1].flag == 0xFF
          && t->b[1].len == 1300 && !memcmp(t->b[1].data, mem + 0x4900, 1300) && !sdm.inserted,
          "SD write with no tape: BCDEFGHIJK.TAP made from the header's name, both blocks in it");
  }
  check(rec_n == 0, "SD write: nothing goes to the cassette");

  /* LOAD-like reads */
  memset(&sdm, 0, sizeof sdm); sdm.on = 1; sdm.inserted = 1;
  put_block(0x00, 25, 3);  put_block(0xFF, 700, 5);     /* program A */
  put_block(0x00, 25, 9);  put_block(0xFF, 40, 11);     /* program B */
  memset(mem + 0x5000, 0, 800);
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.pc == LOAD_SEARCH && R.carry && !memcmp(mem + 0x5000, sdm.b[0].data, 25),
        "header search: first header loaded, carry set, back at $1A81");
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.pc == LOAD_SEARCH && !R.carry, "header search meets a data block: carry clear (LOAD tries again)");
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.carry && !memcmp(mem + 0x5000, sdm.b[2].data, 25), "header search: second header found");
  R = tcall(TAPE_READ, 0x0001, 0xFF, 40, 0x5100, 0);
  check(R.pc == STOP_ADDR && R.carry && !memcmp(mem + 0x5100, sdm.b[3].data, 40),
        "data block after the header: loaded, carry set");
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.carry, "a new search starts from the tape's beginning (wraps round)");
  /* the wanted name at $2302 tells the hook whether LOAD had a name */
  {
    memset(mem + 0x2302, ' ', 10);
    R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
    int blank_spaces = sdm.last_search;
    mem[0x2302] = 0;
    R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
    int blank_zero = sdm.last_search;
    memcpy(mem + 0x2302, "INVADERS  ", 10);
    R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
    int named = sdm.last_search;
    char m2[120];
    snprintf(m2, sizeof m2, "LOAD's search sends 2 for a blank name (spaces %d, zero %d), 1 for a name (%d)",
             blank_spaces, blank_zero, named);
    check(blank_spaces == 2 && blank_zero == 2 && named == 1, m2);
    memset(&sdm, 0, sizeof sdm); sdm.on = 1; sdm.inserted = 1; sdm.wfile = -1;
    put_block(0x00, 25, 3);  put_block(0xFF, 700, 5);
    put_block(0x00, 25, 9);  put_block(0xFF, 40, 11);
    R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);   /* named: header A */
  }
  /* the ROM keeps searching while names don't match: data A, header B, data B ... */
  for (int k = 0; k < 3; k++) {
    R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
    check(R.pc == LOAD_SEARCH, "still searching while the tape has not gone round");
  }
  /* ... and back at the block where this search began */
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  snprintf(msg, sizeof msg, "once round without a match: ERROR 10 (stopped at $%04X, SP %s)",
           R.pc, R.r.SP == ZSTACK ? "with the return address dropped" : "wrong");
  check(R.pc == ERROR10_AT && R.r.SP == ZSTACK && R.r.IFF1 && mem[XS_SDERR] == 10, msg);

  /* data blocks: big (chunked), verify, wrong length, bad checksum */
  memset(&sdm, 0, sizeof sdm); sdm.on = 1; sdm.inserted = 1;
  put_block(0xFF, 1500, 13);
  memset(mem + 0x5000, 0, 1600);
  R = tcall(TAPE_READ, 0x0001, 0xFF, 1500, 0x5000, 0);
  check(R.carry && !memcmp(mem + 0x5000, sdm.b[0].data, 1500) && mem[0x5000 + 1500] == 0,
        "1500-byte data block (three chunks) loaded exactly");
  R = tcall(TAPE_READ, 0x0000, 0xFF, 1500, 0x5000, 0);
  check(R.carry, "VERIFY against the same memory: carry set");
  mem[0x5000 + 1499] ^= 0x80;
  R = tcall(TAPE_READ, 0x0000, 0xFF, 1500, 0x5000, 0);
  check(!R.carry && R.pc == STOP_ADDR, "VERIFY with the last byte changed: carry clear");
  mem[0x5000 + 1499] ^= 0x80;
  R = tcall(TAPE_READ, 0x0001, 0xFF, 1499, 0x5000, 0);
  check(!R.carry && R.pc == STOP_ADDR && mem[XS_SDERR] == 9, "wrong length: bad block, carry clear");
  sdm.b[0].bad_sum = 1;
  R = tcall(TAPE_READ, 0x0001, 0xFF, 1500, 0x5000, 0);
  check(!R.carry && mem[XS_SDERR] == 9, "bad checksum (reported after the data): carry clear");

  /* no tape, BREAK, cassette untouched with SDTAPE off */
  memset(&sdm, 0, sizeof sdm); sdm.on = 1;
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.pc == ERROR10_AT, "no tape in the player: ERROR 10");
  memset(&sdm, 0, sizeof sdm); sdm.on = 1; sdm.inserted = 1;
  put_block(0xFF, 10, 3);
  break_key = 1;
  R = tcall(TAPE_READ, 0x0001, 0xFF, 10, 0x5000, 0);
  break_key = 0;
  check(R.pc == BREAK_AT && R.r.SP == ZSTACK - 2 && R.r.IFF1,
        "SPACE held: BREAK (ERROR 3) with the caller's return address still stacked");
  mem[XS_SDTAPE] = 0;
  sdm.cmds = 0;
  for (int k = 0; k < 300; k++) mem[0x4800 + k] = (unsigned char)k;
  tape_write(1, 0xFF, 0x4800, 300);
  check(sdm.cmds == 0 && rec_n > 1000, "SDTAPE off: the cassette is used, the SD card never asked");
  check(!rom_writes, "SD tape: no ROM writes");

  sdm.on = 0;
  zin_valid = 0;
  tape_on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- SD words: SDTAPE, TAPE, EJECT ---------------------------------------- */

#define ACE_LIT_BYTE 0x104B
#define ACE_WORD     0x05AB
#define ACE_ENDDEF   0x04B6
#define DOCOLON      0x0EC3

static struct result run_tape_code(const char *name)     /* (TAPE) on a counted name */
{
  int n = (int)strlen(name);
  mem[0x2701] = n;
  memcpy(mem + 0x2702, name, n);
  fpush(0x2701);
  rompage = 1;
  stop_at[0] = NEXT_ADDR; stop_at[1] = ERR_ADDR;
  struct result R = z80_call(m16(XTAPE_CF));
  stop_at[0] = stop_at[1] = 0;
  return R;
}

static void test_sd_words(void)
{
  int f0 = failures, a[1];
  char msg[160];
  struct result R;
  printf("SD words: SDTAPE, TAPE, EJECT\n");
  allow_ctrl = 1;
  memset(&sdm, 0, sizeof sdm);
  sdm.on = 1; sdm.wfile = -1; ncardf = 0;
  s16(SV_SPARE, FSTACK);
  rom_writes = bad_ports = 0;

  a[0] = 1; R = run_word("SDTAPE", 1, a);
  check(R.pc == NEXT_ADDR && mem[XS_SDTAPE] != 0 && m16(SV_SPARE) == FSTACK, "1 SDTAPE: tape words use the card");
  a[0] = 0; R = run_word("SDTAPE", 1, a);
  check(R.pc == NEXT_ADDR && mem[XS_SDTAPE] == 0, "0 SDTAPE: back to the cassette");

  int tnlf = word_nlf("TAPE"), body = tnlf + 3;
  check(tnlf && m16(tnlf + 1) == DOCOLON && m16(body) == ACE_LIT_BYTE && mem[body + 2] == 32
        && m16(body + 3) == ACE_WORD && m16(body + 5) == XTAPE_CF && m16(body + 7) == ACE_ENDDEF,
        "TAPE is : TAPE 32 WORD (TAPE) ;");

  /* a card with GAMES.TAP: two programs */
  strcpy(cwd, "/programs");
  strcpy(cardf[0].name, "GAMES.TAP");
  strcpy(cardf[0].dir, "/programs");
  cardf[0].fake_size = 0;
  cardf[0].nblocks = 4;
  for (int k = 0; k < 4; k++) {
    cardf[0].b[k].flag = k & 1 ? 0xFF : 0x00;
    cardf[0].b[k].len = k & 1 ? 50 : 25;
    for (int j = 0; j < cardf[0].b[k].len; j++) cardf[0].b[k].data[j] = (unsigned char)(j + 10 * k);
  }
  ncardf = 1;

  long c0 = sdm.cmds;
  R = run_tape_code("GAMES");
  snprintf(msg, sizeof msg, "TAPE GAMES: GAMES.TAP in the player, SDTAPE on (sent \"%s\")", sdm.lastname);
  check(R.pc == NEXT_ADDR && sdm.inserted && sdm.nblocks == 4 && mem[XS_SDTAPE] == 1
        && !strcmp(sdm.lastname, "GAMES") && sdm.cmds == c0 + 1 && m16(SV_SPARE) == FSTACK, msg);

  /* the hooks now read from it: LOAD's header search */
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.carry && !memcmp(mem + 0x5000, cardf[0].b[0].data, 25), "then LOAD's search reads GAMES.TAP's first header");

  mem[XS_SDERR] = 0;
  mem[XD_ERRCODE] = 0;
  R = run_tape_code("NOPE");
  snprintf(msg, sizeof msg, "TAPE NOPE: ERROR 10 (code %d), SDERR 2 (not found: %d)", mem[XD_ERRCODE], mem[XS_SDERR]);
  check(R.pc == ERR_ADDR && mem[XD_ERRCODE] == 10 && mem[XS_SDERR] == 2, msg);
  check(sdm.inserted && sdm.nblocks == 4, "a failed TAPE leaves the tape in the player");
  s16(SV_SPARE, FSTACK);

  c0 = sdm.cmds;
  R = run_tape_code("");
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 6 && sdm.cmds == c0, "TAPE with no name: ERROR 10, SDERR 6, card not asked");
  s16(SV_SPARE, FSTACK);
  char longname[70]; memset(longname, 'X', 64); longname[64] = 0;
  R = run_tape_code(longname);
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 6 && sdm.cmds == c0, "TAPE with a 64-character name: ERROR 10, SDERR 6");
  s16(SV_SPARE, FSTACK);

  R = run_word("EJECT", 0, a);
  check(R.pc == NEXT_ADDR && !sdm.inserted && mem[XS_SDTAPE] == 1, "EJECT: player empty, SDTAPE still on");
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.pc == ERROR10_AT, "after EJECT, LOAD's search: ERROR 10 (no tape)");

  /* SAVE with no tape writes NAME.TAP; TAPE NAME then plays it */
  memset(mem + 0x4800, ' ', 25);
  mem[0x4800] = 0; memcpy(mem + 0x4801, "MYPROG", 6);
  for (int k = 0; k < 60; k++) mem[0x4900 + k] = (unsigned char)(k * 3);
  tcall(TAPE_WRITE, 0x0000, 0x00, 25, 0x4800, 0);
  tcall(TAPE_WRITE, 0x0000, 0xFF, 60, 0x4900, 0);
  int f = card_find("MYPROG.TAP");
  check(f >= 0 && cardf[f].nblocks == 2 && !memcmp(cardf[f].b[1].data, mem + 0x4900, 60),
        "SAVE MYPROG with no tape: MYPROG.TAP with header and data");
  R = run_tape_code("MYPROG");
  memset(mem + 0x5000, 0, 100);
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  struct result R2 = tcall(TAPE_READ, 0x0001, 0xFF, 60, 0x5100, 0);
  check(R.carry && R2.carry && !memcmp(mem + 0x5000, mem + 0x4800, 25) && !memcmp(mem + 0x5100, mem + 0x4900, 60),
        "TAPE MYPROG, then LOAD: header and data come back");
  check(!rom_writes, "SD words: no ROM writes");

  sdm.on = 0;
  mem[XS_SDTAPE] = 0;
  zin_valid = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- DIR, CD, DELETE ----------------------------------------------------------- */

static void add_file(const char *dir, const char *name, int nblocks, long fake)
{
  struct tfile *f = &cardf[ncardf++];
  strcpy(f->dir, dir); strcpy(f->name, name);
  f->nblocks = nblocks; f->fake_size = fake;
  for (int k = 0; k < nblocks; k++) { f->b[k].flag = k & 1 ? 0xFF : 0; f->b[k].len = k & 1 ? 100 : 25; }
}

/* the text DIR should print for the model's current folder, built independently */
static void expect_dir(char *out)
{
  out[0] = 0;
  for (int k = 0; k < nfolders; k++) {
    char par[80]; parent_of(folders[k], par);
    if (!strcasecmp(par, cwd)) { strcat(out, base_name(folders[k])); strcat(out, "/\r"); }
  }
  for (int k = 0; k < ncardf; k++)
    if (!strcasecmp(cardf[k].dir, cwd)) {
      long n = file_size(&cardf[k]);
      char t[120];
      if (n < 65536) snprintf(t, sizeof t, "%.70s %ld\r", cardf[k].name, n);
      else if (n < 65536L * 1024) snprintf(t, sizeof t, "%.70s %ldK\r", cardf[k].name, n >> 10);
      else snprintf(t, sizeof t, "%.70s 65535K+\r", cardf[k].name);
      strcat(out, t);
    }
}

static struct result run_name_code(int cf, const char *name)   /* (CD)/(DELETE) on a name */
{
  int n = (int)strlen(name);
  mem[0x2701] = n;
  memcpy(mem + 0x2702, name, n);
  fpush(0x2701);
  rompage = 1;
  stop_at[0] = NEXT_ADDR; stop_at[1] = ERR_ADDR;
  struct result R = z80_call(m16(cf));
  stop_at[0] = stop_at[1] = 0;
  s16(SV_SPARE, FSTACK);
  return R;
}

static void test_sd_dir(void)
{
  int f0 = failures, a[1];
  char want[2048], msg[300];
  struct result R;
  printf("SD words: DIR, CD, DELETE\n");
  allow_ctrl = 1;
  tape_on = 1;                          /* port $FE: SPACE */
  trap_rst8 = 1;
  memset(&sdm, 0, sizeof sdm);
  sdm.on = 1; sdm.wfile = -1;
  ncardf = 0; nfolders = 0; no_card = 0;
  strcpy(cwd, "/programs");
  strcpy(folders[nfolders++], "/programs");
  strcpy(folders[nfolders++], "/programs/DEMOS");
  strcpy(folders[nfolders++], "/programs/DEMOS/OLD");
  add_file("/programs", "GAMES.TAP", 4, 0);
  add_file("/programs", "BIG.TAP", 0, 123456);
  add_file("/programs", "HUGE.SCR", 0, 70000000L);       /* over 64M: 65535K+ */
  add_file("/programs/DEMOS", "WAVES.TAP", 2, 0);
  s16(SV_SPARE, FSTACK);
  rom_writes = bad_ports = 0;

  int nl = word_nlf("CD"), dl = word_nlf("DELETE");
  check(nl && m16(nl + 1) == DOCOLON && m16(nl + 3) == ACE_LIT_BYTE && mem[nl + 5] == 32
        && m16(nl + 6) == ACE_WORD && m16(nl + 8) == XCD_CF && m16(nl + 10) == ACE_ENDDEF,
        "CD is : CD 32 WORD (CD) ;");
  check(dl && m16(dl + 1) == DOCOLON && m16(dl + 6) == ACE_WORD && m16(dl + 8) == XDELETE_CF,
        "DELETE is : DELETE 32 WORD (DELETE) ;");

  nprinted = 0;
  R = run_word("DIR", 0, a);
  expect_dir(want);
  snprintf(msg, sizeof msg, "DIR in /programs prints folder, bytes and K sizes: \"%.200s\"", printed);
  check(R.pc == NEXT_ADDR && !strcmp(printed, want) && strstr(printed, "BIG.TAP 120K\r")
        && strstr(printed, "HUGE.SCR 65535K+\r") && strstr(printed, "GAMES.TAP 262\r"), msg);
  if (strcmp(printed, want)) printf("    want \"%s\"\n", want);

  R = run_name_code(XCD_CF, "DEMOS");
  check(R.pc == NEXT_ADDR && !strcmp(cwd, "/programs/DEMOS"), "CD DEMOS: into the folder");
  nprinted = 0; R = run_word("DIR", 0, a); expect_dir(want);
  check(!strcmp(printed, want) && strstr(printed, "OLD/") && strstr(printed, "WAVES.TAP 131"),
        "DIR in DEMOS: OLD/ and WAVES.TAP 131 (two blocks of 25 and 100 bytes, 3 more each)");
  R = run_name_code(XCD_CF, "OLD");
  nprinted = 0; R = run_word("DIR", 0, a);
  check(R.pc == NEXT_ADDR && nprinted == 0, "DIR in an empty folder prints nothing");
  R = run_name_code(XCD_CF, "..");
  check(!strcmp(cwd, "/programs/DEMOS"), "CD ..: up one level");
  R = run_name_code(XCD_CF, "/");
  check(!strcmp(cwd, "/"), "CD /: the top");
  R = run_name_code(XCD_CF, "programs");
  mem[XS_SDERR] = 0;
  R = run_name_code(XCD_CF, "NOPE");
  check(R.pc == ERR_ADDR && mem[XD_ERRCODE] == 10 && mem[XS_SDERR] == 2 && !strcmp(cwd, "/programs"),
        "CD NOPE: ERROR 10, SDERR 2, folder unchanged");

  R = run_name_code(XDELETE_CF, "BIG.TAP");
  check(R.pc == NEXT_ADDR && card_find("BIG.TAP") < 0 && card_find("GAMES.TAP") >= 0,
        "DELETE BIG.TAP: that file only is gone");
  R = run_name_code(XDELETE_CF, "BIG.TAP");
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 2, "DELETE BIG.TAP again: ERROR 10, SDERR 2");
  long c0 = sdm.cmds;
  R = run_name_code(XDELETE_CF, "");
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 6 && sdm.cmds == c0, "DELETE with no name: ERROR 10, SDERR 6");

  break_key = 1;
  nprinted = 0; R = run_word("DIR", 0, a);
  break_key = 0;
  check(R.pc == NEXT_ADDR && nprinted > 0 && strchr(printed, '\r') == printed + nprinted - 1,
        "SPACE held: DIR stops after the first entry");

  no_card = 1;
  nprinted = 0;
  R = run_word("DIR", 0, a);
  check(R.pc == ERR_ADDR && mem[XD_ERRCODE] == 10 && mem[XS_SDERR] == 1 && nprinted == 0,
        "DIR with no card: ERROR 10, SDERR 1, nothing printed");
  no_card = 0;
  s16(SV_SPARE, FSTACK);
  check(!rom_writes, "DIR/CD/DELETE: no ROM writes");

  trap_rst8 = 0;
  tape_on = 0;
  sdm.on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- PGSAVE, PGLOAD, SCRSAVE, SCRLOAD ------------------------------------------- */

static struct result run_num_name(int cf, int n, const char *name)
{
  int len = (int)strlen(name);
  mem[0x2701] = len;
  memcpy(mem + 0x2702, name, len);
  fpush(n);
  fpush(0x2701);
  rompage = 1;
  stop_at[0] = NEXT_ADDR; stop_at[1] = ERR_ADDR;
  struct result R = z80_call(m16(cf));
  stop_at[0] = stop_at[1] = 0;
  return R;
}

static void test_sd_pages(void)
{
  int f0 = failures, f;
  char msg[200];
  struct result R;
  printf("SD words: PGSAVE, PGLOAD, SCRSAVE, SCRLOAD\n");
  allow_ctrl = 1;
  memset(&sdm, 0, sizeof sdm);
  sdm.on = 1; sdm.wfile = -1;
  ncardf = 0; no_card = 0; card_full = 0; open_f = -1; open_mode = 0;
  strcpy(cwd, "/programs");
  s16(SV_SPARE, FSTACK);
  rom_writes = bad_ports = 0;
  unsigned char *pg = ram;                             /* page p = pg + p*8192 */
  for (long k = 0; k < 64L * 8192; k++) pg[k] = (unsigned char)(k * 7 + (k >> 13) * 13);

  win[0] = 11; win[1] = 40;
  R = run_num_name(XPGSAVE_CF, 37, "LEVEL1");
  f = card_find("LEVEL1.PG");
  snprintf(msg, sizeof msg, "37 PGSAVE LEVEL1: LEVEL1.PG holds page 37's 8,192 bytes (sent \"%s\")", sdm.lastname);
  check(R.pc == NEXT_ADDR && f >= 0 && cardf[f].rawlen == 8192 && !memcmp(cardf[f].rawdata, pg + 37 * 8192, 8192), msg);
  check(win[0] == 11 && win[1] == 40 && open_mode == 0 && m16(SV_SPARE) == FSTACK,
        "PGSAVE: user's windows restored, file closed, stack clean");

  memset(pg + 50 * 8192, 0, 8192);
  R = run_num_name(XPGLOAD_CF, 50, "LEVEL1");
  check(R.pc == NEXT_ADDR && !memcmp(pg + 50 * 8192, pg + 37 * 8192, 8192) && win[0] == 11 && win[1] == 40,
        "50 PGLOAD LEVEL1: page 50 = the saved page, windows restored");

  /* a short file loads only what it has */
  f = ncardf++;
  memset(&cardf[f], 0, sizeof cardf[f]);
  strcpy(cardf[f].name, "SHORT.PG"); strcpy(cardf[f].dir, cwd); cardf[f].raw = 1;
  cardf[f].rawlen = 100; memset(cardf[f].rawdata, 0xA5, 100);
  memset(pg + 51 * 8192, 0x11, 8192);
  R = run_num_name(XPGLOAD_CF, 51, "SHORT");
  {
    int ok = R.pc == NEXT_ADDR;
    for (int k = 0; k < 8192; k++) ok = ok && pg[51 * 8192 + k] == (k < 100 ? 0xA5 : 0x11);
    check(ok, "PGLOAD of a 100-byte file: the first 100 bytes, the rest unchanged");
  }
  s16(SV_SPARE, FSTACK);
  R = run_num_name(XPGLOAD_CF, 52, "NOPE");
  check(R.pc == ERR_ADDR && mem[XD_ERRCODE] == 10 && mem[XS_SDERR] == 2 && win[0] == 11 && win[1] == 40,
        "PGLOAD NOPE: ERROR 10, SDERR 2, windows restored");
  s16(SV_SPARE, FSTACK);
  {
    char nm[70]; memset(nm, 'N', 61); nm[61] = 0;   /* 61 + ".PG" = 64 */
    long c0 = sdm.cmds;
    R = run_num_name(XPGSAVE_CF, 1, nm);
    check(R.pc == ERR_ADDR && mem[XS_SDERR] == 6 && sdm.cmds == c0, "PGSAVE with a 61-character name (64 with .PG): ERROR 10, SDERR 6");
    s16(SV_SPARE, FSTACK);
    nm[60] = 0;                                      /* 60 + 3 = 63: allowed */
    R = run_num_name(XPGSAVE_CF, 1, nm);
    check(R.pc == NEXT_ADDR && strlen(sdm.lastname) == 63, "PGSAVE with a 60-character name: 63 with .PG, accepted");
  }
  R = run_num_name(XPGSAVE_CF, 69, "MOD");
  f = card_find("MOD.PG");
  check(f >= 0 && !memcmp(cardf[f].rawdata, pg + 5 * 8192, 8192), "69 PGSAVE: page 69 mod 64 = page 5");

  /* screens: pages 2n and 2n+1, $C000-$EFFF */
  R = run_num_name(XSCRSAVE_CF, 3, "TITLE");
  f = card_find("TITLE.SCR");
  check(R.pc == NEXT_ADDR && f >= 0 && cardf[f].rawlen == 12288
        && !memcmp(cardf[f].rawdata, pg + 6 * 8192, 8192) && !memcmp(cardf[f].rawdata + 8192, pg + 7 * 8192, 4096),
        "3 SCRSAVE TITLE: TITLE.SCR = page 6 + the first 4K of page 7 (12,288 bytes)");
  check(win[0] == 11 && win[1] == 40, "SCRSAVE: windows restored");
  unsigned char keep[4096];
  memcpy(keep, pg + 11 * 8192 + 4096, 4096);
  memset(pg + 10 * 8192, 0, 8192 + 4096);
  R = run_num_name(XSCRLOAD_CF, 5, "TITLE");
  check(R.pc == NEXT_ADDR && !memcmp(pg + 10 * 8192, cardf[f].rawdata, 12288)
        && !memcmp(pg + 11 * 8192 + 4096, keep, 4096) && win[0] == 11 && win[1] == 40,
        "5 SCRLOAD TITLE: screen 5 loaded; its free 4K and the windows untouched");
  R = run_num_name(XSCRSAVE_CF, 33, "WRAP");
  f = card_find("WRAP.SCR");
  check(f >= 0 && !memcmp(cardf[f].rawdata, pg + 2 * 8192, 8192), "33 SCRSAVE: screen 33 mod 32 = screen 1 (pages 2, 3)");

  card_full = 1;
  s16(SV_SPARE, FSTACK);
  R = run_num_name(XSCRSAVE_CF, 0, "FULL");
  card_full = 0;
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 3 && win[0] == 11 && win[1] == 40,
        "SCRSAVE on a full card: ERROR 10, SDERR 3, windows restored");
  s16(SV_SPARE, FSTACK);
  check(!rom_writes, "page and screen words: no ROM writes");

  sdm.on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- FONTLOAD, SDERR ---------------------------------------------------------- */

static void test_sd_font(void)
{
  int f0 = failures, f, a[1];
  struct result R;
  printf("SD words: FONTLOAD, SDERR\n");
  allow_ctrl = 1;
  model_chr = 1;
  memset(&sdm, 0, sizeof sdm);
  sdm.on = 1; sdm.wfile = -1;
  ncardf = 0; no_card = 0; card_full = 0; open_f = -1; open_mode = 0;
  strcpy(cwd, "/programs");
  s16(SV_SPARE, FSTACK);
  rom_writes = bad_ports = 0;
  memset(chr, 0x33, sizeof chr);
  f = ncardf++;
  memset(&cardf[f], 0, sizeof cardf[f]);
  strcpy(cardf[f].name, "GOTHIC.FNT"); strcpy(cardf[f].dir, cwd); cardf[f].raw = 1;
  cardf[f].rawlen = 1024;
  for (int k = 0; k < 1024; k++) cardf[f].rawdata[k] = (unsigned char)(k * 11 + 5);

  int nl = word_nlf("FONTLOAD");
  check(nl && m16(nl + 1) == DOCOLON && m16(nl + 6) == ACE_WORD && m16(nl + 8) == XFONTLOAD_CF,
        "FONTLOAD is : FONTLOAD 32 WORD (FONTLOAD) ;");
  creg[2] = 4; creg[3] = 9;             /* the user's CHR_CPU and CHR_VIEW */
  R = run_num_name(XFONTLOAD_CF, 7, "GOTHIC");
  check(R.pc == NEXT_ADDR && !memcmp(chr[7], cardf[f].rawdata, 1024), "7 FONTLOAD GOTHIC: font 7 = GOTHIC.FNT");
  check(creg[2] == 4 && creg[3] == 9 && m16(SV_SPARE) == FSTACK && open_mode == 0,
        "FONTLOAD: CHR_CPU restored, the font shown unchanged, file closed");
  {
    unsigned char c33[1024]; memset(c33, 0x33, 1024);
    check(!memcmp(chr[4], c33, 1024) && !memcmp(chr[8], c33, 1024), "FONTLOAD: other fonts untouched");
  }
  cardf[f].rawlen = 200;
  memset(chr[2], 0x77, 1024);
  R = run_num_name(XFONTLOAD_CF, 34, "GOTHIC");        /* 34 mod 32 = 2 */
  {
    int ok = R.pc == NEXT_ADDR;
    for (int k = 0; k < 1024; k++) ok = ok && chr[2][k] == (k < 200 ? cardf[f].rawdata[k] : 0x77);
    check(ok, "34 FONTLOAD of a 200-byte file: font 2 (34 mod 32), first 200 bytes only");
  }
  s16(SV_SPARE, FSTACK);
  R = run_num_name(XFONTLOAD_CF, 1, "NOPE");
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 2 && creg[2] == 4, "FONTLOAD NOPE: ERROR 10, SDERR 2, CHR_CPU unchanged");
  s16(SV_SPARE, FSTACK);

  R = run_word("SDERR", 0, a);
  check(R.pc == NEXT_ADDR && m16(SV_SPARE) == FSTACK + 2 && m16(FSTACK) == 2, "SDERR leaves 2 (not found)");
  s16(SV_SPARE, FSTACK);
  R = run_num_name(XFONTLOAD_CF, 1, "GOTHIC");
  R = run_word("SDERR", 0, a);
  check(m16(FSTACK) == 2, "SDERR keeps the last failure after a success");
  s16(SV_SPARE, FSTACK);
  mem[XS_SDERR] = 0;
  R = run_word("SDERR", 0, a);
  check(m16(FSTACK) == 0, "SDERR is 0 with no failure");
  s16(SV_SPARE, FSTACK);
  check(!rom_writes, "FONTLOAD/SDERR: no ROM writes");

  model_chr = 0;
  sdm.on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- end to end: the ROM with the real SD firmware on a FAT RAM disk -------- */

static long card_file(const char *path, unsigned char *buf, long max)
{
  FIL f;
  UINT got;
  if (f_open(&f, path, FA_READ) != FR_OK) return -1;
  f_read(&f, buf, (UINT) max, &got);
  f_close(&f);
  return (long) got;
}

static void test_firmware(void)
{
  int f0 = failures, a[1];
  char want[200];
  static unsigned char buf[20000];
  struct result R;
  printf("End to end: the ROM with the real SD firmware (FatFs on a RAM disk)\n");
  ramdisk_format();
  fpga_reset();
  fw_on = 1;
  allow_ctrl = 1;
  tape_on = 1;
  trap_rst8 = 1;
  model_chr = 1;
  s16(SV_SPARE, FSTACK);
  rom_writes = bad_ports = 0;
  mem[XS_SDTAPE] = 1;
  mem[XS_SDERR] = 0;

  /* SAVE through the tape hooks, with no tape in the player */
  memset(mem + 0x4800, ' ', 25);
  mem[0x4800] = 0; memcpy(mem + 0x4801, "E2EPROG", 7);
  for (int k = 0; k < 300; k++) mem[0x4900 + k] = (unsigned char)(k * 5 + 1);
  rec_n = 0;
  R = tcall(TAPE_WRITE, 0x0000, 0x00, 25, 0x4800, 0);
  struct result R2 = tcall(TAPE_WRITE, 0x0000, 0xFF, 300, 0x4900, 0);
  long n = card_file("/programs/E2EPROG.tap", buf, sizeof buf);
  check(R.pc == STOP_ADDR && R2.pc == STOP_ADDR && n == 28 + 303 && buf[0] == 26 && !memcmp(buf + 2, mem + 0x4800, 25)
        && !memcmp(buf + 30, mem + 0x4900, 300) && rec_n == 0,
        "SAVE (hooks) with no tape: /programs/E2EPROG.tap, header and data, nothing on the cassette");

  /* TAPE, then LOAD (named search) and its data */
  R = run_tape_code("E2EPROG");
  check(R.pc == NEXT_ADDR && mem[XS_SDTAPE] == 1, "TAPE E2EPROG");
  memcpy(mem + 0x2302, "E2EPROG   ", 10);
  memset(mem + 0x5000, 0, 400);
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  R2 = tcall(TAPE_READ, 0x0001, 0xFF, 300, 0x5100, 0);
  check(R.carry && R2.carry && !memcmp(mem + 0x5000, mem + 0x4800, 25) && !memcmp(mem + 0x5100, mem + 0x4900, 300),
        "LOAD E2EPROG through the hooks: header and data back");
  R = tcall(TAPE_READ, 0x0000, 0xFF, 300, 0x4900, 0);
  check(!R.carry, "VERIFY with the tape past the data: no block (carry clear)");
  mem[0x2302] = 0;                      /* LOAD with no name: from the start */
  R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
  check(R.carry && !memcmp(mem + 0x5000, mem + 0x4800, 25), "LOAD with no name: the first header again");
  memcpy(mem + 0x2302, "OTHER     ", 10);
  int reads = 0;
  do {                                  /* LOAD reads headers until ERROR 10 */
    R = tcall(TAPE_READ, 0x0001, 0x00, 25, 0x5000, LOAD_SEARCH);
    reads++;
  } while (R.pc == LOAD_SEARCH && reads < 10);
  snprintf(want, sizeof want, "LOAD OTHER (not on the tape): ERROR 10 once round (after %d reads)", reads);
  check(R.pc == ERROR10_AT && reads <= 3, want);

  /* pages, screens, fonts */
  for (int k = 0; k < 8192; k++) ram[9 * 8192 + k] = (unsigned char)(k ^ (k >> 8));
  win[0] = 11; win[1] = 40;
  s16(SV_SPARE, FSTACK);
  R = run_num_name(XPGSAVE_CF, 9, "PAGE9");
  n = card_file("/programs/PAGE9.PG", buf, sizeof buf);
  check(R.pc == NEXT_ADDR && n == 8192 && !memcmp(buf, ram + 9 * 8192, 8192), "PGSAVE: PAGE9.PG on the card");
  memset(ram + 20 * 8192, 0, 8192);
  R = run_num_name(XPGLOAD_CF, 20, "PAGE9");
  check(R.pc == NEXT_ADDR && !memcmp(ram + 20 * 8192, ram + 9 * 8192, 8192) && win[0] == 11 && win[1] == 40,
        "PGLOAD: page 20 = page 9, windows restored");
  R = run_num_name(XSCRSAVE_CF, 2, "PIC");
  n = card_file("/programs/PIC.SCR", buf, sizeof buf);
  check(R.pc == NEXT_ADDR && n == 12288 && !memcmp(buf, ram + 4 * 8192, 12288), "SCRSAVE: PIC.SCR, 12,288 bytes");
  memset(ram + 12 * 8192, 0, 12288);
  R = run_num_name(XSCRLOAD_CF, 6, "PIC");
  check(R.pc == NEXT_ADDR && !memcmp(ram + 12 * 8192, ram + 4 * 8192, 12288), "SCRLOAD: screen 6 = screen 2");
  {
    FIL f; UINT w;
    for (int k = 0; k < 1024; k++) buf[k] = (unsigned char)(k * 3);
    f_open(&f, "/programs/SET.FNT", FA_WRITE | FA_CREATE_ALWAYS);
    f_write(&f, buf, 1024, &w);
    f_close(&f);
  }
  creg[2] = 0;
  R = run_num_name(XFONTLOAD_CF, 5, "SET");
  check(R.pc == NEXT_ADDR && !memcmp(chr[5], buf, 1024) && creg[2] == 0, "FONTLOAD: font 5 from SET.FNT");

  /* folders and DIR */
  f_mkdir("/programs/DEMOS");
  nprinted = 0;
  R = run_word("DIR", 0, a);
  check(R.pc == NEXT_ADDR && strstr(printed, "DEMOS/\r") == printed && strstr(printed, "E2EPROG.tap 331\r")
        && strstr(printed, "PAGE9.PG 8192\r") && strstr(printed, "PIC.SCR 12288\r") && strstr(printed, "SET.FNT 1024\r"),
        "DIR: the folder first, then the files with their sizes");
  if (failures > f0) printf("    DIR printed \"%.200s\"\n", printed);
  R = run_name_code(XCD_CF, "DEMOS");
  nprinted = 0;
  R = run_word("DIR", 0, a);
  check(R.pc == NEXT_ADDR && nprinted == 0, "CD DEMOS, DIR: empty");
  R = run_name_code(XCD_CF, "..");
  R = run_name_code(XDELETE_CF, "PAGE9.PG");
  FILINFO fi;
  check(R.pc == NEXT_ADDR && f_stat("/programs/PAGE9.PG", &fi) == FR_NO_FILE, "CD .., DELETE PAGE9.PG");
  R = run_tape_code("NOPE");
  snprintf(want, sizeof want, "TAPE NOPE: ERROR 10, SDERR 2 (%d)", mem[XS_SDERR]);
  check(R.pc == ERR_ADDR && mem[XS_SDERR] == 2, want);
  s16(SV_SPARE, FSTACK);
  R = run_word("EJECT", 0, a);
  check(R.pc == NEXT_ADDR, "EJECT");
  check(!rom_writes && fpga_overflows == 0, "no ROM writes, no FIFO overruns");

  fw_on = 0;
  trap_rst8 = 0;
  tape_on = 0;
  model_chr = 0;
  mem[XS_SDTAPE] = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- the PS/2 translation through the ROM's own keyboard routine ($0336) ----- */

static int rom_key(void)                /* the ROM's key decode on the current matrix */
{
  rompage = 1;
  zin_valid = 0;
  struct result R = z80_call(0x0336);
  return R.pc == STOP_ADDR ? R.a : -1;
}

static int kb_char(enum kbd_layout lay, int mod, int sc)
{
  kbd_init(lay, KBD_SYMBOLIC);
  if (mod) { if (mod & 0x100) kbd_byte(0xE0); kbd_byte((uint8_t) mod); }
  if (sc & 0x100) kbd_byte(0xE0);
  kbd_byte((uint8_t) sc);
  return rom_key();
}

static void test_keyboard_rom(void)
{
  int f0 = failures;
  char msg[300];
  printf("Keyboard: PS/2 keys through the ROM's keyboard routine ($0336)\n");
  allow_ctrl = 1;
  kb_on = 1;
  const char *names[2] = { "US", "Portuguese" };
  for (int lay = 0; lay < 2; lay++) {
    int found[128] = {0};
    int mods[3] = { 0, 0x12, 0x111 };
    for (int m = 0; m < (lay ? 3 : 2); m++)
      for (int sc = 1; sc < 0x200; sc++) {
        if (sc == 0x12 || sc == 0x59 || sc == 0x14 || sc == 0x114 || sc == 0x11 || sc == 0x111
            || sc == 0xE0 || sc == 0xF0 || sc == 0xE1 || sc == 0x1E0 || sc == 0x1F0 || sc == 0x1E1
            || sc == 0xFA || sc == 0xAA || sc == 0xEE || sc == 0xFE || sc == 0xFF) continue;
        int c = kb_char((enum kbd_layout) lay, mods[m], sc);
        if (c >= 32 && c < 127) found[c] = 1;
      }
    char missing[100] = "";
    int nmiss = 0;
    for (int c = 32; c < 127; c++) if (!found[c]) { missing[nmiss++] = (char) c; }
    missing[nmiss] = 0;
    snprintf(msg, sizeof msg, "%s layout: all 95 printable characters typed through the ROM (missing: \"%s\")",
             names[lay], missing);
    check(nmiss == 0, msg);
  }
  /* spot checks: the character on the key cap comes out */
  check(kb_char(KBD_US, 0, 0x55) == '=' && kb_char(KBD_US, 0x12, 0x55) == '+'
        && kb_char(KBD_US, 0x12, 0x52) == '"' && kb_char(KBD_US, 0, 0x1C) == 'a'
        && kb_char(KBD_US, 0x12, 0x1C) == 'A' && kb_char(KBD_US, 0x12, 0x1E) == '@',
        "US: = + \" a A @ from their key caps");
  check(kb_char(KBD_PT, 0x12, 0x45) == '=' && kb_char(KBD_PT, 0x12, 0x1E) == '"'
        && kb_char(KBD_PT, 0x111, 0x1E) == '@' && kb_char(KBD_PT, 0x111, 0x3E) == '['
        && kb_char(KBD_PT, 0, 0x54) == '+' && kb_char(KBD_PT, 0x12, 0x3D) == '/'
        && kb_char(KBD_PT, 0, 0x61) == '<' && kb_char(KBD_PT, 0, 0x4A) == '-',
        "Portuguese: = \" @ [ + / < - from their key caps");
  check(kb_char(KBD_US, 0, 0x5A) == 13, "Enter: the ROM's ENTER code (13)");
  kb_on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

/* ---- Forth sessions: text typed into the real ROM's interpreter ------------------
 * The whole machine from reset (TurboACE boot, 0 TURBO), the 50 Hz frame interrupt
 * running the ROM's keyboard scan and line editor, and each character pressed on a
 * PS/2 keyboard through the firmware's translation (key codes found through the
 * ROM's own decoder, as in test_keyboard_rom). A session ends when everything has
 * been typed and the interpreter waits in QUERY again ($059B). */

#define FRAME_T   65000UL               /* 3.25 MHz / 50 Hz */
#define TY_PERIOD (6 * FRAME_T)         /* one character every 6 frames ... */
#define TY_HOLD   (3 * FRAME_T)         /* ... held down for 3 */
#define QUERY_WAIT 0x059B               /* QUERY: waiting for ENTER */
#define QUERY_DONE 0x059F               /* QUERY: ENTER seen, the line is taken */

static int ty_mod[128], ty_sc[128];     /* character -> PS/2 modifier and key */
static const char *ty_text;
static int ty_len, ty_next, ty_base, ty_down = -1, ty_accept;   /* ty_accept: ENTER typed, line not yet taken */
static unsigned long ty_t0;

static void ty_keys(int c, int press)
{
  int m = ty_mod[c], k = ty_sc[c];
  if (press) {
    if (m) { if (m & 0x100) kbd_byte(0xE0); kbd_byte((uint8_t) m); }
    if (k & 0x100) kbd_byte(0xE0);
    kbd_byte((uint8_t) k);
  } else {
    if (k & 0x100) kbd_byte(0xE0);
    kbd_byte(0xF0); kbd_byte((uint8_t) k);
    if (m) { if (m & 0x100) kbd_byte(0xE0); kbd_byte(0xF0); kbd_byte((uint8_t) m); }
  }
}

static void ty_update(void)             /* called on every keyboard read */
{
  if (!ty_text || !ty_t0) return;
  unsigned long dt = tstates - ty_t0;
  int slot = ty_base + (int)(dt / TY_PERIOD), down = dt % TY_PERIOD < TY_HOLD;
  if (ty_down >= 0 && (slot != ty_down || !down)) {
    ty_keys((unsigned char) ty_text[ty_down], 0);
    if (ty_text[ty_down] == '\n') { ty_t0 = 0; ty_base = ty_next; }   /* wait for QUERY again */
    ty_down = -1;
    if (!ty_t0) return;
  }
  if (ty_down < 0 && down && slot == ty_next && ty_next < ty_len) {
    ty_keys((unsigned char) ty_text[ty_next], 1);
    if (ty_text[ty_next] == '\n') ty_accept = 1;
    if (getenv("TYDBG")) fprintf(stderr, "%lu press %d '%c'\n", tstates / FRAME_T, ty_next, ty_text[ty_next] == '\n' ? '$' : ty_text[ty_next]);
    ty_down = ty_next++;
  }
}

static int ty_stop(unsigned short pc)
{
  if (pc == QUERY_DONE) { ty_accept = 0; if (getenv("TYDBG")) fprintf(stderr, "%lu QUERY done\n", tstates / FRAME_T); }
  if (pc != QUERY_WAIT || ty_accept) return 0;
  if (!ty_t0) {                                /* the interpreter is ready: start typing */
    if (!ty_next) rom_writes = 0;               /* (the stock RAM test at reset wraps to $0000) */
    ty_t0 = tstates + 2 * FRAME_T;
  }
  return ty_next == ty_len && ty_down < 0;
}

static void ty_table(void)              /* every character the text may use */
{
  static int done;
  if (done) return;
  done = 1;
  kb_on = 1;
  for (int c = 0; c < 128; c++) ty_sc[c] = -1;
  int mods[2] = { 0, 0x12 };
  for (int m = 0; m < 2; m++)
    for (int sc = 1; sc < 0x200; sc++) {
      if (sc == 0x12 || sc == 0x59 || sc == 0x14 || sc == 0x114 || sc == 0x11 || sc == 0x111
          || sc == 0x7E || sc == 0x58 || (sc & 0xFF) >= 0xE0 || (sc & 0xFF) == 0xAA || (sc & 0xFF) >= 0xFA) continue;
      int c = kb_char(KBD_US, mods[m], sc);
      if (c >= 0 && c < 128 && ty_sc[c] < 0) { ty_mod[c] = mods[m]; ty_sc[c] = sc; }
    }
  ty_mod['\n'] = 0; ty_sc['\n'] = 0x5A;   /* Enter */
  kb_on = 0;
}

static char scr_text[24][33];           /* the Ace's text screen after a session */

/* boot the whole machine and type text ('\n' = ENTER); returns where it stopped */
static struct result forth(const char *text)
{
  ty_table();
  memset(mem + 0x2000, 0, 0xA000);
  memset(ram, 0, sizeof ram);
  memset(creg, 0, sizeof creg);
  win[0] = 0; win[1] = 1;
  rompage = 1;
  allow_ctrl = 1; kb_on = 1; ace_mirror = 1;
  kbd_init(KBD_US, KBD_SYMBOLIC);
  ty_text = text; ty_len = (int) strlen(text); ty_next = 0; ty_down = -1; ty_t0 = 0; ty_base = 0; ty_accept = 0;
  irq_period = FRAME_T;
  stop_hook = ty_stop;
  zlimit = 2000000000L;
  zin_valid = 0;
  struct result R = z80_call(0x0000);
  zlimit = LIMIT; stop_hook = NULL; irq_period = 0;
  ty_text = NULL;
  kb_on = 0; ace_mirror = 0;
  for (int y = 0; y < 24; y++) {
    for (int x = 0; x < 32; x++) {
      int c = mem[0x2400 + 32 * y + x] & 0x7F;
      scr_text[y][x] = c >= 32 && c < 127 ? (char) c : ' ';
    }
    scr_text[y][32] = 0;
  }
  return R;
}

static void show_screen(void)
{
  for (int y = 0; y < 24; y++) printf("    |%s|\n", scr_text[y]);
}

static int screen_has(const char *sub)  /* the screen as one string (lines wrap at 32) */
{
  char all[24 * 32 + 1];
  for (int y = 0; y < 24; y++) memcpy(all + 32 * y, scr_text[y], 32);
  all[24 * 32] = 0;
  return strstr(all, sub) != NULL;
}

static int session_ok;
static void sees(const char *sub, const char *what)
{
  char msg[200];
  snprintf(msg, sizeof msg, "%s (screen shows \"%s\")", what, sub);
  int ok = screen_has(sub);
  check(ok, msg);
  if (!ok) session_ok = 0;
}

static void session(const char *text)
{
  if (getenv("ROMW")) fprintf(stderr, "session: %.40s\n", text);
  struct result R = forth(text);
  session_ok = 1;
  check(R.pc == QUERY_WAIT && !R.timeout, "Forth session: everything typed, back in QUERY");
  check(!rom_writes, "Forth session: no ROM writes after boot");
}

static unsigned rnd_ref(unsigned *seed, unsigned n)
{
  *seed = (unsigned)(((unsigned long)(*seed + 1) * 75) % 65537) - 1;
  return (unsigned)(((unsigned long) *seed * n) >> 16);
}

static void test_forth_words(void)
{
  int f0 = failures;
  char exp[200];
  printf("Programming words, typed into the ROM: 2* 2/ 0<> ' .S 2DUP.. D.. GR RND\n");
  rom_writes = 0;
  if (getenv("BOOTSCREEN")) {             /* the screen after boot, for the FPGA system test */
    unsigned long t0 = tstates;
    session("");
    printf("boot: %lu T-states to QUERY\n", tstates - t0);
    FILE *fd = fopen(getenv("BOOTSCREEN"), "w");
    for (int k = 0; k < 768; k++) fprintf(fd, "%02x\n", mem[0x2400 + k]);
    for (int k = 0; k < 1024; k++) fprintf(fd, "%02x\n", mem[0x3C00 + k]);   /* work RAM, system variables */
    fclose(fd);
    exit(0);
  }
  if (getenv("PROBE")) { static char pt[4000]; strncpy(pt, getenv("PROBE"), 3999);
    for (char *q = pt; *q; q++) if (*q == '|') *q = '\n';
    session(pt); show_screen();
    if (getenv("DUMP")) { FILE *fd = fopen(getenv("DUMP"), "wb"); fwrite(mem, 1, 65536, fd); fclose(fd); }
    exit(0); }
  session("1 TURBO\n"
          "5 2* . -3 2/ . 7 2/ . 0 0<> . 9 0<> .\n"
          "1 2 3 .S . . .\n"
          ".S 77 .\n"
          "5 VARIABLE V ' V @ .\n"
          "1 2 2DUP . . . .\n"
          "1 2 3 4 2OVER . . . . . .\n"
          "1 2 3 4 2SWAP . . . .\n"
          "1 2 3 4 5 6 2ROT . . . . . .\n"
          "1 2 3 2DROP .\n");
  sees("2* . 10 -3 2/ . -2 7 2/ . 3 0 0<> . 0 9 0<> . 1  OK", "2* 2/ 0<>: 10 -2 3 0 1 (2/ rounds down)");
  sees(".S 1 2 3 . 3 . 2 . 1  OK", ".S shows the stack bottom first and leaves it");
  sees(".S 77 . 77  OK", ".S on an empty stack prints nothing");
  sees("' V @ . 5  OK", "' gives the parameter field: a VARIABLE's address");
  sees("2DUP . 2 . 1 . 2 . 1  OK", "2DUP");
  sees("2OVER . 2 . 1 . 4 . 3 . 2 . 1  OK", "2OVER");
  sees("2SWAP . 2 . 1 . 4 . 3  OK", "2SWAP");
  sees("2ROT . 2 . 1 . 6 . 5 . 4 . 3  OK", "2ROT: d1 d2 d3 -- d2 d3 d1");
  sees("2DROP . 1  OK", "2DROP");
  if (!session_ok) show_screen();

  session("1 TURBO\n"
          "1000 1000 U* D. -5 S->D D.\n"
          "1000 1000 U* DNEGATE D. -5 S->D DABS D.\n"
          "1000 1000 U* 999 1000 U* D- D.\n"
          "7 S->D 7 S->D D= . 7 S->D 8 S->D D= .\n"
          "0 0 D0= . 0 1 D0= .\n"
          "-1234 S->D 8 D.R ASCII | EMIT\n"
          "1000 1000 U* 3 D.R ASCII | EMIT\n"
          "1 2 3 4 5 6 7 8 65 GR 9 8 7 6 5 4 3 2 193 GR\n");
  sees("D. 1000000 -5 S->D D. -5  OK", "D. and S->D");
  sees("DNEGATE D. -1000000 -5 S->D DABS D. 5  OK", "D. of a negative double; DABS");
  sees("D- D. 1000  OK", "D-");
  sees("D= . 1 7 S->D 8 S->D D= . 0  OK", "D=");
  sees("D0= . 1 0 1 D0= . 0  OK", "D0=");
  sees("D.R    -1234ASCII | EMIT | OK", "D.R pads to the width");
  sees("D.R 1000000ASCII | EMIT | OK", "D.R: a number wider than the field is printed whole");
  {
    int ok = 1;
    for (int k = 0; k < 8; k++) ok &= mem[0x2C00 + 65 * 8 + k] == 9 - k;
    check(ok, "GR: character 65 (from 193, taken 0-127), first byte the top row");
  }
  if (!session_ok) show_screen();

  session("1 TURBO\n"
          "1 RAND 100 RND . 100 RND . 100 RND . 6 RND .\n"
          "0 RND .\n");
  {
    unsigned sd = 1;
    int r1 = rnd_ref(&sd, 100), r2 = rnd_ref(&sd, 100), r3 = rnd_ref(&sd, 100), r4 = rnd_ref(&sd, 6);
    snprintf(exp, sizeof exp, "100 RND . %d 100 RND . %d 100 RND . %d 6 RND . %d  OK", r1, r2, r3, r4);
    sees(exp, "1 RAND then RND: the sequence of the formula");
    sees("0 RND . 0  OK", "0 RND gives 0");
  }
  if (!session_ok) show_screen();

  /* RND straight through its code: the full cycle and the range */
  {
    static unsigned char seen[65536];
    memset(seen, 0, sizeof seen);
    unsigned sd = 4321;
    mem[XS_SEED] = sd & 255; mem[XS_SEED + 1] = sd >> 8;
    int range_ok = 1, same = 1, cycle = 1;
    for (long k = 0; k < 65536; k++) {
      int n = k < 1000 ? 1 + (int)(k % 7) : 1 + (int)((k * 7919) % 65535);
      int a[1] = { n };
      s16(SV_SPARE, FSTACK);
      run_word("RND", 1, a);
      int r = m16(FSTACK);
      unsigned want = rnd_ref(&sd, (unsigned) n);
      if (r != (int) want) same = 0;
      if (r >= n) range_ok = 0;
      if (seen[m16(XS_SEED)]++) cycle = 0;
      if (m16(SV_SPARE) != FSTACK + 2) same = 0;
    }
    check(same, "RND: 65536 calls equal the formula, one cell in, one out");
    check(range_ok, "RND: always 0 <= r < n");
    check(cycle, "RND: the seed visits all 65536 values once");
    int a[1] = { 0 };
    mem[0x3C2B] = 0x34; mem[0x3C2C] = 0x12;
    s16(SV_SPARE, FSTACK);
    run_word("RAND", 1, a);
    check(m16(XS_SEED) == 0x1234, "0 RAND: seed from FRAMES");
    a[0] = 999; s16(SV_SPARE, FSTACK);
    run_word("RAND", 1, a);
    check(m16(XS_SEED) == 999, "999 RAND: seed 999");
  }
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("Floating point, typed into the ROM: FSQRT FSIN FCOS FTAN PI F< F> F0< F0= FABS\n");
  f0 = failures;
  {
    static const struct { const char *word; double (*fn)(double); const char *xs[16]; } t[] = {
      { "FSQRT", sqrt, { "2.", "9.", "1.E6", ".0001", "123.456", "1.E-20", "5.E30", "0.",
                         "50.", ".5", "1234.5", "7.E-11", NULL } },   /* odd and even exponents */
      { "FSIN", sin, { "0.", ".5", "1.5708", "2.", "3.14159", "4.", "-1.", "-4.", "10.", "1000.", NULL } },
      { "FCOS", cos, { "0.", ".5", "1.", "2.", "3.14159", "-2.", "7.", NULL } },
      { "FTAN", tan, { "0.", ".5", "1.", "-1.", "3.", NULL } },
    };
    for (int w = 0; w < 4; w++) {
      char text[2000] = "1 TURBO\n", line[80];
      for (int k = 0; t[w].xs[k]; k++) {
        snprintf(line, sizeof line, "%s %s F.\n", t[w].xs[k], t[w].word);
        strcat(text, line);
      }
      session(text);
      char all[24 * 32 + 1];
      for (int y = 0; y < 24; y++) memcpy(all + 32 * y, scr_text[y], 32);
      all[24 * 32] = 0;
      for (int k = 0; t[w].xs[k]; k++) {
        char key[80], msg[200];
        snprintf(key, sizeof key, "%s %s F. ", t[w].xs[k], t[w].word);
        char *p = strstr(all, key);
        double x = atof(t[w].xs[k]), got = 0, want = t[w].fn(x);
        int ok = p && sscanf(p + strlen(key), "%lf", &got) == 1;
        double tol = w == 0 ? 6e-6 * want + 1e-30 : 4e-5 + 1e-5 * fabs(x) + (w == 3 ? 4e-5 * want * want : 0);
        ok = ok && fabs(got - want) <= tol;
        snprintf(msg, sizeof msg, "%s %s = %.7g (C: %.7g)", t[w].xs[k], t[w].word, got, want);
        check(ok, msg);
        if (getenv("FSHOW")) printf("    %s\n", msg);
        if (!ok) session_ok = 0;
      }
      if (!session_ok) show_screen();
    }
  }
  session("1 TURBO\n"
          "PI F. -2.5 FABS F. 2.5 FABS F.\n"
          "1. 2. F< . 2. 1. F< . 1. 2. F> . 2. 1. F> .\n"
          "-.5 F0< . .5 F0< . 0. F0< . 0. F0= . 1.E-30 F0= .\n");
  sees("PI F. 3.14159 -2.5 FABS F. 2.5 2.5 FABS F. 2.5  OK", "PI, FABS");
  sees("F< . 1 2. 1. F< . 0 1. 2. F> . 0 2. 1. F> . 1  OK", "F< F>: f1 < f2, f1 > f2");
  sees("F0< . 1 .5 F0< . 0 0. F0< . 0 0. F0= . 1 1.E-30 F0= . 0  OK", "F0< F0=");
  if (!session_ok) show_screen();
  session("1 TURBO\n-4. FSQRT\n");
  sees("ERROR 8", "FSQRT of a negative number: ERROR 8");
  if (!session_ok) show_screen();
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("CASE OF ENDOF ENDCASE, typed into the ROM, and LIST\n");
  f0 = failures;
  session("1 TURBO\n"
          ": T CASE 1 OF 11 ENDOF 2 OF 22 ENDOF 99 SWAP ENDCASE ;\n"
          "1 T . 2 T . 3 T . DEPTH .\n"
          ": N CASE 1 OF 2 CASE 2 OF 12 ENDOF 0 SWAP ENDCASE ENDOF 0 SWAP ENDCASE ;\n"
          "1 N . 5 N . DEPTH .\n"
          ": E CASE ENDCASE ; 5 E DEPTH .\n");
  sees("1 T . 11 2 T . 22 3 T . 99 DEPTH . 0  OK", "CASE: the matching OF, the default, stack balanced");
  sees("1 N . 12 5 N . 0 DEPTH . 0  OK", "CASE nested in an OF");
  sees("5 E DEPTH . 0  OK", "an empty CASE ENDCASE drops x");
  if (!session_ok) show_screen();
  session("1 TURBO\n"
          ": T CASE 1 OF 11 ENDOF 2 OF 22 ENDOF 99 SWAP ENDCASE ;\n"
          "CLS LIST T\n");
  sees(": T", "LIST T: the definition is listed");
  sees("CASE", "LIST shows CASE");
  sees("1 OF", "LIST shows OF");
  sees("11 ENDOF", "LIST shows ENDOF");
  sees("ENDCASE", "LIST shows ENDCASE");
  if (!session_ok) show_screen();
  session("1 TURBO\n: B 1 OF ;\n");
  sees("ERROR 5", "OF without CASE: ERROR 5");
  if (!session_ok) show_screen();
  session("1 TURBO\n: B CASE 1 OF ENDCASE ;\n");
  sees("ERROR 5", "ENDCASE with an open OF: ERROR 5");
  if (!session_ok) show_screen();
  session("1 TURBO\n' NOSUCH\n");
  sees("ERROR 13", "' of an unknown word: ERROR 13");
  if (!session_ok) show_screen();
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

static void load(const char *path, unsigned char *dst, size_t n)
{
  FILE *fp = fopen(path, "rb");
  if (!fp || fread(dst, 1, n, fp) != n) { fprintf(stderr, "cannot read %s\n", path); exit(2); }
  fclose(fp);
}

extern unsigned long prof[65536];
extern int profiling;

/* ---- -1 TURBO keeps the card, -2 TURBO is the pure stock Ace: Forth sessions with
   the real ROM and the real SD firmware on a FAT RAM disk -------------------------- */
static void test_turbo_card(void)
{
  int f0 = failures;
  static unsigned char buf[4096];
  char msg[200];
  printf("TURBO and the card: SD words in 0 TURBO, -1 TURBO keeps the tape, -2 TURBO stock\n");
  ramdisk_format();
  fpga_reset();
  fw_on = 1;
  rom_writes = 0;

  /* 0 TURBO (power-up): the SD words are there; SAVE writes HI.TAP */
  session("1 SDTAPE\n: HI 4242 . ;\nSAVE HI\nDIR\n");
  long n1 = card_file("/programs/HI.tap", buf, sizeof buf);
  snprintf(msg, sizeof msg, "0 TURBO: 1 SDTAPE, SAVE HI writes /programs/HI.tap (%ld bytes)", n1);
  check(n1 > 30, msg);
  sees("HI.tap", "0 TURBO: DIR lists it");
  if (!session_ok) show_screen();

  /* -1 TURBO: TAPE chosen before; LOAD and SAVE use it; the SD words are gone */
  session("TAPE HI\n-1 TURBO\nLOAD HI\nHI\n: YO 77 . ;\nSAVE YO\n\n");
  sees("4242", "-1 TURBO: LOAD HI from the tape chosen before, and HI runs");
  sees("SAVE YO  OK", "-1 TURBO: SAVE YO");
  if (!session_ok) show_screen();
  check(rompage == 1 && creg[7] == 10, "-1 TURBO: ROM page 1 (stock + tape hooks), XCFG MIRROR + KEEP");
  check(m16(SV_FLINK) == 0x1FFF, "-1 TURBO: the FORTH link is the stock $1FFF");
  long n2 = card_file("/programs/HI.tap", buf, sizeof buf);
  int has_yo = 0;
  for (long k = 0; k + 2 <= n2; k++) if (buf[k] == 'Y' && buf[k + 1] == 'O') has_yo = 1;
  snprintf(msg, sizeof msg, "-1 TURBO: SAVE YO appended to HI.tap (%ld -> %ld bytes)", n1, n2);
  check(n2 > n1 && has_yo, msg);

  session("-1 TURBO\nDIR\n\n");
  sees("?DIR", "-1 TURBO: DIR is not a word (stock words only)");
  if (!session_ok) show_screen();

  /* -2 TURBO: page 0, the whole mirror, no card */
  session("TAPE HI\n-2 TURBO\n: ZZ 55 . ;\nZZ\n");
  sees("55", "-2 TURBO: the stock Ace runs Forth");
  check(rompage == 0 && creg[7] == 2, "-2 TURBO: ROM page 0 (byte-identical stock), XCFG MIRROR");
  creg[7] = 0;
  fw_on = 0;
  allow_ctrl = 0;
  rompage = 2;
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");
}

int main(int argc, char **argv)
{
  if (getenv("PROFILE")) {             /* PROFILE=1: T-states per address, PAINT noise */
    for (int k = 0; k < 256; k++) partable[k] = __builtin_parity(k) ? 0 : 4;
    load(argc > 1 ? argv[1] : "../rom/build/turboace.rom", rom[0], sizeof rom);
    mem[SV_SPARE] = FSTACK & 255; mem[SV_SPARE + 1] = FSTACK >> 8;
    mem[XS_WORKPG] = WORKPG;
    srand(7);
    setup_screen(0);
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) put_both(x, y, rand() % 100 < 28);
    put_both(128, 96, 0);
    profiling = 1;
    fpush(128); fpush(96);
    z80_call(HPAINT);
    FILE *fp = fopen("profile.txt", "w");
    for (int a = 0; a < 65536; a++) if (prof[a]) fprintf(fp, "%04X %lu\n", a, prof[a]);
    fclose(fp);
    return 0;
  }
  const char *romfile = argc > 1 ? argv[1] : "../rom/build/turboace.rom";
  for (int k = 0; k < 256; k++) partable[k] = __builtin_parity(k) ? 0 : 4;
  load(romfile, rom[0], sizeof rom);
  memset(mem + 0x2000, 0, 0xA000);
  mem[SV_SPARE] = FSTACK & 255;
  mem[SV_SPARE + 1] = FSTACK >> 8;
  mem[XS_WORKPG] = WORKPG;
  srand(1);

  int x, y, f0 = failures;

  printf("DRAW: every octant and axis from the centre\n");
  static const int deltas[][2] = {
    {0,0}, {100,0}, {-100,0}, {0,80}, {0,-80}, {90,90}, {-90,-90}, {90,-90}, {-90,90},
    {100,37}, {37,91}, {-37,91}, {-100,37}, {-100,-37}, {-37,-91}, {37,-91}, {100,-37},
    {1,0}, {0,1}, {1,1}, {2,1}, {127,95}, {-128,-96}, {127,-96}};
  for (size_t k = 0; k < sizeof deltas / sizeof deltas[0]; k++) {
    set_gflags(0, 0);
    setup_screen(0);
    x = 128; y = 96;
    do_draw(deltas[k][0], deltas[k][1], &x, &y);
    geo_line(128, 96, deltas[k][0], deltas[k][1]);
  }
  setup_screen(0);
  x = 0; y = 0;
  do_draw(255, 191, &x, &y);
  geo_line(0, 0, 255, 191);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("DRAW: clipping and clamped end position\n");
  f0 = failures;
  static const int clip[][4] = {
    {10,10,400,300}, {250,5,-600,20}, {5,180,30,-500}, {128,96,1000,-1000},
    {0,0,-50,-50}, {255,191,300,1}, {100,100,-32000,15000}};
  for (size_t k = 0; k < sizeof clip / sizeof clip[0]; k++) {
    setup_screen(0);
    x = clip[k][0]; y = clip[k][1];
    do_draw(clip[k][2], clip[k][3], &x, &y);
  }
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("DRAW: 300 chained random lines, all four INVERSE/FLIP modes\n");
  f0 = failures;
  setup_screen(0);
  x = 128; y = 96;
  for (int k = 0; k < 300; k++) {
    set_gflags(rand() % 4 == 0, rand() % 3 == 0);
    do_draw(rand() % 601 - 300, rand() % 451 - 225, &x, &y);
  }
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("DRAW: INVERSE erases, FLIP twice restores, INVERSE+FLIP only moves\n");
  f0 = failures;
  setup_screen(0xFF);
  set_gflags(1, 0);
  x = 20; y = 20;
  do_draw(200, 150, &x, &y);
  check(count_pixels(scr) == 256L * 192 - 200, "INVERSE line clears 200 pixels");
  setup_screen(0x55);
  set_gflags(0, 1);
  x = 30; y = 40; do_draw(150, -30, &x, &y);
  x = 30; y = 40; do_draw(150, -30, &x, &y);
  {
    int restored = 1;
    for (int k = 0; k < 0x1800; k++) if (scr[k] != 0x55) restored = 0;
    check(restored, "FLIP line drawn twice restores the bitmap");
  }
  setup_screen(0);
  set_gflags(1, 1);
  x = 10; y = 10; do_draw(50, 60, &x, &y);
  check(count_pixels(scr) == 0 && scr[0x1800] == 0,
        "INVERSE+FLIP draws nothing, colour untouched");
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("CIRCLE: radii 0-96 and beyond, centre and edges\n");
  f0 = failures;
  static const int circ[][3] = {
    {128,96,0}, {128,96,1}, {128,96,2}, {128,96,3}, {128,96,4}, {128,96,5},
    {128,96,7}, {128,96,10}, {128,96,33}, {128,96,50}, {128,96,95},
    {100,90,90}, {0,0,40}, {255,191,60}, {128,96,150}, {128,96,400}, {-20,96,60},
    {128,96,-5}};
  for (size_t k = 0; k < sizeof circ / sizeof circ[0]; k++) {
    set_gflags(0, 0);
    setup_screen(0);
    do_circle(circ[k][0], circ[k][1], circ[k][2]);
    int cx = circ[k][0], cy = circ[k][1], r = circ[k][2];
    if (r >= 0 && cx - r >= 0 && cx + r < W && cy - r >= 0 && cy + r < H)
      geo_circle(cx, cy, r);
    if (r < 0) check(count_pixels(scr) == 0, "CIRCLE r < 0 draws nothing");
  }
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("CIRCLE: each pixel drawn once (FLIP count = plot count), INVERSE erases\n");
  f0 = failures;
  for (int r = 1; r <= 90; r += 7) {
    char msg[96];
    set_gflags(0, 0); setup_screen(0); do_circle(128, 96, r);
    long plain = count_pixels(scr);
    ref_pixels = 0;
    set_gflags(0, 1); setup_screen(0); do_circle(128, 96, r);
    snprintf(msg, sizeof msg, "CIRCLE r %d: FLIP %ld pixels = plot %ld = PIXEL calls %ld",
             r, count_pixels(scr), plain, ref_pixels);
    check(count_pixels(scr) == plain && plain == ref_pixels, msg);
    set_gflags(1, 0); setup_screen(0xFF); do_circle(128, 96, r);
    snprintf(msg, sizeof msg, "CIRCLE r %d: INVERSE clears exactly those pixels", r);
    check(count_pixels(scr) == 256L * 192 - plain, msg);
  }
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("CIRCLE: 100 random circles on one screen, random modes\n");
  f0 = failures;
  setup_screen(0);
  for (int k = 0; k < 100; k++) {
    set_gflags(rand() % 4 == 0, rand() % 3 == 0);
    do_circle(rand() % 320 - 32, rand() % 256 - 32, rand() % 140);
  }
  set_gflags(0, 0);
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  printf("ATTR (hi-res): colour byte of the 8x1 cell, 0 off screen\n");
  f0 = failures;
  setup_screen(0);
  for (int k = 0; k < 0x1800; k++) scr[0x1800 + k] = (unsigned char)(k * 13 + 5);
  memcpy(ref, scr, sizeof ref);
  for (int k = 0; k < 400; k++) {
    int ax = rand() % 300 - 20, ay = rand() % 240 - 20;
    if (k < 4) { ax = k & 1 ? 255 : 0; ay = k & 2 ? 191 : 0; }
    char name[64], msg[96];
    snprintf(name, sizeof name, "ATTR %d,%d", ax, ay);
    fpush(ax); fpush(ay);
    run(name, HATTR, 1);                /* two in, one out */
    unsigned short p = fsp() - 2;
    int got = mem[p] | mem[p + 1] << 8, want = 0;
    if (ax >= 0 && ax < W && ay >= 0 && ay < H)
      want = scr[0x1800 + (191 - ay) * 32 + (ax >> 3)];
    snprintf(msg, sizeof msg, "%s = %d (want %d)", name, got, want);
    check(got == want, msg);
    mem[SV_SPARE] = FSTACK & 255;       /* drop the result */
    mem[SV_SPARE + 1] = FSTACK >> 8;
  }
  compare("ATTR leaves the work page unchanged");
  printf("  %s\n", failures == f0 ? "ok" : "FAILED");

  if (getenv("SESSION")) {               /* SESSION="text": one Forth session, card on (debug) */
    ramdisk_format(); fpga_reset(); fw_on = 1; rom_writes = 0;
    if (getenv("SESSION0")) session(getenv("SESSION0"));   /* an earlier session, same card */
    rom_writes = 0;
    session(getenv("SESSION"));
    show_screen();
    printf("rompage %d XCFG %d rom_writes %ld sysvars", rompage, creg[7], rom_writes);
    for (int k = 0x3C37; k <= 0x3C3E; k++) printf(" %02X", mem[k]);
    printf("\n");
    return 0;
  }
  test_arcs();
  test_paint();
  test_turbo();
  test_words();
  test_tape_hooks();
  test_tape_sd();
  test_sd_words();
  test_sd_dir();
  test_sd_pages();
  test_sd_font();
  test_firmware();
  test_keyboard_rom();
  test_forth_words();
  test_turbo_card();

  printf("%d checks, %s\n", checks,
         failures ? "FAILED" : "all passed");
  if (failures) printf("%d failure(s)\n", failures);
  return failures ? 1 : 0;
}
