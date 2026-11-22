/*
 * TurboACE SD soft CPU: FatFs disk I/O for an SD card in SPI mode.
 * SD v1, SD v2 (SDSC and SDHC/SDXC) and MMC. One sector per command.
 * Not yet run on hardware: it follows the SD Physical Layer specification's
 * SPI mode (CMD0, CMD8, ACMD41, CMD58, CMD16, CMD17, CMD24, CMD9).
 */
#include "ff.h"
#include "diskio.h"
#include "hal.h"

#define CMD0   0            /* GO_IDLE_STATE */
#define CMD1   1            /* SEND_OP_COND (MMC) */
#define CMD8   8            /* SEND_IF_COND */
#define CMD9   9            /* SEND_CSD */
#define CMD12  12
#define CMD16  16           /* SET_BLOCKLEN */
#define CMD17  17           /* READ_SINGLE_BLOCK */
#define CMD24  24           /* WRITE_BLOCK */
#define CMD55  55           /* APP_CMD */
#define CMD58  58           /* READ_OCR */
#define ACMD41 (0x80 | 41)  /* SD_SEND_OP_COND */

static DSTATUS status = STA_NOINIT;
static int block_addr;      /* SDHC/SDXC: sector numbers, else byte addresses */

static int wait_ready(uint32_t ms)
{
    uint32_t t = hal_ms();
    do {
        if (hal_spi(0xFF) == 0xFF) {
            return 1;
        }
    } while (hal_ms() - t < ms);
    return 0;
}

static void deselect(void)
{
    hal_spi_select(0);
    hal_spi(0xFF);          /* the card lets go of MISO */
}

static int select_card(void)
{
    hal_spi_select(1);
    hal_spi(0xFF);
    if (wait_ready(500)) {
        return 1;
    }
    deselect();
    return 0;
}

static uint8_t send_cmd(uint8_t cmd, uint32_t arg)
{
    if (cmd & 0x80) {       /* ACMDn = CMD55 then CMDn */
        uint8_t r = send_cmd(CMD55, 0);
        if (r > 1) {
            return r;
        }
        cmd &= 0x7F;
    }
    deselect();
    if (!select_card()) {
        return 0xFF;
    }
    hal_spi(0x40 | cmd);
    hal_spi(arg >> 24);
    hal_spi(arg >> 16);
    hal_spi(arg >> 8);
    hal_spi(arg);
    hal_spi(cmd == CMD0 ? 0x95 : cmd == CMD8 ? 0x87 : 0x01);   /* CRC where it counts */
    uint8_t r;
    int n = 10;
    do {
        r = hal_spi(0xFF);
    } while ((r & 0x80) && --n);
    return r;
}

static int receive(uint8_t *buf, unsigned n)
{
    uint32_t t = hal_ms();
    uint8_t token;
    do {
        token = hal_spi(0xFF);
    } while (token == 0xFF && hal_ms() - t < 200);
    if (token != 0xFE) {
        return 0;
    }
    for (unsigned i = 0; i < n; i++) {
        buf[i] = hal_spi(0xFF);
    }
    hal_spi(0xFF);          /* CRC, not checked */
    hal_spi(0xFF);
    return 1;
}

DSTATUS disk_initialize(BYTE pdrv)
{
    if (pdrv) {
        return STA_NOINIT;
    }
    hal_spi_fast(0);
    hal_spi_select(0);
    for (int i = 0; i < 10; i++) {
        hal_spi(0xFF);      /* 80 clocks with CS high */
    }
    status = STA_NOINIT;
    int type = 0;           /* 1 MMC, 2 SD v1, 4 SD v2, 8 block addressing */
    if (send_cmd(CMD0, 0) == 1) {
        uint32_t t = hal_ms();
        if (send_cmd(CMD8, 0x1AA) == 1) {
            uint8_t ocr[4];
            for (int i = 0; i < 4; i++) ocr[i] = hal_spi(0xFF);
            if (ocr[2] == 0x01 && ocr[3] == 0xAA) {             /* 2.7-3.6 V */
                while (hal_ms() - t < 1000 && send_cmd(ACMD41, 1UL << 30)) {
                }
                if (hal_ms() - t < 1000 && send_cmd(CMD58, 0) == 0) {
                    for (int i = 0; i < 4; i++) ocr[i] = hal_spi(0xFF);
                    type = ocr[0] & 0x40 ? 4 | 8 : 4;
                }
            }
        } else {
            uint8_t cmd;
            if (send_cmd(ACMD41, 0) <= 1) { type = 2; cmd = ACMD41; }
            else                          { type = 1; cmd = CMD1; }
            while (hal_ms() - t < 1000 && send_cmd(cmd, 0)) {
            }
            if (hal_ms() - t >= 1000 || send_cmd(CMD16, 512) != 0) {
                type = 0;
            }
        }
    }
    deselect();
    if (type) {
        block_addr = type & 8;
        hal_spi_fast(1);
        status = 0;
    }
    return status;
}

DSTATUS disk_status(BYTE pdrv)
{
    return pdrv ? STA_NOINIT : status;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv || !count) return RES_PARERR;
    if (status & STA_NOINIT) return RES_NOTRDY;
    for (; count; count--, sector++, buff += 512) {
        if (send_cmd(CMD17, block_addr ? sector : sector * 512) != 0 || !receive(buff, 512)) {
            deselect();
            return RES_ERROR;
        }
    }
    deselect();
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv || !count) return RES_PARERR;
    if (status & STA_NOINIT) return RES_NOTRDY;
    for (; count; count--, sector++, buff += 512) {
        if (send_cmd(CMD24, block_addr ? sector : sector * 512) != 0) {
            deselect();
            return RES_ERROR;
        }
        hal_spi(0xFF);
        hal_spi(0xFE);                  /* data token */
        for (int i = 0; i < 512; i++) hal_spi(buff[i]);
        hal_spi(0xFF);                  /* CRC */
        hal_spi(0xFF);
        if ((hal_spi(0xFF) & 0x1F) != 0x05 || !wait_ready(500)) {
            deselect();
            return RES_ERROR;
        }
    }
    deselect();
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    if (pdrv) return RES_PARERR;
    if (status & STA_NOINIT) return RES_NOTRDY;
    switch (cmd) {
    case CTRL_SYNC: {
        int ok = select_card();
        deselect();
        return ok ? RES_OK : RES_ERROR;
    }
    case GET_SECTOR_COUNT: {
        uint8_t csd[16];
        DRESULT r = RES_ERROR;
        if (send_cmd(CMD9, 0) == 0 && receive(csd, 16)) {
            if ((csd[0] >> 6) == 1) {   /* CSD 2.0 */
                DWORD c = ((DWORD) (csd[7] & 0x3F) << 16 | (DWORD) csd[8] << 8 | csd[9]) + 1;
                *(LBA_t *) buff = (LBA_t) c << 10;
            } else {                    /* CSD 1.0 */
                unsigned n = (csd[5] & 15) + ((csd[10] & 128) >> 7) + ((csd[9] & 3) << 1) + 2;
                DWORD c = (csd[8] >> 6) + ((DWORD) csd[7] << 2) + ((DWORD) (csd[6] & 3) << 10) + 1;
                *(LBA_t *) buff = (LBA_t) c << (n - 9);
            }
            r = RES_OK;
        }
        deselect();
        return r;
    }
    case GET_SECTOR_SIZE:
        *(WORD *) buff = 512;
        return RES_OK;
    case GET_BLOCK_SIZE:
        *(DWORD *) buff = 1;            /* not known */
        return RES_OK;
    default:
        return RES_PARERR;
    }
}
