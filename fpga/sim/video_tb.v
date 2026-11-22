// =============================================================================
// Test of rtl/video.v: every pixel of whole HDMI frames compared with a reference
// that computes each pixel straight from register-map.md 2.4 (not line by line),
// over text mode, hi-res, and hi-res with OPAQUE; sync and blanking timing;
// memory that answers fetches after a random delay; and a memory too slow for a
// line, which must set underrun.
// =============================================================================
`timescale 1ns / 1ps
module video_tb;
    reg clk = 0, reset = 1;
    always #9.259 clk = ~clk;           // 54 MHz

    reg        mode = 0, opaque = 0;
    reg  [4:0] bg_view = 0, chr_view = 0;
    reg  [3:0] border = 0;
    wire       f_req;
    wire [22:0] f_addr;
    reg        f_ack = 0;
    reg  [7:0] f_rdata = 0;
    wire       ce_pix, hsync_n, vsync_n, de, underrun;
    wire [7:0] r, g, b;
    wire [9:0] hcnt, vcnt;

    video dut (.clk(clk), .reset(reset), .mode(mode), .bg_view(bg_view), .chr_view(chr_view),
        .opaque(opaque), .border(border), .f_req(f_req), .f_addr(f_addr), .f_ack(f_ack),
        .f_rdata(f_rdata), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hsync_n(hsync_n),
        .vsync_n(vsync_n), .de(de), .hcnt(hcnt), .vcnt(vcnt), .underrun(underrun));

    // ---- memory: bytes made from the address; a quarter of the text codes are spaces
    function [7:0] memval(input [22:0] a);
        reg [31:0] h;
        begin
            h = ({9'd0, a} + 32'h1234) * 32'h9E3779B1;
            memval = h[23:16] ^ h[31:24];
            if (a >= 23'h0A0000 && a < 23'h0A8000 && h[3:2] == 2'b00) memval = 8'd32;
        end
    endfunction

    integer max_delay = 8, seed = 99, wait_n;
    always @(posedge clk) begin
        f_ack <= 1'b0;
        if (f_req && !f_ack) begin
            if (wait_n == 0) begin
                f_rdata <= memval(f_addr);
                f_ack <= 1'b1;
                wait_n <= 1 + {$random(seed)} % max_delay;
            end else wait_n <= wait_n - 1;
        end
    end
    initial wait_n = 3;

    // ---- the reference
    function [23:0] palette(input [3:0] c);
        integer lr, lg, lb;
        begin
            lr = c[2] + c[3]; lg = c[1] + c[3]; lb = c[0] + c[3];
            palette = {lr == 2 ? 8'hFF : lr == 1 ? 8'h80 : 8'h00,
                       lg == 2 ? 8'hFF : lg == 1 ? 8'h80 : 8'h00,
                       lb == 2 ? 8'hFF : lb == 1 ? 8'h80 : 8'h00};
        end
    endfunction

    function [23:0] ref_pixel(input integer x, input integer y);
        integer ax, ay, col, row, px, t, bp;
        reg [7:0] code, attr, glyph, bm, bc;
        reg [3:0] c;
        begin
            if (x >= 720 || y >= 576) ref_pixel = 24'h000000;
            else if (x < 104 || x >= 616 || y < 96 || y >= 480) ref_pixel = palette(border);
            else begin
                ax = (x - 104) / 2; ay = (y - 96) / 2;
                col = ax / 8; row = ay / 8; px = ax % 8;
                code  = memval(23'h0A0000 + bg_view * 1024 + row * 32 + col);
                attr  = memval(23'h0A8000 + bg_view * 1024 + row * 32 + col);
                glyph = memval(23'h0B0000 + chr_view * 1024 + (code % 128) * 8 + ay % 8);
                t = ((glyph >> (7 - px)) & 1) ^ (code >> 7);
                if (!mode) c = t ? attr[3:0] : attr[7:4];
                else begin
                    bm = memval(bg_view * 16384 + ay * 32 + col);
                    bc = memval(bg_view * 16384 + 24'h1800 + ay * 32 + col);
                    bp = (bm >> (7 - px)) & 1;
                    if (t) c = attr[3:0];
                    else if (opaque && code != 8'd32) c = attr[7:4];
                    else c = bp ? bc[3:0] : bc[7:4];
                end
                ref_pixel = palette(c);
            end
        end
    endfunction

    integer checks = 0, failures = 0;
    reg [8*200-1:0] msg;
    task check(input ok, input [8*200-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                failures = failures + 1;
                if (failures <= 20) $display("  FAIL %0s", what);
            end
        end
    endtask

    // one whole frame from (0, 0), every pixel and the sync signals compared
    task frame(input checking, input [8*40-1:0] name);
        integer bad, badsync, x, y, n;
        reg [23:0] want;
        begin
            @(posedge clk); while (!(ce_pix && hcnt == 0 && vcnt == 0)) @(posedge clk);
            bad = 0; badsync = 0; n = 0;
            while (n < 864 * 625) begin
                #1;
                if (ce_pix) begin
                    x = hcnt; y = vcnt;
                    want = ref_pixel(x, y);
                    if ({r, g, b} !== want) begin
                        bad = bad + 1;
                        if (checking && bad <= 3) $display("    %0s (%0d,%0d): %06h, want %06h", name, x, y, {r, g, b}, want);
                    end
                    if (de !== (x < 720 && y < 576) || hsync_n !== !(x >= 732 && x < 796)
                        || vsync_n !== !(y >= 581 && y < 586)) badsync = badsync + 1;
                    n = n + 1;
                end
                @(posedge clk);
            end
            if (checking) begin
                $sformat(msg, "%0s: all 864x625 pixels as the reference (%0d differ)", name, bad);
                check(bad == 0, msg);
                $sformat(msg, "%0s: DE, HSYNC, VSYNC timing (%0d wrong)", name, badsync);
                check(badsync == 0, msg);
                check(!underrun, "no line late (underrun)");
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;

        mode = 0; bg_view = 3; chr_view = 5; border = 4'd9;
        frame(0, "warm-up");                       // the first lines were fetched before the settings
        frame(1, "text, page 3, font 5, blue border");
        mode = 1; opaque = 0; bg_view = 7; chr_view = 2; border = 4'd12;
        frame(0, "warm-up");
        frame(1, "hi-res screen 7, text overlay transparent");
        opaque = 1; bg_view = 31; chr_view = 31; border = 4'd15; max_delay = 12;
        frame(0, "warm-up");
        frame(1, "hi-res screen 31, OPAQUE, slower memory");

        max_delay = 90;                         // far too slow for 160 fetches in 64 us
        frame(0, "warm-up");
        check(underrun === 1'b1, "a memory too slow for a line sets underrun");

        $display("video: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
