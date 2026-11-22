// =============================================================================
// Test of rtl/acetiming.v and rtl/arbiter.v (with rtl/sdram.v and the chip model):
//   timing: exactly 65,000 T-states in 20 ms of 54 MHz, each 16 or 17 clocks
//           apart; 208 T a line, 312 lines a frame; INT for 8 lines from T 154 of
//           line 248; the picture time 192 x 128 T a frame.
//   arbiter: a CPU-like port (a random read or write about every microsecond) and
//           a video-like port (reads back to back) share the SDRAM; every read is
//           compared with a reference copy, the CPU never waits long, and video
//           keeps enough throughput for its 160 fetches a line.
// =============================================================================
`timescale 1ns / 1ps
module arbiter_tb;
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
                if (failures <= 20) $display("  FAIL %0s", what);
            end
        end
    endtask

    // ---------------- timing ----------------
    wire       ce_cpu, int_n, picture_time;
    wire [7:0] tstate;
    wire [8:0] line;
    acetiming tim (.clk(clk), .reset(reset), .ce_cpu(ce_cpu), .tstate(tstate), .line(line),
        .int_n(int_n), .picture_time(picture_time));

    // ---------------- SDRAM, arbiter ----------------
    reg         a_req = 0, a_we = 0, b_req = 0;
    reg  [22:0] a_addr = 0, b_addr = 0;
    reg  [7:0]  a_wdata = 0;
    wire        a_ack, b_ack;
    wire [7:0]  a_rdata, b_rdata;
    wire        req, we, ack, ready;
    wire [22:0] addr;
    wire [7:0]  wdata, rdata;
    arbiter arb (.clk(clk), .reset(reset), .a_req(a_req), .a_we(a_we), .a_addr(a_addr),
        .a_wdata(a_wdata), .a_ack(a_ack), .a_rdata(a_rdata), .b_req(b_req), .b_addr(b_addr),
        .b_ack(b_ack), .b_rdata(b_rdata), .c_req(1'b0), .c_addr(23'd0), .c_wdata(8'd0), .c_ack(), .req(req), .we(we), .addr(addr), .wdata(wdata),
        .ack(ack), .rdata(rdata));
    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba;
    wire [10:0] sd_addr;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;
    sdram #(.CLK_MHZ(54)) ctl (.clk(clk), .reset(reset), .req(req), .we(we), .addr(addr),
        .wdata(wdata), .rdata(rdata), .ack(ack), .ready(ready), .sd_clk(sd_clk), .sd_cke(sd_cke),
        .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_ba(sd_ba), .sd_addr(sd_addr), .sd_dqm(sd_dqm), .sd_dq(sd_dq));
    sdram_model chip (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_addr), .dqm(sd_dqm), .dq(sd_dq));

    // both ports work in one 4K area, so video reads what the CPU writes
    localparam AREA = 4096;
    reg [7:0] ref_mem [0:AREA-1];
    reg [AREA-1:0] known;
    integer i;
    initial for (i = 0; i < AREA; i = i + 1) known[i] = 1'b0;

    integer seed = 5150, a_wait, a_max_wait = 0, a_ops = 0, a_bad = 0, b_ops = 0, b_bad = 0,
            b_checked = 0;
    reg     running = 0;
    reg [11:0] off;

    // the CPU side: one access, then 0.6-1.5 us before the next
    initial begin : cpu
        wait (running);
        wait (ready);
        while (1) begin
            repeat (32 + {$random(seed)} % 50) @(posedge clk);
            if (!running) disable cpu;
            off = {$random(seed)} % AREA;
            #1 a_addr = 23'h040000 + off; a_we = known[off] ? {$random(seed)} % 2 : 1;
            a_wdata = $random(seed); a_req = 1;
            a_wait = 0;
            @(negedge clk);
            while (!a_ack) begin @(negedge clk); a_wait = a_wait + 1; end
            if (a_wait > a_max_wait) a_max_wait = a_wait;
            if (a_we) begin ref_mem[off] = a_wdata; known[off] = 1'b1; end
            else if (a_rdata !== ref_mem[off]) a_bad = a_bad + 1;
            a_ops = a_ops + 1;
            #1 a_req = 0;
        end
    end

    // the video side: reads back to back over the same area
    reg [11:0] boff;
    initial begin : vid
        wait (running);
        wait (ready);
        while (1) begin
            if (!running) disable vid;
            boff = {$random(seed)} % AREA;
            @(posedge clk); #1 b_addr = 23'h040000 + boff; b_req = 1;
            @(negedge clk);
            while (!b_ack) @(negedge clk);
            // a CPU write to this byte may have landed meanwhile: check settled bytes only
            if (known[boff] && !(a_req && a_we && a_addr[11:0] == boff)) begin
                b_checked = b_checked + 1;
                if (b_rdata !== ref_mem[boff]) b_bad = b_bad + 1;
            end
            b_ops = b_ops + 1;
            #1 b_req = 0;
        end
    end

    // ---------------- the run ----------------
    integer n, ces, gap, mingap, maxgap, last_ce, frames, int_len, int_start_line, int_start_t,
            pic, tl, t_per_line_ok, lines_ok;
    real t_run;
    initial begin
        repeat (4) @(posedge clk);
        #1 reset = 0;

        // 20 ms of 54 MHz: T-states and their spacing
        ces = 0; mingap = 1000; maxgap = 0; last_ce = -1;
        for (n = 0; n < 1080000; n = n + 1) begin
            @(posedge clk); #1;
            if (ce_cpu) begin
                if (last_ce >= 0) begin
                    gap = n - last_ce;
                    if (gap < mingap) mingap = gap;
                    if (gap > maxgap) maxgap = gap;
                end
                last_ce = n;
                ces = ces + 1;
            end
        end
        $sformat(msg, "65000 T-states in 20 ms (got %0d), 16-17 clocks apart (%0d-%0d)", ces, mingap, maxgap);
        check(ces == 65000 && mingap == 16 && maxgap == 17, msg);

        // one frame from line 0 T 0: lines of 208 T, 312 lines, INT and picture time
        while (!(ce_cpu && line == 0 && tstate == 0)) @(posedge clk);
        @(posedge clk);
        int_len = 0; int_start_line = -1; pic = 0; n = 0; t_per_line_ok = 1;
        while (n < 312 * 208) begin
            #1;
            if (ce_cpu) begin
                if (!int_n) begin
                    if (int_start_line < 0) begin int_start_line = line; int_start_t = tstate; end
                    int_len = int_len + 1;
                end
                if (picture_time) pic = pic + 1;
                if (tstate > 207 || line > 311) t_per_line_ok = 0;
                n = n + 1;
            end
            @(posedge clk);
        end
        check(line == 0 && t_per_line_ok, "312 lines of 208 T-states a frame");
        $sformat(msg, "INT for 8 lines (%0d T) from line 248 T 154 (from line %0d T %0d)",
                 int_len, int_start_line, int_start_t);
        check(int_len == 8 * 208 && int_start_line == 248 && int_start_t == 154, msg);
        $sformat(msg, "picture time 192 x 128 T a frame (%0d)", pic);
        check(pic == 192 * 128, msg);

        // the arbiter: both sides for 4 ms
        running = 1;
        t_run = $realtime;
        #4000000;
        running = 0;
        #20000;
        $sformat(msg, "CPU: %0d accesses, %0d wrong reads", a_ops, a_bad);
        check(a_ops > 2500 && a_bad == 0, msg);
        $sformat(msg, "video: %0d reads (%0d checked), %0d wrong", b_ops, b_checked, b_bad);
        check(b_checked > 1000 && b_bad == 0, msg);
        $sformat(msg, "CPU waits at most %0d clocks (want <= 40: a refresh and a video access)", a_max_wait);
        check(a_max_wait <= 40, msg);
        $sformat(msg, "video throughput %0d reads per 64 us (want >= 200, a line needs 160)",
                 b_ops * 64000 / ($realtime - t_run));
        check(b_ops * 64000 / ($realtime - t_run) >= 200, msg);
        // both asking in the same clock: the CPU goes first
        a_req = 0; b_req = 0;
        repeat (40) @(posedge clk);
        #1 a_addr = 23'h040010; a_we = 0; b_addr = 23'h040020; a_req = 1; b_req = 1;
        @(negedge clk);
        while (!a_ack && !b_ack) @(negedge clk);
        check(a_ack && !b_ack, "both ask in the same clock: the CPU is served first");
        while (!b_ack) begin if (a_ack) #1 a_req = 0; @(negedge clk); end
        #1 a_req = 0; b_req = 0;

        check(chip.errors == 0, "the SDRAM model saw no timing or command errors");

        $display("timing+arbiter: %0d checks, %0s (CPU max wait %0d clocks, video %0d reads)",
                 checks, failures ? "FAILED" : "all passed", a_max_wait, b_ops);
        $finish;
    end
endmodule
