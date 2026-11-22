// =============================================================================
// TurboACE: SPI master, mode 0 (clock idle low, data out on the falling edge,
// in on the rising edge), most significant bit first. start with tx sends one
// byte and receives one (rx, when busy falls). One SCLK half-period is `half`
// clocks: at 54 MHz, 68 gives about 400 kHz (an SD card starting up), 2 gives
// 13.5 MHz.
// =============================================================================
`timescale 1ns / 1ps
module spi_master (
    input            clk,
    input            reset,
    input            start,
    input      [7:0] tx,
    input      [7:0] half,              // clocks per half SCLK period (>= 1)
    output reg [7:0] rx,
    output           busy,
    output reg       sclk,
    output           mosi,
    input            miso
);
    reg [7:0] sh;
    reg [3:0] bits;                     // bits still to send
    reg [7:0] cnt;
    reg       running;

    assign busy = running;
    assign mosi = sh[7];

    always @(posedge clk) begin
        if (reset) begin
            running <= 1'b0;
            sclk <= 1'b0;
            sh <= 8'hFF;
            rx <= 8'hFF;
        end else if (start && !running) begin
            sh <= tx;
            bits <= 4'd8;
            cnt <= half - 8'd1;
            running <= 1'b1;
            sclk <= 1'b0;
        end else if (running) begin
            if (cnt != 0) cnt <= cnt - 8'd1;
            else begin
                cnt <= half - 8'd1;
                if (!sclk) begin                // rising edge: take a bit in
                    sclk <= 1'b1;
                    rx <= {rx[6:0], miso};
                end else begin                  // falling edge: the next bit out
                    sclk <= 1'b0;
                    sh <= {sh[6:0], 1'b1};
                    if (bits == 4'd1) running <= 1'b0;
                    bits <= bits - 4'd1;
                end
            end
        end
    end
endmodule
