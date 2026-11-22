"""kigen: generate a KiCad 10 schematic and a placed (unrouted) PCB from one table of
parts and nets, with the symbols and footprints of the KiCad installation it runs in.
Used by kicad/*/generate.py, run with the KiCad AppImage's Python (README.md):

    toolchain/kicad/kicad-10.0.8-x86_64.AppImage python3.11 kicad/standalone/generate.py

The schematic is drawn by the board's script with wire(), junction(), label() and
power() between the pin ends add() returns; a pin left out of the drawing gets a net
label or power symbol at its end, and an unused pin a no-connect flag. It is written,
then saved again by kicad-cli (sch upgrade), so the file is in KiCad's own current
format. The PCB is built with KiCad's pcbnew module from the netlist KiCad
exports for that schematic, so net names and the symbol-footprint links are KiCad's,
and the parity check holds. Nothing existing is overwritten unless asked (force=True):
the PCB is routed by hand afterwards.
"""
import json
import os
import re
import subprocess
import uuid as _uuid

# the libraries: the AppImage's own (it sets KICAD_STOCK_DATA_HOME), else a system install
KICAD = os.environ.get('KICAD_STOCK_DATA_HOME', '/usr/share/kicad')
if os.environ.get('KICAD_CLI'):
    CLI = os.environ['KICAD_CLI'].split()
elif os.environ.get('SHARUN_DIR'):                        # inside the AppImage
    CLI = [os.path.join(os.environ['SHARUN_DIR'], 'AppRun'), 'kicad-cli']
else:
    CLI = ['kicad-cli']
SCH_VERSION = '20250610'
# the project's own library (kicad/lib, made by lib/make_lib.py): name -> (symbols, footprints)
LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib')
PROJECT_LIBS = {'TurboACE': (os.path.join(LIB, 'TurboACE.kicad_sym'), os.path.join(LIB, 'TurboACE.pretty'))}            # what is written; kicad-cli then saves the current one


# ---- s-expressions -----------------------------------------------------------------

class Q(str):
    """A quoted string (written back with quotes)."""


_TOK = re.compile(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+')


def _unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def parse(text):
    stack = [[]]
    for m in _TOK.finditer(text):
        t = m.group(0)
        if t == '(':
            stack.append([])
        elif t == ')':
            x = stack.pop()
            stack[-1].append(x)
        elif t[0] == '"':
            stack[-1].append(Q(_unescape(t[1:-1])))
        else:
            stack[-1].append(t)
    return stack[0][0]


def num(v):
    s = ('%.4f' % v).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def dump(x, ind=0):
    if isinstance(x, list):
        i = 0
        while i < len(x) and not isinstance(x[i], list):
            i += 1
        s = '(' + ' '.join(dump(a) for a in x[:i])
        for c in x[i:]:
            s += '\n' + '\t' * (ind + 1) + dump(c, ind + 1)
        return s + ')'
    if isinstance(x, Q):
        return '"' + x.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
    if isinstance(x, float):
        return num(x)
    return str(x)


def child(lst, key):
    for c in lst:
        if isinstance(c, list) and c and c[0] == key:
            return c
    return None


def children(lst, key):
    return [c for c in lst if isinstance(c, list) and c and c[0] == key]


def uid():
    return Q(str(_uuid.uuid4()))


# ---- symbol libraries --------------------------------------------------------------

def _load_symbol(lib, name):
    """A symbol from the library: a folder of one file per symbol (KiCad 10), or a
    single library file."""
    d = '%s/symbols/%s.kicad_symdir/%s.kicad_sym' % (KICAD, lib, name)
    f = PROJECT_LIBS[lib][0] if lib in PROJECT_LIBS else \
        d if os.path.exists(d) else '%s/symbols/%s.kicad_sym' % (KICAD, lib)
    with open(f, encoding='utf-8') as fh:
        doc = parse(fh.read())
    for s in children(doc, 'symbol'):
        if s[1] == name:
            return s
    raise SystemExit('%s:%s: not in the library' % (lib, name))


def lib_symbol(lib_id):
    """The library symbol, flattened if derived (as the schematic embeds it) and named
    lib_id, and its pins {number: (x, y, angle, type)} in library coordinates (y up)."""
    lib, name = lib_id.split(':')
    s = _load_symbol(lib, name)
    ext = child(s, 'extends')
    if ext:
        parent = _load_symbol(lib, str(ext[1]))
        if child(parent, 'extends'):
            raise SystemExit('%s: derived twice, not supported' % lib_id)
        own = {str(p[1]): p for p in children(s, 'property')}
        body = []
        for c in parent[2:]:
            if isinstance(c, list) and c[0] == 'property' and str(c[1]) in own:
                body.append(own.pop(str(c[1])))
            elif isinstance(c, list) and c[0] == 'symbol':      # units: Parent_u_s -> Name_u_s
                body.append([c[0], Q(name + str(c[1])[len(str(parent[1])):])] + c[2:])
            else:
                body.append(c)
        body += list(own.values())
        s = ['symbol', Q(lib_id)] + body
    else:
        s = ['symbol', Q(lib_id)] + s[2:]
    pins = {}
    for unit in children(s, 'symbol'):
        for p in children(unit, 'pin'):
            at = child(p, 'at')
            pins[str(child(p, 'number')[1])] = (float(at[1]), float(at[2]), int(float(at[3])), p[1])
    return s, pins


# ---- schematic -----------------------------------------------------------------------

def _font():
    return ['effects', ['font', ['size', 1.27, 1.27]]]


def xform(px, py, rot=0, mirror=None):
    """A library point (y up) placed with rotation rot (degrees, counter-clockwise) and
    then mirror ('y': left-right), as an offset in sheet coordinates (y down)."""
    c, s = {0: (1, 0), 90: (0, 1), 180: (-1, 0), 270: (0, -1)}[rot % 360]
    x, y = px * c - py * s, px * s + py * c
    if mirror == 'y':
        x = -x
    return x, -y


def xangle(a, rot=0, mirror=None):
    a = (a + rot) % 360
    return (180 - a) % 360 if mirror == 'y' else a


class Schematic:
    def __init__(self, project, title, rev, date):
        self.project = project
        self.root = uid()
        self.lib = {}
        self.items = []
        self.pwr = 0
        self.title = (title, rev, date)
        self.placed = {}            # ref -> symbol uuid

    def _sym(self, lib_id):
        if lib_id not in self.lib:
            self.lib[lib_id] = lib_symbol(lib_id)
        return self.lib[lib_id]

    def _place(self, lib_id, ref, value, x, y, rot=0, footprint='', fields=None, mirror=None):
        sym, pins = self._sym(lib_id)
        u = uid()
        values = {'Reference': ref, 'Value': value, 'Footprint': footprint}
        values.update(fields or {})
        props = []
        for p in children(sym, 'property'):
            name = str(p[1])
            if name.startswith('ki_'):                  # library-only fields
                continue
            at = child(p, 'at')
            dx, dy = xform(float(at[1]), float(at[2]), rot, mirror)
            a = int(float(at[3])) if len(at) > 3 else 0
            # a field's angle is taken relative to the symbol: keep the text horizontal
            prop = ['property', Q(name), Q(values.pop(name, p[2])), ['at', x + dx, y + dy, (a + rot) % 180]]
            prop += [c for c in p[3:] if isinstance(c, list) and c[0] != 'at']
            props.append(prop)
        for name, val in values.items():                 # fields the symbol does not have
            props.append(['property', Q(name), Q(val), ['at', x, y, 0], ['hide', 'yes'], _font()])
        flag = {k: str((child(sym, k) or [k, 'yes'])[1]) for k in ('in_bom', 'on_board')}
        s = ['symbol', ['lib_id', Q(lib_id)], ['at', x, y, rot]] + ([['mirror', mirror]] if mirror else []) + [
             ['unit', 1],
             ['exclude_from_sim', 'no'], ['in_bom', flag['in_bom']],
             ['on_board', flag['on_board']], ['dnp', 'no'], ['uuid', u]] + props
        s += [['pin', Q(n), ['uuid', uid()]] for n in pins]
        s.append(['instances', ['project', Q(self.project),
                                ['path', Q('/' + self.root), ['reference', Q(ref)], ['unit', 1]]]])
        self.items.append(s)
        return u, pins

    def power(self, net, x, y, angle):
        """A power symbol for net at (x, y), its body pointing at angle (90: up)."""
        self.pwr += 1
        base = 90 if net.startswith('+') else 270      # where the body points
        self._place('power:' + net, '#PWR%02d' % self.pwr, net, x, y, (angle - base) % 360)

    def flag(self, net, x, y):
        """A PWR_FLAG on net (the module's supply pins are passive): the power symbol at
        (x, y), a short wire down, the flag below it."""
        self.wire((x, y), (x, y + 5.08))
        self.pwr += 1
        if net == 'GND':                                  # the flag above, ground below
            self._place('power:PWR_FLAG', '#FLG%02d' % self.pwr, 'PWR_FLAG', x, y, 0)
            self.power(net, x, y + 5.08, 270)
        else:                                             # the supply above, the flag below
            self.power(net, x, y, 90)
            self._place('power:PWR_FLAG', '#FLG%02d' % self.pwr, 'PWR_FLAG', x, y + 5.08, 180)

    def add(self, lib_id, ref, value, x, y, footprint, nets, fields=None, rot=0, mirror=None,
            wired=()):
        """Place a part; nets maps pin numbers to net names (power nets: '+...' or
        'GND'). A pin in wired is left for a wire (drawn with wire()); any other pin of a
        net gets a power symbol or label at its end; every remaining pin a no-connect
        flag. Returns {pin: (x, y)}, where each pin's end is."""
        u, pins = self._place(lib_id, ref, value, x, y, rot, footprint, fields, mirror)
        self.placed[ref] = str(u)
        unknown = (set(nets) | set(wired)) - set(pins)
        if unknown:
            raise SystemExit('%s: no pins %s' % (ref, sorted(unknown)))
        ends = {}
        for n, (px, py, pa, _) in pins.items():
            dx, dy = xform(px, py, rot, mirror)
            ex, ey = x + dx, y + dy
            ends[n] = (ex, ey)
            out = (xangle(pa, rot, mirror) + 180) % 360   # away from the symbol's body
            net = nets.get(n)
            if n in wired:
                continue
            if net is None:
                self.items.append(['no_connect', ['at', ex, ey], ['uuid', uid()]])
            elif net.startswith('+') or net == 'GND':
                self.power(net, ex, ey, out)
            else:
                self.label(net, ex, ey, out)
        return ends

    def field_at(self, ref, name, x, y):
        """Move a placed symbol's field (e.g. its value, off a wire)."""
        for s in self.items:
            if s[0] == 'symbol' and str(child(child(child(child(s, 'instances'), 'project'), 'path'),
                                              'reference')[1]) == ref:
                for p in children(s, 'property'):
                    if str(p[1]) == name:
                        at = child(p, 'at')
                        at[1:3] = [x, y]
                        return
        raise SystemExit('%s: no field %s' % (ref, name))

    def label(self, net, x, y, angle=0):
        just = {0: 'left', 90: 'left', 180: 'right', 270: 'right'}[angle]
        self.items.append(['label', Q(net), ['at', x, y, angle],
                           _font() + [['justify', just, 'bottom']], ['uuid', uid()]])

    def wire(self, *points):
        """A wire through points (each a corner or a connection: pin ends, labels and
        T joints must be among them)."""
        for (x1, y1), (x2, y2) in zip(points, points[1:]):
            self.items.append(['wire', ['pts', ['xy', x1, y1], ['xy', x2, y2]],
                               ['stroke', ['width', 0], ['type', 'default']], ['uuid', uid()]])

    def junction(self, x, y):
        self.items.append(['junction', ['at', x, y], ['diameter', 0], ['color', 0, 0, 0, 0],
                           ['uuid', uid()]])

    def text(self, s, x, y):
        self.items.append(['text', Q(s), ['exclude_from_sim', 'no'], ['at', x, y, 0],
                           _font() + [['justify', 'left', 'bottom']], ['uuid', uid()]])

    def write(self, path):
        t, rev, date = self.title
        doc = ['kicad_sch', ['version', SCH_VERSION], ['generator', Q('eeschema')],
               ['generator_version', Q('10.0')], ['uuid', self.root], ['paper', Q('A4')],
               ['title_block', ['title', Q(t)], ['date', Q(date)], ['rev', Q(rev)]],
               ['lib_symbols'] + [s for s, _ in self.lib.values()]]
        doc += self.items
        doc += [['sheet_instances', ['path', Q('/'), ['page', Q('1')]]], ['embedded_fonts', 'no']]
        with open(path, 'w', encoding='utf-8') as f:
            f.write(dump(doc) + '\n')
        cli('sch', 'upgrade', '--force', path)          # resaved by KiCad, in its format


# ---- kicad-cli -----------------------------------------------------------------------

def cli(*args):
    r = subprocess.run(CLI + list(args), capture_output=True, text=True)
    if r.returncode not in (0, 5):                  # 5: violations found (reported)
        raise SystemExit('kicad-cli %s failed (%d):\n%s%s' % (' '.join(args), r.returncode, r.stdout, r.stderr))
    return r


def netlist(sch, out):
    """{ref: (value, footprint, symbol uuid, {field: text})}, {net: {(ref, pin), ...}}
    as KiCad sees it."""
    cli('sch', 'export', 'netlist', '--format', 'kicadsexpr', '-o', out, sch)
    with open(out, encoding='utf-8') as f:
        n = parse(f.read())
    comps = {}
    for c in children(child(n, 'components'), 'comp'):
        ts = child(c, 'tstamps') or child(c, 'tstamp')
        fp = child(c, 'footprint')
        fields = {str(child(f, 'name')[1]): str(f[2]) for f in children(child(c, 'fields') or [], 'field')
                  if len(f) > 2 and str(child(f, 'name')[1]) != 'Footprint'}
        comps[str(child(c, 'ref')[1])] = (str(child(c, 'value')[1]), str(fp[1]) if fp else '',
                                          str(ts[1]), fields)
    nets = {}
    for e in children(child(n, 'nets'), 'net'):
        nets[str(child(e, 'name')[1])] = {(str(child(d, 'ref')[1]), str(child(d, 'pin')[1]))
                                          for d in children(e, 'node')}
    return comps, nets


def check_nets(table_nets, nets):
    """The netlist against the table: every table net, exactly; every other pin alone."""
    problems = []
    named = {name.lstrip('/'): pins for name, pins in nets.items()}
    for name, pins in table_nets.items():
        got = named.get(name)
        if got != set(pins):
            problems.append('net %s: table %s, netlist %s' % (name, sorted(pins), sorted(got or [])))
    for name, pins in named.items():
        if name not in table_nets and len(pins) > 1:
            problems.append('net %s not in the table: %s' % (name, sorted(pins)))
    return problems


# ---- PCB ---------------------------------------------------------------------------

def build_pcb(path, sch_file, title, comps, nets, place, rects, texts, board_less=()):
    """place: {ref: (x, y, angle, locked[, reference])} (absolute mm), reference being
    where the reference text goes, (x, y), or None to hide it; rects: [(x1, y1, x2,
    y2, layer, width)]; texts: [(text, x, y, size, layer)]; board_less: refs that are only
    BoM lines (symbols marked not on the board)."""
    import pcbnew
    mm = pcbnew.VECTOR2I_MM
    board = pcbnew.BOARD()
    tb = board.GetTitleBlock()
    tb.SetTitle(title[0])
    tb.SetRevision(title[1])
    tb.SetDate(title[2])
    netinfo = {}
    for name in sorted(nets):
        ni = pcbnew.NETINFO_ITEM(board, name)
        board.Add(ni)
        netinfo[name] = ni
    pad_net = {pin: name for name, pins in nets.items() for pin in pins}
    for ref, (value, fpid, sym_uuid, fields) in sorted(comps.items()):
        lib, name = fpid.split(':')
        if ref in board_less:
            continue
        fp = pcbnew.FootprintLoad(PROJECT_LIBS[lib][1] if lib in PROJECT_LIBS
                                  else '%s/footprints/%s.pretty' % (KICAD, lib), name)
        if fp is None:
            raise SystemExit('%s: footprint %s not found' % (ref, fpid))
        fp.SetFPID(pcbnew.LIB_ID(lib, name))
        fp.SetReference(ref)
        fp.SetValue(value)
        for k, v in fields.items():                       # as Update PCB from Schematic
            fp.SetField(k, v)
        fp.SetPath(pcbnew.KIID_PATH('/' + sym_uuid))
        fp.SetSheetname('')
        fp.SetSheetfile(os.path.basename(sch_file))
        x, y, a, locked = place[ref][:4]
        fp.SetPosition(mm(x, y))
        fp.SetOrientationDegrees(a)
        if len(place[ref]) > 4:
            r = place[ref][4]
            if r is None:
                fp.Reference().SetVisible(False)
            else:
                fp.Reference().SetPosition(mm(*r))
                fp.Reference().SetTextAngleDegrees(0)
                fp.Value().SetPosition(mm(r[0], r[1] + 1.5))   # (on F.Fab) just below
                fp.Value().SetTextAngleDegrees(0)
        for pad in fp.Pads():
            n = pad_net.get((ref, pad.GetNumber()))
            if n:
                pad.SetNet(netinfo[n])
        fp.SetLocked(locked)
        board.Add(fp)
    layer = {'Edge.Cuts': pcbnew.Edge_Cuts, 'F.SilkS': pcbnew.F_SilkS, 'F.Fab': pcbnew.F_Fab}
    for x1, y1, x2, y2, l, w in rects:
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(pcbnew.SHAPE_T_RECT)
        s.SetStart(mm(x1, y1))
        s.SetEnd(mm(x2, y2))
        s.SetLayer(layer[l])
        s.SetWidth(pcbnew.FromMM(w))
        board.Add(s)
    for txt, x, y, size, l in texts:
        t = pcbnew.PCB_TEXT(board)
        t.SetText(txt)
        t.SetPosition(mm(x, y))
        t.SetLayer(layer[l])
        t.SetTextSize(mm(size, size))
        t.SetTextThickness(pcbnew.FromMM(size * 0.15))
        board.Add(t)
    pcbnew.SaveBoard(path, board)


def write_project(path, rules, classes, patterns):
    """A project file with the board rules and net classes (KiCad fills in every other
    setting with its defaults)."""
    pro = {
        'board': {'design_settings': {'rules': rules}},
        'meta': {'filename': os.path.basename(path), 'version': 1},
        'net_settings': {'classes': classes, 'meta': {'version': 3},
                         'netclass_patterns': [{'netclass': c, 'pattern': p} for p, c in patterns]},
    }
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(pro, f, indent=2)
        f.write('\n')


def refuse_overwrite(paths, force):
    """Never overwrite work: not while KiCad has the project open (its lock files), not a
    PCB with any routing (tracks, vias, zones) even with force, and nothing else without
    force."""
    folder = os.path.dirname(os.path.abspath(paths[0]))
    locks = [f for f in os.listdir(folder) if f.startswith('~') and f.endswith('.lck')]
    if locks:
        raise SystemExit('KiCad has the project open (%s): close it first' % ', '.join(locks))
    for p in paths:
        if p.endswith('.kicad_pcb') and os.path.exists(p):
            with open(p, encoding='utf-8') as f:
                pcb = f.read()
            if re.search(r'\((segment|arc|via|zone)\b', pcb):
                raise SystemExit('%s has routing done by hand: not regenerating it, even with --force '
                                 '(change it in KiCad, or move it away first)' % os.path.basename(p))
    there = [p for p in paths if os.path.exists(p)]
    if there and not force:
        raise SystemExit('not overwriting %s (the board may have been edited by hand); '
                         'use --force to regenerate' % ', '.join(there))
