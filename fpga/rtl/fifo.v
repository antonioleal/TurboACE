// =============================================================================
// TurboACE: byte FIFO with the first byte always readable (head), for the SD
// mailbox (register-map.md 2.7: 1024 bytes each way). The memory is read
// synchronously, so it fits a block RAM; a byte pushed into an empty FIFO is
// passed straight to head. push and pop may come in the same clock; clear wins
// over both. A push when full, or a pop when empty, is ignored.
// =============================================================================
`timescale 1ns / 1ps
module fifo #(
    parameter AW = 10                   // 2^AW bytes
) (
    input              clk,
    input              clear,
    input              push,
    input        [7:0] din,
    input              pop,
    output reg   [7:0] head,            // the oldest byte (valid when !empty)
    output reg [AW:0]  count,
    output             empty,
    output             full
);
    reg [7:0]    mem [0:(1 << AW) - 1];
    reg [AW-1:0] wr_ptr, rd_ptr;

    assign empty = count == 0;
    assign full  = count == (1 << AW);

    wire          do_push = push && !full;
    wire          do_pop  = pop && !empty;
    wire [AW-1:0] rd_next = do_pop ? rd_ptr + 1'b1 : rd_ptr;

    initial begin wr_ptr = 0; rd_ptr = 0; count = 0; end

    always @(posedge clk) begin
        if (do_push && !clear) mem[wr_ptr] <= din;
        // head follows the read pointer; a byte written there this clock goes straight through
        head <= (do_push && wr_ptr == rd_next) ? din : mem[rd_next];
        if (clear) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        end else begin
            if (do_push) wr_ptr <= wr_ptr + 1'b1;
            rd_ptr <= rd_next;
            count <= count + do_push - do_pop;
        end
    end
endmodule
