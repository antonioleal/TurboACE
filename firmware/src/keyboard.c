/*
 * TurboACE standalone build: PS/2 keyboard to the Jupiter Ace key matrix
 * (register-map.md decision 26).
 *
 * The Ace matrix, from the ROM's key tables at $0376 (row = A8..A15 low):
 *   row 0 $FEFE: SHIFT SYMBOL Z X C      row 4 $EFFE: 0 9 8 7 6
 *   row 1 $FDFE: A S D F G               row 5 $DFFE: P O I U Y
 *   row 2 $FBFE: Q W E R T               row 6 $BFFE: ENTER L K J H
 *   row 3 $F7FE: 1 2 3 4 5               row 7 $7FFE: SPACE M N B V
 *
 * After every key change the whole matrix is worked out again from the keys
 * held, so combinations never stick.
 *   - Symbolic mode (power-up): the character on the PC key cap, in the chosen
 *     layout, becomes the Ace key or combination that types it (e.g. PC "=" is
 *     SYMBOL SHIFT + L). Ctrl + a key gives SYMBOL SHIFT + that key's position.
 *   - Positional mode (games): letters, digits, Enter and Space press the Ace
 *     key in the same place; Shift = SHIFT, Ctrl = SYMBOL SHIFT.
 *   - Both: Backspace/Delete = DELETE, arrows = cursor keys, Esc = BREAK,
 *     Caps Lock = CAPS LOCK, Tab = DELETE LINE, F4 = INVERSE VIDEO, F9 =
 *     GRAPHICS; Scroll Lock switches the mode (its LED: positional);
 *     Ctrl+Alt+Del asks for a reset.
 */
#include <string.h>
#include "keyboard.h"

/* ---- Ace keys: row * 8 + bit ---------------------------------------------- */
#define K(row, bit) ((row) * 8 + (bit))
enum {
    A_SHIFT = K(0,0), A_SYM = K(0,1), A_Z = K(0,2), A_X = K(0,3), A_C = K(0,4),
    A_A = K(1,0), A_S = K(1,1), A_D = K(1,2), A_F = K(1,3), A_G = K(1,4),
    A_Q = K(2,0), A_W = K(2,1), A_E = K(2,2), A_R = K(2,3), A_T = K(2,4),
    A_1 = K(3,0), A_2 = K(3,1), A_3 = K(3,2), A_4 = K(3,3), A_5 = K(3,4),
    A_0 = K(4,0), A_9 = K(4,1), A_8 = K(4,2), A_7 = K(4,3), A_6 = K(4,4),
    A_P = K(5,0), A_O = K(5,1), A_I = K(5,2), A_U = K(5,3), A_Y = K(5,4),
    A_ENTER = K(6,0), A_L = K(6,1), A_K = K(6,2), A_J = K(6,3), A_H = K(6,4),
    A_SPACE = K(7,0), A_M = K(7,1), A_N = K(7,2), A_B = K(7,3), A_V = K(7,4),
    A_NONE = 0xFF
};
#define WITH_SHIFT 0x100
#define WITH_SYM   0x200

static const uint8_t letter_key[26] = {
    A_A, A_B, A_C, A_D, A_E, A_F, A_G, A_H, A_I, A_J, A_K, A_L, A_M,
    A_N, A_O, A_P, A_Q, A_R, A_S, A_T, A_U, A_V, A_W, A_X, A_Y, A_Z
};
static const uint8_t digit_key[10] = { A_0, A_1, A_2, A_3, A_4, A_5, A_6, A_7, A_8, A_9 };

/* SYMBOL SHIFT + key: the characters the ROM's third table gives */
static const struct { char c; uint8_t key; } sym_chars[] = {
    {'!',A_1},{'@',A_2},{'#',A_3},{'$',A_4},{'%',A_5},{'&',A_6},{'\'',A_7},{'(',A_8},
    {')',A_9},{'_',A_0},{'"',A_P},{';',A_O},{']',A_U},{'[',A_Y},{'=',A_L},{'+',A_K},
    {'-',A_J},{'^',A_H},{'.',A_M},{',',A_N},{'*',A_B},{'/',A_V},{'~',A_A},{'|',A_S},
    {'\\',A_D},{'{',A_F},{'}',A_G},{':',A_Z},{'`',A_X},{'?',A_C},{'<',A_R},{'>',A_T},
};

/* the Ace key (with SHIFT / SYMBOL SHIFT) that types character c, or 0 */
static unsigned char_combo(char c)
{
    if (c >= 'a' && c <= 'z') return letter_key[c - 'a'] | 0x400;
    if (c >= 'A' && c <= 'Z') return letter_key[c - 'A'] | WITH_SHIFT | 0x400;
    if (c >= '0' && c <= '9') return digit_key[c - '0'] | 0x400;
    if (c == ' ') return A_SPACE | 0x400;
    if (c == '\r') return A_ENTER | 0x400;
    for (unsigned i = 0; i < sizeof sym_chars / sizeof sym_chars[0]; i++)
        if (sym_chars[i].c == c) return sym_chars[i].key | WITH_SYM | 0x400;
    return 0;                       /* not on the Ace */
}

/* ---- PS/2 scan codes (set 2); E0 codes are 0x100 + code ------------------- */
enum {
    S_LSHIFT = 0x12, S_RSHIFT = 0x59, S_LCTRL = 0x14, S_RCTRL = 0x114, S_LALT = 0x11,
    S_ALTGR = 0x111, S_CAPS = 0x58, S_SCROLL = 0x7E, S_BACKSPACE = 0x66, S_TAB = 0x0D,
    S_ESC = 0x76, S_ENTER = 0x5A, S_KPENTER = 0x15A, S_SPACE = 0x29, S_F4 = 0x0C,
    S_F9 = 0x01, S_DELETE = 0x171, S_KPDOT = 0x71, S_LEFT = 0x16B, S_RIGHT = 0x174,
    S_UP = 0x175, S_DOWN = 0x172
};

/* key positions shared by both layouts: letters, digits, keypad */
static const struct { uint16_t sc; char c; } base_keys[] = {
    {0x1C,'a'},{0x32,'b'},{0x21,'c'},{0x23,'d'},{0x24,'e'},{0x2B,'f'},{0x34,'g'},{0x33,'h'},
    {0x43,'i'},{0x3B,'j'},{0x42,'k'},{0x4B,'l'},{0x3A,'m'},{0x31,'n'},{0x44,'o'},{0x4D,'p'},
    {0x15,'q'},{0x2D,'r'},{0x1B,'s'},{0x2C,'t'},{0x3C,'u'},{0x2A,'v'},{0x1D,'w'},{0x22,'x'},
    {0x35,'y'},{0x1A,'z'},
    {0x45,'0'},{0x16,'1'},{0x1E,'2'},{0x26,'3'},{0x25,'4'},{0x2E,'5'},{0x36,'6'},{0x3D,'7'},
    {0x3E,'8'},{0x46,'9'},
    {0x70,'0'},{0x69,'1'},{0x72,'2'},{0x7A,'3'},{0x6B,'4'},{0x73,'5'},{0x74,'6'},{0x6C,'7'},
    {0x75,'8'},{0x7D,'9'},{0x79,'+'},{0x7B,'-'},{0x7C,'*'},{0x14A,'/'},{S_KPDOT,'.'},
    {S_SPACE,' '},{S_ENTER,'\r'},{S_KPENTER,'\r'},
};

/* layout keys: plain, Shift, AltGr (0 = nothing the Ace can type) */
struct lkey { uint16_t sc; char plain, shift, altgr; };
static const struct lkey us_keys[] = {
    {0x16,'1','!',0},{0x1E,'2','@',0},{0x26,'3','#',0},{0x25,'4','$',0},{0x2E,'5','%',0},
    {0x36,'6','^',0},{0x3D,'7','&',0},{0x3E,'8','*',0},{0x46,'9','(',0},{0x45,'0',')',0},
    {0x0E,'`','~',0},{0x4E,'-','_',0},{0x55,'=','+',0},{0x54,'[','{',0},{0x5B,']','}',0},
    {0x5D,'\\','|',0},{0x4C,';',':',0},{0x52,'\'','"',0},{0x41,',','<',0},{0x49,'.','>',0},
    {0x4A,'/','?',0},{0x61,'\\','|',0},
};
/* Portuguese (Portugal). The dead keys (acute/grave, tilde/circumflex) type
 * their character at once; ç, º, ª, «, », £, §, € are not on the Ace. */
static const struct lkey pt_keys[] = {
    {0x16,'1','!',0},{0x1E,'2','"','@'},{0x26,'3','#',0},{0x25,'4','$',0},{0x2E,'5','%',0},
    {0x36,'6','&',0},{0x3D,'7','/','{'},{0x3E,'8','(','['},{0x46,'9',')',']'},{0x45,'0','=','}'},
    {0x0E,'\\','|',0},{0x4E,'\'','?',0},{0x55,0,0,0},{0x54,'+','*',0},{0x5B,0,'`',0},
    {0x5D,'~','^',0},{0x4C,0,0,0},{0x52,0,0,0},{0x41,',',';',0},{0x49,'.',':',0},
    {0x4A,'-','_',0},{0x61,'<','>',0},
};

/* ---- State ----------------------------------------------------------------- */
static enum kbd_layout layout;
static enum kbd_mode mode;
static uint16_t held[16];
static int nheld;
static int e0, f0, skip, reset_req;
static int caps_led;
static uint8_t rows[8];
static int send_q[4], send_n, send_wait;

static int is_held(uint16_t sc)
{
    for (int i = 0; i < nheld; i++) if (held[i] == sc) return 1;
    return 0;
}

static void press(uint8_t key) { if (key != A_NONE) rows[key >> 3] |= 1 << (key & 7); }

static void press_combo(unsigned combo)
{
    if (!combo) return;
    press(combo & 0xFF);
    if (combo & WITH_SHIFT) press(A_SHIFT);
    if (combo & WITH_SYM) press(A_SYM);
}

/* the Ace position of a letter/digit/space/enter key, or A_NONE */
static uint8_t position_of(uint16_t sc)
{
    for (unsigned i = 0; i < sizeof base_keys / sizeof base_keys[0]; i++)
        if (base_keys[i].sc == sc) {
            unsigned c = char_combo(base_keys[i].c);
            if (c && !(c & (WITH_SHIFT | WITH_SYM))) return c & 0xFF;
        }
    return A_NONE;
}

static unsigned special(uint16_t sc)
{
    switch (sc) {
    case S_BACKSPACE: case S_DELETE: return A_0 | WITH_SHIFT | 0x400;   /* DELETE */
    case S_LEFT:  return A_5 | WITH_SHIFT | 0x400;
    case S_UP:    return A_6 | WITH_SHIFT | 0x400;
    case S_DOWN:  return A_7 | WITH_SHIFT | 0x400;
    case S_RIGHT: return A_8 | WITH_SHIFT | 0x400;
    case S_ESC:   return A_SPACE | WITH_SHIFT | 0x400;                  /* BREAK */
    case S_CAPS:  return A_2 | WITH_SHIFT | 0x400;                      /* CAPS LOCK */
    case S_TAB:   return A_1 | WITH_SHIFT | 0x400;                      /* DELETE LINE */
    case S_F4:    return A_4 | WITH_SHIFT | 0x400;                      /* INVERSE VIDEO */
    case S_F9:    return A_9 | WITH_SHIFT | 0x400;                      /* GRAPHICS */
    }
    return 0;
}

static int is_modifier(uint16_t sc)
{
    return sc == S_LSHIFT || sc == S_RSHIFT || sc == S_LCTRL || sc == S_RCTRL
        || sc == S_LALT || sc == S_ALTGR || sc == S_SCROLL;
}

static char layout_char(uint16_t sc, int shift, int altgr)
{
    const struct lkey *t = layout == KBD_PT ? pt_keys : us_keys;
    unsigned n = layout == KBD_PT ? sizeof pt_keys / sizeof pt_keys[0]
                                  : sizeof us_keys / sizeof us_keys[0];
    for (unsigned i = 0; i < n; i++)
        if (t[i].sc == sc) return altgr ? t[i].altgr : shift ? t[i].shift : t[i].plain;
    for (unsigned i = 0; i < sizeof base_keys / sizeof base_keys[0]; i++)
        if (base_keys[i].sc == sc) {
            char c = base_keys[i].c;
            if (altgr) return 0;
            if (shift && c >= 'a' && c <= 'z') return (char) (c - 32);
            return c;
        }
    return 0;
}

static void recompute(void)
{
    int shift = is_held(S_LSHIFT) || is_held(S_RSHIFT);
    int ctrl = is_held(S_LCTRL) || is_held(S_RCTRL);
    int altgr = layout == KBD_PT && is_held(S_ALTGR);
    memset(rows, 0, sizeof rows);
    if (mode == KBD_POSITIONAL) {
        if (shift) press(A_SHIFT);
        if (ctrl) press(A_SYM);
    }
    for (int i = 0; i < nheld; i++) {
        uint16_t sc = held[i];
        unsigned sp = special(sc);
        if (sp) { press_combo(sp); continue; }
        if (is_modifier(sc)) continue;
        if (mode == KBD_POSITIONAL || ctrl) {      /* Ctrl: SYMBOL SHIFT + position */
            press(position_of(sc));
            if (ctrl) press(A_SYM);
            continue;
        }
        press_combo(char_combo(layout_char(sc, shift, altgr)));
    }
}

static void queue_send(int b) { if (send_n < 4) send_q[send_n++] = b; }

static void set_leds(void)
{
    queue_send(0xED);
    queue_send((mode == KBD_POSITIONAL ? 1 : 0) | (caps_led ? 4 : 0));
}

void kbd_init(enum kbd_layout l, enum kbd_mode m)
{
    layout = l;
    mode = m;
    nheld = e0 = f0 = skip = reset_req = caps_led = 0;
    send_n = send_wait = 0;
    memset(rows, 0, sizeof rows);
    set_leds();
}

int kbd_byte(uint8_t b)
{
    uint8_t before[8];
    memcpy(before, rows, 8);
    if (skip) { skip--; return 0; }
    if (b == 0xFA) { send_wait = 0; return 0; }     /* acknowledge */
    if (b == 0xAA || b == 0xEE || b == 0xFE || b == 0x00 || b == 0xFF) return 0;
    if (b == 0xE1) { skip = 7; return 0; }          /* Pause: 8 bytes, no key */
    if (b == 0xE0) { e0 = 1; return 0; }
    if (b == 0xF0) { f0 = 1; return 0; }
    uint16_t sc = (uint16_t) (b | (e0 ? 0x100 : 0));
    int release = f0;
    e0 = f0 = 0;
    if (sc == 0x112 || sc == 0x159) return 0;       /* the fake shifts of Print Screen */

    if (release) {
        for (int i = 0; i < nheld; i++)
            if (held[i] == sc) { held[i] = held[--nheld]; break; }
    } else if (!is_held(sc)) {                      /* repeats change nothing */
        if (sc == S_SCROLL) {
            mode = mode == KBD_SYMBOLIC ? KBD_POSITIONAL : KBD_SYMBOLIC;
            set_leds();
        } else if (sc == S_CAPS) {
            caps_led = !caps_led;
            set_leds();
        } else if ((sc == S_DELETE || sc == S_KPDOT)
                   && (is_held(S_LCTRL) || is_held(S_RCTRL))
                   && (is_held(S_LALT) || is_held(S_ALTGR))) {
            reset_req = 1;
        }
        if (nheld < 16) held[nheld++] = sc;
    }
    recompute();
    return memcmp(before, rows, 8) != 0;
}

void kbd_matrix(uint8_t out[8]) { memcpy(out, rows, 8); }
enum kbd_mode kbd_get_mode(void) { return mode; }
int kbd_take_reset(void) { int r = reset_req; reset_req = 0; return r; }

int kbd_take_send(void)
{
    if (!send_n || send_wait) return -1;
    int b = send_q[0];
    memmove(send_q, send_q + 1, (size_t) --send_n * sizeof send_q[0]);
    send_wait = 1;                  /* the next byte after the keyboard's FA */
    return b;
}
