/*
 * The FPGA mailbox on a PC: hal.h for the firmware, and the Z80's side of
 * ports $E5 / $E7 (host_fpga.h) for the tests. Behaves as register-map.md 2.7
 * says the FPGA does; the firmware runs whenever an event is raised, as the
 * soft CPU would react to it.
 */
#include <string.h>
#include "hal.h"
#include "sdproto.h"
#include "host_fpga.h"

static uint8_t  argq[FIFO_SIZE], resq[FIFO_SIZE];
static unsigned arg_head, arg_n, res_head, res_n;
static unsigned events, cmd, xfer, status;
static int      busy;
long            fpga_overflows;         /* FIFO overruns: always a bug */

static void run_firmware(void)
{
    while (events) {
        unsigned ev = events;
        events = 0;
        if (ev & EV_CMD) {
            sdp_command();
        } else if (ev & EV_XFER) {
            sdp_xfer();
        }
    }
}

/* ---- the firmware's side ---- */
unsigned hal_events(void) { unsigned e = events; events = 0; return e; }
int  hal_command(void)    { return (int) cmd; }
int  hal_arg_count(void)  { return (int) arg_n; }
void hal_arg_clear(void)  { arg_n = 0; }
void hal_res_clear(void)  { res_n = 0; }
void hal_xfer(unsigned n) { xfer = n; }
void hal_ready(unsigned st) { status = st; busy = 0; }

int hal_arg_pop(void)
{
    if (!arg_n) return -1;
    int v = argq[arg_head];
    arg_head = (arg_head + 1) % FIFO_SIZE;
    arg_n--;
    return v;
}

void hal_res_push(int b)
{
    if (res_n == FIFO_SIZE) { fpga_overflows++; return; }
    resq[(res_head + res_n++) % FIFO_SIZE] = (uint8_t) b;
}

/* SPI: not used on the PC (diskio_ram.c stands in for the card) */
uint8_t  hal_spi(uint8_t out) { return out; }
void     hal_spi_select(int on) { (void) on; }
void     hal_spi_fast(int on) { (void) on; }
uint32_t hal_ms(void) { static uint32_t t; return t++; }

/* ---- the Z80's side ---- */
static void count_access(void)
{
    if (xfer && !--xfer) {
        busy = 1;
        events |= EV_XFER;
        run_firmware();
    }
}

void fpga_reset(void)
{
    arg_head = arg_n = res_head = res_n = 0;
    events = cmd = xfer = 0;
    busy = 0;
    sdp_init();
}

void z80_out(int port, int v)
{
    if (port == 0xE5) {
        cmd = (unsigned) v & 0xFF;
        res_n = 0;                      /* unread results are dropped */
        xfer = 0;
        busy = 1;
        events |= EV_CMD;
        run_firmware();
    } else if (port == 0xE7) {
        if (arg_n == FIFO_SIZE) { fpga_overflows++; return; }
        argq[(arg_head + arg_n++) % FIFO_SIZE] = (uint8_t) v;
        count_access();
    }
}

int z80_in(int port)
{
    if (port == 0xE5) {
        return (busy ? 0x80 : 0) | (status & (ST_ERROR | ST_CARD | ST_TAPE)) | (res_n ? 1 : 0);
    }
    if (port == 0xE7) {
        int v = 0xFF;
        if (res_n) {
            v = resq[res_head];
            res_head = (res_head + 1) % FIFO_SIZE;
            res_n--;
        }
        count_access();
        return v;
    }
    return 0xFF;
}
