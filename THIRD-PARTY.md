# Third-party components and notices

TurboACE's own files are by the TurboACE authors. The parts below come from others; their
notices travel with TurboACE's sources and with every built file that contains them.
**This file must be shipped with the bitstreams** (T80's licence asks for its notice in
the documentation of synthesised forms).

| Component | Where | Licence | In which built file |
|---|---|---|---|
| T80 Z80 core (Daniel Wallner; MikeJ; Sorgelig, MiSTer version 350) | `fpga/rtl/T80/` (from JupiterACE_MiSTer, see its `TURBOACE.md`) | BSD 3-clause style, below | standalone bitstream |
| PicoRV32 (Claire Xenia Wolf, YosysHQ) | `fpga/rtl/picorv32.v` (unchanged, commit `ef203c2` of github.com/YosysHQ/picorv32) | ISC, below | both bitstreams (the soft CPU) |
| hdl-util/hdmi (Sameer Puri) | `fpga/rtl/hdmi/` (unchanged, commit `517e214` of github.com/hdl-util/hdmi; `LICENSE-MIT` there) | MIT or Apache 2.0 | both bitstreams (HDMI output and sound) |
| `ay.sv`, AY-3-8910 sound (from JupiterACE_MiSTer, the TurboACE author's own core) | `fpga/rtl/ay.sv` (unchanged) | GPL v2 or later | both bitstreams (sound) |
| FatFs R0.16 (ChaN) | `firmware/fatfs/` | 1-clause BSD, `firmware/fatfs/LICENSE.txt` | soft-CPU firmware (both bitstreams) |
| Extension word bodies adapted from the Jupiter-II Expansion XROM (Ricardo Fernandes Lopes) | `rom/src/xdict.asm` | MIT, notice in that file and below | TurboACE ROM pages (flash) |
| Tape-player logic following Jupiter-IIb's `src/tape_sd.cpp` (from xAce) | `firmware/src/sdproto.c` | GPL v2 or later (see `register-map.md` §8, open item 5) | soft-CPU firmware |
| Verilator 5.052 (Wilson Snyder and contributors) | `toolchain/verilator/` (built by `download_toolchain.sh`, not in git) | LGPL v3 or Artistic 2.0 | none: a simulator only |
| GHDL 5.1.1 (Tristan Gingold and contributors) | `toolchain/ghdl/` (built by `download_toolchain.sh`, not in git) | GPL v2 or later | none: turns the T80 into Verilog for simulation only |
| Icarus Verilog 12.0 (Stephen Williams and contributors) | `toolchain/iverilog/` (built by `download_toolchain.sh`, not in git) | GPL v2 or later | none: a simulator only |
| xPack GNU RISC-V Embedded GCC 15.2.0 | `toolchain/xpack-…/` (fetched by `download_toolchain.sh`, not in git) | GPL v3 with the GCC runtime exception | none: the firmware is not affected |
| sjasmplus 1.20.3 (aprisobal and contributors) | `tools/sjasmplus/` | BSD 3-clause, `tools/sjasmplus/LICENSE.md` | none: a build tool only |

The stock Jupiter Ace ROM is not part of TurboACE: each user supplies `/ace.rom`.

## T80

From the T80 sources (`T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Reg.vhd`,
`T80pa.vhd`); the MiSTer version also carries "Copyright (c) 2018 Sorgelig" for its
changes, under the same terms.

```
Version : 0247
Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
All rights reserved

Redistribution and use in source and synthezised forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of the author nor the names of other contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## PicoRV32 (ISC)

```
Copyright (C) 2015  Claire Xenia Wolf <claire@yosyshq.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## Jupiter-II Expansion XROM (MIT)

```
MIT License, Copyright (c) 2020 Ricardo Fernandes Lopes
(https://github.com/ricaflops/Jupiter-II-Expansion, xrom/xrom.z)
Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the
following conditions: The above copyright notice and this permission
notice shall be included in all copies or substantial portions of the
Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
USE OR OTHER DEALINGS IN THE SOFTWARE.
```
