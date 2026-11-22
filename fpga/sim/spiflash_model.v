// =============================================================================
// The board's SPI flash for simulation: the read command ($03, a 24-bit address,
// then bytes one after another while CS stays low). It holds IMAGE (bytes, one hex
// per line) from BASE: TurboACE's ROM pages 2-7 at $500000 (rom/build/
// turboace-flash.bin); everything else reads $FF. errors counts other commands.
// =============================================================================
`timescale 1ns / 1ps
module spiflash_model #(
    parameter IMAGE = "flash.hex",
    parameter BASE  = 24'h500000,
    parameter SIZE  = 49200
) (
    input  sclk,
    input  mosi,
    output miso,
    input  cs_n
);
    reg [7:0]  mem [0:SIZE-1];
    initial $readmemh(IMAGE, mem);
    reg [7:0]  in_sh, out_sh = 8'hFF;
    reg [3:0]  bitn = 0;
    integer    nbytes = 0, errors = 0, reads = 0;
    reg [23:0] a;
    reg [7:0]  op;
    assign miso = cs_n ? 1'bz : out_sh[7];

    function [7:0] byte_at(input [23:0] x);
        byte_at = (x >= BASE && x < BASE + SIZE) ? mem[x - BASE] : 8'hFF;
    endfunction

    always @(negedge cs_n) begin bitn = 0; nbytes = 0; out_sh = 8'hFF; end
    always @(posedge sclk) if (!cs_n) begin in_sh = {in_sh[6:0], mosi}; bitn = bitn + 1; end
    always @(negedge sclk) if (!cs_n) begin
        if (bitn == 8) begin
            bitn = 0;
            case (nbytes)
                0: begin op = in_sh; if (op != 8'h03) errors = errors + 1; end
                1: a[23:16] = in_sh;
                2: a[15:8]  = in_sh;
                3: a[7:0]   = in_sh;
                default: ;
            endcase
            nbytes = nbytes + 1;
            if (nbytes >= 4 && op == 8'h03) begin
                out_sh = byte_at(a); a = a + 1; reads = reads + 1;
            end else out_sh = 8'hFF;
        end else
            out_sh = {out_sh[6:0], 1'b1};
    end
endmodule
