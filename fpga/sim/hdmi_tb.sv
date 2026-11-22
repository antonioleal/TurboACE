// =============================================================================
// Test of the picture through the real HDMI core (hdl-util/hdmi), with Verilator:
// rtl/video.v (fetching from a memory model, as in sim/video_tb.v) feeds the core
// as rtl/top_standalone.v does, and the testbench decodes the core's TMDS symbols
// (10 bits a channel a pixel clock; Verilator leaves the serializer out):
//   - control symbols on channel 0 give HSYNC and VSYNC;
//   - video symbols are TMDS-decoded back to R, G, B;
//   - each pixel's place is counted from the stream itself: video symbols since the
//     line began, lines since VSYNC.
// Every decoded pixel of whole frames must equal the reference picture (computed
// from register-map.md 2.4), the frame must be 720 x 576 inside 864 x 625, and
// HSYNC must start 12 pixels after the active line, for 64 pixels.
// =============================================================================
`timescale 1ns / 1ps
module hdmi_tb;
    reg clk = 0, clk_pixel = 0, reset = 1;
    always #(1000.0 / 108) clk = ~clk;                  // 54 MHz
    always @(posedge clk) clk_pixel <= ~clk_pixel;      // 27 MHz, half of it
    reg clk_x5 = 0;
    always #(1000.0 / 270) clk_x5 = ~clk_x5;            // not used by the sim model
    reg clk_audio = 0;
    always #10416 clk_audio = ~clk_audio;               // 48 kHz

    reg        mode = 0, opaque = 0;
    reg  [4:0] bg_view = 3, chr_view = 5;
    reg  [3:0] border = 4'd9;
    wire       f_req;
    wire [22:0] f_addr;
    reg        f_ack = 0;
    reg  [7:0] f_rdata = 0;
    wire       ce_pix, hsync_n, vsync_n, de, underrun;
    wire [7:0] r, g, b;
    wire [9:0] hcnt, vcnt;
    video vid (.clk(clk), .reset(reset), .mode(mode), .bg_view(bg_view), .chr_view(chr_view),
        .opaque(opaque), .border(border), .f_req(f_req), .f_addr(f_addr), .f_ack(f_ack),
        .f_rdata(f_rdata), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hsync_n(hsync_n),
        .vsync_n(vsync_n), .de(de), .hcnt(hcnt), .vcnt(vcnt), .underrun(underrun));

    // memory, as in video_tb.v
    function automatic [7:0] memval(input [22:0] a);
        reg [31:0] h;
        begin
            h = ({9'd0, a} + 32'h1234) * 32'h9E3779B1;
            memval = h[23:16] ^ h[31:24];
            if (a >= 23'h0A0000 && a < 23'h0A8000 && h[3:2] == 2'b00) memval = 8'd32;
        end
    endfunction
    integer wait_n = 3;
    always @(posedge clk) begin
        f_ack <= 1'b0;
        if (f_req && !f_ack) begin
            if (wait_n == 0) begin f_rdata <= memval(f_addr); f_ack <= 1'b1; wait_n <= 4; end
            else wait_n <= wait_n - 1;
        end
    end

    // as top_standalone.v
    reg pix_level = 0;
    always @(negedge clk) pix_level <= clk_pixel;
    reg reset_hd = 1, reset_pix = 1;
    always @(posedge clk) if (pix_level) reset_hd <= reset;
    always @(posedge clk_pixel) reset_pix <= reset_hd;
    reg [23:0] rgb54, rgb;
    always @(posedge clk) if (pix_level) rgb54 <= {r, g, b};
    always @(posedge clk_pixel) rgb <= rgb54;
    wire [2:0] tmds;
    wire       tmds_clock;
    logic [15:0] aw [1:0];
    assign aw[0] = 16'd0;
    assign aw[1] = 16'd0;
    hdmi #(.VIDEO_ID_CODE(17), .VIDEO_REFRESH_RATE(50.0), .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16),
           .START_X(`START_X), .START_Y(`START_Y)) hdmi (
        .clk_pixel_x5(clk_x5), .clk_pixel(clk_pixel), .clk_audio(clk_audio), .reset(reset_pix),
        .rgb(rgb), .audio_sample_word(aw), .tmds(tmds), .tmds_clock(tmds_clock), .cx(), .cy(),
        .frame_width(), .frame_height(), .screen_width(), .screen_height());

    // ---- the reference picture (register-map.md 2.4), as in video_tb.v
    function automatic [23:0] palette(input [3:0] c);
        integer lr, lg, lb;
        begin
            lr = c[2] + c[3]; lg = c[1] + c[3]; lb = c[0] + c[3];
            palette = {lr == 2 ? 8'hFF : lr == 1 ? 8'h80 : 8'h00,
                       lg == 2 ? 8'hFF : lg == 1 ? 8'h80 : 8'h00,
                       lb == 2 ? 8'hFF : lb == 1 ? 8'h80 : 8'h00};
        end
    endfunction
    function automatic [23:0] ref_pixel(input integer x, input integer y);
        integer ax, ay, col, row, px, t;
        reg [7:0] code, attr, glyph;
        begin
            if (x < 104 || x >= 616 || y < 96 || y >= 480) ref_pixel = palette(border);
            else begin
                ax = (x - 104) / 2; ay = (y - 96) / 2;
                col = ax / 8; row = ay / 8; px = ax % 8;
                code  = memval(23'h0A0000 + bg_view * 1024 + row * 32 + col);
                attr  = memval(23'h0A8000 + bg_view * 1024 + row * 32 + col);
                glyph = memval(23'h0B0000 + chr_view * 1024 + (code % 128) * 8 + ay % 8);
                t = ((glyph >> (7 - px)) & 1) ^ (code >> 7);
                ref_pixel = palette(t ? attr[3:0] : attr[7:4]);
            end
        end
    endfunction

    // ---- TMDS decoding
    function automatic [7:0] tmds_decode(input [9:0] q);
        reg [7:0] d, o;
        integer i;
        begin
            d = q[9] ? ~q[7:0] : q[7:0];
            o[0] = d[0];
            for (i = 1; i < 8; i++) o[i] = q[8] ? d[i] ^ d[i - 1] : ~(d[i] ^ d[i - 1]);
            tmds_decode = o;
        end
    endfunction
    function automatic integer control(input [9:0] q);     // the 2 control bits, or -1
        case (q)
            10'b1101010100: control = 0;
            10'b0010101011: control = 1;
            10'b0101010100: control = 2;
            10'b1010101011: control = 3;
            default: control = -1;
        endcase
    endfunction

    integer checks = 0, failures = 0;
    string  msg;
    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin failures++; $display("  FAIL %s", what); end
    endtask

    // the stream, one symbol a pixel clock
    wire [9:0] s0 = hdmi.tmds_internal[0], s1 = hdmi.tmds_internal[1], s2 = hdmi.tmds_internal[2];
    integer x = 0, y = -1, bad = 0, pixels = 0, lines = 0, frames = 0, last_x = 0;
    integer hs_start = -1, hs_len = 0, since_video = 0, vs_seen = 0, in_video = 0;
    integer hs_bad = 0, width_bad = 0, frame_lines = 0;
    integer c;
    reg checking = 0, prev_vs = 0;
    reg [2:0] mode_d = 0;               // tmds_channel registers its symbol: it follows mode by a clock
    always @(posedge clk_pixel) mode_d <= hdmi.mode;
    reg [23:0] got, want;

    always @(posedge clk_pixel) if (!reset_pix) begin
        c = control(s0);
        // a video symbol: the three channels are TMDS data, not control
        if (mode_d == 3'd1) begin
            got = {tmds_decode(s2), tmds_decode(s1), tmds_decode(s0)};
            if (checking && y >= 0) begin
                want = ref_pixel(x, y);
                if (got !== want) begin
                    bad++;
                    if (bad <= 3) $display("    (%0d,%0d): %06h, want %06h", x, y, got, want);
                end
                pixels++;
            end
            x++;
            in_video = 1;
            since_video = 0;
        end else begin
            if (in_video) begin                // a line has ended
                if (checking && x != 720) width_bad++;
                in_video = 0;
                y++;
                x = 0;
                hs_start = -1;
            end
            since_video++;
            if (c >= 0) begin
                // channel 0's control bits are {VSYNC, HSYNC}, inverted for code 17
                if (!c[0] && hs_start < 0 && y >= 0) begin hs_start = since_video; hs_len = 0; end
                if (!c[0]) hs_len++;
                else if (hs_start >= 0 && hs_len > 0 && checking && hs_len != 64 && !c[1] == 0) hs_bad++;
                if (!c[1] && !prev_vs) begin       // VSYNC starts: a new frame
                    if (checking && y >= 0) frame_lines = y;
                    y = 0;                              // the next video line is line 0
                    frames++;
                    if (frames == 2) checking = 1;
                    if (frames == 4) begin
                        check(bad == 0, $sformatf("every decoded pixel equals the reference (%0d of %0d differ)", bad, pixels));
                        check(pixels == 2 * 720 * 576, $sformatf("2 frames of 720 x 576 video pixels (%0d)", pixels));
                        check(width_bad == 0, "every line has 720 video pixels");
                        check(frame_lines == 576, $sformatf("576 lines from VSYNC to VSYNC (%0d)", frame_lines));
                        check(!underrun, "video kept up");
                        $display("hdmi: %0d checks, %s", checks, failures ? "FAILED" : "all passed");
                        $finish;
                    end
                end
                prev_vs = !c[1];
            end
        end
    end

    // reset ends as in top_standalone.v: on a 54 MHz edge where the pixel clock is low
    reg go = 0;
    always @(posedge clk) if (go && !pix_level) reset <= 0;
    initial begin
        repeat (8) @(posedge clk);
        go = 1;
        #200ms;
        $display("  FAIL timeout");
        $finish;
    end
endmodule
