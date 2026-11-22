/* The FPGA mailbox on a PC (host_fpga.c): the Z80's side of $E5 / $E7. */
#ifndef HOST_FPGA_H
#define HOST_FPGA_H

void fpga_reset(void);          /* power-up: empty FIFOs, firmware started */
void z80_out(int port, int v);  /* OUT ($E5) or OUT ($E7) */
int  z80_in(int port);          /* IN ($E5) or IN ($E7) */
extern long fpga_overflows;

/* the RAM disk (diskio_ram.c) */
void ramdisk_format(void);      /* a fresh, formatted card */
void ramdisk_present(int on);   /* card in the slot or not */

#endif
