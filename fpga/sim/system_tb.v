// =============================================================================
// The standalone Ace, simulated whole: rtl/ace_core.v with the real T80 (turned
// into Verilog by GHDL), the SDRAM model, and the TurboACE ROM (64K, as the
// firmware leaves it in the SDRAM) preloaded. From reset to the ROM's QUERY (an
// opcode fetch at $059B, waiting for a line), then text page 0 in the SDRAM is
// compared with the screen the C harness (test/gfxtest.c) shows after the same
// boot. Also: no read was ever late, video kept up, the SDRAM model saw no error.
// =============================================================================
`timescale 1ns / 1ps
module system_tb;
    localparam real PERIOD = 1000.0 / 54;
    reg clk = 0, reset = 1, cpu_reset = 1;
    always #(PERIOD / 2) clk = ~clk;

    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sdram_ready;
    wire [1:0]  sd_ba;
    wire [10:0] sd_a;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    wire        spk, mic, ce_pix, hs, vs, de, underrun, mb_irq, env, m1_n;
    wire [7:0]  r, g, b;
    wire [31:0] mb_rdata;
    wire [127:0] ay_regs;
    wire [15:0] a;

    ace_core ace (.clk(clk), .reset(reset), .cpu_reset(cpu_reset), .kbd_rows(40'd0), .ear(1'b1),
        .spk(spk), .mic(mic), .mb_rd(1'b0), .mb_wr(1'b0), .mb_addr(4'd0), .mb_wdata(32'd0),
        .mb_rdata(mb_rdata), .mb_irq(mb_irq), .w_req(1'b0), .w_addr(23'd0), .w_data(8'd0), .w_ack(), .ce_pix(ce_pix), .r(r), .g(g), .b(b),
        .hsync_n(hs), .vsync_n(vs), .de(de), .underrun(underrun), .ay_regs(ay_regs),
        .ay_env_restart(env), .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n),
        .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a),
        .sd_dqm(sd_dqm), .sd_dq(sd_dq), .sdram_ready(sdram_ready), .dbg_addr(a), .dbg_m1_n(m1_n));
    sdram_model chip (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(sd_dqm), .dq(sd_dq));

    function [7:0] sd_byte(input [22:0] p);
        reg [31:0] w;
        begin w = chip.mem[p >> 2]; sd_byte = w >> (8 * p[1:0]); end
    endfunction
    task sd_put(input [22:0] p, input [7:0] v);
        reg [31:0] w;
        begin
            w = chip.mem[p >> 2];
            if (^w === 1'bx) w = 32'd0;
            w = (w & ~(32'hFF << (8 * p[1:0]))) | ({24'd0, v} << (8 * p[1:0]));
            chip.mem[p >> 2] = w;
        end
    endtask

    integer checks = 0, failures = 0;
    reg [8*120-1:0] msg;
    task check(input ok, input [8*120-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin failures = failures + 1; $display("  FAIL %0s", what); end
        end
    endtask

    always @(posedge clk) if ($test$plusargs("trace") && !cpu_reset && tstates < 40 && (ace.ce_p || ace.ce_n))
        $display("    T%0d %s a=%h m1=%b mreq=%b rd=%b rfsh=%b wait=%b din=%h rd_byte=%h st=%0d m_req=%b ack=%b rdata=%h",
            tstates, ace.ce_p ? "p" : "n", a, m1_n, ace.mreq_n, ace.rd_n, ace.rfsh_n, ace.wait_n, ace.cpu_din,
            ace.bus.rd_byte, ace.bus.state, ace.bus.m_req, ace.bus.m_ack, ace.bus.m_rdata);
    // stop at once if the CPU's address ever becomes unknown
    reg [15:0] last_a;
    always @(posedge clk) if (!cpu_reset) begin
        if (^a === 1'bx) begin
            $display("  FAIL the CPU's address became unknown after %0d T-states (last %04h)", tstates, last_a);
            $finish;
        end
        last_a <= a;
    end

    reg [7:0] rom [0:65535];
    reg [7:0] want [0:767 + 1024];
    integer i, bad, tstates = 0, frames0, frames1, t0;
    always @(posedge clk) if (!cpu_reset && ace.ce_p) tstates = tstates + 1;

    initial begin
        $readmemh("build/turboace_rom.hex", rom);
        $readmemh("build/boot_screen.hex", want);
        // the SDRAM starts as zeros, as the C harness's memory does (a real chip holds
        // anything; an unknown byte would make the simulated CPU unknown for good)
        for (i = 0; i < 23'h0C0000 / 4; i = i + 1) chip.mem[i] = 32'd0;
        for (i = 0; i < 65536; i = i + 1) sd_put(23'h090000 + i, rom[i]);
        repeat (4) @(posedge clk);
        #1 reset = 0;
        // the SDRAM's 200 us start-up; then the Z80 starts (the firmware would load the ROM)
        @(posedge sdram_ready);
        repeat (10) @(posedge clk);
        #1 cpu_reset = 0;
        $display("system: Z80 running");
        // until the ROM waits for a line (QUERY)
        while (!(m1_n === 1'b0 && a === 16'h059B)) begin
            @(posedge clk);
            if (tstates > 3000000) begin
                $display("  FAIL no QUERY after 3,000,000 T-states (PC around %04h)", a);
                $finish;
            end
        end
        repeat (200) @(posedge clk);
        bad = 0;
        for (i = 0; i < 768; i = i + 1)
            if (sd_byte(23'h0A0000 + i) !== want[i]) begin
                bad = bad + 1;
                if (bad <= 5) $display("    screen byte %0d: %02h, the harness has %02h", i, sd_byte(23'h0A0000 + i), want[i]);
            end
        $sformat(msg, "boot screen (text page 0) as in the C harness (%0d bytes differ)", bad);
        check(bad == 0, msg);
        bad = 0;
        for (i = 0; i < 1024; i = i + 1)
            // FRAMES ($3C2B) and the key-repeat count ($3C27) depend on when the first
            // interrupt comes: the C harness keeps INT pending until it is taken, the
            // Ace (and this design) holds it for 8 lines only; checked separately below
            if (i != 16'h2B && i != 16'h27 && sd_byte(23'h089000 + i) !== want[768 + i]) begin
                bad = bad + 1;
                if (bad <= 8) $display("    work RAM $%04h: %02h, the harness has %02h", 16'h3C00 + i, sd_byte(23'h089000 + i), want[768 + i]);
            end
        $sformat(msg, "work RAM $3C00-$3FFF (system variables) as in the C harness (%0d bytes differ)", bad);
        $display("system: booted to QUERY in %0d T-states", tstates);
        check(bad == 0, msg);
        // interrupts: FRAMES counts one per frame from now on
        frames0 = sd_byte(23'h08902B) | sd_byte(23'h08902C) << 8;
        t0 = tstates;
        while (tstates - t0 < 3 * 64896 + 100) @(posedge clk);
        frames1 = sd_byte(23'h08902B) | sd_byte(23'h08902C) << 8;
        $sformat(msg, "the 50 Hz interrupt: FRAMES went up by 3 in 3 frames (%0d -> %0d)", frames0, frames1);
        check(frames1 - frames0 == 3, msg);
        check(ace.bus.late === 1'b0, "no read was late");
        check(underrun === 1'b0, "video kept up");
        check(chip.errors == 0, "the SDRAM model saw no errors");
        $display("system: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
