/* TurboACE SD soft CPU: hal.h on the FPGA's registers. */
#include "hal.h"

#define REG(a) (*(volatile uint32_t *) (a))

unsigned hal_events(void)
{
    unsigned ev = REG(MB_EVENTS) & (EV_CMD | EV_XFER);
    REG(MB_EVENTS) = ev;
    return ev;
}

int  hal_command(void)      { return REG(MB_CMD) & 0xFF; }
int  hal_arg_count(void)    { return (int) REG(MB_ARGCNT); }
void hal_arg_clear(void)    { REG(MB_ARGCLR) = 1; }
void hal_res_push(int b)    { REG(MB_RES) = (uint32_t) b & 0xFF; }
void hal_res_clear(void)    { REG(MB_RESCLR) = 1; }
void hal_xfer(unsigned n)   { REG(MB_XFER) = n; }
void hal_ready(unsigned st) { REG(MB_STATUS) = st & (ST_ERROR | ST_CARD | ST_TAPE); }

int hal_arg_pop(void)
{
    uint32_t v = REG(MB_ARG);
    return v & 0x100 ? -1 : (int) (v & 0xFF);
}

static uint32_t spi_ctrl;

uint8_t hal_spi(uint8_t out)
{
    REG(SPI_DATA) = out;
    while (REG(SPI_STAT) & 1) {
    }
    return (uint8_t) REG(SPI_DATA);
}

void hal_spi_select(int on)
{
    spi_ctrl = on ? spi_ctrl | 1 : spi_ctrl & ~1u;
    REG(SPI_CTRL) = spi_ctrl;
}

void hal_spi_fast(int on)
{
    spi_ctrl = on ? spi_ctrl | 2 : spi_ctrl & ~2u;
    REG(SPI_CTRL) = spi_ctrl;
}

uint32_t hal_ms(void) { return REG(TIMER_MS); }

int hal_kbd_byte(void)
{
    uint32_t v = REG(KBD_DATA);
    return v & 0x100 ? -1 : (int) (v & 0xFF);
}

int hal_kbd_send(int b)
{
    if (REG(KBD_SEND) & 0x100) return 0;
    REG(KBD_SEND) = (uint32_t) b & 0xFF;
    return 1;
}

void hal_kbd_rows(const uint8_t r[8])
{
    REG(KBD_ROWS03) = r[0] | r[1] << 8 | r[2] << 16 | (uint32_t) r[3] << 24;
    REG(KBD_ROWS47) = r[4] | r[5] << 8 | r[6] << 16 | (uint32_t) r[7] << 24;
}

static uint32_t sys_ctrl = 1;           /* the Z80 is held in reset at power-up */

void hal_z80_reset(int on)
{
    sys_ctrl = on ? sys_ctrl | 1 : sys_ctrl & ~1u;
    REG(SYS_CTRL) = sys_ctrl;
}

void hal_rom_ready(int on)
{
    sys_ctrl = on ? sys_ctrl | 2 : sys_ctrl & ~2u;
    REG(SYS_CTRL) = sys_ctrl;
}

int hal_standalone(void) { return REG(SYS_INFO) & 1; }

void hal_rom_write(unsigned page, unsigned offset, const uint8_t *p, unsigned n)
{
    REG(ROM_ADDR) = page * 8192 + offset;
    while (n--) REG(ROM_DATA) = *p++;
}

int hal_flash_open(unsigned page)
{
    REG(FLASH_ADDR) = FLASH_ROM + (page - 2) * (8192 + 8);
    uint8_t tag[8];
    for (int i = 0; i < 8; i++) tag[i] = (uint8_t) REG(FLASH_DATA);
    return tag[0] == 'T' && tag[1] == 'A' && tag[2] == 'C' && tag[3] == 'E' && tag[4] == page;
}

void hal_flash_read(uint8_t *p, unsigned n)
{
    while (n--) *p++ = (uint8_t) REG(FLASH_DATA);
}

void hal_screen_write(unsigned offset, int c)
{
    REG(SCREEN_ADDR) = offset;
    REG(SCREEN_DATA) = (uint32_t) c;
}
