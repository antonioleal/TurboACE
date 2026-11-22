#!/usr/bin/env python3
"""Write TurboACE's KiCad library (KiCad 10): TurboACE.kicad_sym and TurboACE.pretty.

    $APP python3.11 kicad/lib/make_lib.py      (APP: the KiCad AppImage, ../README.md)

- TangNano20K: the Sipeed Tang Nano 20K module. Pins 1-20 are its left header (J6 on
  Sipeed's v3923 schematic), 21-40 its right header (J5), pin 1 of each at the USB end;
  names as the schematic (IOnn = FPGA pin nn). Footprint: the two rows 20.32 mm apart,
  2.54 mm pitch, pad 1 at the origin, the module (54.04 x 22.55 mm, v3921 drawing) on
  F.Fab and its courtyard, so nothing is placed under it. Seen from above with the USB
  end on the left, J6 (pads 1-20) is the bottom row.
- Socket_1x20: one 1x20 female header for the module, a BoM line only (not on the
  board: the module footprint has the pads).
- LevelShifter_BSS138_4ch: the Adafruit 4-channel BSS138 level shifter (product 757):
  four BSS138 channels, each with 10k pull-ups to LV and HV. Pins 1-6 its low-side
  header (GND A4 A3 A2 A1 LV), 7-12 its high-side header (GND B4 B3 B2 B1 HV). The
  footprint: the two 1x6 rows 10.16 mm apart, the board (15.24 x 20.45 mm) on F.Fab.
  From Adafruit's Eagle files (github.com/adafruit/4-Channel-Level-Shifter-PCB,
  CC BY-SA, Limor Fried/Ladyada for Adafruit Industries).
- LevelShifter_BSS138_4ch_Gebildet: the same circuit on the Gebildet board (a copy of
  SparkFun's BOB-12009, github.com/sparkfun/Logic_Level_Bidirectional, CC BY-SA). Its
  labelled side, mounted facing up (its BSS138s toward the carrier), reads left to
  right LV4 LV3 GND LV LV2 LV1 on one row and HV4 HV3 GND HV HV2 HV1 on the other (the
  seller's photo; SparkFun's top view in the mirror). Pins 1-6 LV1 LV2 LV GND LV3 LV4,
  7-12 HV1 HV2 HV GND HV3 HV4; rows 10.16 mm apart; 15.24 x 12.7 mm.
- MiniDIN6_PS2_Female: the 6-pin mini-DIN (PS/2) female socket, right angle, shielded,
  for the PCB edge: Mauser 011-0716 (its listing's drawing; the pins are those of the
  Same Sky MD-60S). Pins 1 DATA, 2 NC, 3 GND, 4 +5V, 5 CLK, 6 NC, SH the shield (three
  tabs). The front face at the footprint's y = 0, the socket facing -y.

Both files are saved again by kicad-cli (sym/fp upgrade), so they are in KiCad's format.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from kigen import Q, dump, uid, CLI  # noqa: E402

# Sipeed Tang Nano 20K, v3923 schematic: J6 (left) and J5 (right), pin 1 at the USB end
J6 = ['IO73', 'IO74', 'IO75', 'IO85', 'IO77', 'IO15', 'IO16', 'IO27', 'IO28', 'IO25',
      'IO26', 'IO29', 'IO30', 'IO31', 'IO17', 'IO20', 'IO19', 'IO18', '3V3', 'GND']
J5 = ['5V', 'GND', 'IO76', 'IO80', 'IO42', 'IO41', 'IO56', 'IO54', 'IO51', 'IO48',
      'IO55', 'IO49', 'IO86', 'IO79', 'GND', '3V3', 'IO72', 'IO71', 'IO53_DDC_CLK', 'IO52_DDC_DAT']
PINS = {str(i + 1): n for i, n in enumerate(J6 + J5)}      # pad number -> name


def pin(name):
    """The pad number of a named module pin (e.g. 'IO73' -> '1'); the first if repeated."""
    for k, v in PINS.items():
        if v == name:
            return k
    raise KeyError(name)


# the Adafruit level shifter: pins as its Eagle board (JP3 low side, JP4 high side)
LS_LOW = ['GND', 'A4', 'A3', 'A2', 'A1', 'LV']
LS_HIGH = ['GND', 'B4', 'B3', 'B2', 'B1', 'HV']
LS_PINS = {str(i + 1): n for i, n in enumerate(LS_LOW + LS_HIGH)}


# the Gebildet board (SparkFun BOB-12009 circuit): pin numbers by name; their places
# are in gebildet_footprint()
SF_LOW = ['LV1', 'LV2', 'LV', 'GND', 'LV3', 'LV4']
SF_HIGH = ['HV1', 'HV2', 'HV', 'GND', 'HV3', 'HV4']


def sf_pin(name, side=None):
    """The SparkFun-layout shifter's pin number for a name ('LV1' -> '1'; 'GND' needs
    side 'low' or 'high')."""
    if name == 'GND':
        return str(SF_LOW.index('GND') + (7 if side == 'high' else 1))
    return str((SF_LOW + SF_HIGH).index(name) + 1)


def ls_pin(name, side=None):
    """The level shifter's pin number for a name ('A1' -> '5'; 'GND' needs side 'low'
    or 'high')."""
    names = LS_LOW if side == 'low' else LS_HIGH if side == 'high' else LS_LOW + LS_HIGH
    off = 6 if side == 'high' else 0
    return str(names.index(name) + 1 + off) if side else \
        next(k for k, v in LS_PINS.items() if v == name)


ROWS, PITCH = 20.32, 2.54
MOD_W, MOD_H, PIN1_X = 54.04, 22.55, 2.62      # module size; pin 1 from the USB end


def font(size=1.27):
    return ['effects', ['font', ['size', size, size]]]


def prop(name, value, x, y, hide=False):
    p = ['property', Q(name), Q(value), ['at', x, y, 0]]
    if hide:
        p.append(['hide', 'yes'])
    return p + [font()]


def symbols():
    body_y = PITCH * 10.5                      # 26.67
    pins = []
    for i, name in enumerate(J6):              # left side, top to bottom
        pins.append(('%d' % (i + 1), name, -15.24, PITCH * 9.5 - PITCH * i, 0))
    for i, name in enumerate(J5):              # right side
        pins.append(('%d' % (i + 21), name, 15.24, PITCH * 9.5 - PITCH * i, 180))
    unit = ['symbol', Q('TangNano20K_1_1')]
    for num, name, x, y, a in pins:
        kind = 'passive' if name in ('5V', '3V3', 'GND') else 'bidirectional'
        unit.append(['pin', kind, 'line', ['at', x, y, a], ['length', 2.54],
                     ['name', Q(name), font()], ['number', Q(num), font()]])
    nano = ['symbol', Q('TangNano20K'), ['pin_names', ['offset', 1.016]],
            ['exclude_from_sim', 'no'], ['in_bom', 'yes'], ['on_board', 'yes'],
            prop('Reference', 'U', 0, body_y + 2.54),
            prop('Value', 'TangNano20K', 0, -body_y - 2.54),
            prop('Footprint', 'TurboACE:TangNano20K', 0, 0, True),
            prop('Datasheet', 'https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html', 0, 0, True),
            prop('Description', 'Sipeed Tang Nano 20K FPGA module (GW2AR-18). Pins 1-20: left header J6, '
                 '21-40: right header J5, pin 1 of each at the USB end (Sipeed v3923). '
                 'IO52/IO53 are the HDMI DDC (EDID) lines.', 0, 0, True),
            prop('ki_keywords', 'Sipeed Tang Nano 20K FPGA Gowin module', 0, 0, True),
            ['symbol', Q('TangNano20K_0_1'),
             ['rectangle', ['start', -12.7, body_y], ['end', 12.7, -body_y],
              ['stroke', ['width', 0.254], ['type', 'default']], ['fill', ['type', 'background']]]],
            unit, ['embedded_fonts', 'no']]
    sock = ['symbol', Q('Socket_1x20'), ['exclude_from_sim', 'yes'], ['in_bom', 'yes'], ['on_board', 'no'],
            prop('Reference', 'J', 0, 3.81),
            prop('Value', 'Conn_01x20_Socket', 0, -3.81),
            prop('Footprint', 'Connector_PinSocket_2.54mm:PinSocket_1x20_P2.54mm_Vertical', 0, 0, True),
            prop('Datasheet', '~', 0, 0, True),
            prop('Description', '1x20 female header, 2.54 mm, for the module (BoM only: the module '
                 'footprint has the pads)', 0, 0, True),
            ['symbol', Q('Socket_1x20_0_1'),
             ['rectangle', ['start', -5.08, 1.27], ['end', 5.08, -1.27],
              ['stroke', ['width', 0.254], ['type', 'default']], ['fill', ['type', 'none']]]],
            ['embedded_fonts', 'no']]
    # level shifter: low side on the left (LV at the top), high side on the right
    order = ['LV', 'A1', 'A2', 'A3', 'A4', 'GND']
    lsu = ['symbol', Q('LevelShifter_BSS138_4ch_1_1')]
    for side, names, x, a, off in (('low', LS_LOW, -10.16, 0, 0), ('high', LS_HIGH, 10.16, 180, 6)):
        for name in names:
            row = order.index(name.replace('B', 'A').replace('HV', 'LV'))
            kind = 'passive' if name in ('GND', 'LV', 'HV') else 'bidirectional'
            lsu.append(['pin', kind, 'line', ['at', x, 6.35 - 2.54 * row, a], ['length', 2.54],
                        ['name', Q(name), font()], ['number', Q(str(names.index(name) + 1 + off)), font()]])
    shifter = ['symbol', Q('LevelShifter_BSS138_4ch'), ['pin_names', ['offset', 1.016]],
               ['exclude_from_sim', 'no'], ['in_bom', 'yes'], ['on_board', 'yes'],
               prop('Reference', 'U', 0, 10.16),
               prop('Value', 'Adafruit 757', 0, -10.16),
               prop('Footprint', 'TurboACE:LevelShifter_BSS138_4ch', 0, 0, True),
               prop('Datasheet', 'https://www.adafruit.com/product/757', 0, 0, True),
               prop('Description', 'Adafruit 4-channel bi-directional level shifter (product 757): '
                    'BSS138 per channel, 10k pull-ups to LV and HV. Pins 1-6 low side (GND A4 A3 A2 '
                    'A1 LV), 7-12 high side (GND B4 B3 B2 B1 HV). From Adafruit\'s Eagle files '
                    '(CC BY-SA, Limor Fried/Ladyada for Adafruit Industries).', 0, 0, True),
               prop('ki_keywords', 'level shifter BSS138 I2C bidirectional module Adafruit', 0, 0, True),
               ['symbol', Q('LevelShifter_BSS138_4ch_0_1'),
                ['rectangle', ['start', -7.62, 8.89], ['end', 7.62, -8.89],
                 ['stroke', ['width', 0.254], ['type', 'default']], ['fill', ['type', 'background']]]],
               lsu, ['embedded_fonts', 'no']]
    # the Gebildet shifter: pins top to bottom in the order of the board's rows
    sfu = ['symbol', Q('LevelShifter_BSS138_4ch_Gebildet_1_1')]
    for names, x, a, off, supply in ((SF_LOW, -10.16, 0, 0, 'LV'), (SF_HIGH, 10.16, 180, 6, 'HV')):
        rows = names                      # top to bottom in the board's own order
        for i, name in enumerate(names):
            kind = 'passive' if name in ('GND', 'LV', 'HV') else 'bidirectional'
            sfu.append(['pin', kind, 'line', ['at', x, 6.35 - 2.54 * rows.index(name), a], ['length', 2.54],
                        ['name', Q(name), font()], ['number', Q(str(i + 1 + off)), font()]])
    sfe = ['symbol', Q('LevelShifter_BSS138_4ch_Gebildet'), ['pin_names', ['offset', 1.016]],
           ['exclude_from_sim', 'no'], ['in_bom', 'yes'], ['on_board', 'yes'],
           prop('Reference', 'U', 0, 10.16),
           prop('Value', 'Level shifter 4ch BSS138', 0, -10.16),
           prop('Footprint', 'TurboACE:LevelShifter_BSS138_4ch_Gebildet', 0, 0, True),
           prop('Datasheet', 'https://github.com/sparkfun/Logic_Level_Bidirectional', 0, 0, True),
           prop('Description', 'Gebildet 4-channel bi-directional level shifter (SparkFun BOB-12009 '
                'circuit): BSS138 per channel, 10k pull-ups to LV and HV. Pins 1-6 LV1 LV2 LV GND LV3 LV4, '
                '7-12 HV1 HV2 HV GND HV3 HV4; mounted labelled side up.', 0, 0, True),
           prop('ki_keywords', 'level shifter BSS138 I2C bidirectional module Gebildet SparkFun BOB-12009', 0, 0, True),
           ['symbol', Q('LevelShifter_BSS138_4ch_Gebildet_0_1'),
            ['rectangle', ['start', -7.62, 8.89], ['end', 7.62, -8.89],
             ['stroke', ['width', 0.254], ['type', 'default']], ['fill', ['type', 'background']]]],
           sfu, ['embedded_fonts', 'no']]
    # the PS/2 socket: pins on the right, signals at the top
    psu = ['symbol', Q('MiniDIN6_PS2_Female_1_1')]
    for i, (num, name) in enumerate((('5', 'CLK'), ('1', 'DATA'), ('4', '+5V'), ('3', 'GND'),
                                     ('2', 'NC'), ('6', 'NC'), ('SH', 'SHIELD'))):
        psu.append(['pin', 'passive', 'line', ['at', 5.08, 2.54 - 2.54 * i, 180], ['length', 2.54],
                    ['name', Q(name), font()], ['number', Q(num), font()]])
    ps2 = ['symbol', Q('MiniDIN6_PS2_Female'), ['pin_names', ['offset', 1.016]],
           ['exclude_from_sim', 'no'], ['in_bom', 'yes'], ['on_board', 'yes'],
           prop('Reference', 'J', -1.27, 6.35),
           prop('Value', 'PS/2 socket', -1.27, -16.51),
           prop('Footprint', 'TurboACE:MiniDIN6_PS2_Female', 0, 0, True),
           prop('Datasheet', 'https://mauser.pt/011-0716/ficha-mini-din-6-pinos-ps-2-femea-para-soldar-em-pcb-90', 0, 0, True),
           prop('Description', '6-pin mini-DIN (PS/2) female, right angle, shielded, PCB edge (Mauser '
                '011-0716): 1 DATA, 3 GND, 4 +5V, 5 CLK, 2 and 6 not connected, SH the shield.', 0, 0, True),
           prop('ki_keywords', 'PS/2 mini-DIN 6 keyboard socket female', 0, 0, True),
           ['symbol', Q('MiniDIN6_PS2_Female_0_1'),
            ['rectangle', ['start', -6.35, 5.08], ['end', 2.54, -15.24],
             ['stroke', ['width', 0.254], ['type', 'default']], ['fill', ['type', 'background']]]],
           psu, ['embedded_fonts', 'no']]
    return ['kicad_symbol_lib', ['version', 20251024], ['generator', Q('kicad_symbol_editor')],
            ['generator_version', Q('10.0')], nano, sock, shifter, sfe, ps2]


def line(x1, y1, x2, y2, layer, w):
    return ['fp_line', ['start', x1, y1], ['end', x2, y2], ['stroke', ['width', w], ['type', 'solid']],
            ['layer', Q(layer)], ['uuid', uid()]]


def rect(x1, y1, x2, y2, layer, w):
    return ['fp_rect', ['start', x1, y1], ['end', x2, y2], ['stroke', ['width', w], ['type', 'solid']],
            ['fill', 'no'], ['layer', Q(layer)], ['uuid', uid()]]


def text(s, x, y, layer, size=1.0, angle=0):
    return ['fp_text', 'user', Q(s), ['at', x, y, angle], ['layer', Q(layer)], ['uuid', uid()],
            ['effects', ['font', ['size', size, size], ['thickness', round(size * 0.15, 3)]]]]


def footprint():
    x0, x1 = -PIN1_X, MOD_W - PIN1_X                 # the module, pad 1 at the origin
    yc = -ROWS / 2
    y0, y1 = yc - MOD_H / 2, yc + MOD_H / 2
    last = PITCH * 19
    fp = ['footprint', Q('TangNano20K'), ['version', 20241229], ['generator', Q('kigen')],
          ['layer', Q('F.Cu')],
          ['descr', Q('Sipeed Tang Nano 20K on two 1x20 female headers, rows 20.32 mm apart (Sipeed v3921 '
                      'drawing). Pads 1-20: left header J6 (bottom row, USB end on the left), 21-40: '
                      'right header J5.')],
          ['tags', Q('Sipeed Tang Nano 20K FPGA module socket')],
          ['property', Q('Reference'), Q('REF**'), ['at', last / 2, yc + 3, 0], ['layer', Q('F.SilkS')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['property', Q('Value'), Q('TangNano20K'), ['at', last / 2, yc - 3, 0], ['layer', Q('F.Fab')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['attr', 'through_hole'],
          rect(x0, y0, x1, y1, 'F.Fab', 0.1),
          rect(x0 - 0.25, y0 - 0.25, x1 + 0.25, y1 + 0.25, 'F.CrtYd', 0.05),
          text('USB', x0 + 2.5, yc, 'F.SilkS', 0.9), text('HDMI', x1 - 3, yc, 'F.SilkS', 0.9)]
    for y in (0, -ROWS):                             # each socket's outline, pin 1 marked
        fp.append(rect(-1.33, y - 1.33, last + 1.33, y + 1.33, 'F.SilkS', 0.12))
    fp.append(line(-1.33, 1.6, -1.33 + 1.0, 1.6, 'F.SilkS', 0.12))          # pad 1
    fp.append(line(-1.33, -ROWS - 1.6, -1.33 + 1.0, -ROWS - 1.6, 'F.SilkS', 0.12))  # pad 21
    for i in range(40):
        x = PITCH * (i % 20)
        y = 0 if i < 20 else -ROWS
        shape = 'rect' if i in (0, 20) else 'oval'
        fp.append(['pad', Q(str(i + 1)), 'thru_hole', shape, ['at', x, y], ['size', 1.7, 1.7],
                   ['drill', 1.0], ['layers', Q('*.Cu'), Q('*.Mask')], ['uuid', uid()]])
    fp.append(['embedded_fonts', 'no'])
    return fp


def shifter_footprint():
    """Pad 1 (low-side GND) at the origin; the low-side row runs up (-y), the high-side
    row 10.16 mm to the right. Eagle (x, y) -> (x - 2.54, 3.81 - y)."""
    def at(x, y):
        return x - 2.54, 3.81 - y
    (x0, y1), (x1, y0) = at(0, 0), at(15.24, 20.447)
    fp = ['footprint', Q('LevelShifter_BSS138_4ch'), ['version', 20241229], ['generator', Q('kigen')],
          ['layer', Q('F.Cu')],
          ['descr', Q('Adafruit 4-channel BSS138 level shifter (product 757), soldered on its two 1x6 '
                      'headers; rows 10.16 mm apart (Adafruit Eagle files, CC BY-SA)')],
          ['tags', Q('level shifter BSS138 module Adafruit 757')],
          ['property', Q('Reference'), Q('REF**'), ['at', 5.08, y0 - 1.5, 0], ['layer', Q('F.SilkS')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['property', Q('Value'), Q('Adafruit 757'), ['at', 5.08, -6.35, 90], ['layer', Q('F.Fab')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['attr', 'through_hole'],
          rect(x0, y0, x1, y1, 'F.Fab', 0.1),
          rect(x0 - 0.25, y0 - 0.25, x1 + 0.25, y1 + 0.25, 'F.CrtYd', 0.05),
          rect(x0, y0, x1, y1, 'F.SilkS', 0.12)]
    for col, names, off in ((0, LS_LOW, 0), (10.16, LS_HIGH, 6)):
        for i, name in enumerate(names):
            y = -2.54 * i
            fp.append(['pad', Q(str(i + 1 + off)), 'thru_hole', 'rect' if i == 0 else 'oval', ['at', col, y],
                       ['size', 1.7, 1.7], ['drill', 1.0], ['layers', Q('*.Cu'), Q('*.Mask')], ['uuid', uid()]])
            fp.append(text(name, col + (2.3 if col == 0 else -2.3), y, 'F.SilkS', 0.8))
    fp.append(['embedded_fonts', 'no'])
    return fp


def gebildet_footprint():
    """Pad 1 (LV1) at the origin; as the board's labelled side reads from above (the
    seller's photo): the LV row runs LV1 to LV4 toward -x, the HV row 10.16 mm beyond it
    (-y), HV1 above LV1. (SparkFun's top view, the side with the BSS138s, is its mirror.)"""
    x0, x1, y0, y1 = -13.97, 1.27, -11.43, 1.27
    fp = ['footprint', Q('LevelShifter_BSS138_4ch_Gebildet'), ['version', 20241229], ['generator', Q('kigen')],
          ['layer', Q('F.Cu')],
          ['descr', Q('Gebildet 4-channel BSS138 level shifter (SparkFun BOB-12009 circuit), soldered on its '
                      'two 1x6 headers, labelled side up (its BSS138s toward the carrier); rows 10.16 mm apart')],
          ['tags', Q('level shifter BSS138 module Gebildet SparkFun BOB-12009')],
          ['property', Q('Reference'), Q('REF**'), ['at', -6.35, y0 - 1.5, 0], ['layer', Q('F.SilkS')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['property', Q('Value'), Q('Level shifter 4ch BSS138'), ['at', -6.35, -5.08, 0], ['layer', Q('F.Fab')],
           ['uuid', uid()], ['effects', ['font', ['size', 0.8, 0.8], ['thickness', 0.12]]]],
          ['attr', 'through_hole'],
          rect(x0, y0, x1, y1, 'F.Fab', 0.1),
          rect(x0 - 0.25, y0 - 0.25, x1 + 0.25, y1 + 0.25, 'F.CrtYd', 0.05),
          rect(x0, y0, x1, y1, 'F.SilkS', 0.12)]
    for row_y, names, off, label_y in ((0, SF_LOW, 0, -2.6), (-10.16, SF_HIGH, 6, -7.56)):
        for i, name in enumerate(names):
            x = -2.54 * i
            fp.append(['pad', Q(str(i + 1 + off)), 'thru_hole', 'rect' if i == 0 else 'oval', ['at', x, row_y],
                       ['size', 1.7, 1.7], ['drill', 1.0], ['layers', Q('*.Cu'), Q('*.Mask')], ['uuid', uid()]])
            fp.append(text(name, x, label_y, 'F.SilkS', 0.8, 90))
    fp.append(['embedded_fonts', 'no'])
    return fp


def ps2_footprint():
    """The Mauser 011-0716 socket from above (its drawing is a bottom view, mirrored
    here): the front face on y = 0, the socket facing -y, the body 14 mm wide and 13 deep
    (the depth is not given: taken as the height). Pins (holes 0.9): 4 2 1 3 left to
    right 8.5 mm back, 6 and 5 behind 4 and 3 at 11.0; shield tabs (slots 2.2 x 0.7): one
    across at the middle 4.7 back, two lengthwise 13.5 mm apart 5.5 back."""
    w, d = 14.0, 13.0
    pins = {'4': (-3.4, 8.5), '2': (-1.3, 8.5), '1': (1.3, 8.5), '3': (3.4, 8.5),
            '6': (-3.4, 11.0), '5': (3.4, 11.0)}
    fp = ['footprint', Q('MiniDIN6_PS2_Female'), ['version', 20241229], ['generator', Q('kigen')],
          ['layer', Q('F.Cu')],
          ['descr', Q('6-pin mini-DIN (PS/2) female, right angle, shielded, at the PCB edge (Mauser 011-0716, '
                      'its listing\'s drawing; pins as Same Sky MD-60S). Front face on y = 0.')],
          ['tags', Q('PS/2 mini-DIN 6 keyboard socket')],
          ['property', Q('Reference'), Q('REF**'), ['at', 0, d + 1.5, 0], ['layer', Q('F.SilkS')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['property', Q('Value'), Q('PS/2 socket'), ['at', 0, 2.0, 0], ['layer', Q('F.Fab')],
           ['uuid', uid()], ['effects', ['font', ['size', 1, 1], ['thickness', 0.15]]]],
          ['attr', 'through_hole'],
          rect(-w / 2, 0, w / 2, d, 'F.Fab', 0.1),
          rect(-8.1, -0.25, 8.1, d + 0.25, 'F.CrtYd', 0.05),
          # the silkscreen on the sides and back only (the front face is the board edge),
          # the sides just outside the shield tabs' pads
          line(-7.85, 1.0, -7.85, d + 0.12, 'F.SilkS', 0.12),
          line(7.85, 1.0, 7.85, d + 0.12, 'F.SilkS', 0.12),
          line(-7.85, d + 0.12, 7.85, d + 0.12, 'F.SilkS', 0.12),
          text('PS/2', 0, 6.5, 'F.SilkS', 1.0)]
    for n, (x, y) in pins.items():
        fp.append(['pad', Q(n), 'thru_hole', 'circle', ['at', x, y], ['size', 1.6, 1.6], ['drill', 0.9],
                   ['layers', Q('*.Cu'), Q('*.Mask')], ['uuid', uid()]])
    for x, y, a in ((0, 4.7, 0), (-6.75, 5.5, 90), (6.75, 5.5, 90)):
        fp.append(['pad', Q('SH'), 'thru_hole', 'oval', ['at', x, y, a], ['size', 3.0, 1.5],
                   ['drill', 'oval', 2.2, 0.7], ['layers', Q('*.Cu'), Q('*.Mask')], ['uuid', uid()]])
    fp.append(['embedded_fonts', 'no'])
    return fp


def main():
    sym = os.path.join(HERE, 'TurboACE.kicad_sym')
    pretty = os.path.join(HERE, 'TurboACE.pretty')
    os.makedirs(pretty, exist_ok=True)
    with open(sym, 'w', encoding='utf-8') as f:
        f.write(dump(symbols()) + '\n')
    with open(os.path.join(pretty, 'TangNano20K.kicad_mod'), 'w', encoding='utf-8') as f:
        f.write(dump(footprint()) + '\n')
    with open(os.path.join(pretty, 'LevelShifter_BSS138_4ch.kicad_mod'), 'w', encoding='utf-8') as f:
        f.write(dump(shifter_footprint()) + '\n')
    with open(os.path.join(pretty, 'LevelShifter_BSS138_4ch_Gebildet.kicad_mod'), 'w', encoding='utf-8') as f:
        f.write(dump(gebildet_footprint()) + '\n')
    with open(os.path.join(pretty, 'MiniDIN6_PS2_Female.kicad_mod'), 'w', encoding='utf-8') as f:
        f.write(dump(ps2_footprint()) + '\n')
    for args in (['sym', 'upgrade', '--force', sym], ['fp', 'upgrade', '--force', pretty]):
        r = subprocess.run(CLI + args, capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('kicad-cli %s: %s%s' % (' '.join(args), r.stdout, r.stderr))
    print('wrote', os.path.relpath(sym), 'and', os.path.relpath(pretty))


if __name__ == '__main__':
    main()
