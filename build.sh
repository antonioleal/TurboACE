#!/bin/sh
# Build TurboACE from source into release/.
#
#   ./build.sh /path/to/ace.rom          (or ACE_ROM=/path/to/ace.rom ./build.sh)
#
# The stock Jupiter Ace ROM is needed to assemble TurboACE's pages (they are checked
# against it), but nothing in release/ contains any of its bytes: the user's /ace.rom
# on the SD card supplies them at power-up.
#
# release/ has one folder per build, each with everything written into the Tang Nano
# 20K for that build and a LOAD.txt saying how:
#   release/standalone/  turboace-standalone.fs (the bitstream; the soft CPU's firmware
#                        is inside it), turboace-flash.bin (TurboACE's ROM pages 2-7 for
#                        the module's flash at 0x500000), LOAD.txt, SHA256SUMS
#   release/expansion/   the same for the expansion build: turboace-flash.bin for now;
#                        its bitstream is added when its top level exists
# and at the top: sdcpu.bin, sdcpu.elf (the firmware alone, RV32IC, for reference),
# README.md, THIRD-PARTY.md, SHA256SUMS.
# The bitstream needs Gowin EDA in toolchain/gowim (downloaded by hand; without it the
# bitstream is left out, with a warning).
set -eu
cd "$(dirname "$0")"

ACE_ROM=${1:-${ACE_ROM:-}}
if [ -z "$ACE_ROM" ] || [ ! -f "$ACE_ROM" ]; then
    echo "usage: $0 /path/to/ace.rom   (the stock Jupiter Ace ROM, 8192 bytes)" >&2
    exit 1
fi
ACE_ROM=$(cd "$(dirname "$ACE_ROM")" && pwd)/$(basename "$ACE_ROM")

echo "== assembler"
[ -x tools/sjasmplus/sjasmplus ] || make -C tools/sjasmplus

echo "== ROM"
make -C rom check flash ACE_ROM="$ACE_ROM"

echo "== RISC-V compiler"
./download_toolchain.sh

echo "== firmware"
make -C firmware firmware

echo "== FPGA bitstream (standalone)"
BITSTREAMS=
if [ -x toolchain/gowim/IDE/bin/gw_sh ]; then
    make -C fpga bitstream
    BITSTREAMS=fpga/build/turboace-standalone.fs
else
    echo "WARNING: Gowin EDA is not in toolchain/gowim: no bitstream in release/" >&2
fi

echo "== release/"
rm -rf release
mkdir -p release/standalone release/expansion
cp firmware/build/sdcpu.bin firmware/build/sdcpu.elf README.md THIRD-PARTY.md release/
cp rom/build/turboace-flash.bin release/standalone/
cp rom/build/turboace-flash.bin release/expansion/
[ -z "$BITSTREAMS" ] || cp $BITSTREAMS release/standalone/

cat > release/standalone/LOAD.txt <<'TXT'
TurboACE standalone build: a whole Jupiter Ace inside the Tang Nano 20K (PS/2
keyboard, HDMI, microSD), no real Ace needed.

Write both files into the module (openFPGALoader; from the source tree,
`make program BUILD=standalone` does the same):
  openFPGALoader -b tangnano20k -f turboace-standalone.fs
  openFPGALoader -b tangnano20k --external-flash -o 0x500000 turboace-flash.bin

At power-up the stock Jupiter Ace ROM is read from /ace.rom on the microSD card
(8192 bytes, MD5 db6efdfd82cebdfbb493d85b1a5efc3c); it is not in these files.
TXT
cat > release/expansion/LOAD.txt <<'TXT'
TurboACE expansion build: the Tang Nano 20K on the adapter board, plugged into a
real Jupiter Ace.

Not available yet: its bitstream (turboace-expansion.fs) is still to be designed.
When it is, write both files into the module (openFPGALoader; from the source tree,
`make program BUILD=expansion` does the same):
  openFPGALoader -b tangnano20k -f turboace-expansion.fs
  openFPGALoader -b tangnano20k --external-flash -o 0x500000 turboace-flash.bin

At power-up the stock Jupiter Ace ROM is read from /ace.rom on the microSD card
(8192 bytes, MD5 db6efdfd82cebdfbb493d85b1a5efc3c); it is not in these files.
TXT
for d in release/standalone release/expansion; do
    (cd $d && sha256sum $(ls | grep -v -e SHA256SUMS -e '\.txt$') > SHA256SUMS)
done
(cd release && sha256sum sdcpu.bin sdcpu.elf > SHA256SUMS)
ls -lR release
