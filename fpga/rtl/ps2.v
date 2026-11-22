// =============================================================================
// TurboACE standalone build: the PS/2 keyboard port (register-map.md decisions 26,
// 27). Both lines are open-drain: the FPGA only pulls them low (clk_low, data_low)
// and reads them back through the level shifter.
//
//   receive  each frame the keyboard clocks in (10-17 kHz): start bit 0, 8 data
//            bits low first, odd parity, stop bit 1, taken on falling clock edges.
//            A good byte goes into a 16-byte FIFO (rx: b8 set when empty; take
//            pops it). A bad start, parity or stop bit drops the frame; more than
//            about 2 ms between bits starts a new frame.
//   send     (the LEDs) tx_start with tx: hold the clock low for 100 us, pull data
//            low (the start bit) and let the clock go; the keyboard then clocks the
//            8 data bits, the odd parity and the stop bit out of us, one per falling
//            edge, and pulls data low once more to acknowledge. tx_busy until then.
//            Frames from the keyboard are not taken while sending.
// =============================================================================
`timescale 1ns / 1ps
module ps2 #(
    parameter CLK_MHZ = 54
) (
    input            clk,
    input            reset,
    input            ps2_clk,           // the lines, read back
    input            ps2_data,
    output reg       clk_low,           // pull the clock line low
    output reg       data_low,          // pull the data line low
    output     [8:0] rx,                // the oldest byte; b8 set when none
    input            take,
    input            tx_start,
    input      [7:0] tx,
    output           tx_busy,
    output reg [7:0] frames_bad         // frames dropped (for the tests)
);
    // ---- the lines, synchronised; falling clock edges
    reg [2:0] cs, ds;
    always @(posedge clk) begin cs <= {cs[1:0], ps2_clk}; ds <= {ds[1:0], ps2_data}; end
    wire fall = cs[2] && !cs[1];
    wire dat  = ds[1];

    // ---- received bytes
    wire [7:0] head;
    wire       empty;
    reg        push;
    reg  [7:0] byte_in;
    fifo #(.AW(4)) q (.clk(clk), .clear(reset), .push(push), .din(byte_in), .pop(take),
        .head(head), .count(), .empty(empty), .full());
    assign rx = empty ? 9'h100 : {1'b0, head};

    localparam TIMEOUT = 2000 * CLK_MHZ;   // 2 ms
    localparam HOLD    = 100 * CLK_MHZ;    // 100 us

    reg [3:0]  bitn;
    reg [10:0] frame;
    reg [17:0] idle;

    // ---- sending
    localparam T_IDLE = 0, T_HOLD = 1, T_START = 2, T_BITS = 3, T_ACK = 4;
    reg [2:0]  tstate;
    reg [13:0] hold;
    reg [9:0]  tsh;                     // data bits, parity, stop: out one per falling edge
    reg [3:0]  tbits;
    assign tx_busy = tstate != T_IDLE;

    always @(posedge clk) begin
        push <= 1'b0;
        if (reset) begin
            bitn <= 0; idle <= 0; frames_bad <= 0;
            tstate <= T_IDLE; clk_low <= 1'b0; data_low <= 1'b0;
        end else begin
            // receiving
            if (tstate == T_IDLE) begin
                if (fall) begin
                    idle <= 0;
                    frame <= {dat, frame[10:1]};
                    if (bitn == 4'd10) begin
                        bitn <= 0;
                        // frame[0] is the start bit once the 11th bit is shifted in
                        if (!frame[1] && dat && ^frame[10:2] == 1'b1) begin
                            byte_in <= frame[9:2]; push <= 1'b1;
                        end else frames_bad <= frames_bad + 8'd1;
                    end else bitn <= bitn + 4'd1;
                end else if (bitn != 0) begin
                    if (idle == TIMEOUT) begin bitn <= 0; idle <= 0; end
                    else idle <= idle + 18'd1;
                end
            end
            // sending
            case (tstate)
                T_IDLE: if (tx_start) begin
                    tsh <= {1'b1, ~^tx, tx};    // stop, odd parity, data (low first)
                    tbits <= 4'd10;
                    clk_low <= 1'b1; hold <= HOLD; tstate <= T_HOLD;
                    bitn <= 0;
                end
                T_HOLD: if (hold != 0) hold <= hold - 14'd1;
                    else begin data_low <= 1'b1; tstate <= T_START; hold <= 20 * CLK_MHZ; end
                T_START: if (hold != 0) hold <= hold - 14'd1;   // data low a moment, then the clock goes
                    else begin clk_low <= 1'b0; tstate <= T_BITS; end
                T_BITS: if (fall) begin             // the keyboard takes each bit on its rising edge
                    data_low <= !tsh[0];
                    tsh <= {1'b1, tsh[9:1]};
                    tbits <= tbits - 4'd1;
                    if (tbits == 4'd1) tstate <= T_ACK;
                end
                T_ACK: begin
                    data_low <= 1'b0;               // the stop bit: let data go
                    if (fall) tstate <= T_IDLE;     // the keyboard's acknowledge clock
                end
            endcase
        end
    end
endmodule
