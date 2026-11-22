// =============================================================================
// TurboACE: the picture (register-map.md sections 2.3, 2.4, 4).
//
// Output: 720x576 at 50 Hz (CEA-861 video code 17: 864 x 625 at 27 MHz, sync
// negative), here as a pixel enable every other clock of a 54 MHz clock. The
// 256x192 picture is doubled to 512x384 and centred (from x 104, y 96); the
// border (R15 b7-4) fills the rest of the active area.
//
// Each Ace line is fetched into a line buffer while the line before it is shown
// (two HDMI lines, 64 us), through the same req/ack handshake as rtl/sdram.v:
//   text (MODE 0)  per column: code (BG_VIEW page), colour (same offset in colour
//                  RAM), glyph (CHR_VIEW font, row y & 7); code bit 7 inverts.
//                  A pixel is the cellofs's INK (colour b3-0) or PAPER (b7-4).
//   hi-res         also the bitmap byte and its colour byte from screen BG_VIEW
//   (MODE 1)       (8K pages 2n, 2n+1: line y at y*32, colour $1800 above).
//                  Text on top: a text INK pixel shows the text INK; a text PAPER
//                  pixel shows the bitmap pixel in its 8x1 colour, or with OPAQUE
//                  the text PAPER unless the character is a space (code 32).
// Colours are IRGB; each channel is off, half ($80) or full ($FF): colour bit
// plus intensity bit. MODE, BG_VIEW, CHR_VIEW and OPAQUE are taken at the start
// of each line's fetch. underrun goes high (and stays) if a line was not ready.
// r, g, b, de, hsync_n, vsync_n are the pixel at (hcnt, vcnt) while ce_pix is high.
// =============================================================================
`timescale 1ns / 1ps
module video (
    input             clk,              // 54 MHz
    input             reset,
    input             mode,
    input       [4:0] bg_view,
    input       [4:0] chr_view,
    input             opaque,
    input       [3:0] border,
    // fetch port (to the SDRAM arbiter)
    output reg        f_req,
    output reg [22:0] f_addr,
    input             f_ack,
    input       [7:0] f_rdata,
    // picture
    output reg        ce_pix,           // 27 MHz pixel enable
    output reg  [7:0] r,
    output reg  [7:0] g,
    output reg  [7:0] b,
    output reg        hsync_n,
    output reg        vsync_n,
    output reg        de,
    output reg  [9:0] hcnt,
    output reg  [9:0] vcnt,
    output reg        underrun
);
    localparam H_ACTIVE = 720, H_TOTAL = 864, H_SYNC0 = 732, H_SYNC1 = 796;
    localparam V_ACTIVE = 576, V_TOTAL = 625, V_SYNC0 = 581, V_SYNC1 = 586;
    localparam X0 = 104, Y0 = 96;      // the picture's top-left corner

    localparam [22:0] B_BG = 23'h0A0000, B_COL = 23'h0A8000, B_CHR = 23'h0B0000;

    // ---- line buffers: two Ace lines of 256 IRGB colours
    reg [3:0] lbuf [0:511];

    // ---- fetch
    localparam F_IDLE = 0, F_CODE = 1, F_ATTR = 2, F_GLYPH = 3, F_BMP = 4, F_BCOL = 5,
               F_PIX = 6;
    reg  [2:0] fstate;
    reg  [7:0] fy;                      // Ace line being fetched
    reg  [4:0] fcol;
    reg  [2:0] fpix;
    reg        fbuf;
    reg        l_mode, l_opaque;
    reg  [4:0] l_bg, l_chr;
    reg  [7:0] code, attr, glyph, bmp, bcol;
    reg        fetching;

    wire [9:0]  cellofs   = {fy[7:3], fcol};               // row * 32 + column
    wire [13:0] hroff  = {fy, fcol};                    // y * 32 + column (hi-res)
    wire        tpix   = glyph[3'd7 - fpix] ^ code[7];  // text pixel after inverse
    wire        bpix   = bmp[3'd7 - fpix];
    wire [3:0]  bitmap = bpix ? bcol[3:0] : bcol[7:4];
    wire [3:0]  mixed  = tpix ? attr[3:0]
                       : !l_mode ? attr[7:4]
                       : (l_opaque && code != 8'd32) ? attr[7:4] : bitmap;

    // a fetch starts at the start of HDMI line Y0 - 2 + 2y: Ace line y
    wire line_start = ce_pix && hcnt == H_TOTAL - 1;
    wire [9:0] vnext = vcnt == V_TOTAL - 1 ? 10'd0 : vcnt + 10'd1;
    wire start_fetch = line_start && vnext >= Y0 - 2 && vnext < Y0 - 2 + 384 && !vnext[0];

    task request(input [22:0] a);
        begin f_addr <= a; f_req <= 1'b1; end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            fstate <= F_IDLE;
            f_req <= 1'b0;
            fetching <= 1'b0;
            underrun <= 1'b0;
        end else begin
            if (start_fetch) begin
                if (fetching) underrun <= 1'b1;
                fetching <= 1'b1;
                fy <= (vnext - (Y0 - 2)) >> 1;
                fbuf <= ((vnext - (Y0 - 2)) >> 1) & 1'b1;
                fcol <= 5'd0;
                l_mode <= mode; l_opaque <= opaque; l_bg <= bg_view; l_chr <= chr_view;
                fstate <= F_CODE;
                f_req <= 1'b0;
            end else case (fstate)
                F_CODE: if (!f_req) request(B_BG | {l_bg, cellofs});
                        else if (f_ack) begin code <= f_rdata; f_req <= 1'b0; fstate <= F_ATTR; end
                F_ATTR: if (!f_req) request(B_COL | {l_bg, cellofs});
                        else if (f_ack) begin attr <= f_rdata; f_req <= 1'b0; fstate <= F_GLYPH; end
                F_GLYPH: if (!f_req) request(B_CHR | {l_chr, code[6:0], fy[2:0]});
                        else if (f_ack) begin
                            glyph <= f_rdata; f_req <= 1'b0;
                            fstate <= l_mode ? F_BMP : F_PIX;
                            fpix <= 3'd0;
                        end
                F_BMP:  if (!f_req) request({4'b0000, l_bg, hroff});            // screen n at n * 16K
                        else if (f_ack) begin bmp <= f_rdata; f_req <= 1'b0; fstate <= F_BCOL; end
                F_BCOL: if (!f_req) request({4'b0000, l_bg, hroff + 14'h1800});
                        else if (f_ack) begin
                            bcol <= f_rdata; f_req <= 1'b0; fstate <= F_PIX; fpix <= 3'd0;
                        end
                F_PIX: begin                // eight pixels into the line buffer
                    lbuf[{fbuf, fcol, fpix}] <= mixed;
                    fpix <= fpix + 3'd1;
                    if (fpix == 3'd7) begin
                        fcol <= fcol + 5'd1;
                        if (fcol == 5'd31) begin fstate <= F_IDLE; fetching <= 1'b0; end
                        else fstate <= F_CODE;
                    end
                end
                default: ;
            endcase
        end
    end

    // ---- timing and output
    wire        active  = hcnt < H_ACTIVE && vcnt < V_ACTIVE;
    wire        inpic   = hcnt >= X0 && hcnt < X0 + 512 && vcnt >= Y0 && vcnt < Y0 + 384;
    wire [9:0]  ax      = hcnt - X0;                    // doubled Ace x
    wire [9:0]  ay      = vcnt - Y0;                    // doubled Ace y
    wire [3:0]  c       = inpic ? lbuf[{ay[1], ax[8:1]}] : border;
    wire [1:0]  lr = c[2] + c[3], lg = c[1] + c[3], lb = c[0] + c[3];
    function [7:0] level(input [1:0] n);
        level = n == 2'd2 ? 8'hFF : n == 2'd1 ? 8'h80 : 8'h00;
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            ce_pix <= 1'b0;
            hcnt <= 10'd0;
            vcnt <= 10'd0;
            de <= 1'b0; hsync_n <= 1'b1; vsync_n <= 1'b1;
            r <= 0; g <= 0; b <= 0;
        end else begin
            ce_pix <= !ce_pix;
            if (ce_pix) begin
                hcnt <= hcnt == H_TOTAL - 1 ? 10'd0 : hcnt + 10'd1;
                if (hcnt == H_TOTAL - 1) vcnt <= vnext;
            end
            // registered outputs for the pixel at (hcnt, vcnt)
            de      <= active;
            hsync_n <= !(hcnt >= H_SYNC0 && hcnt < H_SYNC1);
            vsync_n <= !(vcnt >= V_SYNC0 && vcnt < V_SYNC1);
            r <= active ? level(lr) : 8'h00;
            g <= active ? level(lg) : 8'h00;
            b <= active ? level(lb) : 8'h00;
        end
    end
endmodule
