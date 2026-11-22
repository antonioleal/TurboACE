/* Tests for the PS/2 keyboard translation (keyboard.c) and the settings file
 * (config.c), on a PC. */
#include <stdio.h>
#include <string.h>
#include "keyboard.h"
#include "config.h"

static int failures, checks;
static void check(int ok, const char *what)
{
    checks++;
    if (!ok) { failures++; printf("  FAIL %s\n", what); }
}

/* Ace key = row * 8 + bit */
#define K(r, b) ((r) * 8 + (b))
enum { SHIFT = K(0,0), SYM = K(0,1), A = K(1,0), P = K(5,0), L = K(6,1), Kk = K(6,2),
       D2 = K(3,1), D5 = K(3,4), D6 = K(4,4), D7 = K(4,3), D8 = K(3,1) + 1000, D0 = K(4,0),
       SPACE = K(7,0), ENTER = K(6,0), D1 = K(3,0), D4 = K(3,3), D9 = K(4,1) };

static uint8_t rows[8];
static void get(void) { kbd_matrix(rows); }
static int down(int key) { return rows[key >> 3] >> (key & 7) & 1; }
static int count(void) { int n = 0; for (int r = 0; r < 8; r++) for (int b = 0; b < 5; b++) n += rows[r] >> b & 1; return n; }

/* exactly these keys pressed */
static int only(int a, int b, int c)
{
    get();
    int want = (a >= 0) + (b >= 0) + (c >= 0);
    return count() == want && (a < 0 || down(a)) && (b < 0 || down(b)) && (c < 0 || down(c));
}

static void make(int sc) { if (sc & 0x100) kbd_byte(0xE0); kbd_byte((uint8_t) sc); }
static void brk(int sc)  { if (sc & 0x100) kbd_byte(0xE0); kbd_byte(0xF0); kbd_byte((uint8_t) sc); }
static void tap(int sc, int mod1)
{
    if (mod1) make(mod1);
    make(sc);
}
static void clear_all(enum kbd_layout l, enum kbd_mode m) { kbd_init(l, m); while (kbd_take_send() >= 0) kbd_byte(0xFA); }

int main(void)
{
    printf("keyboard, symbolic (US)\n");
    clear_all(KBD_US, KBD_SYMBOLIC);
    tap(0x1C, 0);   check(only(A, -1, -1), "a: A");
    brk(0x1C);      check(only(-1, -1, -1), "released: nothing");
    tap(0x1C, 0x12); check(only(A, SHIFT, -1), "Shift+a: SHIFT + A");
    brk(0x1C); brk(0x12);
    tap(0x55, 0);   check(only(L, SYM, -1), "= : SYMBOL SHIFT + L");
    brk(0x55);
    tap(0x55, 0x12); check(only(Kk, SYM, -1), "Shift+= (+): SYMBOL SHIFT + K, PC Shift held back");
    brk(0x55); brk(0x12);
    tap(0x52, 0x59); check(only(P, SYM, -1), "Shift+' (\"): SYMBOL SHIFT + P (right Shift)");
    brk(0x52); brk(0x59);
    tap(0x4D, 0x14); check(only(P, SYM, -1), "Ctrl+P: SYMBOL SHIFT + P (position)");
    brk(0x4D); brk(0x14);
    make(0x1C); make(0x1C); make(0x1C);
    check(only(A, -1, -1), "typematic repeats change nothing");
    brk(0x1C);
    make(0x16B); check(only(D5, SHIFT, -1), "Left: SHIFT + 5"); brk(0x16B);
    make(0x175); check(only(D6, SHIFT, -1), "Up: SHIFT + 6"); brk(0x175);
    make(0x172); check(only(D7, SHIFT, -1), "Down: SHIFT + 7"); brk(0x172);
    make(0x66);  check(only(D0, SHIFT, -1), "Backspace: SHIFT + 0 (DELETE)"); brk(0x66);
    make(0x76);  check(only(SPACE, SHIFT, -1), "Esc: SHIFT + SPACE (BREAK)"); brk(0x76);
    make(0x0D);  check(only(D1, SHIFT, -1), "Tab: SHIFT + 1 (DELETE LINE)"); brk(0x0D);
    make(0x0C);  check(only(D4, SHIFT, -1), "F4: SHIFT + 4 (INVERSE VIDEO)"); brk(0x0C);
    make(0x01);  check(only(D9, SHIFT, -1), "F9: SHIFT + 9 (GRAPHICS)"); brk(0x01);
    make(0x15A); check(only(ENTER, -1, -1), "keypad Enter: ENTER"); brk(0x15A);
    make(0x12); kbd_byte(0xE0); kbd_byte(0x12);      /* Print Screen's fake shift */
    check(only(-1, -1, -1), "Shift alone, and fake shifts: nothing pressed in symbolic mode");
    brk(0x12);

    printf("keyboard, Portuguese\n");
    clear_all(KBD_PT, KBD_SYMBOLIC);
    tap(0x1E, 0x12); check(only(P, SYM, -1), "PT Shift+2 (\"): SYMBOL SHIFT + P");
    brk(0x1E); brk(0x12);
    tap(0x1E, 0x111); check(only(D2, SYM, -1), "PT AltGr+2 (@): SYMBOL SHIFT + 2");
    brk(0x1E); brk(0x111);
    tap(0x45, 0x12); check(only(L, SYM, -1), "PT Shift+0 (=): SYMBOL SHIFT + L");
    brk(0x45); brk(0x12);
    tap(0x54, 0); check(only(Kk, SYM, -1), "PT + key: SYMBOL SHIFT + K");
    brk(0x54);
    tap(0x4C, 0); check(only(-1, -1, -1), "PT c-cedilla: nothing (not on the Ace)");
    brk(0x4C);

    printf("keyboard, modes, LEDs, reset\n");
    kbd_init(KBD_US, KBD_SYMBOLIC);
    int s1 = kbd_take_send(); kbd_byte(0xFA); int s2 = kbd_take_send(); kbd_byte(0xFA);
    check(s1 == 0xED && s2 == 0x00, "start: LEDs off (ED 00)");
    make(0x7E); brk(0x7E);
    s1 = kbd_take_send(); kbd_byte(0xFA); s2 = kbd_take_send(); kbd_byte(0xFA);
    check(kbd_get_mode() == KBD_POSITIONAL && s1 == 0xED && s2 == 0x01, "Scroll Lock: positional, Scroll LED on");
    tap(0x1E, 0x12); check(only(D2, SHIFT, -1), "positional Shift+2: SHIFT + 2");
    brk(0x1E); brk(0x12);
    tap(0x55, 0); check(only(-1, -1, -1), "positional = : no Ace key there");
    brk(0x55);
    make(0x12); check(only(SHIFT, -1, -1), "positional Shift alone: SHIFT");
    brk(0x12);
    make(0x58); brk(0x58);
    s1 = kbd_take_send(); kbd_byte(0xFA); s2 = kbd_take_send(); kbd_byte(0xFA);
    check(s1 == 0xED && s2 == 0x05, "Caps Lock: Caps LED on too (ED 05)");
    make(0x7E); brk(0x7E);
    check(kbd_get_mode() == KBD_SYMBOLIC, "Scroll Lock again: symbolic");
    make(0x14); make(0x11); make(0x171);
    check(kbd_take_reset() && !kbd_take_reset(), "Ctrl+Alt+Del: one reset request");
    brk(0x171); brk(0x11); brk(0x14);
    kbd_byte(0xE1); for (int i = 0; i < 7; i++) kbd_byte(0x14);
    check(only(-1, -1, -1), "Pause (E1 sequence): no key");

    printf("settings file\n");
    struct tconfig c;
    const char *t1 = "# TurboACE\r\nKeyboard = PT\nkeymode=positional  # games\n";
    check(config_parse(t1, (unsigned) strlen(t1), &c) == 2 && c.layout == KBD_PT && c.mode == KBD_POSITIONAL,
          "keyboard = PT, keymode=positional, comments, CR LF");
    const char *t2 = "colour = blue\nkeyboard = de\n";
    check(config_parse(t2, (unsigned) strlen(t2), &c) == 0 && c.layout == KBD_US && c.mode == KBD_SYMBOLIC,
          "unknown names and values: ignored, defaults kept");
    check(config_parse("", 0, &c) == 0 && c.layout == KBD_US, "no file: US, symbolic");

    printf("%d checks, %s\n", checks, failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
