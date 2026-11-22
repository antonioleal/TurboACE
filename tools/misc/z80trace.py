#!/usr/bin/env python3
"""Trace Z80 code reachable from given entry points in a ROM image.

Usage: z80trace.py ROM entry[,entry...] [stop=addr,addr...]
  entry  hex start address(es), e.g. 0038
  stop   hex addresses not to follow; a CALL to one is treated as
         "inline data follows" (e.g. Ace ROM 04B9 enters Forth, 1808 prints
         an inline string), so the flow ends there.

Prints reachable instruction ranges, call/RST targets, and flow-ending
oddities (indirect JP, RST 20 errors, stops).

Limits: static flow only. Targets of JP (HL)/(IX)/(IY) and data read by the
code (tables) are NOT found; check them by hand. Every conditional branch is
assumed possible.

Example (TurboACE extension-page copy range, see register-map.md section 5):
  python3 tools/misc/z80trace.py ace.rom 0038 stop=04B9,1808
"""
import sys

IXD = {0x34, 0x35, 0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x7E, 0x86, 0x8E, 0x96,
       0x9E, 0xA6, 0xAE, 0xB6, 0xBE} | set(range(0x70, 0x76)) | {0x77}

def base_len(op):
    if op in (0x01, 0x11, 0x21, 0x31, 0x22, 0x2A, 0x32, 0x3A, 0xC3, 0xCD):
        return 3
    if (op & 0xC7) in (0xC2, 0xC4):          # JP cc / CALL cc
        return 3
    if (op & 0xC7) == 0x06 or (op & 0xC7) == 0xC6:   # LD r,n / ALU n
        return 2
    if op in (0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0xD3, 0xDB):
        return 2
    return 1

def decode(rom, a):
    """Return (length, kind, target). kind in: seq, jp, jpc, jr, jrc, call, callc, rst, ret, retc, jpind, halt"""
    def b(x): return rom[x] if x < len(rom) else 0
    def w(x): return rom[x] | (rom[x + 1] << 8)
    op = b(a)
    if op == 0xCB:
        return 2, 'seq', None
    if op == 0xED:
        op2 = b(a + 1)
        if op2 in (0x43, 0x4B, 0x53, 0x5B, 0x63, 0x6B, 0x73, 0x7B):
            return 4, 'seq', None
        if op2 in (0x45, 0x4D):
            return 2, 'ret', None
        return 2, 'seq', None
    if op in (0xDD, 0xFD):
        op2 = b(a + 1)
        if op2 == 0xCB:
            return 4, 'seq', None
        if op2 == 0xE9:
            return 2, 'jpind', None
        if op2 == 0x36:
            return 4, 'seq', None
        if op2 in IXD:
            return 3, 'seq', None
        if op2 in (0x21, 0x22, 0x2A):
            return 4, 'seq', None
        return 1 + base_len(op2), 'seq', None
    n = base_len(op)
    if op == 0xC3:
        return 3, 'jp', w(a + 1)
    if (op & 0xC7) == 0xC2:
        return 3, 'jpc', w(a + 1)
    if op == 0xCD:
        return 3, 'call', w(a + 1)
    if (op & 0xC7) == 0xC4:
        return 3, 'callc', w(a + 1)
    if op == 0x18:
        d = b(a + 1); d = d - 256 if d > 127 else d
        return 2, 'jr', (a + 2 + d) & 0xFFFF
    if op in (0x10, 0x20, 0x28, 0x30, 0x38):
        d = b(a + 1); d = d - 256 if d > 127 else d
        return 2, 'jrc', (a + 2 + d) & 0xFFFF
    if (op & 0xC7) == 0xC7:
        return 1, 'rst', op & 0x38
    if op == 0xC9:
        return 1, 'ret', None
    if (op & 0xC7) == 0xC0:
        return 1, 'retc', None
    if op == 0xE9:
        return 1, 'jpind', None
    if op == 0x76:
        return 1, 'halt', None
    return n, 'seq', None


def trace(rom, entries, stops=()):
    """Follow code from entries. Returns (seen, calls, oddities):
    seen = {addr: instruction length}, calls = {target: {callers}},
    oddities = list of strings (indirect jumps, errors, stops)."""
    stops = set(stops)
    seen = {}          # addr -> length
    calls = {}         # target -> set(callers)
    oddities = []
    work = list(entries)
    while work:
        a = work.pop()
        while True:
            if a in seen or a >= len(rom):
                break
            if a in stops:
                oddities.append(f'stop at {a:04X}')
                break
            ln, kind, t = decode(rom, a)
            seen[a] = ln
            nxt = a + ln
            if kind in ('jp', 'jr'):
                work.append(t); break
            if kind in ('jpc', 'jrc'):
                work.append(t)
            elif kind in ('call', 'callc'):
                calls.setdefault(t, set()).add(a)
                work.append(t)
                if t in stops:
                    oddities.append(f'CALL {t:04X} at {a:04X} (inline data follows; not followed)')
                    if kind == 'call':
                        break
            elif kind == 'rst':
                calls.setdefault(t, set()).add(a)
                work.append(t)
                if t == 0x20:
                    oddities.append(f'RST 20 (error) at {a:04X}')
                    break
            elif kind in ('ret', 'halt'):
                break
            elif kind == 'jpind':
                oddities.append(f'indirect JP at {a:04X}')
                break
            a = nxt

    return seen, calls, oddities


def ranges_of(seen):
    """Coalesce {addr: length} into a list of [start, end) ranges."""
    out = []
    for a in sorted(seen):
        end = a + seen[a]
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([a, end])
    return out


def main(argv):
    rom = open(argv[1], 'rb').read()
    entries = [int(x, 16) for x in argv[2].split(',')]
    stops = set()
    for a in argv[3:]:
        if a.startswith('stop='):
            stops |= {int(x, 16) for x in a[5:].split(',') if x}
    seen, calls, oddities = trace(rom, entries, stops)
    ranges = ranges_of(seen)
    total = sum(e - s for s, e in ranges)
    print(f'reachable bytes: {total} in {len(ranges)} ranges')
    for s, e in ranges:
        print(f'  {s:04X}-{e-1:04X}  ({e-s} bytes)')
    print('call/rst targets:', ' '.join(f'{t:04X}' for t in sorted(calls)))
    print('lowest/highest:', f'{ranges[0][0]:04X}', f'{ranges[-1][1]-1:04X}')
    for o in oddities:
        print('  !', o)


if __name__ == '__main__':
    main(sys.argv)
