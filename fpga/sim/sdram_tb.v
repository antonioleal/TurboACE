// =============================================================================
// Test of rtl/sdram.v against the chip model (sdram_model.v), at 54 MHz:
//   - start-up, then random byte writes and reads over the whole 8 MB, compared
//     with a reference copy (each written address remembered);
//   - the four byte lanes of one word written separately do not disturb each other;
//   - a long idle stretch: refreshes keep coming;
//   - the model's timing checks (tRCD, tRP, tRC, tRFC, tWR, refresh interval) pass.
// Prints "sdram: N checks, all passed" or the failures.
// =============================================================================
`timescale 1ns / 1ps
module sdram_tb;
    localparam real PERIOD = 1000.0 / 54;
    reg clk = 0, reset = 1;
    always #(PERIOD / 2) clk = ~clk;

    reg         req = 0, we = 0;
    reg  [22:0] addr = 0;
    reg  [7:0]  wdata = 0;
    wire [7:0]  rdata;
    wire        ack, ready;
    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba;
    wire [10:0] sd_addr;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;

    sdram #(.CLK_MHZ(54)) dut (
        .clk(clk), .reset(reset), .req(req), .we(we), .addr(addr), .wdata(wdata),
        .rdata(rdata), .ack(ack), .ready(ready),
        .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_addr(sd_addr),
        .sd_dqm(sd_dqm), .sd_dq(sd_dq));

    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .a(sd_addr), .dqm(sd_dqm), .dq(sd_dq));

    integer checks = 0, failures = 0;
    task check(input ok, input [8*80-1:0] what);
        begin
            checks = checks + 1;
            if (!ok) begin
                failures = failures + 1;
                if (failures <= 20) $display("  FAIL %0s", what);
            end
        end
    endtask

    // one access: raise req (at a random moment), hold it until ack, drop it
    task access(input w, input [22:0] a, input [7:0] d, output [7:0] q);
        integer n;
        begin
            @(posedge clk); repeat ({$random(seed)} % 3) @(posedge clk);
            #1 req = 1; we = w; addr = a; wdata = d;
            n = 0;
            @(negedge clk);                 // sample between edges: no race with ack
            while (!ack && n < 100) begin @(negedge clk); n = n + 1; end
            check(n < 100, "an access finishes within 100 clocks");
            q = rdata;
            #1 req = 0;
        end
    endtask

    localparam N = 20000;
    reg [22:0] wa [0:N-1];
    reg [7:0]  wd [0:N-1];
    reg [7:0]  q;
    integer i, j, refs0, seed = 12345;
    reg [8*80-1:0] msg;
    real t0;

    initial begin
        repeat (5) @(posedge clk);
        #1 reset = 0;
        // start-up takes 200 us: the controller is not ready before
        @(posedge clk); #1 req = 1; we = 1; addr = 0; wdata = 8'hA5;
        @(negedge clk); while (!ack) @(negedge clk);
        check($realtime > 200000, "a request waits for the 200 us start-up");
        #1 req = 0;
        access(0, 23'h000000, 8'h00, q);
        check(q === 8'hA5, "first write and read back");

        // random bytes over the whole 8 MB (addresses distinct: bit pattern from i)
        for (i = 0; i < N; i = i + 1) begin
            wa[i] = {$random(seed)} % (1 << 23);
            wa[i][7:0] = i[7:0];         // keep them distinct across a 256-wide stripe
            wa[i][22:15] = i[15:8];
            wd[i] = $random(seed);
            access(1, wa[i], wd[i], q);
        end
        for (i = 0; i < N; i = i + 1) begin
            access(0, wa[i], 8'h00, q);
            if (q !== wd[i]) begin        // !==: a z or x read is a failure
                $sformat(msg, "byte at %06h read %02h, written %02h", wa[i], q, wd[i]);
                check(0, msg);
            end else checks = checks + 1;
        end

        // byte lanes of one word
        for (j = 0; j < 4; j = j + 1) access(1, 23'h123400 + j, 8'h10 + j, q);
        access(1, 23'h123402, 8'hEE, q);
        for (j = 0; j < 4; j = j + 1) begin
            access(0, 23'h123400 + j, 8'h00, q);
            check(q === (j == 2 ? 8'hEE : 8'h10 + j), "byte lanes are independent");
        end
        // the corners of the address space (banks, rows, columns)
        access(1, 23'h7FFFFF, 8'h5A, q); access(1, 23'h000003, 8'hC3, q);
        access(0, 23'h7FFFFF, 8'h00, q); check(q === 8'h5A, "last byte of 8 MB");
        access(0, 23'h000003, 8'h00, q); check(q === 8'hC3, "byte 3 of the first word");

        // idle for 1 ms: about 66 refreshes, and the model checks the interval
        refs0 = chip.refreshes; t0 = $realtime;
        #1000000;
        $sformat(msg, "1 ms idle: %0d refreshes (want at least 64)", chip.refreshes - refs0);
        check(chip.refreshes - refs0 >= 64, msg);

        check(chip.errors == 0, "the chip model saw no timing or command errors");
        $display("sdram: %0d checks, %0s (%0d writes, %0d reads, %0d refreshes, %0d model errors)",
                 checks, failures ? "FAILED" : "all passed", chip.writes, chip.reads,
                 chip.refreshes, chip.errors);
        $finish;
    end
endmodule
