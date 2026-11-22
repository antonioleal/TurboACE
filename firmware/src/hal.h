/*
 * TurboACE SD soft CPU: the hardware it runs on (register-map.md section 2.7).
 *
 * The soft CPU sits inside the FPGA. It talks to the Z80 through a mailbox
 * behind ports $E5 (SDCMD) and $E7 (SDDATA), and to the card through an SPI
 * master. hal_fpga.c implements these functions with the registers below;
 * test/host_fpga.c implements them on a PC for the tests.
 *
 * Mailbox, as the FPGA behaves:
 *   - The Z80 writes argument bytes to $E7: they queue in the ARG FIFO.
 *   - The Z80 writes a command to $E5: the FPGA sets BUSY, empties the RES
 *     FIFO (unread results are dropped), stops any data-phase count, and
 *     raises EV_CMD.
 *   - The firmware reads the command and its arguments, pushes results into
 *     the RES FIFO (the Z80 reads them from $E7), and calls hal_ready(), which
 *     sets ERROR/CARD/TAPE and clears BUSY.
 *   - Data phase: before hal_ready() the firmware loads hal_xfer(n). The FPGA
 *     counts the Z80's $E7 accesses (reads or writes); when n is reached it
 *     sets BUSY itself and raises EV_XFER. So the Z80 can never see BUSY clear
 *     before the firmware has dealt with the chunk.
 *   - $E5 read: BUSY (b7), ERROR (b6), CARD (b5), TAPE (b4), DATA (b0: the RES
 *     FIFO is not empty; made by the FPGA).
 */
#ifndef HAL_H
#define HAL_H

#include <stdint.h>

/* ---- Register map (soft CPU addresses) ---------------------------------- */
#define MB_BASE      0x10000000u
#define MB_STATUS    (MB_BASE + 0x00)   /* W: b6 ERROR, b5 CARD, b4 TAPE; a write clears BUSY */
#define MB_EVENTS    (MB_BASE + 0x04)   /* R: b0 CMD, b1 XFER;  W: 1s clear them */
#define MB_CMD       (MB_BASE + 0x08)   /* R: the last command byte */
#define MB_ARG       (MB_BASE + 0x0C)   /* R: next ARG FIFO byte (b8 set: empty) */
#define MB_ARGCNT    (MB_BASE + 0x10)   /* R: bytes in the ARG FIFO */
#define MB_RES       (MB_BASE + 0x14)   /* W: push a byte to the RES FIFO */
#define MB_RESCLR    (MB_BASE + 0x18)   /* W: empty the RES FIFO */
#define MB_XFER      (MB_BASE + 0x1C)   /* W: $E7 accesses before BUSY and EV_XFER (0: off) */
#define MB_ARGCLR    (MB_BASE + 0x20)   /* W: empty the ARG FIFO */

#define SPI_BASE     0x20000000u
#define SPI_DATA     (SPI_BASE + 0x00)  /* W: send a byte (starts a transfer); R: byte received */
#define SPI_STAT     (SPI_BASE + 0x04)  /* R: b0 busy */
#define SPI_CTRL     (SPI_BASE + 0x08)  /* W: b0 card selected (CS low), b1 fast clock */

#define TIMER_MS     0x30000000u        /* R: milliseconds since reset */

/* standalone build only (decisions 24, 26) */
#define KBD_DATA     0x40000000u        /* R: next byte from the PS/2 keyboard (b8 set: none) */
#define KBD_SEND     0x40000004u        /* W: a byte to the keyboard (b8 R: sender busy) */
#define KBD_ROWS03   0x40000008u        /* W: Ace matrix rows 0-3, one per byte, bit set = pressed */
#define KBD_ROWS47   0x4000000Cu        /* W: rows 4-7 */
#define SYS_CTRL     0x40000010u        /* W: b0 hold the Z80 in reset (set at power-up),
                                           b1 ROM ready (the TurboACE ROM is served) */

/* both builds (decision 24) */
#define SYS_INFO     0x40000014u        /* R: b0 standalone build */
#define ROM_ADDR     0x50000000u        /* W: byte address in the 64K ROM (page * 8192 + offset) */
#define ROM_DATA     0x50000004u        /* W: a byte; ROM_ADDR then moves on */
#define FLASH_ADDR   0x50000008u        /* W: byte address in the board's flash */
#define FLASH_DATA   0x5000000Cu        /* R: a byte; FLASH_ADDR then moves on */
#define FLASH_ROM    0x00500000u        /* where the build puts ROM pages 2-7 (48K), with
                                           "TACE" + page number before each page */
#define SCREEN_ADDR  0x50000010u        /* W: offset in text page 0 (standalone messages) */
#define SCREEN_DATA  0x50000014u        /* W: a character; SCREEN_ADDR then moves on */

#define FIFO_SIZE    1024               /* ARG and RES FIFOs, bytes each */

/* ---- Status and events -------------------------------------------------- */
#define ST_ERROR     0x40
#define ST_CARD      0x20
#define ST_TAPE      0x10

#define EV_CMD       0x01
#define EV_XFER      0x02

/* ---- Mailbox ------------------------------------------------------------ */
unsigned hal_events(void);          /* pending events; they are cleared */
int  hal_command(void);             /* the last command byte */
int  hal_arg_count(void);
int  hal_arg_pop(void);             /* the next argument byte, or -1 */
void hal_arg_clear(void);
void hal_res_push(int b);
void hal_res_clear(void);
void hal_xfer(unsigned n);          /* the next data-phase chunk: n $E7 accesses */
void hal_ready(unsigned status);    /* ERROR/CARD/TAPE bits, and BUSY cleared */

/* ---- SD card over SPI --------------------------------------------------- */
uint8_t  hal_spi(uint8_t out);      /* one byte out and in */
void     hal_spi_select(int on);    /* chip select */
void     hal_spi_fast(int on);      /* about 400 kHz while starting, then fast */
uint32_t hal_ms(void);

/* ---- Standalone build: keyboard and Z80 reset --------------------------- */
int  hal_kbd_byte(void);            /* next byte from the keyboard, or -1 */
int  hal_kbd_send(int b);           /* 0 if the sender is busy */
void hal_kbd_rows(const uint8_t rows[8]);
void hal_z80_reset(int on);

/* ---- The ROM at power-up (romload.c) ------------------------------------ */
int  hal_standalone(void);
void hal_rom_ready(int on);
void hal_rom_write(unsigned page, unsigned offset, const uint8_t *p, unsigned n);
int  hal_flash_open(unsigned page);      /* 0: page missing; else hal_flash_read gives its 8K */
void hal_flash_read(uint8_t *p, unsigned n);
void hal_screen_write(unsigned offset, int c);

#endif
