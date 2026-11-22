// =============================================================================
// Test of rtl/mailbox.v: random operations from both sides, every value read
// compared with a reference model written from firmware/test/host_fpga.c (the
// mailbox the firmware is tested against). Plus the directed cases of
// register-map.md 2.6/2.7: a full data phase, a command dropping unread results,
// FIFO limits, and an event raised in the same clock as the soft CPU clears it.
// =============================================================================
`timescale 1ns / 1ps
module mailbox_tb;
    reg clk = 0, reset = 1;
    always #10 clk = ~clk;

    reg         z_cmd_wr = 0, z_data_wr = 0, z_status_rd = 0, z_data_rd = 0;
    reg  [7:0]  z_din = 0;
    wire [7:0]  z_dout;
    reg         c_rd = 0, c_wr = 0;
    reg  [5:2]  c_addr = 0;
    reg  [31:0] c_wdata = 0;
    wire [31:0] c_rdata;
    wire        irq;

    mailbox dut (.clk(clk), .reset(reset), .z_cmd_wr(z_cmd_wr), .z_data_wr(z_data_wr),
        .z_status_rd(z_status_rd), .z_data_rd(z_data_rd), .z_din(z_din), .z_dout(z_dout),
        .c_rd(c_rd), .c_wr(c_wr), .c_addr(c_addr), .c_wdata(c_wdata), .c_rdata(c_rdata),
        .irq(irq));

    integer checks = 0, failures = 0;
    reg [8*100-1:0] msg;
    task check(input ok, input [8*100-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                failures = failures + 1;
                if (failures <= 25) $display("  FAIL %0s", what);
            end
        end
    endtask

    // ---- the reference: host_fpga.c ----
    localparam FIFO = 1024;
    reg [7:0] argq [0:FIFO-1];
    reg [7:0] resq [0:FIFO-1];
    integer arg_head = 0, arg_n = 0, res_head = 0, res_n = 0;
    integer r_events = 0, r_cmd = 0, r_xfer = 0, r_status = 0, r_busy = 0;

    task r_count_access;
        if (r_xfer != 0) begin
            r_xfer = r_xfer - 1;
            if (r_xfer == 0) begin r_busy = 1; r_events = r_events | 2; end
        end
    endtask

    // ---- the Z80's side ----
    task z_out(input integer port, input [7:0] v);
        begin
            @(negedge clk); z_din = v;
            if (port == 8'hE5) z_cmd_wr = 1; else z_data_wr = 1;
            @(negedge clk); z_cmd_wr = 0; z_data_wr = 0;
            if (port == 8'hE5) begin
                r_cmd = v; res_n = 0; r_xfer = 0; r_busy = 1; r_events = r_events | 1;
            end else begin
                if (arg_n < FIFO) begin argq[(arg_head + arg_n) % FIFO] = v; arg_n = arg_n + 1; end
                r_count_access;
            end
        end
    endtask

    task z_in(input integer port, output [7:0] q);
        integer want;
        begin
            @(negedge clk);
            if (port == 8'hE5) z_status_rd = 1; else z_data_rd = 1;
            @(negedge clk);                 // a Z80 read lasts a few clocks
            @(negedge clk);
            q = z_dout;
            if (port == 8'hE5) begin
                want = (r_busy ? 8'h80 : 0) | (r_status & 8'h70) | (res_n ? 1 : 0);
                $sformat(msg, "IN ($E5) = %02h, model %02h", q, want);
            end else begin
                want = 8'hFF;
                if (res_n) begin want = resq[res_head]; res_head = (res_head + 1) % FIFO; res_n = res_n - 1; end
                r_count_access;
                $sformat(msg, "IN ($E7) = %02h, model %02h", q, want);
            end
            check(q === want[7:0], msg);
            z_status_rd = 0; z_data_rd = 0;
            @(negedge clk);
        end
    endtask

    // ---- the soft CPU's side ----
    task c_write(input [3:0] a, input [31:0] v);
        begin
            @(negedge clk); c_addr = a; c_wdata = v; c_wr = 1;
            @(negedge clk); c_wr = 0;
            case (a)
                4'h0: begin r_status = v & 8'h70; r_busy = 0; end
                4'h1: r_events = r_events & ~v;
                4'h5: if (res_n < FIFO) begin resq[(res_head + res_n) % FIFO] = v; res_n = res_n + 1; end
                4'h6: res_n = 0;
                4'h7: r_xfer = v & 16'hFFFF;
                4'h8: arg_n = 0;
            endcase
        end
    endtask

    task c_read(input [3:0] a, output [31:0] q);
        integer want;
        begin
            @(negedge clk); c_addr = a; c_rd = 1;
            #1 q = c_rdata;
            @(negedge clk); c_rd = 0;
            case (a)
                4'h1: want = r_events;
                4'h2: want = r_cmd;
                4'h3: if (arg_n) begin want = argq[arg_head]; arg_head = (arg_head + 1) % FIFO; arg_n = arg_n - 1; end
                      else want = 32'h100;
                4'h4: want = arg_n;
                default: want = 0;
            endcase
            $sformat(msg, "soft CPU reads %08h at $%02h, model %08h", q, a * 4, want);
            check(q === want, msg);
        end
    endtask

    reg [7:0]  q8;
    reg [31:0] q32;
    integer i, k, op, seed = 777;

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;

        // ---- directed: one command with arguments, results, and a 3-access data phase
        z_out(8'hE7, 8'h05); z_out(8'hE7, 8'h41);       // arguments
        z_out(8'hE5, 8'h12);                            // READ
        check(irq === 1'b1, "a command raises an interrupt to the soft CPU");
        z_in(8'hE5, q8); check(q8[7] === 1'b1, "BUSY after a command");
        c_read(4'h1, q32); c_write(4'h1, 32'h1);
        check(irq === 1'b0, "the interrupt ends when the event is cleared");
        c_read(4'h2, q32); c_read(4'h4, q32);
        c_read(4'h3, q32); c_read(4'h3, q32); c_read(4'h3, q32);    // two arguments, then empty
        c_write(4'h5, 8'h03); c_write(4'h5, 8'h00);                 // result: count 3
        c_write(4'h5, 8'hAA); c_write(4'h5, 8'hBB); c_write(4'h5, 8'hCC);
        c_write(4'h7, 32'd5);                                       // 2 result bytes + 3 data
        c_write(4'h0, 32'h20);                                      // CARD, BUSY off
        z_in(8'hE5, q8); check(q8 === 8'h21, "status: CARD, DATA, not BUSY");
        z_in(8'hE7, q8); z_in(8'hE7, q8);
        z_in(8'hE7, q8); z_in(8'hE7, q8);
        z_in(8'hE5, q8); check(q8[7] === 1'b0, "not BUSY before the last access of the chunk");
        z_in(8'hE7, q8);
        z_in(8'hE5, q8); check(q8 === 8'hA0, "BUSY at once after the chunk's last access");
        c_read(4'h1, q32); check(q32 === 32'h2, "EV_XFER after the chunk");
        c_write(4'h1, 32'h2);
        c_write(4'h0, 32'h20);

        // ---- directed: a command drops unread results
        c_write(4'h5, 8'h11); c_write(4'h5, 8'h22);
        z_out(8'hE5, 8'h01);
        z_in(8'hE5, q8); check(q8[0] === 1'b0, "a command empties the result FIFO");
        z_in(8'hE7, q8); check(q8 === 8'hFF, "$E7 with nothing waiting reads $FF");
        c_write(4'h1, 32'h3); c_write(4'h0, 32'h0);

        // ---- directed: FIFO limits (1024 bytes each way)
        c_write(4'h8, 1);
        for (i = 0; i < FIFO + 3; i = i + 1) z_out(8'hE7, i);
        c_read(4'h4, q32); check(q32 === 32'd1024, "the ARG FIFO holds 1024 bytes, more are dropped");
        for (i = 0; i < FIFO; i = i + 1) c_read(4'h3, q32);
        c_read(4'h3, q32); check(q32 === 32'h100, "and gives them back in order, then empty");
        for (i = 0; i < FIFO + 3; i = i + 1) c_write(4'h5, i);
        for (i = 0; i < FIFO + 1; i = i + 1) z_in(8'hE7, q8);
        check(q8 === 8'hFF, "the RES FIFO holds 1024 bytes, in order");

        // ---- directed: a byte into an empty FIFO is readable the very next clock
        c_write(4'h8, 1);
        @(negedge clk); z_din = 8'h5E; z_data_wr = 1; c_addr = 4'h3;
        @(negedge clk); z_data_wr = 0;
        check(c_rdata === 32'h05E, "the ARG FIFO's head shows a new byte at once");
        argq[(arg_head + arg_n) % FIFO] = 8'h5E; arg_n = arg_n + 1; r_count_access;
        c_read(4'h3, q32);

        // ---- directed: the soft CPU clears EV_CMD in the same clock as a new command
        c_write(4'h1, 32'h3);
        @(negedge clk);
        c_addr = 4'h1; c_wdata = 32'h1; c_wr = 1; z_din = 8'h06; z_cmd_wr = 1;
        @(negedge clk); c_wr = 0; z_cmd_wr = 0;
        r_cmd = 6; res_n = 0; r_xfer = 0; r_busy = 1; r_events = r_events | 1;
        c_read(4'h1, q32); check(q32[0] === 1'b1, "a new command wins over a clear in the same clock");

        // ---- random: both sides, compared with the model
        for (i = 0; i < 200000; i = i + 1) begin
            op = {$random(seed)} % 100;
            k = $random(seed);
            if      (op < 3)  z_out(8'hE5, k);
            else if (op < 22) z_out(8'hE7, k);
            else if (op < 40) z_in(8'hE7, q8);
            else if (op < 47) z_in(8'hE5, q8);
            else if (op < 50) c_write(4'h0, k & 32'h70);
            else if (op < 55) c_read(4'h1, q32);
            else if (op < 58) c_write(4'h1, k & 3);
            else if (op < 60) c_read(4'h2, q32);
            else if (op < 72) c_read(4'h3, q32);
            else if (op < 75) c_read(4'h4, q32);
            else if (op < 92) c_write(4'h5, k & 8'hFF);
            else if (op < 93) c_write(4'h6, 1);
            else if (op < 97) c_write(4'h7, {$random(seed)} % 12);
            else if (op < 98) c_write(4'h8, 1);
            else              begin c_read(4'h1, q32); end
        end

        $display("mailbox: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
