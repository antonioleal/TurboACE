/* Interface of the harness CPU loop (z80core.c). */
#define STOP_ADDR 0x7000
#define IX_SENT   0x1234
#define IY_SENT   0x04C8
#define LIMIT     50000000L

struct zregs {                          /* register file, in or out of a call */
  unsigned short AF, BC, DE, HL, AF1, BC1, DE1, HL1, IX, IY, SP;
  int IFF1;
};
struct result { int carry, a, ix_ok, iy_ok, sp_ok, timeout; unsigned short pc; struct zregs r; };
extern struct zregs zin;                 /* start registers when zin_valid (SP stays ZSTACK) */
extern int zin_valid;
extern unsigned short call_ret;
extern int trap_rst8;                    /* RST $08 (print A) is captured, not run */
extern char printed[8192];
extern int nprinted;          /* return address pushed by z80_call (0 = STOP_ADDR) */
extern unsigned short stop_at[4];       /* extra addresses that end a call (0 = unused) */
struct result z80_call(unsigned short entry);   /* RET to STOP_ADDR ends it */
extern unsigned long irq_period;         /* T-states between IM 1 interrupts (0 = none) */
extern int (*stop_hook)(unsigned short pc);   /* non-zero ends the call (NULL = unused) */
extern long zlimit;                      /* instructions before a call times out */
unsigned char rd(unsigned short a);
void wr(unsigned short a, unsigned char v);
extern unsigned char partable[256];
