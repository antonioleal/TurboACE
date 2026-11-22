/* TurboACE SD soft CPU: the $E5/$E7 protocol engine (sdproto.c). */
#ifndef SDPROTO_H
#define SDPROTO_H

#include "ff.h"

extern FATFS sdp_fs;        /* the card's FatFs work area, shared with power-up (main.c) */

void sdp_init(void);        /* at start: nothing open, BUSY clear */
void sdp_command(void);     /* on EV_CMD: the Z80 wrote a command */
void sdp_xfer(void);        /* on EV_XFER: a data-phase chunk has moved */

#endif
