#!/usr/bin/env python3
"""Post-process GHDL's Verilog of the T80 (build/t80.v) for simulation:

1. registers start at 0, as the FPGA's flip-flops do at power-up (GHDL leaves them
   unknown, and some T80 registers have no reset);
2. GHDL 5.1.1 drops T80.vhd's concurrent `DI_Reg <= DI;` from the Verilog: the
   inner T80 module declares `wire [7:0] di_reg;` and uses it, but nothing drives
   it. The assignment is put back (and this stops if the wire is not, or no longer,
   undriven, so a fixed GHDL is noticed);
3. the file is marked as Verilog-2005 (`begin_keywords), because GHDL names T80's
   data-out port `do`, a keyword in SystemVerilog (Verilator reads it otherwise).

Usage: fix_t80_netlist.py IN OUT
"""
import re
import sys

src = open(sys.argv[1]).read()
src = re.sub(r'^(  reg (\[[^\]]*\] )?[A-Za-z_][A-Za-z0-9_]*);$', r'\1 = 0;', src, flags=re.M)

mods = src.split('\nmodule ')
fixed = 0
for i, m in enumerate(mods):
    if not m.startswith('t80_0_'):
        continue
    if not re.search(r'^  wire \[7:0\] di_reg;$', m, re.M):
        sys.exit('fix_t80_netlist: no di_reg wire in the inner T80')
    if re.search(r'assign di_reg =', m):
        sys.exit('fix_t80_netlist: di_reg is driven now: this fix is no longer needed')
    mods[i] = m.replace('  wire [7:0] di_reg;\n', '  wire [7:0] di_reg;\n  assign di_reg = di;  // T80.vhd: DI_Reg <= DI (dropped by GHDL)\n', 1)
    fixed += 1
if fixed != 1:
    sys.exit('fix_t80_netlist: expected one inner T80 module, found %d' % fixed)
open(sys.argv[2], 'w').write('`begin_keywords "1364-2005"\n' + '\nmodule '.join(mods) + '\n`end_keywords\n')
