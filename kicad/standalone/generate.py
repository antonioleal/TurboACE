#!/usr/bin/env python3
"""Generate the standalone carrier board for KiCad 10: schematic, project, placed PCB,
BoM and schematic PDF, then check them: ERC, DRC with schematic parity, the netlist
against the table below, and the module sockets' geometry. README.md in this folder
gives the sources of every number. Run with the KiCad AppImage's Python, which brings
pcbnew, kicad-cli and the libraries:

    APP=toolchain/kicad/kicad-10.0.8-x86_64.AppImage     # ./download_toolchain.sh puts it there
    $APP python3.11 kicad/standalone/generate.py

    --force       regenerate (loses edits made by hand in KiCad)
    --check       only the checks, on the files as they are
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import kigen  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'lib'))
from make_lib import PINS, pin as P, sf_pin as L  # noqa: E402

NAME = 'standalone'
SCH = os.path.join(HERE, NAME + '.kicad_sch')
PCB = os.path.join(HERE, NAME + '.kicad_pcb')
PRO = os.path.join(HERE, NAME + '.kicad_pro')
BOM = os.path.join(HERE, NAME + '-bom.csv')
PDF = os.path.join(HERE, NAME + '-schematic.pdf')
BUILD = os.path.join(HERE, 'build')

# ---- parts ------------------------------------------------------------------------
FP = {
    'nano': 'TurboACE:TangNano20K',
    'socket': 'Connector_PinSocket_2.54mm:PinSocket_1x20_P2.54mm_Vertical',
    'kbd': 'TurboACE:MiniDIN6_PS2_Female',
    'shifter': 'TurboACE:LevelShifter_BSS138_4ch_Gebildet',
    'c': 'Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm',     # leaded ceramic, 5 mm leads
    'hole': 'MountingHole:MountingHole_3.2mm_M3',
}

# Every net and its pins (ref, pin). U1 is the module (kicad/lib: pins 1-20 its left
# header J6, 21-40 its right header J5, pin 1 of each at the USB end); every other module
# pin is left unconnected. U2 is the level shifter module (kicad/lib: the Gebildet board,
# LV1-LV4 and LV, HV1-HV4 and HV; channels 3, 4 unused).
NETS = {
    'PS2_CLK': [('U1', P('IO73')), ('U2', L('LV1'))],            # FPGA 73, 3.3 V side
    'PS2_DAT': [('U1', P('IO74')), ('U2', L('LV2'))],            # FPGA 74
    'KBD_CLK': [('J3', '5'), ('U2', L('HV1'))],                  # keyboard, 5 V side
    'KBD_DAT': [('J3', '1'), ('U2', L('HV2'))],
    '+5V': [('U1', '21'), ('U2', L('HV')), ('C1', '1'), ('J3', '4')],
    '+3V3': [('U1', '19'), ('U1', '36'), ('U2', L('LV'))],
    'GND': [('U1', '20'), ('U1', '22'), ('U1', '35'), ('U2', L('GND', 'low')), ('U2', L('GND', 'high')),
            ('C1', '2'), ('J3', '3'), ('J3', 'SH')],
}

# ref: (symbol, value, footprint, description)
PARTS = {
    'U1': ('TurboACE:TangNano20K', 'TangNano20K', 'nano',
           'Sipeed Tang Nano 20K, plugged into J1 (left header J6, pins 1-20) and J2 (right header J5, 21-40)'),
    'J1': ('TurboACE:Socket_1x20', 'Conn_01x20_Socket', 'socket', 'for U1 left header (J6); BoM only'),
    'J2': ('TurboACE:Socket_1x20', 'Conn_01x20_Socket', 'socket', 'for U1 right header (J5); BoM only'),
    'J3': ('TurboACE:MiniDIN6_PS2_Female', 'PS/2 socket', 'kbd',
           'PS/2 keyboard socket, 6-pin mini-DIN female, right angle, shielded (Mauser 011-0716): '
           '1 DATA, 3 GND, 4 +5V, 5 CLK, shield GND'),
    'U2': ('TurboACE:LevelShifter_BSS138_4ch_Gebildet', 'Level shifter 4ch BSS138', 'shifter',
           'Gebildet 4-channel BSS138 level shifter (SparkFun BOB-12009 layout), soldered on its two 6-pin '
           'headers: channel 1 clock, 2 data; LV 3.3 V, HV 5 V; 10k pull-ups on board'),
    'C1': ('Device:C', '100n', 'c', 'keyboard supply decoupling, at J3'),
    'H1': ('Mechanical:MountingHole', 'MountingHole', 'hole', 'M3'),
    'H2': ('Mechanical:MountingHole', 'MountingHole', 'hole', 'M3'),
    'H3': ('Mechanical:MountingHole', 'MountingHole', 'hole', 'M3'),
    'H4': ('Mechanical:MountingHole', 'MountingHole', 'hole', 'M3'),
}

# The schematic (mm, A4; 2.54 mm grid): the module U1 drawn as seen from above, USB
# end up (J6 on the left, J5 on the right, each header's pin 1 at the top); signal flow
# right to left on straight wires: U1 -> level shifter U2 -> PS/2 socket J3.
# ref: (x, y, rotation, mirror); U2 is mirrored so its LV side faces U1.
SHEET = {
    'U1': (203.2, 102.87, 0, None),      # as the module from above, USB end up: J6 left
    'J1': (254.0, 124.46, 0, None), 'J2': (254.0, 137.16, 0, None),
    'U2': (147.32, 85.09, 0, 'y'),       # LV side toward U1; LV1/HV1 on U1 pin 1's row
    'J3': (111.76, 81.28, 0, None),      # CLK and DATA on U1 pins 1 and 2's rows
    'C1': (91.44, 80.01, 0, None),
    'H1': (114.3, 139.7, 0, None), 'H2': (132.08, 139.7, 0, None),
    'H3': (149.86, 139.7, 0, None), 'H4': (167.64, 139.7, 0, None),
}
WIRED = {'U1': ('1', '2', '19', '20', '21', '22', '35', '36'), 'J3': ('1', '3', '4', '5', 'SH'),
         'U2': tuple(L(n) for n in ('LV1', 'LV2', 'HV1', 'HV2', 'LV', 'HV')) + (L('GND', 'low'), L('GND', 'high'))}

# ---- board (mm; the board's top-left corner at (100, 100), the USB end on the left) ----
X0, Y0 = 100.0, 100.0
W, H = 54.04, 60.0                  # flush with the module's ends (USB-C, HDMI overhang)
MOD_TOP = 9.0                       # the module's edge, from the board's top edge
MOD_H = 22.55                       # module 54.04 x 22.55 (Sipeed, v3921 drawing)
ROWS = 20.32                        # header rows, centre to centre
PIN1_X = 2.62                       # first pin from the module's USB end
ROW_TOP = MOD_TOP + MOD_H / 2 - ROWS / 2       # J2 (right header, J5)
ROW_BOT = ROW_TOP + ROWS                       # J1 (left header, J6)

PLACE = {   # ref: (x, y, angle, locked), relative to (X0, Y0)
    'U1': (PIN1_X, ROW_BOT, 0, True, (W / 2, ROW_BOT - 5.0)),     # pad 1: J6 pin 1, USB end
    # J3, the PS/2 socket, at the USB edge, its front face on it, so the keyboard plugs in
    # on the same side as the USB cable; low enough that its shield tab clears U1's pins
    'J3': (0.0, 40.2, 90, False, (10.5, 49.8)),
    'C1': (17.0, 49.5, 0, False),                  # near J3, keyboard supply decoupling
    # U2 turned half round so its LV row is the one nearer U1, LV1 at its USB end, the HV
    # row below
    'U2': (15.5, 35.0, 180, False),
    'H1': (4.0, 4.0, 0, True, None), 'H2': (W - 4.0, 4.0, 0, True, None),
    'H3': (4.0, H - 4.0, 0, True, None), 'H4': (W - 4.0, H - 4.0, 0, True, None),
}

RULES = {'min_clearance': 0.2, 'min_track_width': 0.2, 'min_via_diameter': 0.6,
         'min_through_hole_diameter': 0.3, 'min_copper_edge_clearance': 0.5}
CLASSES = [
    {'name': 'Default', 'clearance': 0.2, 'track_width': 0.25, 'via_diameter': 0.6, 'via_drill': 0.3},
    {'name': 'Power', 'clearance': 0.2, 'track_width': 0.5, 'via_diameter': 0.8, 'via_drill': 0.4},
]
PATTERNS = [('+5V', 'Power'), ('+3V3', 'Power'), ('GND', 'Power')]


MOD_Y = MOD_TOP + MOD_H / 2
RECTS = [(0, 0, W, H, 'Edge.Cuts', 0.1)]          # the module's outline is in its footprint
TEXTS = [('TurboACE standalone carrier', W / 2, 3.2, 1.0, 'F.SilkS'),
         ('TANG NANO 20K', W / 2, MOD_Y, 1.0, 'F.SilkS'),
]                                                   # USB and HDMI: in U1's footprint
TITLE = ('TurboACE standalone carrier', '0.1', '2026-11-19')


def generate(force):
    kigen.refuse_overwrite([SCH, PCB, PRO], force)
    pins = {}
    for net, members in NETS.items():
        for ref, pin in members:
            pins.setdefault(ref, {})[pin] = net
    sch = kigen.Schematic(NAME, *TITLE)
    end = {}
    for ref, (sym, value, fp, desc) in PARTS.items():
        x, y, rot, mirror = SHEET[ref]
        for pin, xy in sch.add(sym, ref, value, x, y, FP[fp], pins.get(ref, {}), {'Description': desc},
                               rot, mirror, WIRED.get(ref, ())).items():
            end[ref, pin] = xy

    def e(ref, pin):
        return end[ref, pin]
    # straight through, right to left: U1 IO73/IO74 - U2 LV1/LV2, U2 HV1/HV2 - J3 CLK/DATA
    clk_y, dat_y = e('U1', '1')[1], e('U1', '2')[1]
    sch.wire(e('U1', '1'), (172.72, clk_y), e('U2', L('LV1')))
    sch.wire(e('U1', '2'), (170.18, dat_y), e('U2', L('LV2')))
    sch.wire(e('U2', L('HV1')), (121.92, clk_y), e('J3', '5'))
    sch.wire(e('U2', L('HV2')), (124.46, dat_y), e('J3', '1'))
    sch.label('PS2_CLK', 172.72, clk_y)
    sch.label('PS2_DAT', 170.18, dat_y)
    sch.label('KBD_CLK', 121.92, clk_y)
    sch.label('KBD_DAT', 124.46, dat_y)
    # U2's supplies, sideways out of its sides (LV and HV are just below the signal
    # wires): the LV side faces U1 (right), the HV side J3 (left); both GNDs down
    for name, side, net, a, d in (('LV', None, '+3V3', 0, 5.08), ('HV', None, '+5V', 180, -5.08),
                                  ('GND', 'low', 'GND', 270, 7.62), ('GND', 'high', 'GND', 270, -7.62)):
        x, y = e('U2', L(name, side))
        sch.wire((x, y), (x + d, y))
        sch.power(net, x + d, y, a)
    # J3's supply and shield: short wires out to the right; +5V sideways (the DATA wire is
    # just above it), GND and the shield down
    for pin, net, a, d in (('4', '+5V', 0, 2.54), ('3', 'GND', 270, 5.08), ('SH', 'GND', 270, 5.08)):
        x, y = e('J3', pin)
        sch.wire((x, y), (x + d, y))
        sch.power(net, x + d, y, a)
    sch.field_at('U1', 'Value', SHEET['U1'][0], e('U1', '20')[1] + 6.35)
    # the module's supply pins: J6 (left) +3V3 up, GND down; J5 (right) +5V and +3V3 out
    # to the right, its two GND pins joined with one GND symbol
    for pin, net, a in (('19', '+3V3', 90), ('20', 'GND', 270)):
        x, y = e('U1', pin)
        sch.wire((x, y), (x - 5.08, y))
        sch.power(net, x - 5.08, y, a)
    x, y = e('U1', '21')
    sch.wire((x, y), (x + 5.08, y))
    sch.power('+5V', x + 5.08, y, 90)
    (x2, y2), (x15, y15) = e('U1', '22'), e('U1', '35')
    gx, gy = x2 + 7.62, (y2 + y15) / 2
    gy = round(gy / 2.54) * 2.54
    sch.wire((x2, y2), (gx, y2), (gx, gy), (gx, y15), (x15, y15))
    sch.wire((gx, gy), (gx + 5.08, gy))
    sch.junction(gx, gy)
    sch.power('GND', gx + 5.08, gy, 270)
    x, y = e('U1', '36')
    sch.wire((x, y), (x + 12.7, y))
    sch.power('+3V3', x + 12.7, y, 90)
    sch.flag('+5V', 228.6, 152.4)
    sch.flag('+3V3', 246.38, 152.4)
    sch.flag('GND', 264.16, 152.4)
    sch.text('Tang Nano 20K on two 1x20 sockets, rows 20.32 mm apart, pin 1 of each at the USB end.\n'
             'U1 pins 1-20 = module left header (J6), 21-40 = right header (J5); J1, J2 the sockets (BoM only). PS/2: FPGA 73 (CLK), 74 (DATA).\n'
             'U2: Gebildet 4-channel BSS138 level shifter (SparkFun BOB-12009 layout), channels 1-2: a BSS138 each, 10k pull-ups on both sides.\n'
             'J3: PS/2 socket (mini-DIN 6 female, at the board edge): 1 DATA, 3 GND, 4 +5V, 5 CLK, shield to GND.',
             25.4, 160.02)
    sch.write(SCH)
    kigen.write_project(PRO, RULES, CLASSES, PATTERNS)
    os.makedirs(BUILD, exist_ok=True)
    comps, nets = kigen.netlist(SCH, os.path.join(BUILD, NAME + '.net'))
    place = {r: (X0 + p[0], Y0 + p[1]) + tuple(p[2:4])
             + ((None if p[4] is None else (X0 + p[4][0], Y0 + p[4][1]),) if len(p) > 4 else ())
             for r, p in PLACE.items()}
    kigen.build_pcb(PCB, SCH, TITLE, comps, nets, place,
                    [(X0 + a, Y0 + b, X0 + c, Y0 + d, l, w) for a, b, c, d, l, w in RECTS],
                    [(t, X0 + x, Y0 + y, sz, l) for t, x, y, sz, l in TEXTS], board_less=('J1', 'J2'))


def check():
    import json
    import pcbnew
    os.makedirs(BUILD, exist_ok=True)
    ok = True
    comps, nets = kigen.netlist(SCH, os.path.join(BUILD, NAME + '.net'))
    probs = kigen.check_nets(NETS, nets)
    for p in probs:
        print('  FAIL', p)
    print('  %s netlist = table (%d nets, %d parts)' % ('ok  ' if not probs else 'FAIL', len(NETS), len(comps)))
    ok &= not probs

    erc = os.path.join(BUILD, 'erc.json')
    kigen.cli('sch', 'erc', '--format', 'json', '--severity-all', '-o', erc, SCH)
    v = [x for s in json.load(open(erc))['sheets'] for x in s['violations']]
    for x in v:
        print('    ERC %s: %s' % (x['severity'], x['description']))
    print('  %s ERC: %d violations' % ('ok  ' if not v else 'FAIL', len(v)))
    ok &= not v

    drc = os.path.join(BUILD, 'drc.json')
    kigen.cli('pcb', 'drc', '--format', 'json', '--severity-all', '--schematic-parity', '-o', drc, PCB)
    d = json.load(open(drc))
    viol = d['violations']
    unconn = d.get('unconnected_items', [])
    parity = d.get('schematic_parity', [])
    for x in viol + parity:
        print('    DRC %s: %s' % (x['severity'], x['description']))
    print('  %s DRC: %d violations, %d parity issues, %d unconnected (to route by hand)'
          % ('ok  ' if not viol and not parity else 'FAIL', len(viol), len(parity), len(unconn)))
    ok &= not viol and not parity

    # the module's sockets: rows 20.32 mm apart, pads at 2.54 mm running toward the HDMI end
    board = pcbnew.LoadBoard(PCB)
    pad = {}
    for fp in board.GetFootprints():
        for p in fp.Pads():
            pad[(fp.GetReference(), p.GetNumber())] = (pcbnew.ToMM(p.GetPosition().x), pcbnew.ToMM(p.GetPosition().y))
    geo = (abs(pad[('U1', '1')][1] - pad[('U1', '21')][1] - ROWS) < 1e-3
           and abs(pad[('U1', '20')][0] - pad[('U1', '1')][0] - 19 * 2.54) < 1e-3
           and abs(pad[('U1', '40')][0] - pad[('U1', '21')][0] - 19 * 2.54) < 1e-3
           and abs(pad[('U1', '1')][0] - pad[('U1', '21')][0]) < 1e-3
           and abs(pad[('U1', '1')][0] - (X0 + PIN1_X)) < 1e-3
           and pad[('U1', '1')][1] > pad[('U1', '21')][1]           # J6 the bottom row
           # U2: its LV row (pins 1-6) the one nearer U1, 10.16 mm from the HV row, and
           # the labelled side up as in the seller's photo: from LV1 along the LV row to
           # LV4, the HV row is on the right (y down: the cross product is positive)
           and pad[('U2', '1')][1] < pad[('U2', '7')][1]
           and abs(pad[('U2', '7')][1] - pad[('U2', '1')][1] - 10.16) < 1e-3
           and ((pad[('U2', '6')][0] - pad[('U2', '1')][0]) * (pad[('U2', '7')][1] - pad[('U2', '1')][1])
                - (pad[('U2', '6')][1] - pad[('U2', '1')][1]) * (pad[('U2', '7')][0] - pad[('U2', '1')][0])) > 0)
    print('  %s module: rows 20.32 mm apart, pin 1 of both at the USB end, pins 2.54 mm '
          'toward HDMI, J6 the bottom row; U2 LV row toward U1, labelled side up' % ('ok  ' if geo else 'FAIL'))
    ok &= geo
    # J3: the socket's front face on the USB edge (the plug goes in there), its pins 8.5
    # and 11.0 mm behind it
    j3 = [fp for fp in board.GetFootprints() if fp.GetReference() == 'J3'][0]
    xs = [pcbnew.ToMM(s.GetBoundingBox().GetLeft()) for s in j3.GraphicalItems() if s.GetLayer() == pcbnew.F_Fab]
    edge = (abs(min(xs) - X0) < 0.1 and abs(pad[('J3', '1')][0] - X0 - 8.5) < 0.05
            and abs(pad[('J3', '5')][0] - X0 - 11.0) < 0.05)
    print('  %s J3 front face on the USB edge, its pins behind it' % ('ok  ' if edge else 'FAIL'))
    ok &= edge
    nc = board.FindNet('+5V').GetNetClassName()       # 'Power,Default': class, fallback
    print('  %s +5V is in net class %s' % ('ok  ' if nc.split(',')[0] == 'Power' else 'FAIL', nc))
    ok &= nc.split(',')[0] == 'Power'

    kigen.cli('sch', 'export', 'bom', '-o', BOM, '--fields', 'Reference,Value,Footprint,${QUANTITY},Description',
              '--labels', 'Refs,Value,Footprint,Qty,Description', '--group-by', 'Value,Footprint', SCH)
    kigen.cli('sch', 'export', 'pdf', '-o', PDF, SCH)
    print('  BoM: %s; schematic PDF: %s' % (os.path.relpath(BOM), os.path.relpath(PDF)))
    return ok


if __name__ == '__main__':
    if '--check' not in sys.argv:
        generate('--force' in sys.argv)
        # the checks in a fresh process: pcbnew keeps the project settings it saw while
        # the board was being made, and would read the net classes back stale
        import subprocess
        sys.exit(subprocess.run([sys.executable, os.path.abspath(__file__), '--check']).returncode)
    sys.exit(0 if check() else 1)
