/* TurboACE SD soft CPU: the main loop. */
#include "ff.h"
#include "hal.h"
#include "sdproto.h"
#include "keyboard.h"
#include "config.h"
#include "romload.h"

/* the settings file, if the card has one (the SD protocol mounts the card
 * itself later; this only reads). One FatFs work area serves all three. */
static void read_config(struct tconfig *cfg)
{
    static char text[512];
    FIL f;
    UINT got = 0;
    if (f_mount(&sdp_fs, "", 1) == FR_OK && f_open(&f, "/turboace.cfg", FA_READ) == FR_OK) {
        f_read(&f, text, sizeof text, &got);
        f_close(&f);
    }
    config_parse(text, got, cfg);
}

int main(void)
{
    struct tconfig cfg;
    rom_boot(&sdp_fs);              /* the Z80 runs from here on */
    read_config(&cfg);
    kbd_init(cfg.layout, cfg.mode);
    sdp_init();
    for (;;) {
        unsigned ev = hal_events();
        if (ev & EV_CMD) {          /* a new command ends any data phase */
            sdp_command();
        } else if (ev & EV_XFER) {
            sdp_xfer();
        }
        int b = hal_kbd_byte();     /* standalone build: the PS/2 keyboard */
        if (b >= 0 && kbd_byte((uint8_t) b)) {
            uint8_t rows[8];
            kbd_matrix(rows);
            hal_kbd_rows(rows);
        }
        if (kbd_take_reset()) {
            hal_z80_reset(1);
            for (uint32_t t = hal_ms(); hal_ms() - t < 2;) {
            }
            hal_z80_reset(0);
        }
        int s = kbd_take_send();
        if (s >= 0) hal_kbd_send(s);
    }
}
