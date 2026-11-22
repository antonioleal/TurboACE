// =============================================================================
// TurboACE standalone build: the Jupiter Ace inside the FPGA, without the soft
// CPU's peripherals and the HDMI encoder (those wrap it at the top level):
//   T80 (t80_core.vhd) + the bus (cpubus.v) + the ports (ports.v) + the SD mailbox
//   (mailbox.v) + the frame timing (acetiming.v) + video (video.v), sharing the
//   SDRAM (arbiter.v, sdram.v).
// The Ace's own port (any even port, register-map.md section 1): IN gives the keys
// of the rows whose address line A8-A15 is low (bits 4-0, 0 = pressed), EAR in
// bit 5, bits 7-6 high, and turns the speaker off; OUT turns it on and sets MIC
// from bit 3 (as JupiterACE_MiSTer rtl/ace.sv).
// =============================================================================
`timescale 1ns / 1ps
module ace_core (
    input             clk,              // 54 MHz
    input             reset,
    input             cpu_reset,        // hold the Z80 (SYS_CTRL b0, while the ROM loads)
    // keyboard: 8 rows x 5 keys, row r in bits 5r+4..5r (1 = pressed)
    input      [39:0] kbd_rows,
    input             ear,
    output reg        spk,
    output reg        mic,
    // the SD mailbox's soft-CPU side
    input             mb_rd,
    input             mb_wr,
    input       [5:2] mb_addr,
    input      [31:0] mb_wdata,
    output     [31:0] mb_rdata,
    output            mb_irq,
    // the soft CPU's writes into the SDRAM (the ROM, start-up messages)
    input             w_req,
    input      [22:0] w_addr,
    input       [7:0] w_data,
    output            w_ack,
    // picture
    output            ce_pix,
    output      [7:0] r, g, b,
    output            hsync_n, vsync_n, de,
    output            underrun,
    // sound registers (ay.sv)
    output    [127:0] ay_regs,
    output            ay_env_restart,
    // the SDRAM
    output            sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output      [1:0] sd_ba,
    output     [10:0] sd_a,
    output      [3:0] sd_dqm,
    inout      [31:0] sd_dq,
    output            sdram_ready,
    // for the tests
    output     [15:0] dbg_addr,
    output            dbg_m1_n
);
    // ---- timing
    wire       ce_p, ce_n, int_n, picture_time;
    wire [7:0] tstate;
    wire [8:0] line;
    acetiming tim (.clk(clk), .reset(reset), .ce_cpu(ce_p), .ce_cpu_n(ce_n), .tstate(tstate),
        .line(line), .int_n(int_n), .picture_time(picture_time));

    // ---- the Z80
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, wait_n, late;
    wire [15:0] addr;
    wire [7:0]  cpu_din, cpu_dout;
    // The T80's outputs change only on the clock after one of its enables (ce_p, ce_n;
    // 8 or more clocks apart) and take longer than one 54 MHz clock to settle, so the
    // bus takes them two clocks after each enable, into t_held: the paths into t_held
    // (and inside the T80, all enable-gated) are timed as two clocks in
    // turboace_standalone.sdc. Nothing else sees the T80's outputs directly.
    // T80_SLOW (simulation only) checks that: every output that changes reads as
    // garbage (inverted) for its first clock, as it could on the chip; the tests must pass.
    wire        t_m1_n, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_rfsh_n, t_halt_n;
    wire [15:0] t_addr;
    wire [7:0]  t_dout;
    // the T80's reset, from its own register: the soft CPU's SYS_CTRL bit would otherwise
    // reach the T80's synchronous reset logic through a gate and a long route (timing)
    reg t80_reset_n = 1'b0;
    always @(posedge clk) t80_reset_n <= !(reset || cpu_reset);
    t80_core cpu (.clk(clk), .reset_n(t80_reset_n), .cen_p(ce_p), .cen_n(ce_n),
        .wait_n(wait_n), .int_n(int_n), .nmi_n(1'b1), .m1_n(t_m1_n), .mreq_n(t_mreq_n),
        .iorq_n(t_iorq_n), .rd_n(t_rd_n), .wr_n(t_wr_n), .rfsh_n(t_rfsh_n), .halt_n(t_halt_n),
        .addr(t_addr), .din(cpu_din), .dout(t_dout));
    wire [30:0] t_now = {t_m1_n, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_rfsh_n, t_halt_n, t_addr, t_dout};
`ifdef T80_SLOW
    reg  [30:0] t_was = 31'd0;
    always @(posedge clk) t_was <= t_now;
    wire [30:0] t_out = t_now != t_was ? ~t_now : t_now;
`else
    wire [30:0] t_out = t_now;
`endif
    reg  [1:0]  ce_p_d = 2'b00, ce_n_d = 2'b00;
    reg  [30:0] t_held = {7'b1111111, 24'd0};   // strobes inactive
    always @(posedge clk) begin
        ce_p_d <= {ce_p_d[0], ce_p};
        ce_n_d <= {ce_n_d[0], ce_n};
        if (reset || cpu_reset) t_held <= {7'b1111111, 24'd0};
        else if (ce_p_d[1] || ce_n_d[1]) t_held <= t_out;
    end
    assign {m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, addr, cpu_dout} = t_held;
    assign dbg_addr = addr;
    assign dbg_m1_n = m1_n;

    // ---- ports
    wire        io_wr, io_rd;
    wire [7:0]  p_dout, sd_dout;
    wire        p_en;
    wire [4:0]  bg_cpu, bg_view, chr_cpu, chr_view;
    wire        mode, xcfg_attr, xcfg_mirror, xcfg_opaque, xcfg_keep;
    wire [2:0]  rompage;
    wire [5:0]  win0, win1;
    wire [3:0]  ink, paper, border;
    wire        sd_cmd_wr, sd_data_wr, sd_status_rd, sd_data_rd;
    ports prt (.clk(clk), .reset(reset), .io_wr(io_wr), .io_rd(io_rd), .addr(addr),
        .din(cpu_dout), .dout(p_dout), .dout_en(p_en), .bg_cpu(bg_cpu), .bg_view(bg_view),
        .chr_cpu(chr_cpu), .chr_view(chr_view), .mode(mode), .rompage(rompage),
        .xcfg_attr(xcfg_attr), .xcfg_mirror(xcfg_mirror), .xcfg_opaque(xcfg_opaque), .xcfg_keep(xcfg_keep),
        .win0(win0), .win1(win1), .ay_sel(), .ay_regs(ay_regs), .ay_env_restart(ay_env_restart),
        .ink(ink), .paper(paper), .border(border), .sd_cmd_wr(sd_cmd_wr), .sd_data_wr(sd_data_wr),
        .sd_status_rd(sd_status_rd), .sd_data_rd(sd_data_rd), .sd_dout(sd_dout));

    mailbox mb (.clk(clk), .reset(reset), .z_cmd_wr(sd_cmd_wr), .z_data_wr(sd_data_wr),
        .z_status_rd(sd_status_rd), .z_data_rd(sd_data_rd), .z_din(cpu_dout), .z_dout(sd_dout),
        .c_rd(mb_rd), .c_wr(mb_wr), .c_addr(mb_addr), .c_wdata(mb_wdata), .c_rdata(mb_rdata),
        .irq(mb_irq));

    // the Ace's even port: keys, EAR, speaker, MIC
    wire       even = !addr[0];
    reg  [4:0] keys;
    integer    row;
    always @(*) begin
        keys = 5'd0;
        for (row = 0; row < 8; row = row + 1)
            if (!addr[8 + row]) keys = keys | kbd_rows[5 * row +: 5];
    end
    wire [7:0] io_dout = p_en ? p_dout : even ? {2'b11, ear, ~keys} : 8'hFF;
    always @(posedge clk) begin
        if (reset) begin spk <= 1'b0; mic <= 1'b0; end
        else if (io_rd && even) spk <= 1'b0;
        else if (io_wr && even) begin spk <= 1'b1; mic <= cpu_dout[3]; end
    end

    // ---- memory
    wire        m_req, m_we, m_ack, v_req, v_ack;
    wire [22:0] m_addr, v_addr;
    wire [7:0]  m_wdata, m_rdata, v_rdata;
    cpubus bus (.clk(clk), .reset(reset), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n),
        .wr_n(wr_n), .m1_n(m1_n), .rfsh_n(rfsh_n), .addr(addr), .cpu_dout(cpu_dout),
        .cpu_din(cpu_din), .wait_n(wait_n), .late(late), .picture_time(picture_time),
        .rompage(rompage), .bg_cpu(bg_cpu), .chr_cpu(chr_cpu), .xcfg_attr(xcfg_attr),
        .xcfg_mirror(xcfg_mirror), .xcfg_keep(xcfg_keep), .win0(win0), .win1(win1), .colour({paper, ink}),
        .io_wr(io_wr), .io_rd(io_rd), .io_dout(io_dout), .m_req(m_req), .m_we(m_we),
        .m_addr(m_addr), .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata));

    video vid (.clk(clk), .reset(reset), .mode(mode), .bg_view(bg_view), .chr_view(chr_view),
        .opaque(xcfg_opaque), .border(border), .f_req(v_req), .f_addr(v_addr), .f_ack(v_ack),
        .f_rdata(v_rdata), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hsync_n(hsync_n),
        .vsync_n(vsync_n), .de(de), .hcnt(), .vcnt(), .underrun(underrun));

    wire        req, we, ack;
    wire [22:0] sdaddr;
    wire [7:0]  wdata, rdata;
    arbiter arb (.clk(clk), .reset(reset), .a_req(m_req), .a_we(m_we), .a_addr(m_addr),
        .a_wdata(m_wdata), .a_ack(m_ack), .a_rdata(m_rdata), .b_req(v_req), .b_addr(v_addr),
        .b_ack(v_ack), .b_rdata(v_rdata), .c_req(w_req), .c_addr(w_addr), .c_wdata(w_data), .c_ack(w_ack), .req(req), .we(we), .addr(sdaddr), .wdata(wdata),
        .ack(ack), .rdata(rdata));
    sdram #(.CLK_MHZ(54)) ctl (.clk(clk), .reset(reset), .req(req), .we(we), .addr(sdaddr),
        .wdata(wdata), .rdata(rdata), .ack(ack), .ready(sdram_ready), .sd_clk(sd_clk),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_addr(sd_a), .sd_dqm(sd_dqm), .sd_dq(sd_dq));
endmodule
