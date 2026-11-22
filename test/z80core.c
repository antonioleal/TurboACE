/* CPU loop for the TurboACE test harness: Ian Collier's xz80 instruction set
 * (Jupiter-IIb src/z80ops.c, GPL v2+), compiled in from the Jupiter-IIb tree.
 * Kept in its own file because z80ops.c defines short macros (cy, hl, ...). */
#include <stdio.h>
#include "z80core.h"

extern unsigned long tstates;
extern int ram_paging, ram_latch_pending;
void ram_latch(unsigned char r);
unsigned int in(int h, int l);
unsigned int out(int h, int l, int a);
void save_dictionary_out_p(unsigned char c);
void spool_error_p(unsigned char c);
extern unsigned char mem[65536];

/* memory macros expected by z80ops.c */
#define fetch(x)          rd((unsigned short)(x))
#define fetch2(x)         ((fetch((x) + 1) << 8) | fetch(x))
#define store(x, y)       wr((unsigned short)(x), (unsigned char)(y))
#define store2b(x, hi, lo) do { wr((unsigned short)(x), (lo)); \
                                wr((unsigned short)((x) + 1), (hi)); } while (0)
#define store2(x, y)      store2b(x, (y) >> 8, (y) & 255)
#define bc ((b << 8) | c)
#define de ((d << 8) | e)
#define hl ((h << 8) | l)
#define parity(a) (partable[a])
unsigned char partable[256];

#define ZSTACK   0x8000

/* constants the ED traps in edops.c use (values from Jupiter-IIb z80.h);
 * the traps themselves are stubs that count as errors */
#define TAPE_LOAD_ERROR (-1)
#define TAPE_LOAD_BREAK (-2)
#define ROM_TAPE_ERROR  0x1ab6
#define ROM_TAPE_BREAK  0x04f0
#define ROM_LOAD_HEADER_RETURN 0x1a81

unsigned short stop_at[4];
unsigned long irq_period;               /* the Ace: 65000 (3.25 MHz / 50 Hz) */
static unsigned long irq_next;
static int irq_pending;
int (*stop_hook)(unsigned short pc);
unsigned short zpc_now;                 /* the instruction being run (debug) */
long zlimit = LIMIT;
struct zregs zin;
unsigned short call_ret;
int trap_rst8;
char printed[8192];
int nprinted;
int zin_valid;
unsigned long prof[65536];             /* T-states per instruction address */
int profiling;

struct result z80_call(unsigned short entry)
{
  unsigned char a = 0, f = 0, b = 0, c = 0, d = 0, e = 0, h = 0, l = 0;
  unsigned char r = 0, a1 = 0, f1 = 0, b1 = 0, c1 = 0, d1 = 0, e1 = 0, h1 = 0, l1 = 0;
  unsigned char i = 0, iff1 = 0, iff2 = 0, im = 2;
  unsigned short pc = entry, ix = IX_SENT, iy = IY_SENT, sp = ZSTACK;
  unsigned int radjust = 0;
  unsigned char ixoriy = 0, new_ixoriy = 0, intsample, halted = 0, op;
  struct result res = {0};
  long n = 0;
  if (zin_valid) {
    a = zin.AF >> 8; f = zin.AF; b = zin.BC >> 8; c = zin.BC; d = zin.DE >> 8; e = zin.DE;
    h = zin.HL >> 8; l = zin.HL; a1 = zin.AF1 >> 8; f1 = zin.AF1; b1 = zin.BC1 >> 8;
    c1 = zin.BC1; d1 = zin.DE1 >> 8; e1 = zin.DE1; h1 = zin.HL1 >> 8; l1 = zin.HL1;
    ix = zin.IX; iy = zin.IY; iff1 = iff2 = zin.IFF1;
  }
  sp -= 2;
  store2(sp, call_ret ? call_ret : STOP_ADDR);
  while ((pc != STOP_ADDR && (!call_ret || pc != call_ret)
          && (!pc || (pc != stop_at[0] && pc != stop_at[1] && pc != stop_at[2] && pc != stop_at[3])))
         || new_ixoriy) {
    if (++n > zlimit) { res.timeout = 1; break; }
    zpc_now = pc;
    if (stop_hook && !new_ixoriy && stop_hook(pc)) break;
    if (trap_rst8 && pc == 0x0008 && !new_ixoriy) {   /* print A, then RET */
      if (nprinted < (int)sizeof printed - 1) printed[nprinted++] = (char)a;
      printed[nprinted] = 0;
      pc = fetch2(sp);
      sp += 2;
      continue;
    }
    ixoriy = new_ixoriy;
    new_ixoriy = 0;
    intsample = 1;
    unsigned short pc0 = pc;
    unsigned long t0 = tstates;
    op = fetch(pc);
    pc++;
    radjust++;
    switch (op) {
#include "z80ops.c"
    }
    if (profiling) prof[pc0] += tstates - t0;
    /* the frame interrupt, IM 1 as on the Ace: held until interrupts are enabled,
       then RST $38 (13 T-states); a HALT returns to the next instruction */
    if (irq_period) {
      if (tstates >= irq_next) {
        irq_pending = 1;
        irq_next = tstates - tstates % irq_period + irq_period;
      }
      if (irq_pending && intsample && iff1 && !new_ixoriy) {
        if (halted) { pc++; halted = 0; }
        iff1 = iff2 = 0;
        push2(pc);
        pc = 0x38;
        tstates += 13;
        irq_pending = 0;
      }
    }
  }
  (void)r; (void)a1; (void)f1; (void)b1; (void)c1; (void)d1; (void)e1; (void)h1;
  (void)l1; (void)i; (void)iff1; (void)iff2; (void)im; (void)intsample; (void)halted;
  (void)radjust;
  res.pc = pc;
  res.r.AF = (a << 8) | f; res.r.BC = (b << 8) | c; res.r.DE = (d << 8) | e;
  res.r.HL = (h << 8) | l; res.r.AF1 = (a1 << 8) | f1; res.r.BC1 = (b1 << 8) | c1;
  res.r.DE1 = (d1 << 8) | e1; res.r.HL1 = (h1 << 8) | l1;
  res.r.IX = ix; res.r.IY = iy; res.r.SP = sp; res.r.IFF1 = iff1;
  res.carry = f & 1;
  res.a = a;
  res.ix_ok = ix == IX_SENT;
  res.iy_ok = iy == IY_SENT;
  res.sp_ok = sp == ZSTACK;
  return res;
}


