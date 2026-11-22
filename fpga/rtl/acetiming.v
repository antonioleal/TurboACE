// =============================================================================
// TurboACE: the Jupiter Ace's own frame timing, for the standalone build
// (register-map.md decision 25), as the stock Ace (JupiterACE_MiSTer rtl/video.v):
//
//   - 3.25 MHz: ce_cpu is one clock in 16.6 of the 54 MHz clock, exactly 13 in 216
//     (each T-state at most one 54 MHz clock off its ideal time);
//   - a line is 208 T-states, a frame 312 lines (64,896 T, 50.08 Hz);
//   - the picture is the first 128 T-states of lines 0-191;
//   - INT (int_n low) for 8 lines from T-state 154 of line 248;
//   - picture_time: high while the picture is drawn: a CPU access to the
//     video-priority copies ($2400-$27FF, $2C00-$2FFF) then waits (WAIT) until it
//     ends, as on the stock Ace.
// =============================================================================
`timescale 1ns / 1ps
module acetiming (
    input            clk,               // 54 MHz
    input            reset,
    output reg       ce_cpu,            // one clock per T-state, at its start
    output           ce_cpu_n,          // ... and at its middle (8 clocks later), for T80pa
    output reg [7:0] tstate,            // 0-207
    output reg [8:0] line,              // 0-311
    output reg       int_n,
    output           picture_time
);
    reg [7:0] acc;
    reg [7:0] ce_dly;                   // ce_cpu, 1-8 clocks ago
    assign ce_cpu_n = ce_dly[7];

    assign picture_time = line < 9'd192 && tstate < 8'd128;

    always @(posedge clk) begin
        if (reset) begin
            acc <= 8'd0;
            ce_cpu <= 1'b0;
            tstate <= 8'd0;
            line <= 9'd0;
            int_n <= 1'b1;
            ce_dly <= 8'd0;
        end else begin
            ce_dly <= {ce_dly[6:0], ce_cpu};
            // 13 / 216 of 54 MHz = 3.25 MHz
            if (acc >= 8'd203) begin acc <= acc - 8'd203; ce_cpu <= 1'b1; end
            else begin acc <= acc + 8'd13; ce_cpu <= 1'b0; end
            if (ce_cpu) begin
                if (tstate == 8'd207) begin
                    tstate <= 8'd0;
                    line <= line == 9'd311 ? 9'd0 : line + 9'd1;
                end else
                    tstate <= tstate + 8'd1;
                if (tstate == 8'd153) begin
                    if (line == 9'd248) int_n <= 1'b0;
                    if (line == 9'd256) int_n <= 1'b1;
                end
            end
        end
    end
endmodule
