// =============================================================================
// The standalone build from power-on to picture, with Verilator: rtl/top_standalone.v
// as built for the board (Gowin parts as their -DSIM models) with models of the
// SDRAM, the microSD card (a FAT card with /ace.rom, sim/mkcard.c) and the SPI flash
// (TurboACE's ROM pages 2-7). The firmware (build/firmware.hex, read from the
// directory the simulation runs in) loads the ROM and releases the T80, which boots
// to QUERY; then one whole HDMI frame is decoded from the HDMI core's TMDS symbols
// and every pixel compared with the screen worked out from the SDRAM's own text,
// colour and font RAM (text page 0, font 0), with a black border.
// =============================================================================
`timescale 1ns / 1ps
module top_tb;
    reg sys_clk = 0;
    always #(1000.0 / 54) sys_clk = ~sys_clk;          // 27 MHz (the models make the rest)

    wire       tmds_clk_p, tmds_clk_n;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       sd_clk, sd_cmd, sd_dat0, sd_dat3;
    wire       fl_cs_n, fl_clk, fl_mosi, fl_miso, fl_wp_n, fl_hold_n;
    wire       ps2_clk, ps2_data;
    wire [3:0] led;
    wire       O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n;
    wire [1:0] O_sdram_ba;
    wire [10:0] O_sdram_addr;
    wire [3:0] O_sdram_dqm;
    wire [31:0] IO_sdram_dq;

    pullup (ps2_clk);
    pullup (ps2_data);

    // FIRMWARE: the simulation runs in build/
    top_standalone #(.FIRMWARE("firmware.hex")) top (.sys_clk(sys_clk), .s1(1'b0),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n), .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat0(sd_dat0),
        .sd_dat3(sd_dat3), .flash_spi_cs_n(fl_cs_n), .flash_spi_clk(fl_clk), .flash_spi_mosi(fl_mosi),
        .flash_spi_miso(fl_miso), .flash_spi_wp_n(fl_wp_n), .flash_spi_hold_n(fl_hold_n),
        .ps2_clk(ps2_clk), .ps2_data(ps2_data), .led(led), .O_sdram_clk(O_sdram_clk),
        .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_ba(O_sdram_ba),
        .O_sdram_addr(O_sdram_addr), .O_sdram_dqm(O_sdram_dqm), .IO_sdram_dq(IO_sdram_dq));

    sdram_model chip (.clk(O_sdram_clk), .cke(O_sdram_cke), .cs_n(O_sdram_cs_n), .ras_n(O_sdram_ras_n),
        .cas_n(O_sdram_cas_n), .we_n(O_sdram_wen_n), .ba(O_sdram_ba), .a(O_sdram_addr),
        .dqm(O_sdram_dqm), .dq(IO_sdram_dq));
    sdcard_model #(.IMAGE("card.hex")) card (.sclk(sd_clk), .mosi(sd_cmd), .miso(sd_dat0), .cs_n(sd_dat3));
    spiflash_model #(.IMAGE("flash.hex")) flash (.sclk(fl_clk), .mosi(fl_mosi), .miso(fl_miso), .cs_n(fl_cs_n));

    function automatic [7:0] sd_byte(input [22:0] p);
        reg [31:0] w;
        begin w = chip.mem[p >> 2]; sd_byte = w >> (8 * p[1:0]); end
    endfunction

    // ---- the screen worked out from the SDRAM (text page 0, its colours, font 0), as it
    // was when the frame began: a snapshot (the ROM flashes the cursor from its interrupt)
    reg [7:0] snap [0:3 * 1024 - 1];
    task automatic take_snapshot;
        for (int i = 0; i < 1024; i++) begin
            snap[i] = sd_byte(23'h0A0000 + i);
            snap[1024 + i] = sd_byte(23'h0A8000 + i);
            snap[2048 + i] = sd_byte(23'h0B0000 + i);
        end
    endtask
    function automatic bit snapshot_still_true;
        snapshot_still_true = 1;
        for (int i = 0; i < 1024; i++)
            if (snap[i] != sd_byte(23'h0A0000 + i) || snap[1024 + i] != sd_byte(23'h0A8000 + i)
                || snap[2048 + i] != sd_byte(23'h0B0000 + i)) snapshot_still_true = 0;
    endfunction
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
            if (x < 104 || x >= 616 || y < 96 || y >= 480) ref_pixel = palette(4'd0);
            else begin
                ax = (x - 104) / 2; ay = (y - 96) / 2;
                col = ax / 8; row = ay / 8; px = ax % 8;
                code  = snap[row * 32 + col];
                attr  = snap[1024 + row * 32 + col];
                glyph = snap[2048 + (code % 128) * 8 + ay % 8];
                t = ((glyph >> (7 - px)) & 1) ^ (code >> 7);
                ref_pixel = palette(t ? attr[3:0] : attr[7:4]);
            end
        end
    endfunction

    // ---- TMDS decoding (as sim/hdmi_tb.sv)
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
    function automatic integer control(input [9:0] q);
        case (q)
            10'b1101010100: control = 0;
            10'b0010101011: control = 1;
            10'b0101010100: control = 2;
            10'b1010101011: control = 3;
            default: control = -1;
        endcase
    endfunction

    integer checks = 0, failures = 0;
    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) begin failures++; $display("  FAIL %s", what); end
        else $display("  ok   %s", what);
    endtask

    wire clk_pixel = top.clk_pixel;
    wire [9:0] s0 = top.hdmi.tmds_internal[0], s1 = top.hdmi.tmds_internal[1], s2 = top.hdmi.tmds_internal[2];
    reg  [2:0] mode_d = 0;
    always @(posedge clk_pixel) mode_d <= top.hdmi.mode;

    // decode frames once `decoding` is set: the first whole frame after a VSYNC
    reg decoding = 0, prev_vs = 0, framing = 0, done = 0;
    integer x = 0, y = 0, in_video = 0, bad = 0, pixels = 0, c, frames_changed = 0;
    reg [23:0] got, want;
    always @(posedge clk_pixel) if (decoding && !done) begin
        c = control(s0);
        if (mode_d == 3'd1) begin
            if (framing) begin
                got = {tmds_decode(s2), tmds_decode(s1), tmds_decode(s0)};
                want = ref_pixel(x, y);
                if (got !== want) begin
                    bad++;
                    if (bad <= 3) $display("    (%0d,%0d): %06h, want %06h", x, y, got, want);
                end
                pixels++;
            end
            x++;
            in_video = 1;
        end else begin
            if (in_video) begin in_video = 0; y++; x = 0; end
            if (c >= 0) begin
                if (!c[1] && !prev_vs) begin             // VSYNC: a frame starts / ends
                    if (framing) begin
                        if (snapshot_still_true()) done = 1;
                        else begin                       // the screen changed meanwhile: the next frame
                            frames_changed++; bad = 0; pixels = 0;
                        end
                    end
                    if (!done) begin take_snapshot(); framing = 1; y = 0; x = 0; end
                end
                prev_vs = !c[1];
            end
        end
    end

    integer t_boot;
    initial begin
        $display("top: power-on");
        // the firmware releases the Z80 with the ROM loaded (SYS_CTRL: ROM ready, Z80 running)
        wait (top.rom_ready == 1'b1 && top.z80_reset == 1'b0);
        $display("top: the firmware released the Z80 at %0.1f ms (LED: ROM ready %b)", $realtime / 1.0e6, !led[1]);
        check(top.rom_ready === 1'b1, "the firmware loaded the ROM from the SD card and the flash");
        // the T80 boots to QUERY (an opcode fetch at $059B)
        wait (top.ace.dbg_m1_n === 1'b0 && top.ace.dbg_addr === 16'h059B);
        $display("top: the Ace waits for a line (QUERY) at %0.1f ms", $realtime / 1.0e6);
        decoding = 1;
        wait (done);
        check(bad == 0, $sformatf("one whole HDMI frame decoded: every pixel as the screen in the SDRAM (%0d of %0d differ)", bad, pixels));
        check(pixels == 720 * 576, $sformatf("720 x 576 pixels (%0d; %0d frame(s) skipped while the screen changed)", pixels, frames_changed));
        check(chip.errors == 0 && card.errors == 0 && flash.errors == 0, "the SDRAM, card and flash models saw no errors");
        check(!top.underrun, "video kept up");
        $display("top: %0d checks, %s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
    initial begin #1500ms; $display("  FAIL timeout"); $finish; end
endmodule
