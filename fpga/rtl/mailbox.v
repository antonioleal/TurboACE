// =============================================================================
// TurboACE: the SD mailbox between the Z80 (ports $E5/$E7) and the soft CPU
// (register-map.md 2.6, 2.7). It behaves as firmware/test/host_fpga.c, which the
// firmware is tested against:
//
//   Z80 OUT ($E7)  the byte goes into the ARG FIFO; counts as a data-phase access
//   Z80 OUT ($E5)  command byte: BUSY set, the RES FIFO emptied (unread results are
//                  dropped), the data-phase count stopped, EV_CMD raised
//   Z80 IN ($E7)   the next RES byte ($FF if none), taken at the end of the read;
//                  counts as a data-phase access
//   Z80 IN ($E5)   BUSY b7, ERROR b6, CARD b5, TAPE b4, DATA b0 (RES not empty)
//   data phase     after XFER = n, the n-th $E7 access (read or write) sets BUSY
//                  and raises EV_XFER, so the Z80 never sees BUSY clear before the
//                  firmware has handled the chunk
//
// Soft-CPU registers (word offsets from MB_BASE; rd/wr are one-clock strobes):
//   $00 STATUS W: b6 ERROR, b5 CARD, b4 TAPE; the write clears BUSY
//   $04 EVENTS R: b0 EV_CMD, b1 EV_XFER;  W: 1s clear them (a new event wins)
//   $08 CMD    R: the last command byte
//   $0C ARG    R: the next ARG byte, b8 set if there was none (the read takes it)
//   $10 ARGCNT R: bytes in the ARG FIFO
//   $14 RES    W: push a byte for the Z80
//   $18 RESCLR W: empty the RES FIFO
//   $1C XFER   W: $E7 accesses before BUSY and EV_XFER (0: off)
//   $20 ARGCLR W: empty the ARG FIFO
// irq is high while an event is pending.
// =============================================================================
`timescale 1ns / 1ps
module mailbox (
    input             clk,
    input             reset,
    // Z80 side (from ports.v)
    input             z_cmd_wr,         // OUT ($E5)
    input             z_data_wr,        // OUT ($E7)
    input             z_status_rd,      // IN ($E5), high during the read
    input             z_data_rd,        // IN ($E7), high during the read
    input       [7:0] z_din,
    output      [7:0] z_dout,
    // soft-CPU side
    input             c_rd,
    input             c_wr,
    input       [5:2] c_addr,           // word offset
    input      [31:0] c_wdata,
    output reg [31:0] c_rdata,
    output            irq
);
    reg        busy;
    reg  [2:0] st;                      // ERROR, CARD, TAPE (bits 6-4)
    reg  [1:0] events;
    reg  [7:0] cmd;
    reg [15:0] xfer;

    // the end of a Z80 $E7 read: take the byte then
    reg  data_rd_q;
    always @(posedge clk) data_rd_q <= z_data_rd;
    wire z_data_rd_end = data_rd_q && !z_data_rd;
    wire z_access = z_data_wr || z_data_rd_end;

    wire c_res_push = c_wr && c_addr == 4'h5;
    wire c_res_clr  = c_wr && c_addr == 4'h6;
    wire c_arg_clr  = c_wr && c_addr == 4'h8;
    wire c_arg_pop  = c_rd && c_addr == 4'h3;

    wire [7:0]  arg_head, res_head;
    wire [10:0] arg_count, res_count;
    wire        arg_empty, res_empty;

    fifo #(.AW(10)) argq (.clk(clk), .clear(reset || c_arg_clr), .push(z_data_wr), .din(z_din),
        .pop(c_arg_pop), .head(arg_head), .count(arg_count), .empty(arg_empty), .full());
    fifo #(.AW(10)) resq (.clk(clk), .clear(reset || c_res_clr || z_cmd_wr), .push(c_res_push),
        .din(c_wdata[7:0]), .pop(z_data_rd_end), .head(res_head), .count(res_count),
        .empty(res_empty), .full());

    assign z_dout = z_status_rd ? {busy, st, 3'b000, !res_empty}
                  : res_empty ? 8'hFF : res_head;
    assign irq = |events;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            st <= 3'b000;
            events <= 2'b00;
            cmd <= 8'h00;
            xfer <= 16'd0;
        end else begin
            if (c_wr && c_addr == 4'h1) events <= events & ~c_wdata[1:0];
            if (c_wr && c_addr == 4'h0) begin
                st <= c_wdata[6:4];
                busy <= 1'b0;
            end
            if (c_wr && c_addr == 4'h7) xfer <= c_wdata[15:0];
            // the Z80's side wins over the soft CPU's in the same clock
            if (z_cmd_wr) begin
                cmd <= z_din;
                busy <= 1'b1;
                xfer <= 16'd0;
                events[0] <= 1'b1;
            end else if (z_access && xfer != 0) begin
                xfer <= xfer - 16'd1;
                if (xfer == 16'd1) begin
                    busy <= 1'b1;
                    events[1] <= 1'b1;
                end
            end
        end
    end

    always @(*) begin
        case (c_addr)
            4'h1: c_rdata = {30'd0, events};
            4'h2: c_rdata = {24'd0, cmd};
            4'h3: c_rdata = arg_empty ? 32'h100 : {24'd0, arg_head};
            4'h4: c_rdata = {21'd0, arg_count};
            default: c_rdata = 32'd0;
        endcase
    end
endmodule
