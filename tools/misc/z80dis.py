#!/usr/bin/env python3
"""Small Z80 disassembler (documented instructions, plus IXH/IXL forms).

Usage: z80dis.py ROM START [END]      addresses in hex; END exclusive (default START+0x40)
As a module: dis(mem, addr) -> (length, text)

Decoding follows the usual x/y/z/p/q split of the opcode byte.
"""
import sys

R = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']
RP = ['BC', 'DE', 'HL', 'SP']
RP2 = ['BC', 'DE', 'HL', 'AF']
CC = ['NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M']
ALU = ['ADD A,', 'ADC A,', 'SUB ', 'SBC A,', 'AND ', 'XOR ', 'OR ', 'CP ']
ROT = ['RLC', 'RRC', 'RL', 'RR', 'SLA', 'SRA', 'SLL', 'SRL']
IM = ['0', '0', '1', '2', '0', '0', '1', '2']
BLI = {(4, 0): 'LDI', (4, 1): 'CPI', (4, 2): 'INI', (4, 3): 'OUTI',
       (5, 0): 'LDD', (5, 1): 'CPD', (5, 2): 'IND', (5, 3): 'OUTD',
       (6, 0): 'LDIR', (6, 1): 'CPIR', (6, 2): 'INIR', (6, 3): 'OTIR',
       (7, 0): 'LDDR', (7, 1): 'CPDR', (7, 2): 'INDR', (7, 3): 'OTDR'}


def dis(m, a):
    def b(o): return m[(a + o) & 0xFFFF]
    def w(o): return b(o) | b(o + 1) << 8
    def h8(v): return '$%02X' % v
    def h16(v): return '$%04X' % v

    op = b(0)
    if op in (0xDD, 0xFD):
        ix = 'IX' if op == 0xDD else 'IY'
        op2 = b(1)
        if op2 == 0xCB:
            d = b(2) - 256 if b(2) > 127 else b(2)
            o3 = b(3)
            x, y, z = o3 >> 6, (o3 >> 3) & 7, o3 & 7
            ref = '(%s%+d)' % (ix, d)
            if x == 0: t = '%s %s' % (ROT[y], ref)
            elif x == 1: t = 'BIT %d,%s' % (y, ref)
            elif x == 2: t = 'RES %d,%s' % (y, ref)
            else: t = 'SET %d,%s' % (y, ref)
            return 4, t
        n, t = dis_main(m, (a + 1) & 0xFFFF, ix)
        return n + 1, t
    if op == 0xED:
        o2 = b(1)
        x, y, z, p, q = o2 >> 6, (o2 >> 3) & 7, o2 & 7, (o2 >> 4) & 3, (o2 >> 3) & 1
        if x == 1:
            if z == 0: return 2, 'IN %s(C)' % ('' if y == 6 else R[y] + ',')
            if z == 1: return 2, 'OUT (C),%s' % ('0' if y == 6 else R[y])
            if z == 2: return 2, '%s HL,%s' % ('SBC' if q == 0 else 'ADC', RP[p])
            if z == 3:
                return 4, ('LD (%s),%s' % (h16(w(2)), RP[p]) if q == 0
                           else 'LD %s,(%s)' % (RP[p], h16(w(2))))
            if z == 4: return 2, 'NEG'
            if z == 5: return 2, 'RETI' if y == 1 else 'RETN'
            if z == 6: return 2, 'IM ' + IM[y]
            return 2, ['LD I,A', 'LD R,A', 'LD A,I', 'LD A,R', 'RRD', 'RLD', 'NOP', 'NOP'][y]
        if x == 2 and (y, z) in BLI:
            return 2, BLI[(y, z)]
        return 2, 'DB $ED,%s' % h8(o2)
    if op == 0xCB:
        o2 = b(1)
        x, y, z = o2 >> 6, (o2 >> 3) & 7, o2 & 7
        if x == 0: return 2, '%s %s' % (ROT[y], R[z])
        return 2, '%s %d,%s' % (['', 'BIT', 'RES', 'SET'][x], y, R[z])
    return dis_main(m, a, None)


def dis_main(m, a, ix):
    """Unprefixed opcode at a; ix = 'IX'/'IY' when after DD/FD."""
    def b(o): return m[(a + o) & 0xFFFF]
    def w(o): return b(o) | b(o + 1) << 8
    def h8(v): return '$%02X' % v
    def h16(v): return '$%04X' % v
    op = b(0)
    x, y, z, p, q = op >> 6, (op >> 3) & 7, op & 7, (op >> 4) & 3, (op >> 3) & 1
    extra = [0]                             # displacement byte used

    def reg(i, hl_ok=True):
        if ix is None: return R[i]
        if i == 6:
            extra[0] = 1
            d = b(1) - 256 if b(1) > 127 else b(1)
            return '(%s%+d)' % (ix, d)
        if hl_ok and i in (4, 5): return ix + ('H' if i == 4 else 'L')
        return R[i]

    def rp(i): return ix if (ix and i == 2) else RP[i]
    def rp2(i): return ix if (ix and i == 2) else RP2[i]
    hl = ix or 'HL'

    def ret(n, t): return n + extra[0], t
    if x == 0:
        if z == 0:
            if y == 0: return 1, 'NOP'
            if y == 1: return 1, "EX AF,AF'"
            d = b(1) - 256 if b(1) > 127 else b(1)
            tgt = h16((a + 2 + d) & 0xFFFF)
            if y == 2: return 2, 'DJNZ ' + tgt
            if y == 3: return 2, 'JR ' + tgt
            return 2, 'JR %s,%s' % (CC[y - 4], tgt)
        if z == 1:
            return (3, 'LD %s,%s' % (rp(p), h16(w(1)))) if q == 0 else (1, 'ADD %s,%s' % (hl, rp(p)))
        if z == 2:
            t = [('LD (BC),A', 1), ('LD A,(BC)', 1), ('LD (DE),A', 1), ('LD A,(DE)', 1),
                 ('LD (%s),%s' % (h16(w(1)), hl), 3), ('LD %s,(%s)' % (hl, h16(w(1))), 3),
                 ('LD (%s),A' % h16(w(1)), 3), ('LD A,(%s)' % h16(w(1)), 3)][y]
            return t[1], t[0]
        if z == 3: return 1, ('INC ' if q == 0 else 'DEC ') + rp(p)
        if z == 4: r_ = reg(y); return ret(1, 'INC ' + r_)
        if z == 5: r_ = reg(y); return ret(1, 'DEC ' + r_)
        if z == 6:
            r_ = reg(y)
            return ret(2, 'LD %s,%s' % (r_, h8(b(1 + extra[0]))))
        return 1, ['RLCA', 'RRCA', 'RLA', 'RRA', 'DAA', 'CPL', 'SCF', 'CCF'][y]
    if x == 1:
        if op == 0x76: return 1, 'HALT'
        mem_op = 6 in (y, z)
        d = reg(y, not mem_op)
        s = reg(z, not mem_op)
        return ret(1, 'LD %s,%s' % (d, s))
    if x == 2:
        r_ = reg(z)
        return ret(1, ALU[y] + r_)
    if z == 0: return 1, 'RET ' + CC[y]
    if z == 1:
        if q == 0: return 1, 'POP ' + rp2(p)
        return 1, ['RET', 'EXX', 'JP (%s)' % hl, 'LD SP,%s' % hl][p]
    if z == 2: return 3, 'JP %s,%s' % (CC[y], h16(w(1)))
    if z == 3:
        if y == 0: return 3, 'JP ' + h16(w(1))
        if y == 2: return 2, 'OUT (%s),A' % h8(b(1))
        if y == 3: return 2, 'IN A,(%s)' % h8(b(1))
        return 1, [None, None, None, None, 'EX (SP),%s' % hl, 'EX DE,HL', 'DI', 'EI'][y]
    if z == 4: return 3, 'CALL %s,%s' % (CC[y], h16(w(1)))
    if z == 5:
        if q == 0: return 1, 'PUSH ' + rp2(p)
        if p == 0: return 3, 'CALL ' + h16(w(1))
        return 1, 'DB %s' % h8(op)          # prefixes handled by the caller
    if z == 6: return 2, ALU[y] + h8(b(1))
    return 1, 'RST %s' % h8(y * 8)


def main(argv):
    mem = bytearray(65536)
    data = open(argv[1], 'rb').read()
    mem[:len(data)] = data
    a = int(argv[2], 16)
    end = int(argv[3], 16) if len(argv) > 3 else a + 0x40
    while a < end:
        n, t = dis(mem, a)
        print('%04X  %-12s %s' % (a, mem[a:a + n].hex(' ').upper(), t))
        a += n


if __name__ == '__main__':
    main(sys.argv)
