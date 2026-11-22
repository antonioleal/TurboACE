// =============================================================================
// TurboACE standalone build: the top level for the Tang Nano 20K (register-map.md
// decisions 24-27, 31). The Jupiter Ace (ace_core.v), the soft CPU (sdcpu.v), the
// PS/2 keyboard (ps2.v), the sound (audio.v) and HDMI (hdl-util/hdmi, rtl/hdmi/).
//
// Clocks, all from one PLL (clocks.v) so they keep a fixed phase:
//   270 MHz (27 MHz crystal x 10) -> /2: 135 MHz for HDMI's 10:1 serializer
//                                  -> /5: 54 MHz, the system clock
//   135 MHz /5 -> 27 MHz, the HDMI pixel clock (exactly half of 54 MHz)
// The SDRAM's clock is the 54 MHz clock inverted (forwarded by a DDR output).
//
// HDMI: video.v keeps its own 864 x 625 counters; the HDMI core counts the same
// frame from the same reset (released at a fixed phase of the pixel clock, below),
// so each of video.v's pixels lands where it belongs. Both the pixel and the HDMI
// side's reset cross from 54 MHz to the pixel clock the same way (copied where the
// pixel clock falls, taken where it rises), so there is no race at a shared edge
// and the core starts at (0, 0). Checked by sim/hdmi_tb.sv and sim/top_tb.sv, which
// decode the core's TMDS symbols; a pixel either way fails. Sound: 48 kHz, 16 bits, the
// same sample on both channels.
//
// Pins: tang_nano_20k_standalone.cst. Buttons: S1 (88) resets everything.
// =============================================================================
`timescale 1ns / 1ps
module top_standalone #(
    parameter FIRMWARE = "build/firmware.hex"  // the soft CPU's program, read at synthesis
                                               // (make -C fpga gowin makes it)
) (
    input         sys_clk,              // 27 MHz
    input         s1,                   // button: reset (high when pressed)
    // HDMI
    output        tmds_clk_p, tmds_clk_n,
    output  [2:0] tmds_d_p, tmds_d_n,
    // microSD (SPI mode)
    output        sd_clk,
    output        sd_cmd,               // MOSI
    input         sd_dat0,              // MISO
    output        sd_dat3,              // CS
    // the board's SPI flash (MSPI pins used as ordinary I/O after configuration)
    output        flash_spi_cs_n,
    output        flash_spi_clk,
    output        flash_spi_mosi,
    input         flash_spi_miso,
    output        flash_spi_wp_n,
    output        flash_spi_hold_n,
    // PS/2 keyboard, through the level shifter (open-drain)
    inout         ps2_clk,
    inout         ps2_data,
    // LEDs (low = on): 0 Z80 running, 1 ROM ready, 2 SD card in use, 3 video late
    output  [3:0] led,
    // the SDRAM in the GW2AR-18's package (fixed names)
    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,
    output        O_sdram_cas_n,
    output        O_sdram_ras_n,
    output        O_sdram_wen_n,
    output  [1:0] O_sdram_ba,
    output [10:0] O_sdram_addr,
    output  [3:0] O_sdram_dqm,
    inout  [31:0] IO_sdram_dq
);
    // ---- clocks and reset
    wire clk, clk_pixel, clk_pixel_x5, locked;
    clocks clocks (.clk27(sys_clk), .clk54(clk), .clk135(clk_pixel_x5), .clk27_pixel(clk_pixel),
        .locked(locked));

    // Reset ends on a 54 MHz edge where the 27 MHz pixel clock is low (its level is
    // taken at the 54 MHz falling edge, when it is steady), so video.v's pixel enable
    // and the HDMI core's counters always start in the same relation, whatever the
    // moment the PLL locks or S1 is let go.
    reg [7:0] rst_cnt = 8'd0;
    reg       pix_level = 1'b0, released = 1'b0;
    always @(negedge clk) pix_level <= clk_pixel;
    wire reset = !released;
    always @(posedge clk)
        if (!locked || s1) begin rst_cnt <= 8'd0; released <= 1'b0; end
        else if (!rst_cnt[7]) rst_cnt <= rst_cnt + 8'd1;
        else if (!pix_level) released <= 1'b1;
    // the HDMI side's reset: copied where the pixel clock falls, taken where it rises
    reg reset_hd = 1'b1, reset_pix = 1'b1;
    always @(posedge clk) if (pix_level) reset_hd <= reset;
    always @(posedge clk_pixel) reset_pix <= reset_hd;

    // ---- the soft CPU and its keyboard port
    wire        mb_rd, mb_wr, mb_irq, w_req, w_ack, z80_reset, rom_ready;
    wire [5:2]  mb_addr;
    wire [31:0] mb_wdata, mb_rdata;
    wire [22:0] w_addr;
    wire [7:0]  w_data;
    wire [39:0] kbd_rows;
    wire [8:0]  kbd_in;
    wire        kbd_take, kbd_send, kbd_busy;
    wire [7:0]  kbd_out;
    wire        ps2_clk_low, ps2_data_low;

    assign flash_spi_wp_n = 1'b1;
    assign flash_spi_hold_n = 1'b1;

    sdcpu #(.FIRMWARE(FIRMWARE), .STANDALONE(1)) softcpu (.clk(clk), .reset(reset),
        .mb_rd(mb_rd), .mb_wr(mb_wr), .mb_addr(mb_addr), .mb_wdata(mb_wdata), .mb_rdata(mb_rdata),
        .sd_sclk(sd_clk), .sd_mosi(sd_cmd), .sd_miso(sd_dat0), .sd_cs_n(sd_dat3),
        .fl_sclk(flash_spi_clk), .fl_mosi(flash_spi_mosi), .fl_miso(flash_spi_miso),
        .fl_cs_n(flash_spi_cs_n), .kbd_in(kbd_in), .kbd_take(kbd_take), .kbd_send(kbd_send),
        .kbd_out(kbd_out), .kbd_busy(kbd_busy), .kbd_rows(kbd_rows), .z80_reset(z80_reset),
        .rom_ready(rom_ready), .w_req(w_req), .w_addr(w_addr), .w_data(w_data), .w_ack(w_ack));

    ps2 #(.CLK_MHZ(54)) kbd (.clk(clk), .reset(reset), .ps2_clk(ps2_clk), .ps2_data(ps2_data),
        .clk_low(ps2_clk_low), .data_low(ps2_data_low), .rx(kbd_in), .take(kbd_take),
        .tx_start(kbd_send), .tx(kbd_out), .tx_busy(kbd_busy), .frames_bad());
    assign ps2_clk  = ps2_clk_low  ? 1'b0 : 1'bz;
    assign ps2_data = ps2_data_low ? 1'b0 : 1'bz;

    // ---- the Ace
    wire        spk, mic, ce_pix, hs, vs, de, underrun, env, m1_n, ce_ay;
    wire [7:0]  r, g, b;
    wire [127:0] ay_regs;
    wire [15:0] a;
    wire        sdram_ready, sd_clk_int;
    ace_core ace (.clk(clk), .reset(reset), .cpu_reset(z80_reset), .kbd_rows(kbd_rows), .ear(1'b1),
        .spk(spk), .mic(mic), .mb_rd(mb_rd), .mb_wr(mb_wr), .mb_addr(mb_addr), .mb_wdata(mb_wdata),
        .mb_rdata(mb_rdata), .mb_irq(mb_irq), .w_req(w_req), .w_addr(w_addr), .w_data(w_data),
        .w_ack(w_ack), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hsync_n(hs), .vsync_n(vs), .de(de),
        .underrun(underrun), .ay_regs(ay_regs), .ay_env_restart(env), .sd_clk(sd_clk_int),
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba), .sd_a(O_sdram_addr),
        .sd_dqm(O_sdram_dqm), .sd_dq(IO_sdram_dq), .sdram_ready(sdram_ready), .dbg_addr(a),
        .dbg_m1_n(m1_n));
    assign ce_ay = ace.ce_p;            // the Ace's T-states: 3.25 MHz

    // the SDRAM clock: 54 MHz inverted, forwarded by a DDR output
    ddr_clock_out sdclk (.clk(clk), .q(O_sdram_clk));

    // ---- sound
    wire [15:0] sample;
    wire        sample_ce, clk_audio;
    audio snd (.clk(clk), .reset(reset), .ce_ay(ce_ay), .ay_regs(ay_regs), .env_restart(env),
        .beeper(spk), .sample(sample), .sample_ce(sample_ce), .clk_audio(clk_audio));
    reg [15:0] sample_a;                // held for the HDMI core's audio clock
    always @(posedge clk) if (sample_ce) sample_a <= sample;

    // ---- HDMI: video.v's pixel is copied on the 54 MHz edge where the pixel clock
    // falls, so it is steady for a whole 54 MHz cycle when the pixel clock rises and
    // the HDMI side takes it: no two registers on different clocks meet at one edge
    reg [23:0] rgb54, rgb;
    always @(posedge clk) if (pix_level) rgb54 <= {r, g, b};
    always @(posedge clk_pixel) rgb <= rgb54;
    wire [2:0] tmds;
    wire       tmds_clock;
    hdmi #(.VIDEO_ID_CODE(17), .VIDEO_REFRESH_RATE(50.0), .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16),
           .VENDOR_NAME({"TurboACE"}), .PRODUCT_DESCRIPTION({"Jupiter Ace", 40'd0}),
           .START_X(0), .START_Y(0)) hdmi (     // see the HDMI note at the top
        .clk_pixel_x5(clk_pixel_x5), .clk_pixel(clk_pixel), .clk_audio(clk_audio),
        .reset(reset_pix), .rgb(rgb), .audio_sample_word('{sample_a, sample_a}),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(), .cy(), .frame_width(), .frame_height(),
        .screen_width(), .screen_height());
    tmds_out tmdsbuf (.tmds(tmds), .tmds_clock(tmds_clock), .clk_p(tmds_clk_p), .clk_n(tmds_clk_n),
        .d_p(tmds_d_p), .d_n(tmds_d_n));

    // ---- LEDs (low = on)
    reg sd_seen;
    always @(posedge clk) if (reset) sd_seen <= 1'b0; else if (!sd_dat3) sd_seen <= 1'b1;
    assign led = ~{underrun, sd_seen, rom_ready, !z80_reset};
endmodule
