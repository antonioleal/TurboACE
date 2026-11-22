#!/bin/sh
# Download the tools that are not kept in git into toolchain/, checked by SHA-256:
#   xPack GNU RISC-V Embedded GCC 15.2.0-1 (Linux x64), for the soft-CPU firmware;
#   Icarus Verilog 12.0, built from source (needs autoconf, bison, flex, gperf, g++),
#   to simulate the FPGA design (fpga/);
#   GHDL 5.1.1, built from source with its mcode back end (needs GNAT, the GCC Ada
#   compiler), to simulate the VHDL parts (the T80 Z80 core) with the Verilog;
#   Verilator 5.052, built from source (needs autoconf, bison, flex, perl, g++), to
#   simulate the SystemVerilog HDMI core (hdl-util/hdmi) with the design.
#   KiCad 10.0.8, the official AppImage (a download, nothing to build), for the boards
#   (kicad/); KICAD_APPIMAGE=/path/to/it copies one already downloaded.
# firmware/Makefile uses toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-.
# Licence: GCC/binutils GPL v3 with the runtime library exception, newlib BSD-style;
# firmware built with it is not affected.
set -eu

VERSION=15.2.0-1
NAME=xpack-riscv-none-elf-gcc-$VERSION
TARBALL=$NAME-linux-x64.tar.gz
URL=https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$VERSION/$TARBALL
SHA256=aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758

cd "$(dirname "$0")"
mkdir -p toolchain
cd toolchain

if [ -x "$NAME/bin/riscv-none-elf-gcc" ]; then
    echo "toolchain/$NAME is already there"
else
    echo "downloading $TARBALL"
    curl -fL -o "$TARBALL" "$URL"
    echo "$SHA256  $TARBALL" | sha256sum -c -
    tar xzf "$TARBALL"
    rm "$TARBALL"
    echo "installed toolchain/$NAME"
fi

# Icarus Verilog (GPL v2+; a tool only, nothing of it goes into the bitstreams)
IV_VERSION=12_0
IV_TARBALL=iverilog-$IV_VERSION.tar.gz
IV_URL=https://github.com/steveicarus/iverilog/archive/refs/tags/v$IV_VERSION.tar.gz
IV_SHA256=a68cb1ef7c017ef090ebedb2bc3e39ef90ecc70a3400afb4aa94303bc3beaa7d

if [ -x iverilog/bin/iverilog ]; then
    echo "toolchain/iverilog is already there"
else
    echo "downloading and building Icarus Verilog $IV_VERSION (a few minutes)"
    curl -fL -o "$IV_TARBALL" "$IV_URL"
    echo "$IV_SHA256  $IV_TARBALL" | sha256sum -c -
    tar xzf "$IV_TARBALL"
    (cd "iverilog-$IV_VERSION" && sh autoconf.sh && ./configure --prefix="$PWD/../iverilog" \
        && make -j"$(nproc)" && make install) > iverilog-build.log 2>&1 \
        || { echo "Icarus Verilog build failed: see toolchain/iverilog-build.log"; exit 1; }
    rm -rf "iverilog-$IV_VERSION" "$IV_TARBALL" iverilog-build.log
    echo "installed toolchain/iverilog"
fi

# GHDL (GPL v2+; a tool only, nothing of it goes into the bitstreams)
GH_VERSION=5.1.1
GH_TARBALL=ghdl-$GH_VERSION.tar.gz
GH_URL=https://github.com/ghdl/ghdl/archive/refs/tags/v$GH_VERSION.tar.gz
GH_SHA256=aca5d20522ef9b8e273e95c9157d2d3f77f6e40a4fdeee431fa330885bd78f7f

if [ -x ghdl/bin/ghdl ]; then
    echo "toolchain/ghdl is already there"
else
    command -v gnatmake >/dev/null || { echo "GHDL needs GNAT (the GCC Ada compiler)"; exit 1; }
    echo "downloading and building GHDL $GH_VERSION (a few minutes)"
    curl -fL -o "$GH_TARBALL" "$GH_URL"
    echo "$GH_SHA256  $GH_TARBALL" | sha256sum -c -
    tar xzf "$GH_TARBALL"
    (cd "ghdl-$GH_VERSION" && ./configure --prefix="$PWD/../ghdl" \
        && make -j"$(nproc)" && make install) > ghdl-build.log 2>&1 \
        || { echo "GHDL build failed: see toolchain/ghdl-build.log"; exit 1; }
    rm -rf "ghdl-$GH_VERSION" "$GH_TARBALL" ghdl-build.log
    echo "installed toolchain/ghdl"
fi

# Verilator (LGPL v3 or Artistic 2.0; a tool only, nothing of it goes into the bitstreams)
VL_VERSION=5.052
VL_TARBALL=verilator-$VL_VERSION.tar.gz
VL_URL=https://github.com/verilator/verilator/archive/refs/tags/v$VL_VERSION.tar.gz
VL_SHA256=8c8d2e11e6ad32f641dd250742a94195ddecb912e2e2dabe2f42ddbbb99c1092

if [ -x verilator/bin/verilator ]; then
    echo "toolchain/verilator is already there"
else
    echo "downloading and building Verilator $VL_VERSION (ten minutes or more)"
    curl -fL -o "$VL_TARBALL" "$VL_URL"
    echo "$VL_SHA256  $VL_TARBALL" | sha256sum -c -
    tar xzf "$VL_TARBALL"
    (cd "verilator-$VL_VERSION" && autoconf && ./configure --prefix="$PWD/../verilator" \
        && make -j"$(nproc)" && make install) > verilator-build.log 2>&1 \
        || { echo "Verilator build failed: see toolchain/verilator-build.log"; exit 1; }
    rm -rf "verilator-$VL_VERSION" "$VL_TARBALL" verilator-build.log
    echo "installed toolchain/verilator"
fi

# KiCad 10.0.8 (GPL v3+; a tool only), the official AppImage, for the boards (kicad/):
# kicad-cli, KiCad's Python with pcbnew, and the libraries, all in one file:
#   toolchain/kicad/kicad-10.0.8-x86_64.AppImage python3.11 kicad/standalone/generate.py
# KiCad ships it inside a .tar (482 MB). The SHA-256 is of the AppImage itself, which
# KiCad signed (its .minisig, next to the .tar, verifies with the release key). An
# AppImage already downloaded is copied instead: KICAD_APPIMAGE=/path/to/it.
KC_VERSION=10.0.8
KC_NAME=kicad-$KC_VERSION-x86_64.AppImage
KC_URL=https://mirrors.mit.edu/kicad/appimage/stable/$KC_NAME.tar
KC_SHA256=3cc636c7722120768cb1400b35557dd1eb92624cbc0e0d0dbe03c21cfda03262

if [ -x "kicad/$KC_NAME" ]; then
    echo "toolchain/kicad/$KC_NAME is already there"
else
    mkdir -p kicad
    if [ -n "${KICAD_APPIMAGE:-}" ]; then
        echo "copying $KICAD_APPIMAGE"
        cp "$KICAD_APPIMAGE" "kicad/$KC_NAME.part"
    else
        echo "downloading KiCad $KC_VERSION (482 MB)"
        curl -fL -o "kicad/$KC_NAME.tar" "$KC_URL"
        tar xf "kicad/$KC_NAME.tar" -C kicad "$KC_NAME"
        rm "kicad/$KC_NAME.tar"
        mv "kicad/$KC_NAME" "kicad/$KC_NAME.part"
    fi
    echo "$KC_SHA256  kicad/$KC_NAME.part" | sha256sum -c - \
        || { rm -f "kicad/$KC_NAME.part"; echo "not KiCad $KC_VERSION's AppImage"; exit 1; }
    chmod +x "kicad/$KC_NAME.part"
    mv "kicad/$KC_NAME.part" "kicad/$KC_NAME"
    echo "installed toolchain/kicad/$KC_NAME"
fi
