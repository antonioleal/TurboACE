// =============================================================================
// Test of rtl/cpubus.v with the real ports, arbiter, SDRAM controller and chip
// model, the frame timing and the video generator (fetching meanwhile). The Z80 is
// a bus model with the datasheet's cycle timing, one T-state per ce_cpu:
//   M1:    MREQ, RD from T1's middle; data taken at T3's start; refresh T3-T4
//   read:  MREQ, RD from T1's middle; data taken at T3's middle
//   write: MREQ from T1's middle, WR from T2's middle to T3's middle
//   I/O:   IORQ and RD/WR from T2's start, one automatic wait state, end at T3's middle
//   WAIT is sampled at T2's middle (and each wait state's middle).
// =============================================================================
`timescale 1ns / 1ps
module cpubus_tb;
    localparam real PERIOD = 1000.0 / 54;
    reg clk = 0, reset = 1;
    always #(PERIOD / 2) clk = ~clk;

    integer checks = 0, failures = 0;
    reg [8*120-1:0] msg;
    task check(input ok, input [8*120-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                failures = failures + 1;
                if (failures <= 25) $display("  FAIL %0s", what);
            end
        end
    endtask

    // ---- the system
    wire       ce_cpu, int_n, picture_time;
    wire [7:0] tstate;
    wire [8:0] line;
    acetiming tim (.clk(clk), .reset(reset), .ce_cpu(ce_cpu), .tstate(tstate), .line(line),
        .int_n(int_n), .picture_time(picture_time));

    reg         mreq_n = 1, iorq_n = 1, rd_n = 1, wr_n = 1, m1_n = 1, rfsh_n = 1;
    reg  [15:0] a = 0;
    reg  [7:0]  dout = 0;
    wire [7:0]  din;
    wire        wait_n, io_wr, io_rd, late;
    wire [7:0]  io_dout;
    wire        io_en;

    wire [4:0]  bg_cpu, bg_view, chr_cpu, chr_view;
    wire        mode, xcfg_attr, xcfg_mirror, xcfg_opaque, xcfg_keep;
    wire [2:0]  rompage;
    wire [5:0]  win0, win1;
    wire [7:0]  ay_sel;
    wire [127:0] ay_regs;
    wire [3:0]  ink, paper, border;
    ports prt (.clk(clk), .reset(reset), .io_wr(io_wr), .io_rd(io_rd), .addr(a), .din(dout),
        .dout(io_dout), .dout_en(io_en), .bg_cpu(bg_cpu), .bg_view(bg_view), .chr_cpu(chr_cpu),
        .chr_view(chr_view), .mode(mode), .rompage(rompage), .xcfg_attr(xcfg_attr),
        .xcfg_mirror(xcfg_mirror), .xcfg_opaque(xcfg_opaque), .xcfg_keep(xcfg_keep), .win0(win0), .win1(win1),
        .ay_sel(ay_sel), .ay_regs(ay_regs), .ay_env_restart(), .ink(ink), .paper(paper),
        .border(border), .sd_cmd_wr(), .sd_data_wr(), .sd_status_rd(), .sd_data_rd(),
        .sd_dout(8'hFF));

    wire        m_req, m_we, m_ack;
    wire [22:0] m_addr;
    wire [7:0]  m_wdata, m_rdata;
    cpubus bus (.clk(clk), .reset(reset), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n),
        .wr_n(wr_n), .m1_n(m1_n), .rfsh_n(rfsh_n), .addr(a), .cpu_dout(dout), .cpu_din(din),
        .wait_n(wait_n), .late(late), .picture_time(picture_time), .rompage(rompage), .bg_cpu(bg_cpu),
        .chr_cpu(chr_cpu), .xcfg_attr(xcfg_attr), .xcfg_mirror(xcfg_mirror), .xcfg_keep(xcfg_keep), .win0(win0),
        .win1(win1), .colour(ay_regs[8 * 14 +: 8]), .io_wr(io_wr), .io_rd(io_rd),
        .io_dout(io_en ? io_dout : 8'hFF), .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
        .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata));

    wire        v_req, v_ack, ce_pix, hs, vs, de, underrun;
    wire [22:0] v_addr;
    wire [7:0]  v_rdata, r, g, b;
    wire [9:0]  hcnt, vcnt;
    video vid (.clk(clk), .reset(reset), .mode(1'b1), .bg_view(5'd2), .chr_view(5'd3),
        .opaque(1'b0), .border(4'd0), .f_req(v_req), .f_addr(v_addr), .f_ack(v_ack),
        .f_rdata(v_rdata), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hsync_n(hs), .vsync_n(vs),
        .de(de), .hcnt(hcnt), .vcnt(vcnt), .underrun(underrun));

    wire        req, we, ack, ready;
    wire [22:0] addr;
    wire [7:0]  wdata, rdata;
    arbiter arb (.clk(clk), .reset(reset), .a_req(m_req), .a_we(m_we), .a_addr(m_addr),
        .a_wdata(m_wdata), .a_ack(m_ack), .a_rdata(m_rdata), .b_req(v_req), .b_addr(v_addr),
        .b_ack(v_ack), .b_rdata(v_rdata), .c_req(1'b0), .c_addr(23'd0), .c_wdata(8'd0), .c_ack(), .req(req), .we(we), .addr(addr), .wdata(wdata),
        .ack(ack), .rdata(rdata));
    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    sdram #(.CLK_MHZ(54)) ctl (.clk(clk), .reset(reset), .req(req), .we(we), .addr(addr),
        .wdata(wdata), .rdata(rdata), .ack(ack), .ready(ready), .sd_clk(sd_clk), .sd_cke(sd_cke),
        .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_addr(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq));
    sdram_model chip (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq));

    // the SDRAM's bytes, straight from the model
    function [7:0] sd_byte(input [22:0] p);
        reg [31:0] w;
        begin w = chip.mem[p >> 2]; sd_byte = w >> (8 * p[1:0]); end
    endfunction
    task sd_put(input [22:0] p, input [7:0] v);
        reg [31:0] w;
        begin
            w = chip.mem[p >> 2];
            w = (w & ~(32'hFF << (8 * p[1:0]))) | ({24'd0, v} << (8 * p[1:0]));
            chip.mem[p >> 2] = w;
        end
    endtask

    // count CPU-side SDRAM requests (each raise)
    integer mreqs = 0;
    reg m_req_q = 0;
    always @(posedge clk) begin m_req_q <= m_req; if (m_req && !m_req_q) mreqs = mreqs + 1; end
    integer io_wr_pulses = 0;
    always @(posedge clk) if (io_wr) io_wr_pulses = io_wr_pulses + 1;

    // ---- the Z80 bus model
    integer tw, max_tw = 0;
    task trise; begin @(posedge clk); while (!ce_cpu) @(posedge clk); #1; end endtask
    task tfall; begin repeat (8) @(posedge clk); #1; end endtask
    task waits;                         // WAIT sampled at T2's middle, then each TW's
        begin
            tw = 0;
            while (!wait_n) begin trise; tfall; tw = tw + 1; end
        end
    endtask

    task fetch(input [15:0] ad, output [7:0] d);
        begin
            trise; a = ad; m1_n = 0; rfsh_n = 1;
            tfall; mreq_n = 0; rd_n = 0;
            trise; tfall; waits;
            trise; d = din; mreq_n = 1; rd_n = 1; m1_n = 1; rfsh_n = 0; a = 16'h3F00;
            tfall; mreq_n = 0;
            trise; tfall; mreq_n = 1;
            rfsh_n = 1;
        end
    endtask
    task mread(input [15:0] ad, output [7:0] d);
        begin
            trise; a = ad;
            tfall; mreq_n = 0; rd_n = 0;
            trise; tfall; waits;
            trise; tfall; d = din; mreq_n = 1; rd_n = 1;
        end
    endtask
    task mwrite(input [15:0] ad, input [7:0] v);
        begin
            trise; a = ad;
            tfall; mreq_n = 0; dout = v;
            trise; tfall; wr_n = 0; waits;
            trise; tfall; wr_n = 1; mreq_n = 1;
        end
    endtask
    task ioout(input [15:0] port, input [7:0] v);
        begin
            trise; a = port; dout = v;
            trise; iorq_n = 0; wr_n = 0;
            tfall; waits;
            trise; tfall;                       // the automatic wait state
            trise; tfall; iorq_n = 1; wr_n = 1;
        end
    endtask
    task ioin(input [15:0] port, output [7:0] d);
        begin
            trise; a = port;
            trise; iorq_n = 0; rd_n = 0;
            tfall; waits;
            trise; tfall;
            trise; tfall; d = din; iorq_n = 1; rd_n = 1;
        end
    endtask
    task inta(output [7:0] d);                  // IM 1 interrupt acknowledge
        begin
            trise; m1_n = 0; a = 16'h1234;
            trise; trise; iorq_n = 0;
            tfall; trise; tfall; d = din; iorq_n = 1; m1_n = 1;
        end
    endtask

    reg [7:0] q, q2;
    integer i, k, k2, seed = 31, n0, w0, end_t, end_line, reads = 0, slow = 0;
    reg [15:0] ad;
    reg [7:0] refm [0:65535];
    reg [65535:0] known;

    initial begin
        known = 0;
        repeat (4) @(posedge clk);
        #1 reset = 0;
        wait (ready);

        // ---- ROM: page ROMPAGE (1 after reset), read-only
        for (i = 0; i < 64; i = i + 1) sd_put(23'h090000 + 1 * 8192 + 16'h0100 + i, 8'hA0 ^ i);
        for (i = 0; i < 64; i = i + 1) sd_put(23'h090000 + 3 * 8192 + 16'h0100 + i, 8'h30 + i);
        fetch(16'h0105, q); check(q === (8'hA0 ^ 5), "M1 fetch from ROM page 1");
        mread(16'h0122, q); check(q === (8'hA0 ^ 8'h22), "memory read from ROM page 1");
        ioout(16'h00E3, 8'hC3);                 // ROMPAGE 3
        mread(16'h0107, q); check(q === 8'h37, "ROMPAGE 3: page 3's byte");
        mwrite(16'h0107, 8'h99);
        trise; trise; trise;
        check(sd_byte(23'h090000 + 3 * 8192 + 16'h0107) === 8'h37, "a write to ROM changes nothing");
        ioout(16'h00E3, 8'hC1);

        // ---- I/O through ports.v
        n0 = io_wr_pulses;
        ioout(16'h00E3, 8'h00 | 5'd9);          // BG_CPU 9
        check(io_wr_pulses == n0 + 1 && bg_cpu == 9, "OUT ($E3): one strobe, BG_CPU = 9");
        ioin(16'h00E3, q); check(q === 8'h09, "IN ($E3) with A15-A13 = 0: BG_CPU");
        ioin(16'hE0E3, q); check(q === 8'hA8, "IN ($E3) with A = $E0: the ID");
        ioout(16'h00FD, 8'd14); ioout(16'h00FF, 8'h5A);   // PAPER 5, INK 10
        n0 = io_wr_pulses;
        inta(q);
        check(q === 8'hFF && io_wr_pulses == n0, "interrupt acknowledge: not I/O, bus $FF");

        // ---- BG write: the byte and PAPER:INK in colour RAM
        mwrite(16'h2010, 8'h41);
        repeat (4) trise;                       // no fetch follows: the colour byte goes after 32 clocks
        check(sd_byte(23'h0A0000 + 9 * 1024 + 16) === 8'h41, "BG write lands in text page BG_CPU");
        check(sd_byte(23'h0A8000 + 9 * 1024 + 16) === 8'h5A, "... and R14 (PAPER:INK) in its colour RAM");
        mread(16'h2010, q); check(q === 8'h41, "BG read back");
        ioout(16'h00E3, 8'hE1);                 // XCFG.ATTR
        mread(16'h2010, q); check(q === 8'h5A, "ATTR: the window reads the colour byte");
        mwrite(16'h2011, 8'h77);
        repeat (4) trise;
        check(sd_byte(23'h0A8000 + 9 * 1024 + 17) === 8'h77, "ATTR: a write goes to colour RAM only");
        ioout(16'h00E3, 8'hE0);

        // ---- CHR: write-only
        ioout(16'h00E3, 8'h40 | 5'd4);          // CHR_CPU 4
        mwrite(16'h2808, 8'h3C);
        trise; trise;
        check(sd_byte(23'h0B0000 + 4 * 1024 + 8) === 8'h3C, "CHR write lands in font CHR_CPU");
        mread(16'h2808, q); check(q === 8'hFF, "CHR reads $FF (write-only)");

        // ---- contention: $2410 in the picture waits until the picture time ends
        while (!(picture_time && line < 9'd180 && tstate < 8'd60)) trise;
        mread(16'h2410, q);
        end_t = tstate; end_line = line;
        check(q === 8'h41, "the video-priority copy reads the same byte");
        $sformat(msg, "contended read finishes after the picture time (line %0d T %0d)", end_line, end_t);
        check(end_t >= 128 || end_line >= 192, msg);
        while (!(picture_time && line < 9'd180 && tstate < 8'd60)) trise;
        mread(16'h2010, q);
        $sformat(msg, "the CPU-priority copy is not held (%0d wait states)", tw);
        check(tw <= 1 && tstate < 8'd70, msg);

        // ---- random reads and writes over RAM, with M1 fetches and posted writes
        ioout(16'h00E1, 8'h00 | 6'd20); ioout(16'h00E1, 8'h80 | 6'd21);
        n0 = mreqs; w0 = 0;
        for (i = 0; i < 4000; i = i + 1) begin
            k = {$random(seed)} % 3;
            if (i % 2) k = 1 + i % 2;   // half the time a read of a known byte
            k2 = {$random(seed)} % 512;                    // a pool of 512 addresses
            case (k2 % 4)
                0: ad = 16'h3000 + k2 * 5;                  // extension RAM
                1: ad = 16'h4000 + k2 * 61;                 // fixed RAM
                default: ad = 16'hC000 + k2 * 31;           // windows
            endcase
            if (k == 0 || !known[ad]) begin
                q2 = $random(seed);
                mwrite(ad, q2); refm[ad] = q2; known[ad] = 1'b1;
                w0 = w0 + 1;
            end else begin
                if (k == 1) mread(ad, q); else fetch(ad, q);
                if (tw > max_tw) max_tw = tw;
                reads = reads + 1; if (tw) slow = slow + 1;
                $sformat(msg, "read %04h = %02h, written %02h", ad, q, refm[ad]);
                check(q === refm[ad], msg);
            end
        end
        $sformat(msg, "one SDRAM request per memory cycle, none for refresh (%0d for 4000)", mreqs - n0);
        check(mreqs - n0 == 4000, msg);
        // a BG write and at once a read of its colour byte (ATTR): served from the buffer
        ioout(16'h00FD, 8'd14); ioout(16'h00FF, 8'hC3);
        ioout(16'h00E3, 8'hE0);
        mwrite(16'h2020, 8'h11);
        ioout(16'h00E3, 8'hE1);                 // ATTR (the colour byte may still be waiting)
        mread(16'h2020, q);
        check(q === 8'hC3, "the colour byte reads right even straight after its BG write");
        ioout(16'h00E3, 8'hE0);
        // the hardest case: a BG write (two SDRAM writes behind it), then at once an opcode fetch
        for (i = 0; i < 200; i = i + 1) begin
            mwrite(16'h2000 + i, i);
            fetch(16'h4000 + 61 * (i % 128), q);
            if (tw) slow = slow + 1;
            reads = reads + 1;
            if (known[16'h4000 + 61 * (i % 128)]) begin
                $sformat(msg, "fetch after a BG write: %04h = %02h, want %02h", 16'h4000 + 61 * (i % 128), q, refm[16'h4000 + 61 * (i % 128)]);
                check(q === refm[16'h4000 + 61 * (i % 128)], msg);
            end
        end
        check(sd_byte(23'h000000 + 20 * 8192 + 5) === refm[16'hC005] || !known[16'hC005],
              "window 0 is page 20 in the SDRAM");
        check(!underrun, "video kept up meanwhile");
        check(late === 1'b0, "no read ever took longer than its bound (L_MAX)");
        $sformat(msg, "no wait states on ordinary reads (%0d of %0d had one)", slow, reads);
        check(slow == 0, msg);
        check(chip.errors == 0, "the SDRAM model saw no errors");

        $display("cpubus: %0d checks, %0s (reads with a wait state: %0d of %0d)", checks,
                 failures ? "FAILED" : "all passed", slow, reads);
        $finish;
    end
endmodule
