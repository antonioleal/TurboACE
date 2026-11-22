// =============================================================================
// Test of rtl/audio.v (with rtl/ay.sv): exactly 48 kHz; silence is 0; a tone on
// channel A (period 256: 203125 / 256 = 793 Hz) has that frequency and its level
// (volume 15: 12287, halved); the beeper adds its level; a channel-B tone of
// period 100 (2031 Hz) is found too.
// =============================================================================
`timescale 1ns / 1ps
module audio_tb;
    localparam real PERIOD = 1000.0 / 54;
    reg clk = 0, reset = 1;
    always #(PERIOD / 2) clk = ~clk;

    reg [7:0] acc = 0; reg ce_ay = 0;
    always @(posedge clk) if (acc >= 203) begin acc <= acc - 203; ce_ay <= 1; end
                          else begin acc <= acc + 13; ce_ay <= 0; end

    reg  [7:0] r [0:15];
    wire [127:0] regs = {r[15], r[14], r[13], r[12], r[11], r[10], r[9], r[8],
                         r[7], r[6], r[5], r[4], r[3], r[2], r[1], r[0]};
    reg  beeper = 0;
    wire [15:0] sample;
    wire sample_ce, clk_audio;
    audio dut (.clk(clk), .reset(reset), .ce_ay(ce_ay), .ay_regs(regs), .env_restart(1'b0),
        .beeper(beeper), .sample(sample), .sample_ce(sample_ce), .clk_audio(clk_audio));

    integer checks = 0, failures = 0;
    reg [8*120-1:0] msg;
    task check(input ok, input [8*120-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin failures = failures + 1; $display("  FAIL %0s", what); end
        end
    endtask

    // n samples: their count, smallest, largest, and rising crossings of the middle
    integer cnt, lo, hi, ups, mid;
    task listen(input integer n);
        integer k, prev, s;
        begin
            cnt = 0; lo = 65535; hi = 0; ups = 0; prev = -1;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk); while (!sample_ce) @(posedge clk);
                #1 s = sample;
                cnt = cnt + 1;
                if (s < lo) lo = s;
                if (s > hi) hi = s;
                if (prev >= 0 && prev < mid && s >= mid) ups = ups + 1;
                prev = s;
            end
        end
    endtask

    integer i, n;
    real t0, hz;
    initial begin
        for (i = 0; i < 16; i = i + 1) r[i] = 0;
        r[7] = 8'hFF;                           // all off
        // ay.sv's /8 prescaler has no reset: on the FPGA it powers up at 0, as here
        dut.psg.pre = 3'd0;
        repeat (4) @(posedge clk);
        reset = 0;

        // 48 kHz: 480 samples in 10 ms
        t0 = $realtime; n = 0;
        while ($realtime - t0 < 10.0e6) begin @(posedge clk); if (sample_ce) n = n + 1; end
        $sformat(msg, "48 kHz: %0d samples in 10 ms", n);
        check(n == 480, msg);

        // and exactly 1125 clocks of 54 MHz apart
        @(posedge clk); while (!sample_ce) @(posedge clk);
        n = 0;
        @(posedge clk); n = 1; while (!sample_ce) begin @(posedge clk); n = n + 1; end
        $sformat(msg, "samples exactly 1125 clocks apart (%0d)", n);
        check(n == 1125, msg);

        mid = 1; listen(200);
        $sformat(msg, "silence is 0 (samples %0d-%0d)", lo, hi);
        check(lo == 0 && hi == 0, msg);

        // channel A: period 256, volume 15, tone on
        r[0] = 8'h00; r[1] = 8'h01; r[8] = 8'h0F; r[7] = 8'hFE;
        listen(100);                            // settle
        mid = 3072; listen(4800);               // 0.1 s
        hz = ups * 10.0;
        $sformat(msg, "channel A, period 256: %0.0f Hz (793 expected), level %0d-%0d (0-6143)", hz, lo, hi);
        check(hz > 760 && hz < 830 && lo == 0 && hi > 5700 && hi <= 6144, msg);

        // the beeper on as well: 6144 more
        beeper = 1; listen(100);
        mid = 6144 + 3072; listen(4800);
        $sformat(msg, "beeper on: the level rises by 6144 (%0d-%0d)", lo, hi);
        check(lo >= 6100 && lo <= 6150 && hi > 11800, msg);
        beeper = 0;

        // channel B instead: period 100, volume 15
        r[8] = 0; r[2] = 8'd100; r[3] = 0; r[9] = 8'h0F; r[7] = 8'hFD;
        listen(100);
        mid = 3072; listen(4800);
        hz = ups * 10.0;
        $sformat(msg, "channel B, period 100: %0.0f Hz (2031 expected)", hz);
        check(hz > 1950 && hz < 2110, msg);

        $display("audio: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
