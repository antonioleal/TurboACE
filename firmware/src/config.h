/* TurboACE: the settings file /turboace.cfg on the SD card (config.c). */
#ifndef CONFIG_H
#define CONFIG_H

#include "keyboard.h"

struct tconfig {
    enum kbd_layout layout;     /* keyboard = us | pt          (default us) */
    enum kbd_mode   mode;       /* keymode = symbolic | positional (default symbolic) */
};

/* parse the file's text (len bytes); unknown lines are ignored. Returns the
 * number of settings understood. cfg gets the defaults first. */
int config_parse(const char *text, unsigned len, struct tconfig *cfg);

#endif
