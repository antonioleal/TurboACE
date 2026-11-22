# TurboACE

A hardware expansion for the standard Jupiter Ace, built around a Tang Nano 20K FPGA
module. The same module can also be a complete Jupiter Ace on its own (see
[Two builds](#two-builds-expansion-and-standalone)). It adds:

- 512K of paged RAM (64 × 8K pages, two windows);
- a 256×192 hi-res bitmap with 8×1 colour;
- colour text, 32 text pages and 32 character sets;
- HDMI output, with AY sound carried over HDMI;
- SD card storage: programs as tape files, RAM pages, screens and fonts;
- an extension ROM with new Forth words.

Original Jupiter Ace software keeps working.

The design is in [`register-map.md`](register-map.md) and the ROM source in [`rom/`](rom/README.md).
The SD card firmware (for the soft CPU in the FPGA) is in [`firmware/`](firmware/README.md),
and the FPGA design (being written) in [`fpga/`](fpga/README.md).
The tests are in [`test/`](test/).
`./build.sh /path/to/ace.rom` builds everything into `release/`, one folder per build
(`release/standalone/`, `release/expansion/`) with the files written into the module (the
bitstream, with the soft CPU's firmware inside, and the ROM pages for its flash) and a
`LOAD.txt` saying how. It fetches the RISC-V compiler with
`./download_toolchain.sh` the first time; the bitstream needs Gowin EDA in
`toolchain/gowim`. Third-party components and their notices are listed in
[`THIRD-PARTY.md`](THIRD-PARTY.md).

## Two builds: Expansion and Standalone

TurboACE comes as two FPGA bitstreams, made from the same design. Which one the module
runs depends only on what was last written into it:

- **Expansion:** the module sits on a small adapter board plugged into a real Jupiter
  Ace's edge connector. The Ace's own Z80, keyboard and cassette are used; TurboACE
  adds memory, graphics, sound, HDMI and the SD card.
- **Standalone:** no Jupiter Ace is needed. The whole Ace (Z80, memory, keyboard port,
  beeper, 50 Hz interrupt) is inside the FPGA, with a PS/2 keyboard and the SD card as
  the only tape. It runs the same software at the same speed (3.25 MHz, with the stock
  screen-access timing), plus everything TurboACE adds.

|  | Expansion | Standalone |
|---|---|---|
| Needs | a Jupiter Ace, the adapter board, the Tang Nano 20K | the Tang Nano 20K, a PS/2 keyboard and adapter |
| Z80 | the Ace's own | inside the FPGA (T80 core) |
| Keyboard | the Ace's own | PS/2, translated to the Ace's keys (below) |
| Tape | the Ace's cassette port, or the SD card with `SDTAPE` | the SD card only (`SDTAPE` is always on) |
| Display and sound | HDMI (TurboACE's screens and AY sound) | HDMI (screen, AY sound and the beeper) |
| Without `/ace.rom` | the Ace starts on its own ROM, as a stock Ace | `TURBOACE: CANNOT START` on the screen, tries again every second |

**Changing build** means writing the other bitstream into the module through its USB
port with [openFPGALoader](https://github.com/trabucayre/openFPGALoader); nothing else
changes. Both builds also need TurboACE's own ROM pages in the module's flash, written
once (see [`rom/`](rom/README.md)):

```
make program BUILD=standalone ACE_ROM=/path/to/ace.rom   # bitstream and ROM pages
make program-bitstream BUILD=expansion                   # later: change build only
```

`ACE_ROM` is only used to build the ROM pages; the stock ROM itself is not written to
the board. `make load BUILD=...` loads a bitstream until power-off, for testing, and
`FPGALOADER=echo` shows the commands without running them. The targets are in the
top-level [`Makefile`](Makefile).

### Installing the standalone build

**You need:**

- the Tang Nano 20K and a USB-C cable (it powers and programs the module);
- a PS/2 keyboard and the small PS/2 adapter ([The keyboard](#the-keyboard-standalone) below);
- an HDMI display that accepts 720×576 at 50 Hz (most TVs and many monitors);
- a microSD card, FAT32, holding your copy of the stock ROM as `/ace.rom`
  ([The SD card](#the-sd-card) below);
- on the PC: [openFPGALoader](https://github.com/trabucayre/openFPGALoader).

**The files** are in `release/standalone/`, made by `./build.sh /path/to/ace.rom` (it
needs Gowin EDA in `toolchain/gowim` for the bitstream; see [`INDEX.md`](INDEX.md)):
`turboace-standalone.fs` (the bitstream) and `turboace-flash.bin` (TurboACE's ROM pages).
Its `LOAD.txt` has the same commands as below.

**Steps:**

1. **Prepare the card:** format it FAT32 and copy the stock ROM to it as `/ace.rom`.
   Programs go in `/programs`.
2. **Wire the keyboard** through the level shifter to FPGA pins **73** (clock) and
   **74** (data), the first two pins of the module's left header at the USB end, with
   5 V and ground, as in the table below. Plug in the display.
3. **Connect the module** to the PC by USB. Check that openFPGALoader sees it:
   ```
   openFPGALoader --detect -b tangnano20k
   ```
   If it says it cannot open the device, your user may not have access to the USB
   port: run the command as root once, or allow it permanently with a udev rule
   (the module's USB ID is `0403:6010`), then unplug and replug the module:
   ```
   # /etc/udev/rules.d/99-tangnano20k.rules
   SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0666"
   ```
   ```
   udevadm control --reload-rules && udevadm trigger
   ```
4. **Write TurboACE's ROM pages** into the module's flash (once; both builds use them):
   ```
   make program-rom ACE_ROM=/path/to/ace.rom
   ```
   or, from `release/standalone/`:
   `openFPGALoader -b tangnano20k --external-flash -o 0x500000 turboace-flash.bin`
5. **Try the bitstream** without writing it to flash; it is lost at power-off:
   ```
   make load BUILD=standalone
   ```
   With the card in, the Jupiter Ace's screen and prompt appear on the display within
   a second.
6. **Write it to flash** so the module starts as a Jupiter Ace at every power-up:
   ```
   make program-bitstream BUILD=standalone
   ```
   or, from `release/standalone/`: `openFPGALoader -b tangnano20k -f turboace-standalone.fs`

`make program BUILD=standalone ACE_ROM=/path/to/ace.rom` does steps 4 and 6 together.
Button **S1** on the module resets everything (as a power-up); **Ctrl + Alt + Del**
resets only the Ace.

**The module's LEDs** (on when lit) show how far it got:

| LED (pin) | On means |
|---|---|
| 0 (15) | the Z80 is running |
| 1 (16) | the ROM is loaded (from `/ace.rom` and the flash) |
| 2 (17) | the SD card has been used |
| 3 (18) | the picture fell behind (should never light) |

**If something is wrong:**

- *No picture:* check the display accepts 720×576 at 50 Hz. If LEDs 0 and 1 are on, the
  Ace is running and the fault is in the HDMI output; this first bitstream has not yet
  been tried on a board, so please report it.
- *`TURBOACE: CANNOT START` on the screen:* `/ace.rom` is missing or not the stock ROM
  (it must be 8,192 bytes, MD5 `db6efdfd82cebdfbb493d85b1a5efc3c`). TurboACE tries again
  every second, so fixing the card is enough.
- *LED 1 stays off:* the card is not read: check it is FAT32 and fully inserted, and that
  step 4 was done.
- *The keyboard does nothing:* check the level shifter's wiring and its 5 V and 3.3 V
  supplies; data and clock must not be swapped.

### The SD card

**The card must hold `/ace.rom`**, your own copy of the stock Jupiter Ace ROM (8,192
bytes, MD5 `db6efdfd82cebdfbb493d85b1a5efc3c`). TurboACE does not include it: at power-up
it reads it from the card, checks it, and builds its ROM from it. If it is missing or
different, the standalone build says why on the screen and starts as soon as the card is
right; the expansion leaves the Ace to start on its own ROM, as a plain stock Ace.

The SD words start in the folder `/programs`; see [SD card](#sd-card) below.

### The keyboard (standalone)

A PC keyboard with a PS/2 connector plugs into a small PS/2 adapter next to the module.
The keyboard works at 5 V and the FPGA at 3.3 V, so the clock and data lines go through
a bidirectional level shifter (one small MOSFET and two pull-up resistors per line):

| PS/2 socket pin | Signal | Goes to |
|---|---|---|
| 1 | data | level shifter, 5 V side → 3.3 V side → FPGA pin 74 (left header, pin 2) |
| 3 | ground | GND |
| 4 | +5 V | the module's 5 V pin (from USB) |
| 5 | clock | level shifter, 5 V side → 3.3 V side → FPGA pin 73 (left header, pin 1) |
| 2, 6 | — | not connected |

The full parts list and wiring are in
[`hardware/standalone-carrier.md`](hardware/standalone-carrier.md).

The keyboard has two modes; **Scroll Lock** switches between them, and its
light is on in positional mode.

- **Symbolic** (at power-up): a key types what is printed on it. PC `=` gives `=`, even
  though the Ace types it with SYMBOL SHIFT + L. Best for typing programs.
- **Positional:** the keys act as the Ace's keys in the same place. Shift is SHIFT and
  Ctrl is SYMBOL SHIFT. Best for games.

These keys work in both modes:

| PC key | Ace key | Does |
|---|---|---|
| Backspace, Delete | SHIFT + 0 | delete |
| ← ↑ ↓ → | SHIFT + 5 / 6 / 7 / 8 | move the cursor |
| Esc | SHIFT + SPACE | BREAK |
| Caps Lock | SHIFT + 2 | caps lock (the light follows) |
| Tab | SHIFT + 1 | delete line |
| F4 | SHIFT + 4 | inverse video on/off |
| F9 | SHIFT + 9 | graphics on/off |
| Ctrl + Alt + Del | | reset the Ace |

**US and Portuguese layouts.** A settings file on the card, `/turboace.cfg`, chooses the
layout and the starting mode; without it the keyboard is US and symbolic:

```
# /turboace.cfg
keyboard = pt          # us or pt
keymode = symbolic     # symbolic or positional
```

On the Portuguese layout the accent keys (´ ` ~ ^) type their own character at once.
ç, º, ª, «, », £, § and € have no Ace key and type nothing.

## Starting up: `TURBO`

There is no switch. The machine powers up as a **51K Jupiter Ace**, like a stock Ace with
a 48K RAM pack. Only a few new words are visible: `TURBO`, which selects the mode, and the
SD card words `SDTAPE`, `TAPE`, `EJECT`, `DIR`, `CD`, `DELETE` and `SDERR`, so old
programs can be loaded from the card straight away.

| Command | Mode |
|---------|------|
| `1 TURBO` | **TurboACE**: all the words below. The machine stack moves below `$C000`, leaving the paged RAM free. Gives `ERROR 1` if the dictionary is too close to `$C000` |
| `0 TURBO` | **51K Ace** (the power-up mode): only `TURBO` and the SD card words visible, stock text screen, white on black |
| `-1 TURBO` | **Stock Ace with the card, until reset**: the stock words only and the `$3000` mirror of the system variables, but the tape words keep using the card (the tape chosen before, with `SDTAPE` on). See [The SD card in `-1 TURBO`](#the-sd-card-in--1-turbo) |
| `-2 TURBO` | **Completely stock Ace until reset**: the original ROM, byte for byte, the whole `$3000` mirror and the real cassette. For software that needs an untouched machine |

`TURBO` ends like `QUIT`. The dictionary and the data stack are kept, but the rest of the
input line is not run, so use it on a line of its own or as the last word of a program.

```
1 TURBO
1 MODE CLS 128 96 50 CIRCLE
```

Both builds start this way, once `/ace.rom` is on the card
([The SD card](#the-sd-card)).

## New Forth words

After `1 TURBO`, the words below are added to the `FORTH` vocabulary. Your own words keep
working alongside them.

**Conventions**

- **Stack effects** are written `( before -- after )`, as in the Ace manual.
- **Hi-res coordinates** are `x` 0–255 (left to right) and `y` 0–191 (bottom to top).
  The origin is the bottom-left corner.
- **Colours** are numbers 0–15, given by name with the colour constants below.
- **Examples** assume `1 TURBO` has been typed. Loops (`DO … LOOP`) and `."` are used
  inside colon definitions, as the Ace requires.

> Word addresses are not frozen yet. Programs saved with this ROM may need recompiling
> after a ROM update.

### Quick reference

| Group | Words |
|-------|-------|
| Mode | `TURBO` |
| Utilities | `COUNT` `+!` `?` `DEPTH` `HEX` `CMOVE` `FILL` |
| Programming | `.S` `'` `2*` `2/` `0<>` `CASE` `OF` `ENDOF` `ENDCASE` `RND` `RAND` `GR` |
| Double numbers | `2DUP` `2DROP` `2SWAP` `2OVER` `2ROT` `D.` `D.R` `D-` `D=` `D0=` `DABS` `S->D` |
| Floating point | `PI` `FSQRT` `FSIN` `FCOS` `FTAN` `FABS` `F<` `F>` `F0<` `F0=` |
| Sound | `PLAY!` `PLAY@` |
| Colour | `INK` `PAPER` `BORDER` `DARK` `BLACK` `GREY` `BLUE` `GREEN` `CYAN` `RED` `PURPLE` `YELLOW` `WHITE` |
| Screens and memory | `MODE` `PG0` `PG1` `FONT` `VIEW` `WORK` `SCREEN` |
| Graphics | `PLOT` `DRAW` `CIRCLE` `PAINT` `POINT` `ATTR` `INVERSE` `FLIP` `CLS` `OPAQUE` |
| SD card | `SDTAPE` `TAPE` `EJECT` `DIR` `CD` `DELETE` `PGSAVE` `PGLOAD` `SCRSAVE` `SCRLOAD` `FONTLOAD` `SDERR` |

### Mode

| Word | What it does |
|------|--------------|
| `TURBO` | Select the mode: `1` TurboACE, `0` 51K Ace, `-1` stock Ace with the card, `-2` completely stock Ace (both until reset) |

#### `TURBO` `( n -- )`

Selects the machine's mode, described in [Starting up](#starting-up-turbo) above.
At power-up only `TURBO` and the SD card words are visible.

- `1 TURBO`: all the new words.
- `0 TURBO`: back to a plain 51K Ace, with the SD card words.
- `-1 TURBO`: a stock Ace until the next reset, whose tape words still use the card.
- `-2 TURBO` (or any lower number): a completely stock Ace until the next reset.

`TURBO` restarts the interpreter like `QUIT`, so make it the last word on a line.

```
1 TURBO
```

### Utilities

| Word | What it does |
|------|--------------|
| `COUNT` | Turn a counted string's address into address and length |
| `+!` | Add a number to a variable |
| `?` | Print a variable's value |
| `DEPTH` | Count the items on the data stack |
| `HEX` | Switch number input and output to base 16 |
| `CMOVE` | Copy a block of memory (overlap-safe) |
| `FILL` | Fill a block of memory with one byte |

#### `COUNT` `( addr -- addr+1 n )`

Turns the address of a *counted string* (a length byte followed by the characters) into
the address and length that `TYPE` expects.

```
CREATE GREETING 5 C, 72 C, 69 C, 76 C, 76 C, 79 C,
GREETING COUNT TYPE
```

This prints `HELLO`.

#### `+!` `( n addr -- )`

Adds `n` to the number stored at `addr`. It is handy for counters and scores.

```
0 VARIABLE SCORE
: HIT 10 SCORE +! ;
HIT HIT HIT SCORE ?
```

This prints `30`.

#### `?` `( addr -- )`

Prints the number stored at `addr`. It is short for `@ .`.

```
SCORE ?
```

#### `DEPTH` `( -- n )`

The number of items on the data stack, without changing them. Useful for checking that a
word leaves the stack as expected.

```
1 2 3 DEPTH .
```

This prints `3`, and `1 2 3` are still on the stack.

#### `HEX` `( -- )`

Switches number input and output to base 16. `DECIMAL` (a stock word) switches back.
Addresses are easier to write in hex.

```
HEX 2400 DECIMAL .
```

This prints `9216`, the address of the text screen.

#### `CMOVE` `( from to n -- )`

Copies `n` bytes from address `from` to address `to`. The areas may overlap: `CMOVE`
chooses the copy direction so that nothing is overwritten before it is copied. This example
keeps a copy of the text screen in RAM page 4. The second line, typed later, brings it back.

```
4 PG0  HEX 2400 C000 300 CMOVE DECIMAL
4 PG0  HEX C000 2400 300 CMOVE DECIMAL
```

The text screen is `$300` (768) bytes at `$2400`. Characters copied back to the screen take
the current `INK` and `PAPER`.

#### `FILL` `( addr n byte -- )`

Sets `n` bytes, starting at `addr`, to `byte`. This is the memory fill; the graphics flood
fill is `PAINT`.

```
HEX 2400 300 DECIMAL 42 FILL
```

This fills the whole text screen with `*` (character 42) in the current colours.

```
5 PG0  HEX C000 2000 0 FILL DECIMAL
```

This clears all of RAM page 5 (8K).

### Programming

| Word | What it does |
|------|--------------|
| `.S` | Print the whole data stack without changing it |
| `'` | The parameter field of the next word (a variable's address) |
| `2*` | Multiply by 2 |
| `2/` | Divide by 2, rounding down |
| `0<>` | 1 if a number is not zero |
| `CASE` `OF` `ENDOF` `ENDCASE` | Choose between several cases by value |
| `RND` | A random number from 0 to n−1 |
| `RAND` | Start the random numbers from a seed |
| `GR` | Define the shape of a character |

#### `.S` `( -- )`

Prints every item on the data stack, the oldest first, and leaves them all there. Use it
while trying out words, to see what they leave behind.

```
1 2 3 .S
```

This prints `1 2 3`, and the three numbers are still on the stack. With an empty stack
`.S` prints nothing.

#### `'` `( -- addr )`

`' name` gives the parameter field of the word `name`: for a `VARIABLE` that is its
address, for a `CONSTANT` the place where its value is kept. Words that are not in the
dictionary give `ERROR 13`.

```
5 VARIABLE LIVES
' LIVES ?
```

This prints `5`.

#### `2*` `( n -- 2n )` · `2/` `( n -- n/2 )`

Fast multiply and divide by 2. `2/` shifts, so it rounds down: `-3 2/` gives `-2`.

```
5 2* .   -3 2/ .
```

This prints `10 -2`.

#### `0<>` `( n -- f )`

1 if `n` is not zero, 0 if it is. Handy in `IF` and `UNTIL` tests.

```
0 0<> .   9 0<> .
```

This prints `0 1`.

#### `CASE` `OF` `ENDOF` `ENDCASE`

Choose what to do from a value, instead of a chain of `IF`s. Used inside colon
definitions:

```
: SPELL ( n -- )
  CASE
    1 OF ." ONE " ENDOF
    2 OF ." TWO " ENDOF
    ." MANY " ( n is still on the stack here )
  ENDCASE ;
1 SPELL  2 SPELL  7 SPELL
```

This prints `ONE TWO MANY`.

- `CASE` takes the value to test.
- Each `v OF … ENDOF` runs its words when the value equals `v`, then continues after
  `ENDCASE`. The value is dropped before the words run.
- Words between the last `ENDOF` and `ENDCASE` run when no `OF` matched; the value is
  still on the stack there, and `ENDCASE` drops it.
- `CASE` can be nested. A wrong order (for example `ENDOF` without `OF`) gives
  `ERROR 5`, as an `IF` without `THEN` does.
- `LIST` and `EDIT` show them like `IF` and `THEN`.

#### `RND` `( n -- r )` · `RAND` `( n -- )`

`RND` gives a random number from 0 to `n`−1 (`0 RND` gives 0). `RAND` sets where the
sequence starts: the same seed always gives the same numbers, which helps when testing a
game; `0 RAND` takes the seed from the frame counter, so each run is different.

```
0 RAND
: DICE 6 RND 1+ ;
DICE .  DICE .  DICE .
```

This prints three throws of a die. The sequence repeats only after 65,536 numbers.

#### `GR` `( b1 b2 b3 b4 b5 b6 b7 b8 c -- )`

Defines the shape of character `c` (0–127) from eight bytes, `b1` the top row. Each bit
set is an INK pixel, bit 7 on the left. It changes the character set being written,
chosen with `FONT`.

```
HEX 18 3C 7E DB FF 24 5A A5 DECIMAL 127 GR
127 EMIT
```

This turns character 127 into a small invader and prints it. Hex is easier than decimal
for row patterns: each hex digit is four pixels. Character `c + 128` shows the same shape
inverted.

### Double numbers

| Word | What it does |
|------|--------------|
| `2DUP` | Copy a double number (or a floating-point number) |
| `2DROP` | Drop a double number |
| `2SWAP` | Swap two double numbers |
| `2OVER` | Copy the second double number to the top |
| `2ROT` | Bring the third double number to the top |
| `D.` | Print a double number |
| `D.R` | Print a double number right-aligned in a field |
| `D-` | Subtract double numbers |
| `D=` | 1 if two double numbers are equal |
| `D0=` | 1 if a double number is zero |
| `DABS` | Absolute value of a double number |
| `S->D` | Turn a number into a double number |

A double number takes two stack cells, the high part on top, and holds values up to about
±2,000 million. The stock words `U*`, `D+`, `D<`, `DNEGATE` and `U/MOD` make and use
them. A floating-point number also takes two cells, so the `2…` words move those too.

#### `2DUP` `2DROP` `2SWAP` `2OVER` `2ROT`

The stack words `DUP`, `DROP`, `SWAP`, `OVER` and `ROT`, for pairs of cells:
`( d -- d d )`, `( d -- )`, `( d1 d2 -- d2 d1 )`, `( d1 d2 -- d1 d2 d1 )` and
`( d1 d2 d3 -- d2 d3 d1 )`.

```
1.5 2DUP F* F.
```

This prints `2.25`.

#### `D.` `( d -- )` · `D.R` `( d n -- )`

`D.` prints a double number and a space, like `.`. `D.R` prints it right-aligned in `n`
characters, which lines up columns; a number too wide for the field is printed whole.

```
1000 1000 U* D.
-1234 S->D 8 D.R
```

This prints `1000000`, then `-1234` after four spaces.

#### `D-` `( d1 d2 -- d )` · `D=` `( d1 d2 -- f )` · `D0=` `( d -- f )`

Subtraction and tests for double numbers (`D+` and `D<` are stock words).

```
1000 1000 U*  999 1000 U*  D- D.
```

This prints `1000`.

#### `DABS` `( d -- |d| )` · `S->D` `( n -- d )`

`DABS` removes the sign of a double number; `S->D` turns a number into a double number
with the same value.

```
-5 S->D DABS D.
```

This prints `5`.

### Floating point

| Word | What it does |
|------|--------------|
| `PI` | The number π, 3.14159 |
| `FSQRT` | Square root |
| `FSIN` `FCOS` `FTAN` | Sine, cosine and tangent of an angle in radians |
| `FABS` | Absolute value |
| `F<` `F>` | Compare two floating-point numbers |
| `F0<` `F0=` | Test a floating-point number for negative or zero |

The Ace's floating-point numbers (typed with a decimal point, like `1.5`) have six
digits; the stock words `F+` `F-` `F*` `F/` `FNEGATE` `F.` `INT` and `UFLOAT` work on
them. These words add the functions. Use `2DUP` `2DROP` `2SWAP` `2OVER` to move them on
the stack.

#### `PI` `( -- f )`

```
2. PI F* F.
```

This prints `6.28318`, the length of a circle of radius 1.

#### `FSQRT` `( f -- r )`

The square root, to all six digits. A negative number gives `ERROR 8`, the Ace's
floating-point error.

```
2. FSQRT F.   1.E6 FSQRT F.
```

This prints `1.41422 1000.`.

#### `FSIN` `( x -- f )` · `FCOS` `( x -- f )` · `FTAN` `( x -- f )`

Sine, cosine and tangent of `x` radians (degrees × `PI` / 180). They are good to about
five digits for angles up to a few turns; for very large angles (thousands of radians)
the six-digit numbers lose precision. `x` must be less than about 200,000. The tangent of
a right angle gives `ERROR 8`.

```
: DEG PI F* 180. F/ ;
30. DEG FSIN F.   60. DEG FCOS F.   45. DEG FTAN F.
```

This prints `.499999 .500001 1.00001`: right to within a few millionths.

#### `FABS` `( f -- |f| )` · `F<` `( f1 f2 -- flag )` · `F>` `( f1 f2 -- flag )`

`FABS` removes the sign. `F<` gives 1 if `f1` is less than `f2`, `F>` if it is greater.

```
-2.5 FABS F.   1. 2. F< .
```

This prints `2.5 1`.

#### `F0<` `( f -- flag )` · `F0=` `( f -- flag )`

1 if `f` is negative, or zero.

```
-.5 F0< .   0. F0= .
```

This prints `1 1`.

### Sound

| Word | What it does |
|------|--------------|
| `PLAY!` | Write an AY sound register |
| `PLAY@` | Read an AY sound register |

TurboACE has an AY-3-8910-compatible sound generator, built into its FPGA and heard
through the HDMI output. It behaves like a real AY-3-8910 clocked at 3.25 MHz.

- **Registers 0–13** make sound: three tone channels, noise and an envelope.
- **Registers 14 and 15** carry the colours, so leave them to `INK`, `PAPER` and `BORDER`.

#### `PLAY!` `( value reg -- )`

Writes `value` to AY register `reg`.

A tone's frequency is 3,250,000 / (16 × period), where the period is held in registers 0
(low byte) and 1 (high byte) for channel A. Register 8 is channel A's volume (0–15), and
register 7 switches channels on.

Register 7's top two bits don't affect the colours on TurboACE, but keeping them set
(values of 192 or more, as in the example) stays compatible with a real AY.

```
: TONE ( period -- ) 256 /MOD 1 PLAY! 0 PLAY! 15 8 PLAY! 254 7 PLAY! ;
: QUIET 0 8 PLAY! ;
203 TONE
```

`203 TONE` plays about 1 kHz on channel A until `QUIET`. A larger period gives a lower note.

#### `PLAY@` `( reg -- value )`

Reads AY register `reg`.

```
8 PLAY@ .
```

This prints channel A's volume.

### Colour

| Word | What it does |
|------|--------------|
| `INK` | Set the colour of text and drawing |
| `PAPER` | Set the background colour |
| `BORDER` | Set the border colour |
| `DARK` | Turn a colour into its dark version |
| `BLACK` `GREY` `BLUE` `GREEN` `CYAN` `RED` `PURPLE` `YELLOW` `WHITE` | Colour constants (0, 8–15) |

Colours are numbers 0–15. Bit 3 is the intensity (bright), and bits 2, 1 and 0 are red,
green and blue:

| Number | Colour | Number | Colour |
|--------|--------|--------|--------|
| 0 | black | 8 | `GREY` |
| 1 | dark blue | 9 | `BLUE` |
| 2 | dark green | 10 | `GREEN` |
| 3 | dark cyan | 11 | `CYAN` |
| 4 | dark red | 12 | `RED` |
| 5 | dark purple | 13 | `PURPLE` |
| 6 | dark yellow (brown) | 14 | `YELLOW` |
| 7 | light grey | 15 | `WHITE` |

**Text colour:**

- **Each character cell has its own colours,** taken from `INK` and `PAPER` when the
  character is written.
- **Changing colour doesn't affect what is already on screen.** `CLS` repaints every cell
  in the current colours.

**Hi-res:** the drawing words paint every 8-pixel colour cell they touch in the current
`INK` and `PAPER`.

#### `INK` `( c -- )` · `PAPER` `( c -- )` · `BORDER` `( c -- )`

Set the colour of the characters and lines (`INK`), of their background (`PAPER`), and of
the screen border (`BORDER`).

```
: TITLE  BLUE PAPER CLS  RED BORDER
  YELLOW INK ." TURBOACE"  WHITE INK ;
TITLE
```

This shows a blue screen with a red border and yellow text, and leaves white ink for what
follows.

#### `DARK` `( c -- c' )`

Gives the dark version of a colour by clearing its intensity bit. Use it with the colour
constants to reach colours 0–7.

```
RED DARK INK
```

This selects dark red ink (colour 4). `GREY DARK` is black.

#### `BLACK` `GREY` `BLUE` `GREEN` `CYAN` `RED` `PURPLE` `YELLOW` `WHITE` `( -- c )`

Colour constants: 0, 8, 9, 10, 11, 12, 13, 14 and 15.

```
WHITE INK BLACK PAPER BLACK BORDER CLS
```

This restores the power-up colours.

### Screens and memory

| Word | What it does |
|------|--------------|
| `MODE` | Switch between text (`0`) and hi-res (`1`) |
| `PG0` | Show an 8K RAM page at `$C000–$DFFF` |
| `PG1` | Show an 8K RAM page at `$E000–$FFFF` |
| `FONT` | Select one of 32 character sets |
| `VIEW` | Choose the screen that is shown |
| `WORK` | Choose the screen that is printed and drawn on |
| `SCREEN` | Choose the screen that is shown and written (`VIEW` + `WORK`) |

#### `MODE` `( n -- )`

- `0 MODE`: the stock 32×24 text screen.
- `1 MODE`: the 256×192 hi-res screen, with the text shown on top of it (see
  [Text in hi-res](#text-in-hi-res)).

Switching mode doesn't clear anything, so follow `1 MODE` with `CLS` the first time.

```
1 MODE CLS
128 96 40 CIRCLE
0 MODE
```

The circle is kept, and is there again after the next `1 MODE`.

#### `PG0` `( p -- )` · `PG1` `( p -- )`

TurboACE has 512K of extra RAM, as 64 pages of 8K. Two windows each show one page:

- `p PG0` shows page `p` at `$C000–$DFFF`;
- `p PG1` shows page `p` at `$E000–$FFFF`.

After `1 TURBO` this area holds only your data. The graphics words borrow both windows
while they draw, and always restore your pages.

```
10 PG0  HEX 1234 C000 ! DECIMAL
11 PG0  HEX C000 @ . DECIMAL
10 PG0  HEX C000 @ . DECIMAL
```

The first `.` prints whatever page 11 holds. The second prints `1234` again from page 10.

```
10 PG0  20 PG1  HEX C000 E000 2000 CMOVE DECIMAL
```

This copies all of page 10 into page 20.

Hi-res screen `n` uses pages `2n` and `2n+1` (screen 0 uses pages 0 and 1). Keep your data
in pages that your screens don't use.

#### `FONT` `( n -- )`

Selects character set `n` (0–31), both for the screen and for redefining characters.

- **Set 0** is the standard character set.
- **Sets 1–31 are not set up at power-up.** Define every character you will use before
  showing one.
- **Character data:** a character's eight rows of pixels go at
  `11264 + 8 × code`, top row first.
- **The character memory can be written but not read back.**

```
: SMILE  60 66 153 165 129 165 66 60  11552 11544 DO I C! LOOP ;
: DEMO  1 FONT  11264 1024 0 FILL  SMILE  CLS ." ###"
  BEGIN INKEY 0= UNTIL  BEGIN INKEY UNTIL  0 FONT ;
DEMO
```

`SMILE` stores a smiling face as character 35 (`#`) in the current font. Its eight rows are
listed bottom row first, because the loop stores the last number pushed first.

`DEMO` selects font 1 and blanks it, so nothing undefined shows. It adds the face, and
prints three faces until a key is pressed. Then `0 FONT` brings back the standard set, and
the same cells show `###`.

#### `VIEW` `( n -- )` · `WORK` `( n -- )` · `SCREEN` `( n -- )`

There are 32 screens, numbered 0–31. Each one has a text page, and in hi-res also a
picture.

- `n VIEW` chooses the screen that is **shown**.
- `n WORK` chooses the screen that is **written**: printing goes to its text page and
  drawing to its picture.
- `n SCREEN` does both.

Drawing on a screen that isn't shown, then showing it, gives flicker-free animation:

```
: SHOW ( n -- ) DUP WORK CLS  DUP 10 * 20 + 128 96 ROT CIRCLE  VIEW ;
1 MODE  1 SHOW  2 SHOW  3 SHOW  0 SCREEN
```

Each `SHOW` draws a circle on a hidden screen and then shows it.

There is one print position, shared by all the text pages. While `WORK` and `VIEW` differ,
what you type goes to the hidden page, so end with `n SCREEN` before returning to the
keyboard.

### Graphics

| Word | What it does |
|------|--------------|
| `PLOT` | Plot, unplot, invert or move to a point |
| `DRAW` | Draw a line or an arc from the current position |
| `CIRCLE` | Draw a circle |
| `PAINT` | Fill an enclosed area |
| `POINT` | Test whether a pixel is set |
| `ATTR` | Read the colour at a pixel or character cell |
| `INVERSE` | Make drawing erase instead of draw |
| `FLIP` | Make drawing invert pixels |
| `CLS` | Clear the screen (picture and text in hi-res) |
| `OPAQUE` | Make text over a hi-res picture transparent or opaque |

`DRAW`, `CIRCLE`, `PAINT` and `POINT` work in hi-res (`1 MODE`) only. In text mode they
do nothing, and `POINT` returns 0. `PLOT`, `CLS` and `ATTR` work in both modes.

#### `PLOT` `( x y n -- )`

Plots one point and sets the position that `DRAW` starts from. `n` selects what happens
to the pixel:

| `n` | Effect |
|-----|--------|
| 0 | unplot (clear) |
| 1 | plot (set) |
| 2 | move only |
| 3 | invert |

In text mode, `PLOT` is the stock 64×48 block `PLOT`. In hi-res, points off the screen are
ignored.

```
: DOTS 256 0 DO I 96 1 PLOT 4 +LOOP ;
1 MODE CLS DOTS
```

This draws a dotted line across the middle of the screen.

#### `DRAW` `( dx dy a -- )`

Draws from the current position to a point `dx` across and `dy` up from it, and moves the
position there. `a` is the angle to turn through on the way, in degrees:

| `a` | Line drawn |
|-----|------------|
| 0 | straight line |
| positive | arc turning anticlockwise (to the left) |
| negative | arc turning clockwise |

Parts outside the screen are not drawn, and the position stops at the screen edge.

```
: BOX  40 40 1 PLOT  100 0 0 DRAW  0 100 0 DRAW  -100 0 0 DRAW  0 -100 0 DRAW ;
: BOWL 150 140 1 PLOT  80 0 180 DRAW ;
1 MODE CLS BOX BOWL
```

`BOX` draws a square. `BOWL` draws a half circle hanging below a line 80 pixels wide.

#### `CIRCLE` `( x y r -- )`

Draws a circle with centre `x y` and radius `r`. Parts outside the screen are not drawn,
and the `DRAW` position is not changed.

```
: RINGS 90 10 DO 128 96 I CIRCLE 10 +LOOP ;
1 MODE CLS RINGS
```

This draws eight circles around the centre.

#### `PAINT` `( x y -- )`

Fills the area around `x y` with `INK`. Outlines drawn with `DRAW` and `CIRCLE` are closed
for `PAINT`, so the fill never leaks out through their diagonal steps.

- **With `1 INVERSE`, `PAINT` erases** an area of set pixels instead.
- **It gives `ERROR 1` if it runs out of memory.** This can happen with very complicated
  shapes and little free memory.
- **Speed:** a full screen takes about 1.4 seconds. Shapes broken up by many small gaps
  are slower.

```
: HOUSE  CYAN INK
  60 40 1 PLOT  100 0 0 DRAW  0 70 0 DRAW  -100 0 0 DRAW  0 -70 0 DRAW
  60 110 2 PLOT  50 50 0 DRAW  50 -50 0 DRAW
  RED INK 100 70 PAINT  YELLOW INK 110 130 PAINT ;
1 MODE CLS HOUSE
```

The walls are a box. `60 110 2 PLOT` moves to the top-left corner without drawing, and the
roof is two lines meeting at the top. The walls are then filled red and the roof yellow.

Colour belongs to 8-pixel cells, so parts of the cyan outline that share a cell with the
fill take the fill's colour.

#### `POINT` `( x y -- f )`

Returns 1 if the pixel at `x y` is set (INK), or 0 if it is clear or off the screen. Use it
to test for collisions.

```
: HIT? ( x y -- ) POINT IF ." BANG" THEN ;
1 MODE CLS  128 96 1 PLOT  128 96 HIT?
```

This prints `BANG`.

#### `ATTR` `( x y -- c )`

Returns a colour byte, PAPER × 16 + INK, or 0 if `x y` is out of range.

- **Hi-res:** the colour of the 8-pixel cell that holds pixel `x y`.
- **Text mode:** the colours of the character at column `x` (0–31) and line `y` (0–23,
  counted from the top).

```
128 96 ATTR 16 /MOD . .
```

This prints the PAPER, then the INK, at the centre of the screen.

#### `INVERSE` `( f -- )` · `FLIP` `( f -- )`

Change how `DRAW`, `CIRCLE` and `PAINT` affect pixels until you change them back:

| | `0 FLIP` | `1 FLIP` |
|---|---|---|
| `0 INVERSE` | draw (set pixels, the normal case) | invert pixels |
| `1 INVERSE` | erase (clear pixels) | move only, draw nothing |

`FLIP` flips each pixel it touches. Inverting is useful for moving
shapes: drawing the same shape twice with `1 FLIP` removes it and leaves the background
as it was. `PLOT` ignores both settings, because its `n` already selects the effect.

```
: RING 128 96 30 CIRCLE ;
1 MODE CLS RING
1 INVERSE RING 0 INVERSE
1 FLIP RING RING 0 FLIP
```

The second line erases the ring. In the third line the ring appears and disappears again.

#### `CLS` `( -- )`

Clears the screen.

- **Text mode:** the stock `CLS`.
- **Hi-res:** clears the picture of the `WORK` screen to the current `PAPER` and `INK`,
  moves the `DRAW` position to 0,0, and clears the text on top of it.

```
1 MODE  BLUE PAPER WHITE INK CLS
```

This gives an empty blue hi-res screen.

#### `OPAQUE` `( f -- )`

Sets how text looks over a hi-res picture:

- `0 OPAQUE` (the default): only the letters cover the picture.
- `1 OPAQUE`: each character also covers its 8×8 cell in its `PAPER` colour, which is
  easier to read over a busy picture.

Spaces never cover the picture.

```
: BUSY 192 0 DO 0 I 1 PLOT 255 0 0 DRAW 4 +LOOP ;
: LABEL BLACK PAPER YELLOW INK ." SCORE 100" ;
1 MODE CLS BUSY  1 OPAQUE LABEL
```

The label sits on a solid black strip over the striped picture.

### Text in hi-res

In `1 MODE` the text screen is shown on top of the picture, so `."`, `.`, the input line and
the cursor all stay visible, each character in the colours it was printed with. Spaces
are transparent, so after `CLS` the whole picture shows. With `1 OPAQUE`, each printed
character also covers its 8×8 cell with its PAPER colour, which keeps text readable over
busy pictures.

### Example: a filled, outlined disc with an arch

```
: DISC ( -- )
  1 MODE  BLACK PAPER  CLS
  YELLOW INK  128 96 60 CIRCLE  128 96 PAINT
  RED INK     128 96 60 CIRCLE
  WHITE INK   68 96 1 PLOT  120 0 0 DRAW
  GREEN INK   68 96 1 PLOT  120 0 -90 DRAW
  WHITE INK   ." A DISC" ;
DISC
```

The text `A DISC` appears in white over the picture, at the top left after `CLS`.
Type `0 MODE` to go back to text mode.


### SD card

| Word | What it does |
|------|--------------|
| `SDTAPE` | Make the stock tape words use the SD card (`1`) or the real cassette (`0`) |
| `TAPE` | Put a tape file from the card in the virtual tape player |
| `EJECT` | Empty the virtual tape player |
| `DIR` | List the files in the current folder |
| `CD` | Change the current folder |
| `DELETE` | Delete a file |
| `PGSAVE` | Save an 8K RAM page to a file |
| `PGLOAD` | Load an 8K RAM page from a file |
| `SCRSAVE` | Save a hi-res screen (picture and colours) to a file |
| `SCRLOAD` | Load a hi-res screen from a file |
| `FONTLOAD` | Load a character set from a file |
| `SDERR` | The reason for the last SD card error |

The microSD card on the TurboACE module holds an ordinary FAT file system, so a PC can
read and write it too.

- **Names:** words that take a file name read it from the line, like `SAVE name`.
- **Folder:** the current folder starts at `/programs`.
- **Errors:** any failure gives `ERROR 10`, the Ace's tape error. `SDERR` then tells you
  why.

#### `SDTAPE` `( f -- )`

With `1 SDTAPE`, the Ace's own tape words use the card instead of the cassette: `SAVE`,
`LOAD`, `BSAVE`, `BLOAD`, `VERIFY` and `BVERIFY`. Everything you know about them still
applies, but a load takes a moment instead of minutes.

- `0 SDTAPE` goes back to the real cassette, which is also the power-up setting.
- The setting stays after `0 TURBO` and `-1 TURBO`, so a plain 51K Ace, or a stock Ace,
  can load old programs from the card too.

```
1 SDTAPE
SAVE MYGAME
```

With no tape file in the player, this writes `MYGAME.TAP` in the current folder.

#### `TAPE` `( -- )` · `EJECT` `( -- )`

`TAPE name` puts a tape file in the virtual player, at its start, and turns `SDTAPE` on.
It looks for `name`, then `name.TAP`, then `name.TZX`. The tape then behaves like a
cassette:

- **`LOAD name`** searches it for that program. It gives `ERROR 10` after going once
  round the tape without finding it.
- **`LOAD` with no name** lists what is on it.
- **`SAVE`** adds to the end.

`EJECT` takes the tape out. After that, each `SAVE name` writes its own `name.TAP` file.
`TAPE` gives `ERROR 10` if the file isn't on the card, or if the name is missing or
longer than 63 characters. The tape already in the player then stays there.

```
TAPE GAMES
LOAD
LOAD INVADERS
EJECT
```

This lists the programs on `GAMES.TAP`, then loads `INVADERS` from it.

#### `DIR` `( -- )` · `CD` `( -- )` · `DELETE` `( -- )`

- **`DIR`** lists the current folder, one entry per line, folders first. A folder is
  shown with `/` after its name. A file is shown with its size: bytes under 64K,
  `nnnK` from 64K, and `65535K+` from 64 MB up. Holding SPACE stops the listing.
- **`CD name`** moves into a folder. `CD ..` goes up one level, and `CD /` goes to the
  top.
- **`DELETE name`** deletes a file.

`CD` and `DELETE` give `ERROR 10` if the folder or file isn't there; the current folder
stays as it was.

```
DIR
CD GAMES
DELETE OLDTEST.TAP
```

A listing looks like this:

```
DEMOS/
GAMES.TAP 262
MUSIC.TAP 120K
```

#### `PGSAVE` `( p -- )` · `PGLOAD` `( p -- )`

Save RAM page `p` (0–63) to `name.PG`, or load it back. The file holds exactly the
8,192 bytes of the page.

- **A shorter file** loads only the bytes it has; the rest of the page is unchanged.
- **Names:** the name plus `.PG` can be up to 63 characters.
- **Windows:** the words borrow window 0 while they work, and always give back your
  `PG0`/`PG1` pages.

```
10 PGSAVE LEVEL1
10 PGLOAD LEVEL1
```

#### `SCRSAVE` `( n -- )` · `SCRLOAD` `( n -- )`

Save hi-res screen `n` to `name.SCR`, or load it back. The file holds the picture and its
colours (12K), in the screen's own layout.

- **The screen's free 4K** at the end of page `2n+1` is not saved, and `SCRLOAD` leaves it
  alone.
- **Windows:** the words borrow both windows while they work, and give them back.

```
0 SCRSAVE TITLE
0 SCRLOAD TITLE
```

#### `FONTLOAD` `( n -- )`

Loads a character set from `name.FNT` into font `n` (0–31). The file holds 128 characters
of 8 bytes each (1,024 bytes), each character's top row first.

- **The font shown doesn't change:** follow with `n FONT` to use it.
- **A shorter file** loads only the characters it has. There is no `FONTSAVE`, because
the character memory cannot be read back. Keep your font data in RAM, and save it with
`PGSAVE` or `BSAVE`.

```
1 FONTLOAD GOTHIC  1 FONT
```

#### `SDERR` `( -- n )`

The reason for the last SD card failure, or 0 if there has been none since the machine
was switched on. A later success doesn't clear it:

| `n` | Meaning |
|-----|---------|
| 1 | no card |
| 2 | not found |
| 3 | card full |
| 4 | write-protected |
| 5 | read error |
| 6 | bad name |
| 7 | no file open |
| 8 | too large |
| 9 | bad tape block |
| 10 | end of tape |

```
SDERR .
```


### The SD card in `-1 TURBO`

`-1 TURBO` and `-2 TURBO` both make a stock Jupiter Ace until reset: only the stock words,
and `$3000`–`$3BFF` mirrors the system variables again. They differ in the tape:

- **`-1 TURBO`:** the stock ROM with only its two tape hooks (12 bytes). With `SDTAPE` on,
  `LOAD`, `SAVE`, `BLOAD`, `BSAVE`, `VERIFY` and `BVERIFY` use the card, and the tape
  chosen with `TAPE` before the switch, also when a running program calls them; with
  `SDTAPE` off, the real cassette. The last 256 bytes of the mirror (`$3B00`–`$3BFF`) stay
  TurboACE's, for the card's working state. No words are added and no dictionary space is
  used. To change tape, reset: the card words are not there in this mode.
- **`-2 TURBO`:** the original ROM, byte for byte, the whole mirror, and the real cassette
  only.

|  | Expansion | Standalone |
|---|---|---|
| `SDTAPE` at power-up | off (the real cassette) | on, and stays on (no cassette) |
| `-1 TURBO` | the card if `SDTAPE` is on (`1 SDTAPE` or `TAPE name` first), else the real cassette | the card, with the tape chosen before |
| `-2 TURBO` | the real cassette | no tape at all |

```
TAPE GAMES
-1 TURBO
LOAD INVADERS
```

Both stay one-way: only a reset brings TurboACE back.
