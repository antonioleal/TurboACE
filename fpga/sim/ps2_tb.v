// =============================================================================
// Test of rtl/ps2.v with a model keyboard on open-drain lines (pull-ups), its clock
// at about 12.5 kHz: bytes from the keyboard arrive in order through the FIFO; a
// frame with a bad parity is dropped and the next one still arrives; bytes the host
// sends (the LED command $ED and its argument) reach the keyboard with the right
// parity, after the clock was held low at least 100 us, and the keyboard's
// acknowledge ends the sending.
// =============================================================================
`timescale 1ns / 1ps
module ps2_tb;
    localparam real PERIOD = 1000.0 / 54;
    reg clk = 0, reset = 1;
    always #(PERIOD / 2) clk = ~clk;

    // open-drain lines: pulled up, low if either side pulls
    wire clk_low, data_low;
    reg  kb_clk_low = 0, kb_data_low = 0;
    wire ps2_clk  = !(clk_low || kb_clk_low);
    wire ps2_data = !(data_low || kb_data_low);

    wire [8:0] rx;
    reg        take = 0, tx_start = 0;
    reg  [7:0] tx = 0;
    wire       tx_busy;
    wire [7:0] frames_bad;
    ps2 dut (.clk(clk), .reset(reset), .ps2_clk(ps2_clk), .ps2_data(ps2_data), .clk_low(clk_low),
        .data_low(data_low), .rx(rx), .take(take), .tx_start(tx_start), .tx(tx), .tx_busy(tx_busy),
        .frames_bad(frames_bad));

    integer checks = 0, failures = 0;
    reg [8*100-1:0] msg;
    task check(input ok, input [8*100-1:0] what);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin failures = failures + 1; $display("  FAIL %0s", what); end
        end
    endtask

    localparam HALF = 40000;            // 40 us: a 12.5 kHz clock
    // the keyboard sends a byte (bad = 1: wrong parity)
    task kb_send(input [7:0] b, input bad);
        reg [10:0] f;
        integer k;
        begin
            f = {1'b1, ~^b ^ bad, b, 1'b0};
            for (k = 0; k < 11; k = k + 1) begin
                kb_data_low = !f[k];
                #(HALF / 2); kb_clk_low = 1;      // falling edge: the host takes the bit
                #HALF;       kb_clk_low = 0;
                #(HALF / 2);
            end
            kb_data_low = 0;
            #(2 * HALF);
        end
    endtask
    // the keyboard receives a byte the host sends: returns it, its parity bit, and
    // how long the host held the clock low first
    task kb_receive(output [7:0] b, output par, output real held);
        real t0;
        integer k;
        reg [9:0] bits;
        begin
            wait (!ps2_clk); t0 = $realtime;
            wait (ps2_clk); held = $realtime - t0;
            check(!ps2_data, "the host's start bit (data low) when it lets the clock go");
            #(HALF);
            for (k = 0; k < 10; k = k + 1) begin  // data, parity, stop
                kb_clk_low = 1; #HALF;             // the host changes data after this edge
                kb_clk_low = 0; #(HALF / 2);
                bits[k] = ps2_data;                // taken on the rising edge
                #(HALF / 2);
            end
            check(bits[9] === 1'b1, "the host's stop bit");
            kb_data_low = 1;                       // acknowledge
            kb_clk_low = 1; #HALF; kb_clk_low = 0; #HALF;
            kb_data_low = 0;
            b = bits[7:0]; par = bits[8];
        end
    endtask

    task host_take(output [8:0] v);
        begin @(negedge clk); v = rx; take = !rx[8]; @(negedge clk); take = 0; end
    endtask

    reg [8:0] v;
    reg [7:0] b;
    reg       par;
    real      held;
    integer   i;

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        #100000;
        // keyboard to host: a make code, an extended break, a bad frame, then more
        kb_send(8'h1C, 0); kb_send(8'hE0, 0); kb_send(8'hF0, 0); kb_send(8'h75, 0);
        kb_send(8'h5A, 1);                          // bad parity: dropped
        kb_send(8'h29, 0);
        host_take(v); check(v === 9'h01C, "first byte $1C");
        host_take(v); check(v === 9'h0E0, "then $E0");
        host_take(v); check(v === 9'h0F0, "then $F0");
        host_take(v); check(v === 9'h075, "then $75");
        host_take(v); $sformat(msg, "the bad frame is dropped, the next arrives ($29, got %h)", v);
        check(v === 9'h029, msg);
        host_take(v); check(v === 9'h100, "then nothing (b8 set)");
        check(frames_bad == 1, "one frame counted bad");

        // host to keyboard: the LED command and its argument
        @(negedge clk); tx = 8'hED; tx_start = 1; @(negedge clk); tx_start = 0;
        check(tx_busy, "sending: busy");
        kb_receive(b, par, held);
        $sformat(msg, "$ED reaches the keyboard (got %h), odd parity, clock held %0.0f us", b, held / 1000);
        check(b == 8'hED && par == ~^b && held >= 100000, msg);
        #(HALF);
        check(!tx_busy, "the acknowledge ends the sending");
        @(negedge clk); tx = 8'h04; tx_start = 1; @(negedge clk); tx_start = 0;
        kb_receive(b, par, held);
        check(b == 8'h04 && par == ~^b, "the argument $04 (Caps Lock light)");
        #(HALF);
        // and the keyboard's answer arrives
        kb_send(8'hFA, 0);
        host_take(v); check(v === 9'h0FA, "the keyboard's acknowledge byte $FA arrives");

        $display("ps2: %0d checks, %0s", checks, failures ? "FAILED" : "all passed");
        $finish;
    end
endmodule
