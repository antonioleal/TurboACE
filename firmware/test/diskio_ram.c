/* FatFs disk I/O on a RAM disk, for the PC tests. */
#include <string.h>
#include <stdlib.h>
#include "ff.h"
#include "diskio.h"
#include "host_fpga.h"

#define SECTORS (32 * 2048)             /* 32 MB */
static unsigned char *disk;
static int present = 1;

DSTATUS disk_initialize(BYTE pdrv) { return pdrv || !present ? STA_NOINIT : 0; }
DSTATUS disk_status(BYTE pdrv)     { return pdrv || !present ? STA_NOINIT : 0; }

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv || !present) return RES_NOTRDY;
    if (sector + count > SECTORS) return RES_PARERR;
    memcpy(buff, disk + (size_t) sector * 512, (size_t) count * 512);
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv || !present) return RES_NOTRDY;
    if (sector + count > SECTORS) return RES_PARERR;
    memcpy(disk + (size_t) sector * 512, buff, (size_t) count * 512);
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    if (pdrv || !present) return RES_NOTRDY;
    switch (cmd) {
    case CTRL_SYNC:        return RES_OK;
    case GET_SECTOR_COUNT: *(LBA_t *) buff = SECTORS; return RES_OK;
    case GET_SECTOR_SIZE:  *(WORD *) buff = 512; return RES_OK;
    case GET_BLOCK_SIZE:   *(DWORD *) buff = 1; return RES_OK;
    }
    return RES_PARERR;
}

void ramdisk_format(void)
{
    static unsigned char work[FF_MAX_SS * 8];
    if (!disk) disk = malloc((size_t) SECTORS * 512);
    memset(disk, 0, (size_t) SECTORS * 512);
    present = 1;
    MKFS_PARM opt = { FM_ANY | FM_SFD, 0, 0, 0, 0 };   /* FAT16 at this size */
    if (f_mkfs("", &opt, work, sizeof work) != FR_OK) abort();
}

void ramdisk_present(int on) { present = on; }
