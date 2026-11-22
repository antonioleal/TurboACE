// =============================================================================
// Test of rtl/ports.v and rtl/memmap.v against register-map.md sections 1-5.
// =============================================================================
`timescale 1ns / 1ps
module ports_tb;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg         io_wr = 0, io_rd = 0;
    reg  [15:0] addr = 0;
    reg  [7:0]  din = 0;
    wire [7:0]  dout;
    wire        dout_en;
    wire [4:0]  bg_cpu, bg_view, chr_cpu, chr_view;
    wire        mode, xcfg_attr, xcfg_mirror, xcfg_opaque, xcfg_keep;
    wire [2:0]  rompage;
    wire [5:0]  win0, win1;
    wire [7:0]  ay_sel;
    wire [127:0] ay_regs;
    wire        ay_env_restart;
    wire [3:0]  ink, paper, border;
    wire        sd_cmd_wr, sd_data_wr, sd_status_rd, sd_data_rd;
    reg  [7:0]  sd_dout = 8'h5C;

    ports dut (.clk(clk), .reset(reset), .io_wr(io_wr), .io_rd(io_rd), .addr(addr),
        .din(din), .dout(dout), .dout_en(dout_en), .bg_cpu(bg_cpu), .bg_view(bg_view),
        .chr_cpu(chr_cpu), .chr_view(chr_view), .mode(mode), .rompage(rompage),
        .xcfg_attr(xcfg_attr), .xcfg_mirror(xcfg_mirror), .xcfg_opaque(xcfg_opaque), .xcfg_keep(xcfg_keep),
        .win0(win0), .win1(win1), .ay_sel(ay_sel), .ay_regs(ay_regs),
        .ay_env_restart(ay_env_restart), .ink(ink), .paper(paper), .border(border),
        .sd_cmd_wr(sd_cmd_wr), .sd_data_wr(sd_data_wr), .sd_status_rd(sd_status_rd),
        .sd_data_rd(sd_data_rd), .sd_dout(sd_dout));

    reg  [15:0] maddr = 0;
    wire [2:0]  region;
    wire [22:0] sd_addr, col_addr;
    wire        can_read, can_write, col_write, vidpri;
    memmap map (.addr(maddr), .rompage(rompage), .bg_cpu(bg_cpu), .chr_cpu(chr_cpu),
        .xcfg_attr(xcfg_attr), .xcfg_mirror(xcfg_mirror), .xcfg_keep(xcfg_keep), .win0(win0), .win1(win1),
        .region(region), .sd_addr(sd_addr), .can_read(can_read), .can_write(can_write),
        .col_write(col_write), .col_addr(col_addr), .vidpri(vidpri));

    integer checks = 0, failures = 0;
    reg [8*100-1:0] msg;
    task check(input ok, input [8*100-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                failures = failures + 1;
                if (failures <= 30) $display("  FAIL %0s", what);
            end
        end
    endtask

    task out(input [15:0] a, input [7:0] d);    // OUT: one-clock strobe
        begin
            @(negedge clk); addr = a; din = d; io_wr = 1;
            @(negedge clk); io_wr = 0;
        end
    endtask
    // IN: returns the byte, or 16'h1xx if nothing drove the bus
    task in(input [15:0] a, output [8:0] q);
        begin
            @(negedge clk); addr = a; io_rd = 1;
            #1 q = dout_en ? {1'b0, dout} : 9'h100;
            @(negedge clk); io_rd = 0;
        end
    endtask

    reg [8:0] q;
    reg strobe_seen;
    integer c, k;

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;

        // ---- reset values (register-map.md 2.3, 2.5, 4.1)
        for (c = 0; c < 8; c = c + 1) begin
            in({c[2:0], 5'b0, 8'hE3}, q);
            $sformat(msg, "$E3 selector %0d after reset reads %h", c, q);
            check(q === (c == 6 ? 9'h001 : c == 7 ? 9'h0A8 : 9'h000), msg);
        end
        in(16'h00E1, q); check(q === 9'h000, "window 0 = page 0 after reset");
        in(16'h80E1, q); check(q === 9'h001, "window 1 = page 1 after reset");
        check(ink == 4'hF && paper == 4'h0 && border == 4'h0, "white INK on black after reset");

        // ---- $E3 commands, each independent; the parameter is D4-D0, the selector A15-A13
        out(16'h12E3, 8'h00 | 5'd7);  out(16'h34E3, 8'h20 | 5'd19);
        out(16'h56E3, 8'h40 | 5'd31); out(16'h78E3, 8'h60 | 5'd1);
        out(16'h9AE3, 8'h80 | 5'b11111);        // MODE: only bit 0 counts
        out(16'hBCE3, 8'hA0 | 5'b10101);        // reserved: nothing
        out(16'hDEE3, 8'hC0 | 5'b11110);        // ROMPAGE: bits 2-0
        out(16'hF0E3, 8'hE0 | 5'b00111);        // XCFG: ATTR, MIRROR, OPAQUE
        check(bg_cpu == 7 && bg_view == 19 && chr_cpu == 31 && chr_view == 1,
              "BG_CPU, BG_VIEW, CHR_CPU, CHR_VIEW written (A15-A8 on writes ignored)");
        check(mode == 1 && rompage == 3'd6 && xcfg_attr && xcfg_mirror && xcfg_opaque,
              "MODE, ROMPAGE, XCFG written");
        in(16'h00E3, q); check(q === 9'h007, "BG_CPU reads 000ppppp");
        in(16'h20E3, q); check(q === 9'h013, "BG_VIEW reads back");
        in(16'h40E3, q); check(q === 9'h01F, "CHR_CPU reads back");
        in(16'h60E3, q); check(q === 9'h001, "CHR_VIEW reads back");
        in(16'h80E3, q); check(q === 9'h001, "MODE reads 0000000m");
        in(16'hA0E3, q); check(q === 9'h000, "reserved command reads 0");
        in(16'hC0E3, q); check(q === 9'h006, "ROMPAGE reads 00000ppp");
        in(16'hE0E3, q); check(q === 9'h0A9, "XCFG reads the ID with ATTR (MIRROR, OPAQUE write-only)");
        in(16'hFFE3, q); check(q === 9'h0A9, "the selector is A15-A13 only");
        out(16'h00E3, 8'h80);                   // MODE 0
        check(mode == 0 && bg_cpu == 7 && rompage == 6 && xcfg_opaque,
              "writing MODE changes only the mode");
        out(16'h00E3, 8'hE0);                   // XCFG 0
        in(16'hE0E3, q); check(q === 9'h0A8 && !xcfg_mirror && !xcfg_opaque, "XCFG cleared, ID stays");
        // detecting TurboACE: LD A,$E0 / IN A,($E3) / AND $FE / CP $A8
        in(16'hE0E3, q); check((q[7:0] & 8'hFE) == 8'hA8 && !q[8], "the detection sequence finds $A8");

        // ---- $E1 windows
        out(16'h00E1, 8'h25);                   // window 0 = 37
        out(16'h00E1, 8'hBE);                   // window 1 = 62 (D6 reserved, ignored)
        check(win0 == 37 && win1 == 62, "$E1 sets each window, D7 chooses, D5-D0 the page");
        in(16'h00E1, q); check(q === 9'h025, "$E1 read, A15 = 0: window 0");
        in(16'h80E1, q); check(q === 9'h03E, "$E1 read, A15 = 1: window 1");

        // ---- AY: select at $FD, value at $FF; the odd $F1-$FF all decode
        for (k = 0; k < 16; k = k + 1) begin
            out({8'h00, 8'hFD}, k);
            out({8'h00, 8'hFF}, 8'hF0 | k);
        end
        for (k = 0; k < 16; k = k + 1) begin
            out(16'h00FD, k);
            in(16'h00FF, q);
            $sformat(msg, "AY R%0d reads %h (unused bits 0)", k, q);
            check(q === {1'b0, (k == 1 || k == 3 || k == 5 || k == 13) ? 8'h00 | k :
                         (k == 6 || k == 8 || k == 9 || k == 10) ? 8'h10 | k : 8'hF0 | k}, msg);
        end
        check(ay_regs[8 * 7 +: 8] == 8'hF7 && ay_regs[8 * 13 +: 8] == 8'hFD, "AY registers out to the sound core");
        out(16'h00FD, 7); out(16'h00FF, 8'h00);  // R7: ports as inputs
        out(16'h00FD, 14); out(16'h00FF, 8'h3C);
        out(16'h00FD, 15); out(16'h00FF, 8'hA5);
        check(paper == 4'h3 && ink == 4'hC && border == 4'hA, "R14/R15 colours whatever R7 says");
        out(16'h00FD, 14); in(16'h00FF, q); check(q === 9'h03C, "R14 reads back whatever R7 says");
        in(16'h00FD, q); check(q === 9'h100, "a read of $FD leaves the bus alone");
        out(16'h00F1, 2); out(16'h00F3, 8'h77);  // $F1 select, $F3 write (A1 = 1)
        out(16'h00FD, 2); in(16'h00FF, q); check(q === 9'h077, "AY decoded on A7-A4 and A0: $F1/$F3 work");
        out(16'h00FD, 8'h20); in(16'h00FF, q); check(q === 9'h0FF, "AY register 32: not a register, reads $FF");
        out(16'h00FF, 8'h99);
        out(16'h00FD, 0); in(16'h00FF, q); check(q === 9'h0F0, "a write with no register selected changes nothing");
        // envelope restart pulse after R13
        out(16'h00FD, 13);
        @(negedge clk); addr = 16'h00FF; din = 8'h0E; io_wr = 1;
        @(negedge clk); io_wr = 0;
        check(ay_env_restart === 1'b1, "writing R13 restarts the envelope (one clock later)");
        @(negedge clk); check(ay_env_restart === 1'b0, "the restart pulse is one clock");

        // ---- not decoded, SD strobes
        in(16'h00E9, q); check(q === 9'h100, "$E9 is not decoded");
        in(16'h00E2, q); check(q === 9'h100, "$E2 (even port) is not TurboACE's");
        in(16'h01E3, q); check(q === 9'h000 | {1'b0, 3'b000, bg_cpu}, "$E3 with A8 set still $E3");
        @(negedge clk); addr = 16'h00E5; din = 8'h10; io_wr = 1;
        #1 strobe_seen = sd_cmd_wr && !sd_data_wr && !sd_status_rd;
        @(negedge clk); io_wr = 0;
        check(strobe_seen, "OUT ($E5): the SD command strobe");
        @(negedge clk); addr = 16'h00E7; io_wr = 1;
        #1 strobe_seen = sd_data_wr && !sd_cmd_wr;
        @(negedge clk); io_wr = 0;
        check(strobe_seen, "OUT ($E7): the SD data strobe");
        in(16'h00E7, q); check(q === 9'h05C, "IN ($E7): the mailbox's byte");
        in(16'h00E5, q); check(q === 9'h05C, "IN ($E5): the mailbox's byte");

        // ---- the memory map (section 3)
        out(16'h00E3, 8'hC0 | 3);               // ROMPAGE 3
        out(16'h00E3, 8'h00 | 9);               // BG_CPU 9
        out(16'h00E3, 8'h40 | 17);              // CHR_CPU 17
        out(16'h00E1, 8'h00 | 40);              // window 0 = 40
        out(16'h00E1, 8'h80 | 41);              // window 1 = 41
        #1;
        maddr = 16'h1234; #1;
        check(region == 0 && sd_addr == 23'h090000 + 3 * 8192 + 16'h1234 && can_read && !can_write,
              "ROM: page ROMPAGE, read-only");
        maddr = 16'h2010; #1;
        check(region == 1 && sd_addr == 23'h0A0000 + 9 * 1024 + 16 && col_write
              && col_addr == 23'h0A8000 + 9 * 1024 + 16 && !vidpri, "BG $2010: page BG_CPU, colour too");
        maddr = 16'h2410; #1;
        check(sd_addr == 23'h0A0000 + 9 * 1024 + 16 && vidpri, "BG $2410: the same byte, video-priority");
        maddr = 16'h2C05; #1;
        check(region == 2 && sd_addr == 23'h0B0000 + 17 * 1024 + 5 && !can_read && can_write && vidpri,
              "CHR $2C05: page CHR_CPU, write-only, video-priority");
        maddr = 16'h3000; #1;
        check(region == 3 && sd_addr == 23'h088000, "$3000: extension RAM");
        maddr = 16'h3BFF; #1;
        check(region == 3 && sd_addr == 23'h088BFF, "$3BFF: last byte of the extension RAM");
        maddr = 16'h3C47; #1;
        check(region == 4 && sd_addr == 23'h089047, "$3C47: work RAM");
        maddr = 16'h4000; #1;
        check(region == 5 && sd_addr == 23'h080000, "$4000: fixed RAM");
        maddr = 16'hBFFF; #1;
        check(region == 5 && sd_addr == 23'h087FFF, "$BFFF: last byte of fixed RAM");
        maddr = 16'hC001; #1;
        check(region == 6 && sd_addr == 40 * 8192 + 1, "$C001: window 0, page 40");
        maddr = 16'hFFFF; #1;
        check(region == 6 && sd_addr == 41 * 8192 + 8191, "$FFFF: window 1, page 41");
        out(16'h00E3, 8'hE0 | 3);               // XCFG: ATTR + MIRROR
        maddr = 16'h2010; #1;
        check(sd_addr == 23'h0A8000 + 9 * 1024 + 16 && !col_write, "ATTR: the BG window addresses colour RAM");
        maddr = 16'h3447; #1;
        check(region == 4 && sd_addr == 23'h089047, "MIRROR: $3447 is the work RAM's $3C47");
        maddr = 16'h3B79; #1;
        check(region == 4 && sd_addr == 23'h089379, "MIRROR: $3B79 is the work RAM's $3F79 (-2 TURBO)");
        out(16'h00E3, 8'hE0 | 4'b1010);         // XCFG: MIRROR + KEEP (-1 TURBO)
        check(xcfg_mirror && xcfg_keep && !xcfg_attr, "XCFG: MIRROR and KEEP written");
        maddr = 16'h3B79; #1;
        check(region == 3 && sd_addr == 23'h088B79, "KEEP: $3B79 stays extension RAM (the SD state)");
        maddr = 16'h3B00; #1;
        maddr = 16'h3B00; #1;
        check(region == 3 && sd_addr == 23'h088B00, "KEEP: $3B00, first byte kept");
        maddr = 16'h3AFF; #1;
        check(region == 4 && sd_addr == 23'h0892FF, "KEEP: $3AFF still mirrors $3EFF");
        maddr = 16'h3000; #1;
        check(region == 4 && sd_addr == 23'h089000, "KEEP: $3000 still mirrors $3C00");
        out(16'h00E3, 8'hE0 | 4'b1000);         // KEEP alone: no mirror
        maddr = 16'h3447; #1;
        check(region == 3 && sd_addr == 23'h088447, "KEEP without MIRROR: $3447 is extension RAM");

        $display("ports: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
