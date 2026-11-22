#!/usr/bin/env python3
"""Static checks on the assembled TurboACE ROM pages (no emulator needed).

Usage: romcheck.py BUILD_DIR
  BUILD_DIR holds stock.rom, page0.bin..page7.bin and turboace.sym
  (sjasmplus --sym output).

Checks (register-map.md section 5):
  1. page 0 is the stock ROM, byte for byte;
  2. page 1 differs from stock only at $008E-$0091 (the boot hook);
  3. pages 2-7 carry the stock copy ranges, with only $0153 patched;
  4. page 2 boot entry ($0092) and exit ($0097-$009A) are in place;
  5. code reachable from the interrupt vector and RST $10/$18 stays inside the
     copy ranges in every extension page; boot and graphics code stay inside
     page 2's code area;
  6. the XDICT image fits below the state area ($3B00);
  7. the dictionary chain from the last extension word runs through the stock
     ROM to the end, every name decodes, and no stock word is shadowed except
     the ones listed in ALLOWED_SHADOWS.
Exit status 0 if every check passes.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z80trace import trace  # noqa: E402

COPY_RANGES = [(0x0010, 0x0020), (0x0038, 0x003B), (0x013A, 0x017E),
               (0x0310, 0x03EE), (0x0859, 0x0865)]
PATCH_0153 = 0x18                       # JR Z ($28) -> JR ($18)
HOOK = bytes([0x3E, 0xC2, 0xD3, 0xE3])  # LD A,$C2 / OUT ($E3),A
EXIT = bytes([0x3E, 0xC1, 0xD3, 0xE3])  # LD A,$C1 / OUT ($E3),A
TAPE_HOOK = bytes([0x3E, 0xC3, 0xD3, 0xE3])     # LD A,$C3 / OUT ($E3),A
# page 1 differs from stock only here (boot hook, tape block write, block read)
PAGE1_PATCHES = {0x008E: HOOK, 0x1820: TAPE_HOOK, 0x18A7: TAPE_HOOK}
# page 3 fixed stubs: address -> bytes (register-map.md section 5, "Tape hooks")
PAGE3_EXITS = [0x04EC, 0x1828, 0x18A2, 0x18A7, 0x1AB2]   # each EXIT, on to +4 in page 1
PAGE3_ENTRIES = {0x1824: 'TWRITE_HOOK', 0x18AB: 'TREAD_HOOK'}
XDICT_BASE, XSTATE = 0x3000, 0x3B00
FORTH_LINK0 = 0x1FFF
ALLOWED_SHADOWS = {'PLOT', 'CLS'}       # supersets of the stock words (MODE 0 = stock)

failures = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        failures.append(msg)


def in_ranges(addr, ranges):
    return any(s <= addr < e for s, e in ranges)


def load_syms(path):
    syms = {}
    for line in open(path):
        m = re.match(r'\s*([A-Za-z_][\w.]*)\s*:?\s*(?:EQU|equ)\s+(?:0x|\$)?([0-9A-Fa-f]+)', line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def walk_dict(mem, nlf):
    """Yield (nlf, name, cfa contents) following links until link 0."""
    seen = set()
    while nlf and nlf not in seen:
        seen.add(nlf)
        ln = mem[nlf] & 0x3F
        link = mem[nlf - 2] | mem[nlf - 1] << 8
        raw = mem[nlf - 2 - ln:nlf - 2]
        if ln and (not raw[-1] & 0x80 or any(c & 0x80 for c in raw[:-1])):
            raise ValueError(f'bad name at NLF {nlf:04X}')
        name = bytes(c & 0x7F for c in raw).decode('ascii')
        cf = mem[nlf + 1] | mem[nlf + 2] << 8
        yield nlf, name, cf
        nlf = link
    if nlf:
        raise ValueError(f'dictionary loop at {nlf:04X}')


def main(build):
    stock = open(os.path.join(build, 'stock.rom'), 'rb').read()
    pages = [open(os.path.join(build, f'page{n}.bin'), 'rb').read() for n in range(8)]
    syms = load_syms(os.path.join(build, 'turboace.sym'))

    print('pages')
    check(all(len(p) == 0x2000 for p in pages), 'eight 8K pages')
    check(pages[0] == stock, 'page 0 is the stock ROM')
    diff1 = [a for a in range(0x2000) if pages[1][a] != stock[a]]
    allowed1 = {a for s in PAGE1_PATCHES for a in range(s, s + 4)}
    check(diff1 and set(diff1) <= allowed1,
          f'page 1 differs from stock only at the hooks $008E, $1820, $18A7 ({len(diff1)} bytes)')
    for at, code in PAGE1_PATCHES.items():
        check(pages[1][at:at + 4] == code,
              f'page 1 hook at ${at:04X} = LD A,${code[1]:02X} / OUT ($E3),A')

    print('extension pages: copy ranges')
    for n in range(2, 8):
        p = pages[n]
        bad = [a for s, e in COPY_RANGES for a in range(s, e)
               if p[a] != (PATCH_0153 if a == 0x0153 else stock[a])]
        check(not bad, f'page {n} copy ranges match stock except $0153'
              + (f' (first mismatch ${bad[0]:04X})' if bad else ''))

    print('page 2 boot hook')
    p2 = pages[2]
    boot_setup = syms.get('BOOT_SETUP')
    check(boot_setup is not None, 'symbol BOOT_SETUP present')
    check(p2[0x0092] == 0xC3 and (p2[0x0093] | p2[0x0094] << 8) == boot_setup,
          '$0092: JP BOOT_SETUP')
    check(p2[0x0097:0x009B] == EXIT, '$0097: LD A,$C1 / OUT ($E3),A (returns to $009B)')

    print('page 3 tape hooks')
    p3 = pages[3]
    for at in PAGE3_EXITS:
        check(p3[at:at + 4] == EXIT, f'page 3 ${at:04X}: LD A,$C1 / OUT ($E3),A (on to ${at + 4:04X} in page 1)')
    for at, label in PAGE3_ENTRIES.items():
        ok = label in syms and p3[at] == 0xC3 and (p3[at + 1] | p3[at + 2] << 8) == syms[label]
        check(ok, f'page 3 ${at:04X}: JP {label}')
    stops3 = {at + 4 for at in PAGE3_EXITS}
    code3 = [(0x0865, syms.get('SDPAGE_END', 0))] + [(at, at + 4) for at in PAGE3_EXITS] + COPY_RANGES
    for label in list(PAGE3_ENTRIES.values()) + ['SD_TAPE_INSERT', 'SD_TAPE_EJECT', 'SD_CD', 'SD_DELETE', 'SD_DIR_ENTRY',
                                                        'SD_PG_SAVE', 'SD_PG_LOAD', 'SD_SCR_SAVE', 'SD_SCR_LOAD',
                                                        'SD_FONT_LOAD']:
        if label in syms:
            seen, _, odd = trace(p3, [syms[label]], stops=stops3)
            outside = [a for a in seen if not in_ranges(a, code3)]
            check(not outside, f'{label}: reachable code stays in page 3 code and its exit stubs'
                  + (f' (escapes at ${outside[0]:04X})' if outside else ''))

    print('reachability')
    for n in range(2, 8):
        seen, _, odd = trace(pages[n], [0x0038, 0x0010, 0x0018])
        outside = [a for a in seen if not in_ranges(a, COPY_RANGES)]
        check(not outside and not odd,
              f'page {n}: interrupt and RST $10/$18 paths stay in the copy ranges'
              + (f' (escapes at ${outside[0]:04X})' if outside else ''))
    code_area = [(0x0092, 0x009B), (syms.get('XDICT_IMAGE', 0), syms.get('PAGE2_END', 0))]
    allowed = code_area + COPY_RANGES
    for label in ('BOOT_SETUP', 'HPLOT', 'HDRAW', 'HCIRCLE', 'HPOINT', 'HCLS', 'HATTR', 'HPAINT', 'HSTOCK'):
        if label not in syms:
            check(False, f'symbol {label} present')
            continue
        seen, _, odd = trace(p2, [syms[label]], stops={0x009B})
        outside = [a for a in seen if not in_ranges(a, allowed)]
        check(not outside, f'{label}: all reachable code inside page 2 code + copy ranges'
              + (f' (escapes at ${outside[0]:04X})' if outside else ''))

    print('XDICT')
    img, length = syms.get('XDICT_IMAGE'), syms.get('XDICT_LEN')
    last = syms.get('XDICT_LAST_NLF')
    check(None not in (img, length, last), 'symbols XDICT_IMAGE, XDICT_LEN, XDICT_LAST_NLF present')
    if None in (img, length, last):
        return
    check(XDICT_BASE + length <= XSTATE,
          f'image is {length} bytes, ends at ${XDICT_BASE + length:04X} (limit $3B00)')
    mem = bytearray(0x10000)
    mem[0:0x2000] = pages[1]
    mem[XDICT_BASE:XDICT_BASE + length] = p2[img:img + length]
    try:
        chain = list(walk_dict(mem, last))
    except ValueError as e:
        check(False, f'dictionary chain: {e}')
        return
    ext = [(a, nm, cf) for a, nm, cf in chain if XDICT_BASE <= a < XSTATE]
    rom = [(a, nm, cf) for a, nm, cf in chain if a < 0x2000]
    check(len(ext) + len(rom) == len(chain), 'every header is in XDICT or the ROM')
    check(any(a == FORTH_LINK0 for a, _, _ in rom), 'chain passes the stock $1FFF header')
    check(rom[-1][1] == 'QUIT', f'chain ends at QUIT ({len(rom)} ROM headers)')
    stock_names = {nm for _, nm, _ in rom if nm}
    shadows = {nm for _, nm, _ in ext} & stock_names
    check(shadows <= ALLOWED_SHADOWS,
          f'shadowed stock words: {sorted(shadows) or "none"} (allowed: {sorted(ALLOWED_SHADOWS)})')
    for a, nm, cf in ext:
        if cf == 0x1108:                # compiler word (CASE, OF, ...), like the ROM's IF
            rt = mem[a + 3] | mem[a + 4] << 8          # its run-time part's code field
            off = mem[rt - 2] | mem[rt - 1] << 8
            target = (rt - 2 + off - (0x10000 if off & 0x8000 else 0)) & 0xFFFF
            check(mem[a] & 0x40 and target == a - 2 - len(nm) - 1,
                  f'{nm}: compiler word is IMMEDIATE and its run-time part points at its name')
            continue
        ok = cf in (0x0EC3, a + 3)
        if not ok:
            check(False, f'{nm}: code field ${cf:04X} is neither DOCOLON, a compiler word nor inline code')
    turbo = syms.get('TURBO_NLF')
    first = [(a, nm) for a, nm, _ in ext if a == turbo]
    check(bool(first) and first[0][1] == 'TURBO'
          and (mem[turbo - 2] | mem[turbo - 1] << 8) == FORTH_LINK0,
          'TURBO_NLF is TURBO and links straight to $1FFF (0 TURBO chain)')
    print(f'  info XDICT words ({len(ext)}): ' + ' '.join(nm for _, nm, _ in reversed(ext)))
    print(f'  info page 2 code area ends at ${syms.get("PAGE2_END", 0):04X} of $2000')


if __name__ == '__main__':
    main(sys.argv[1])
    print('FAILED: %d check(s)' % len(failures) if failures else 'all checks passed')
    sys.exit(1 if failures else 0)
