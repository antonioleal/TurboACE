// =============================================================================
// The standalone build's power-up, simulated whole: rtl/ace_core.v and rtl/sdcpu.v
// (PicoRV32 running the real firmware, firmware/build/sdcpu.bin) with models of the
// SDRAM, the microSD card (a FAT card with /ace.rom, made by sim/mkcard.c) and the
// board's SPI flash (TurboACE's ROM pages 2-7 at $500000). The firmware must start
// the card, read /ace.rom, check its MD5, take pages 2-7 from the flash, build the
// 64K ROM in the SDRAM and release the Z80 with the ROM ready. Then the 64K must be
// rom/build/turboace.rom byte for byte, and the card and flash saw nothing unknown.
// =============================================================================
`timescale 1ns / 1ps
module powerup_tb;
    localparam real PERIOD = 1000.0 / 54;
    reg clk = 0, reset = 1;
    always #(PERIOD / 2) clk = ~clk;

    // ---- the Ace
    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sdram_ready;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    wire        spk, mic, ce_pix, hs, vs, de, underrun, mb_irq, env, m1_n;
    wire [7:0]  r, g, b;
    wire [127:0] ay_regs;
    wire [15:0] a;
    wire        mb_rd, mb_wr, w_req, w_ack, z80_reset, rom_ready;
    wire [5:2]  mb_addr;
    wire [31:0] mb_wdata, mb_rdata;
    wire [22:0] w_addr;
    wire [7:0]  w_data;
    wire [39:0] kbd_rows;

    ace_core ace (.clk(clk), .reset(reset), .cpu_reset(z80_reset), .kbd_rows(kbd_rows), .ear(1'b1),
        .spk(spk), .mic(mic), .mb_rd(mb_rd), .mb_wr(mb_wr), .mb_addr(mb_addr), .mb_wdata(mb_wdata),
        .mb_rdata(mb_rdata), .mb_irq(mb_irq), .w_req(w_req), .w_addr(w_addr), .w_data(w_data),
        .w_ack(w_ack), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hsync_n(hs), .vsync_n(vs), .de(de),
        .underrun(underrun), .ay_regs(ay_regs), .ay_env_restart(env), .sd_clk(sd_clk),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq),
        .sdram_ready(sdram_ready), .dbg_addr(a), .dbg_m1_n(m1_n));
    sdram_model chip (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq));

    // ---- the soft CPU
    wire card_sclk, card_mosi, card_miso, card_cs_n, fl_sclk, fl_mosi, fl_miso, fl_cs_n;
    wire kbd_take, kbd_send;
    wire kbd_busy = 1'b0;
    wire [7:0] kbd_out;
    sdcpu #(.FIRMWARE("build/firmware.hex"), .STANDALONE(1)) soft (.clk(clk), .reset(reset),
        .mb_rd(mb_rd), .mb_wr(mb_wr), .mb_addr(mb_addr), .mb_wdata(mb_wdata), .mb_rdata(mb_rdata),
        .sd_sclk(card_sclk), .sd_mosi(card_mosi), .sd_miso(card_miso), .sd_cs_n(card_cs_n),
        .fl_sclk(fl_sclk), .fl_mosi(fl_mosi), .fl_miso(fl_miso), .fl_cs_n(fl_cs_n),
        .kbd_in(9'h100), .kbd_take(kbd_take), .kbd_send(kbd_send), .kbd_out(kbd_out),
        .kbd_busy(kbd_busy), .kbd_rows(kbd_rows), .z80_reset(z80_reset), .rom_ready(rom_ready),
        .w_req(w_req), .w_addr(w_addr), .w_data(w_data), .w_ack(w_ack));
`ifdef BADCARD
    sdcard_model #(.IMAGE("build/card_bad.hex")) card
`else
    sdcard_model #(.IMAGE("build/card.hex")) card
`endif (.sclk(card_sclk), .mosi(card_mosi),
        .miso(card_miso), .cs_n(card_cs_n));
    spiflash_model #(.IMAGE("build/flash.hex")) flash (.sclk(fl_sclk), .mosi(fl_mosi),
        .miso(fl_miso), .cs_n(fl_cs_n));

    function [7:0] sd_byte(input [22:0] p);
        reg [31:0] w;
        begin w = chip.mem[p >> 2]; sd_byte = w >> (8 * p[1:0]); end
    endfunction

    integer checks = 0, failures = 0;
    reg [8*120-1:0] msg;
    task check(input ok, input [8*120-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin failures = failures + 1; $display("  FAIL %0s", what); end
        end
    endtask

    function screen_line(input integer y, input [8*40-1:0] text);   // text page 0, line y
        integer n, len, ok;
        begin
            len = 0;
            for (n = 0; n < 40; n = n + 1) if (text[8 * n +: 8] != 0) len = n + 1;
            ok = 1;
            for (n = 0; n < len; n = n + 1)
                if (sd_byte(23'h0A0000 + y * 32 + n) !== text[8 * (len - 1 - n) +: 8]) ok = 0;
            screen_line = ok;
        end
    endfunction

    reg [7:0] rom [0:65535];
    integer i, bad;
    real t_start;

    initial begin
        $readmemh("build/turboace_rom.hex", rom);
        for (i = 0; i < 23'h0C0000 / 4; i = i + 1) chip.mem[i] = 32'd0;   // as the C harness
        repeat (4) @(posedge clk);
        #1 reset = 0;
        t_start = $realtime;
`ifdef BADCARD
        // /ace.rom with one byte changed: the Z80 stays held and the screen says why
        while ($realtime - t_start < 300.0e6) @(posedge clk);
        check(z80_reset === 1'b1, "a wrong /ace.rom: the Z80 stays held");
        check(screen_line(10, "TURBOACE: CANNOT START"), "line 10: TURBOACE: CANNOT START");
        check(screen_line(12, "/ACE.ROM IS NOT THE STOCK ROM"), "line 12: /ACE.ROM IS NOT THE STOCK ROM");
        check(sd_byte(23'h0A8000 + 10 * 32) === 8'h0F, "the message is white on black (colour RAM)");
        $display("powerup (wrong /ace.rom): %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
`endif
        // the firmware releases the Z80 when the ROM is in (or after 1 s: it never did)
        while (z80_reset !== 1'b0 && $realtime - t_start < 1.0e9) @(posedge clk);
        $sformat(msg, "the firmware released the Z80 (after %0.1f ms)", ($realtime - t_start) / 1.0e6);
        check(z80_reset === 1'b0, msg);
        check(rom_ready === 1'b1, "... with the ROM ready (SYS_CTRL b1)");
        bad = 0;
        for (i = 0; i < 65536; i = i + 1)
            if (sd_byte(23'h090000 + i) !== rom[i]) begin
                bad = bad + 1;
                if (bad <= 5) $display("    ROM byte %04h: %02h, turboace.rom has %02h", i, sd_byte(23'h090000 + i), rom[i]);
            end
        $sformat(msg, "the 64K ROM in the SDRAM is rom/build/turboace.rom (%0d bytes differ)", bad);
        check(bad == 0, msg);
        $sformat(msg, "the card saw only known commands (%0d unknown, %0d blocks read)", card.errors, card.reads);
        check(card.errors == 0 && card.reads > 0, msg);
        $sformat(msg, "the flash saw only read commands (%0d bytes read)", flash.reads);
        check(flash.errors == 0 && flash.reads >= 49152, msg);
        check(chip.errors == 0, "the SDRAM model saw no errors");
        $display("powerup: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
