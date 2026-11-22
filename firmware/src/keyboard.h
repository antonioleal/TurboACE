/* TurboACE standalone build: PS/2 keyboard to the Jupiter Ace key matrix
 * (register-map.md decision 26). keyboard.c */
#ifndef KEYBOARD_H
#define KEYBOARD_H

#include <stdint.h>

enum kbd_layout { KBD_US, KBD_PT };
enum kbd_mode   { KBD_SYMBOLIC, KBD_POSITIONAL };

void kbd_init(enum kbd_layout layout, enum kbd_mode mode);
/* one byte from the keyboard (scan code set 2); 1 if the matrix changed */
int  kbd_byte(uint8_t b);
/* the matrix: rows[r] bit b set = Ace key pressed. Row r is the one read with
 * A(8+r) low ($FEFE, $FDFE, ... $7FFE); bit b is data bit b. */
void kbd_matrix(uint8_t rows[8]);
enum kbd_mode kbd_get_mode(void);
int  kbd_take_reset(void);      /* 1 once after Ctrl+Alt+Del */
/* the next byte to send to the keyboard (LED commands), or -1 */
int  kbd_take_send(void);

#endif
