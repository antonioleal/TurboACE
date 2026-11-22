// =============================================================================
// TurboACE: shares the SDRAM controller (rtl/sdram.v) between the CPU and video.
// Both sides use the controller's handshake: raise req with the request, hold it
// until ack (one clock), then drop it; each raise is one access.
//
//   port A: the CPU (reads and writes), first: its bus cycle cannot wait long
//   port B: video fetches (reads), whenever the CPU is not asking
//   port C: the soft CPU's writes (the ROM at power-up, start-up messages), last
//
// The CPU makes at most one access per memory cycle (about 1 us at 3.25 MHz)
// against about 0.2 us per SDRAM access, so video keeps most of the bandwidth;
// a CPU request waits at most for a refresh and one video access already started.
// =============================================================================
`timescale 1ns / 1ps
module arbiter (
    input             clk,
    input             reset,
    // A: CPU
    input             a_req,
    input             a_we,
    input      [22:0] a_addr,
    input       [7:0] a_wdata,
    output reg        a_ack,
    output reg  [7:0] a_rdata,
    // B: video
    input             b_req,
    input      [22:0] b_addr,
    output reg        b_ack,
    output reg  [7:0] b_rdata,
    // C: soft CPU (writes)
    input             c_req,
    input      [22:0] c_addr,
    input       [7:0] c_wdata,
    output reg        c_ack,
    // to the controller
    output reg        req,
    output reg        we,
    output reg [22:0] addr,
    output reg  [7:0] wdata,
    input             ack,
    input       [7:0] rdata
);
    reg       busy;
    reg [1:0] grant;                    // 0 A, 1 B, 2 C
    reg       a_done, b_done, c_done;   // this raise of req has been served

    always @(posedge clk) begin
        a_ack <= 1'b0;
        b_ack <= 1'b0;
        c_ack <= 1'b0;
        if (reset) begin
            busy <= 1'b0;
            req <= 1'b0;
            a_done <= 1'b0;
            b_done <= 1'b0;
            c_done <= 1'b0;
        end else begin
            if (!a_req) a_done <= 1'b0;
            if (!b_req) b_done <= 1'b0;
            if (!c_req) c_done <= 1'b0;
            if (!busy && !req) begin
                if (a_req && !a_done) begin
                    busy <= 1'b1; grant <= 2'd0;
                    req <= 1'b1; we <= a_we; addr <= a_addr; wdata <= a_wdata;
                end else if (b_req && !b_done) begin
                    busy <= 1'b1; grant <= 2'd1;
                    req <= 1'b1; we <= 1'b0; addr <= b_addr;
                end else if (c_req && !c_done) begin
                    busy <= 1'b1; grant <= 2'd2;
                    req <= 1'b1; we <= 1'b1; addr <= c_addr; wdata <= c_wdata;
                end
            end else if (busy && ack) begin
                req <= 1'b0;            // low for at least a clock before the next
                busy <= 1'b0;
                case (grant)
                    2'd0: begin a_ack <= 1'b1; a_rdata <= rdata; a_done <= 1'b1; end
                    2'd1: begin b_ack <= 1'b1; b_rdata <= rdata; b_done <= 1'b1; end
                    default: begin c_ack <= 1'b1; c_done <= 1'b1; end
                endcase
            end
        end
    end
endmodule
