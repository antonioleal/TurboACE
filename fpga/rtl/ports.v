// =============================================================================
// TurboACE: the Z80's I/O ports (register-map.md sections 1, 2.1-2.5, 4.1).
//
//   $E3  control port. Write cccddddd: command ccc, parameter ddddd. Read: the
//        selector is A15-A13 (IN A,(n) puts A on A15-A8), result per command:
//        000 BG_CPU, 001 BG_VIEW, 010 CHR_CPU, 011 CHR_VIEW (000ppppp), 100 MODE
//        (0000000m), 101 reserved (0), 110 ROMPAGE (00000ppp, reset 1),
//        111 XCFG (write: b0 ATTR, b1 MIRROR, b2 OPAQUE, b3 KEEP; read 1010100a,
//        the ID).
//   $E1  user-RAM page: write w0pppppp (window w, page 0-63); read 00pppppp of the
//        window on A15. Reset: window 0 = page 0, window 1 = page 1.
//   $E5  $E7  SD card: decoded here, served by the mailbox (sd_* signals).
//   odd $F1-$FF  the AY, decoded as on Jupiter-II (A7 A6 A5 A4 A0): a write with
//        A1 = 0 ($FD) selects a register, with A1 = 1 ($FF) writes it; a read with
//        A1 = 1 reads it ($FD reads leave the bus alone). Unused bits read 0;
//        R14 (PAPER:INK) and R15 (BORDER) are the colour registers whatever R7 says.
//   $E1, $E3, $E5, $E7 are decoded on the whole low byte; $E9-$EF are not decoded.
//
// Bus side: io_wr is a one-clock strobe per I/O write, io_rd is high during an
// I/O read; addr and din are stable meanwhile. dout / dout_en: this module (or the
// SD mailbox through it) drives the data bus.
// =============================================================================
`timescale 1ns / 1ps
module ports (
    input             clk,
    input             reset,
    input             io_wr,
    input             io_rd,
    input      [15:0] addr,
    input       [7:0] din,
    output reg  [7:0] dout,
    output reg        dout_en,
    // $E3
    output reg  [4:0] bg_cpu,
    output reg  [4:0] bg_view,
    output reg  [4:0] chr_cpu,
    output reg  [4:0] chr_view,
    output reg        mode,             // 0 text, 1 hi-res
    output reg  [2:0] rompage,
    output reg        xcfg_attr,
    output reg        xcfg_mirror,
    output reg        xcfg_opaque,
    output reg        xcfg_keep,        // with MIRROR: $3B00-$3BFF stay extension RAM
    // $E1
    output reg  [5:0] win0,
    output reg  [5:0] win1,
    // the AY's registers (for ay.sv) and the colours
    output reg  [7:0] ay_sel,
    output     [127:0] ay_regs,         // R0 in bits 7-0 ... R15 in bits 127-120
    output reg        ay_env_restart,   // one clock after R13 is written
    output      [3:0] ink,
    output      [3:0] paper,
    output      [3:0] border,
    // SD ports to the mailbox
    output            sd_cmd_wr,        // OUT ($E5): command byte = din
    output            sd_data_wr,       // OUT ($E7): data byte = din
    output            sd_status_rd,     // IN ($E5)
    output            sd_data_rd,       // IN ($E7)
    input       [7:0] sd_dout           // the mailbox's answer to those reads
);
    wire p_e3 = addr[7:0] == 8'hE3;
    wire p_e1 = addr[7:0] == 8'hE1;
    wire p_e5 = addr[7:0] == 8'hE5;
    wire p_e7 = addr[7:0] == 8'hE7;
    wire p_ay = addr[7:4] == 4'hF && addr[0];

    assign sd_cmd_wr    = io_wr && p_e5;
    assign sd_data_wr   = io_wr && p_e7;
    assign sd_status_rd = io_rd && p_e5;
    assign sd_data_rd   = io_rd && p_e7;

    reg [7:0] ay [0:15];
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : regs_out
        assign ay_regs[8 * g + 7 -: 8] = ay[g];
    end endgenerate
    assign ink    = ay[14][3:0];
    assign paper  = ay[14][7:4];
    assign border = ay[15][7:4];

    integer i;
    always @(posedge clk) begin
        ay_env_restart <= 1'b0;
        if (reset) begin
            bg_cpu <= 0; bg_view <= 0; chr_cpu <= 0; chr_view <= 0;
            mode <= 0; rompage <= 3'd1;
            xcfg_attr <= 0; xcfg_mirror <= 0; xcfg_opaque <= 0; xcfg_keep <= 0;
            win0 <= 6'd0; win1 <= 6'd1;
            ay_sel <= 8'd0;
            for (i = 0; i < 16; i = i + 1) ay[i] <= 8'd0;
            ay[14] <= 8'h0F;            // white INK on black PAPER
        end else if (io_wr) begin
            if (p_e3) case (din[7:5])
                3'd0: bg_cpu   <= din[4:0];
                3'd1: bg_view  <= din[4:0];
                3'd2: chr_cpu  <= din[4:0];
                3'd3: chr_view <= din[4:0];
                3'd4: mode     <= din[0];
                3'd5: ;                 // reserved
                3'd6: rompage  <= din[2:0];
                3'd7: {xcfg_keep, xcfg_opaque, xcfg_mirror, xcfg_attr} <= din[3:0];
            endcase
            if (p_e1) begin
                if (din[7]) win1 <= din[5:0];
                else        win0 <= din[5:0];
            end
            if (p_ay) begin
                if (!addr[1]) ay_sel <= din;
                else if (ay_sel < 8'd16) begin
                    ay[ay_sel[3:0]] <= din;
                    if (ay_sel == 8'd13) ay_env_restart <= 1'b1;
                end
            end
        end
    end

    // reads
    reg [7:0] ay_read;
    wire [7:0] ay_cur = ay[ay_sel[3:0]];
    always @(*) begin
        case (ay_sel[3:0])
            4'd1, 4'd3, 4'd5, 4'd13: ay_read = ay_cur & 8'h0F;
            4'd6, 4'd8, 4'd9, 4'd10: ay_read = ay_cur & 8'h1F;
            default:                 ay_read = ay_cur;
        endcase
        if (ay_sel >= 8'd16) ay_read = 8'hFF;   // no register selected
    end

    always @(*) begin
        dout = 8'hFF;
        dout_en = 1'b0;
        if (io_rd) begin
            if (p_e3) begin
                dout_en = 1'b1;
                case (addr[15:13])
                    3'd0: dout = {3'b000, bg_cpu};
                    3'd1: dout = {3'b000, bg_view};
                    3'd2: dout = {3'b000, chr_cpu};
                    3'd3: dout = {3'b000, chr_view};
                    3'd4: dout = {7'b0, mode};
                    3'd5: dout = 8'h00;
                    3'd6: dout = {5'b0, rompage};
                    3'd7: dout = {7'b1010100, xcfg_attr};
                endcase
            end else if (p_e1) begin
                dout_en = 1'b1;
                dout = {2'b00, addr[15] ? win1 : win0};
            end else if (p_e5 || p_e7) begin
                dout_en = 1'b1;
                dout = sd_dout;
            end else if (p_ay && addr[1]) begin
                dout_en = 1'b1;
                dout = ay_read;
            end
        end
    end
endmodule
