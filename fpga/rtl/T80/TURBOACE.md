# T80 — Z80 core for the standalone build

VHDL, the MiSTer-maintained T80 (version 350): Daniel Wallner 2001-2002, MikeJ 2005,
Sorgelig 2018. BSD 3-clause style licence, in each file and in `../../../THIRD-PARTY.md`
(`register-map.md` decision 25).

Copied from the JupiterACE_MiSTer project, `rtl/T80/` at commit `85d01a6`, with one change:
the four sub-unit instantiations (`T80.vhd`: `T80_MCode`, `T80_ALU`, `T80_Reg`; `T80pa.vhd`: `T80`)
read `name : entity work.X` instead of `name : work.X`, standard VHDL-93 direct
instantiation, which GHDL requires; and in `T80.vhd` the block-I/O parity mask
`(ioq and x"7")` (9 bits against 4) is written `(ioq and "000000111")`, its meaning, as
GHDL does not widen operands. The design is the same. That copy adds to `T80pa.vhd` a `HOLD` input and
`HELD` output (stop at an instruction boundary, for snapshots); they default to off and
TurboACE does not use them.

TurboACE uses `T80pa` (synchronous, with the enables `CEN_p` at each T-state's start and
`CEN_n` at its middle). For simulation, GHDL turns it into Verilog
(`ghdl synth --out=verilog`, see `../../Makefile`), so the simulated Z80 is the same code
Gowin EDA synthesises.
