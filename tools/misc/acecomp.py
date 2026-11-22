#!/usr/bin/env python3
"""Turn colon words compiled by the stock Jupiter Ace ROM into sjasmplus source.

Usage: acecomp.py MEMDUMP STOCKROM WORD... [-h HEADERLESS...]   (run from the top folder)

MEMDUMP is 64K of memory after a Forth session in the test harness (test/gfxtest:
PROBE=... DUMP=file) in which the words were typed in, so their cells are exactly
what the ROM compiles. Each word's body is printed as DW lines for rom/src/xdict.asm:
stock words by their ace_words.inc names, run-time parts (literals, IF, DO, ...) with
their operands (branch offsets on their own line), and references to the other words
as <LABEL>_PF - 2. Words after -h get no header (only a label and the code field).
"""
import re
import sys

INC = 'rom/inc/'


def equates(path):
    out = {}
    for line in open(path):
        m = re.match(r'(\w+)\s+EQU\s+\$([0-9A-Fa-f]+)', line)
        if m:
            out.setdefault(int(m.group(2), 16), m.group(1))
    return out


def label(name):
    special = {'+': 'PLUS', '-': 'MINUS', '*': 'STAR', '/': 'SLASH', '.': 'DOT',
               '!': 'STORE', '@': 'FETCH', '=': 'EQ', '<': 'LT', '>': 'GT',
               "'": 'TICK', '?': 'Q'}
    return 'FW_' + ''.join(c if c.isalnum() else special.get(c, f'X{ord(c):02X}') for c in name)


def main():
    args = sys.argv[1:]
    mem = open(args[0], 'rb').read()
    rom = open(args[1], 'rb').read()
    rest = args[2:]
    headerless = set(rest[rest.index('-h') + 1:]) if '-h' in rest else set()
    wanted = rest[:rest.index('-h')] if '-h' in rest else rest
    stock = {a: n for a, n in equates(INC + 'ace_words.inc').items() if '_NLF_' not in n}
    internal = equates(INC + 'ace_internal.inc')

    # the RAM words of the session, newest first: FORTH's parameter field ($3C4C)
    # holds the name-length field of the newest word in the vocabulary
    words, nlf = {}, mem[0x3C4C] | mem[0x3C4D] << 8
    while nlf >= 0x3C00:
        ln = mem[nlf] & 0x3F
        name = bytes(c & 0x7F for c in mem[nlf - 4 - ln:nlf - 4]).decode()
        words[name] = nlf + 1                       # code field address
        nlf = mem[nlf - 2] | mem[nlf - 1] << 8
    while 0x3000 <= nlf < 0x3B00:               # then TurboACE's own words (no length field)
        ln = mem[nlf] & 0x3F
        name = bytes(c & 0x7F for c in mem[nlf - 2 - ln:nlf - 2]).decode()
        words.setdefault(name, nlf + 1)
        nlf = mem[nlf - 2] | mem[nlf - 1] << 8
    cfa_name = {cfa: n for n, cfa in words.items()}

    def m16(a):
        return mem[a] | mem[a + 1] << 8

    for name in wanted:
        cfa = words[name]
        if m16(cfa) != 0x0EC3:
            sys.exit(f'{name}: not a colon word')
        lab = label(name)
        print(f'; {name}')
        if name in headerless:
            print(f'{lab}_PF EQU $ + 2')
            print('        DW  ACE_DOCOLON')
        else:
            print(f'        XCOLON "{name}"')
            print(f'{lab}_PF:')
        a = cfa + 2
        while True:
            c = m16(a)
            a += 2
            if c == 0x04B6:
                print('        DW  ACE_ENDDEF')
                break
            if c in cfa_name:
                print(f'        DW  {label(cfa_name[c])}_PF - 2')
                continue
            if c >= 0x2000:
                sys.exit(f'{name}: cell ${c:04X} at ${a - 2:04X} is no known word')
            sym = internal.get(c) or stock.get(c)
            if c < 0x2000 and c >= 3 and sym is None:
                sys.exit(f'{name}: unknown cell ${c:04X} at ${a - 2:04X}')
            n = rom[c - 3] if c in internal and c != 0x0EC3 else 0
            if c == internal_addr(internal, 'ACE_LIT_WORD'):
                print(f'        DW  {sym}, ${m16(a):04X}')
                a += 2
            elif c == internal_addr(internal, 'ACE_LIT_BYTE'):
                print(f'        DW  {sym}')
                print(f'        DB  {mem[a]}')
                a += 1
            elif n:
                print(f'        DW  {sym}')
                ops = mem[a:a + n]
                if n == 2:                          # a branch offset: relative, kept as is
                    off = m16(a)
                    print(f'        DW  {off - 0x10000 if off & 0x8000 else off}')
                else:
                    print('        DB  ' + ', '.join(f'${b:02X}' for b in ops))
                a += n
            else:
                print(f'        DW  {sym}')
        print()


def internal_addr(internal, sym):
    for a, n in internal.items():
        if n == sym:
            return a
    return None


if __name__ == '__main__':
    main()
