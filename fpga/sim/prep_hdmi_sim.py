#!/usr/bin/env python3
"""A copy of hdl-util/hdmi (rtl/hdmi/) for Verilator, which cannot fold the
SystemVerilog cast int'(real) in a constant expression. The two localparams of
audio_clock_regeneration_packet.sv that use it are written with $rtoi and $itor
instead; int'(real) rounds to nearest, so 0.5 is added before $rtoi (which
truncates): the values are the same. The sources in rtl/hdmi/ stay unchanged
(Gowin EDA takes them as they are).

Usage: prep_hdmi_sim.py SRC_DIR OUT_DIR
"""
import os
import sys

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
swaps = {
    "audio_clock_regeneration_packet.sv": [
        ("20'(int'(VIDEO_RATE * int'(N) / 128 / AUDIO_RATE))",
         "20'($rtoi(VIDEO_RATE * $itor(N) / 128 / AUDIO_RATE + 0.5))"),
        ("$clog2(20'(int'(real'(CYCLE_TIME_STAMP_COUNTER_IDEAL) * 1.1)))",
         "$clog2(20'($rtoi($itor(CYCLE_TIME_STAMP_COUNTER_IDEAL) * 1.1 + 0.5)))"),
    ],
}
for name in sorted(os.listdir(src)):
    if not name.endswith(".sv"):
        continue
    text = open(os.path.join(src, name)).read()
    for old, new in swaps.get(name, []):
        if text.count(old) != 1:
            sys.exit(f"prep_hdmi_sim: {name}: expected text not found (hdl-util changed?)")
        text = text.replace(old, new)
    open(os.path.join(out, name), "w").write(text)
