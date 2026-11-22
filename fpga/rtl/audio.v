// =============================================================================
// TurboACE: the sound, as HDMI audio samples (register-map.md decisions 16, 31).
//   - the AY-3-8910: ay.sv (from JupiterACE_MiSTer, the user's own core), run at
//     3.25 MHz (ce_ay), registers from ports.v;
//   - the Ace's beeper (the speaker bit of its even port), in the standalone build,
//     where there is no other speaker;
//   - mixed: the three channels (0-12287 each) and the beeper (12288 when on), and
//     halved: 0 - 24574, so nothing clips and silence is exactly 0 (no click when
//     sound starts);
//   - averaged over each sample period (a box filter against aliasing) and given
//     out at exactly 48 kHz: one sample every 1125 clocks of 54 MHz (sample_ce),
//     16 bits signed. clk_audio is a 48 kHz square wave for the HDMI core.
// =============================================================================
`timescale 1ns / 1ps
module audio (
    input             clk,              // 54 MHz
    input             reset,
    input             ce_ay,            // 3.25 MHz
    input     [127:0] ay_regs,          // R0 in bits 7-0 ... R15 in bits 127-120
    input             env_restart,
    input             beeper,
    output reg [15:0] sample,           // signed
    output reg        sample_ce,        // one clock: a new sample
    output reg        clk_audio
);
    wire [13:0] ch_a, ch_b, ch_c;
    ay psg (.clk(clk), .ce_ay(ce_ay), .reset(reset),
        .r0(ay_regs[7:0]),   .r1(ay_regs[15:8]),  .r2(ay_regs[23:16]),   .r3(ay_regs[31:24]),
        .r4(ay_regs[39:32]), .r5(ay_regs[47:40]), .r6(ay_regs[55:48]),   .r7(ay_regs[63:56]),
        .r8(ay_regs[71:64]), .r9(ay_regs[79:72]), .r10(ay_regs[87:80]),  .r11(ay_regs[95:88]),
        .r12(ay_regs[103:96]), .r13(ay_regs[111:104]), .env_restart(env_restart),
        .ch_a(ch_a), .ch_b(ch_b), .ch_c(ch_c));

    // the level now: 0 - 49149
    wire [15:0] level = ch_a + ch_b + ch_c + (beeper ? 16'd12288 : 16'd0);

    reg [10:0] n;                       // 0 - 1124
    reg [26:0] acc;                     // up to 1125 x 49149
    wire [26:0] total = acc + level;
    // mean = total / 1125 ~ total * 233 / 2^18 (1/1125.08)
    wire [34:0] scaled = total * 8'd233;
    wire [16:0] mean = scaled[34:18];

    always @(posedge clk) begin
        sample_ce <= 1'b0;
        if (reset) begin
            n <= 0; acc <= 0; sample <= 0; clk_audio <= 1'b0;
        end else begin
            if (n == 11'd562) clk_audio <= 1'b1;
            if (n == 11'd1124) begin
                n <= 0;
                acc <= 0;
                sample <= mean[16:1];               // halved: silence is 0
                sample_ce <= 1'b1;
                clk_audio <= 1'b0;
            end else begin
                n <= n + 11'd1;
                acc <= total;
            end
        end
    end
endmodule
