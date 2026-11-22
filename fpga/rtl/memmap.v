// =============================================================================
// TurboACE: where a CPU memory address goes (register-map.md sections 3, 4.2, 5).
// Combinational. Everything TurboACE stores is in the SDRAM, laid out as:
//
//   $000000  user RAM, 64 pages x 8K (512K)      $C000-$FFFF through windows 0/1
//   $080000  fixed RAM, 32K                      $4000-$BFFF
//   $088000  extension RAM, 3K                   $3000-$3BFF
//   $089000  work RAM, 1K (standalone build)     $3C00-$3FFF
//   $090000  ROM, 8 pages x 8K                   $0000-$1FFF, page ROMPAGE
//   $0A0000  text (BG) RAM, 32 pages x 1K        $2000-$27FF, page BG_CPU
//   $0A8000  colour RAM, 32 pages x 1K           the same, with XCFG.ATTR
//   $0B0000  character (CHR) RAM, 32 pages x 1K  $2800-$2FFF, page CHR_CPU
//
// $2000-$23FF / $2400-$27FF are the same 1K (and $2800/$2C00): the second copy of
// each is the video-priority one (vidpri), which the WAIT contention applies to.
// CHR RAM is write-only for the CPU, ROM read-only. A write to the BG window
// (XCFG.ATTR = 0) also writes the current PAPER:INK into colour RAM (col_addr).
// With XCFG.MIRROR, $3000-$3BFF are mirrors of $3C00-$3FFF (-2 TURBO); with KEEP
// as well, $3B00-$3BFF stay extension RAM, the SD code's state (-1 TURBO).
// =============================================================================
`timescale 1ns / 1ps
module memmap (
    input      [15:0] addr,
    input       [2:0] rompage,
    input       [4:0] bg_cpu,
    input       [4:0] chr_cpu,
    input             xcfg_attr,
    input             xcfg_mirror,
    input             xcfg_keep,
    input       [5:0] win0,
    input       [5:0] win1,
    output reg  [2:0] region,
    output reg [22:0] sd_addr,          // where the byte is
    output reg        can_read,
    output reg        can_write,
    output reg        col_write,        // a write also goes to colour RAM ...
    output     [22:0] col_addr,         // ... here
    output            vidpri            // a video-priority copy ($2400-$27FF, $2C00-$2FFF)
);
    localparam R_ROM = 3'd0, R_BG = 3'd1, R_CHR = 3'd2, R_EXT = 3'd3, R_WORK = 3'd4,
               R_FIXED = 3'd5, R_USER = 3'd6;
    localparam [22:0] B_USER = 23'h000000, B_FIXED = 23'h080000, B_EXT = 23'h088000,
                      B_WORK = 23'h089000, B_ROM = 23'h090000, B_BG = 23'h0A0000,
                      B_COL = 23'h0A8000, B_CHR = 23'h0B0000;

    assign vidpri   = (addr[15:12] == 4'h2) && addr[10];
    assign col_addr = B_COL | {bg_cpu, addr[9:0]};

    always @(*) begin
        can_read = 1'b1;
        can_write = 1'b1;
        col_write = 1'b0;
        casez (addr[15:10])
            6'b000???: begin            // $0000-$1FFF
                region = R_ROM;
                sd_addr = B_ROM | {rompage, addr[12:0]};
                can_write = 1'b0;
            end
            6'b00100?: begin            // $2000-$27FF
                region = R_BG;
                sd_addr = (xcfg_attr ? B_COL : B_BG) | {bg_cpu, addr[9:0]};
                col_write = !xcfg_attr;
            end
            6'b00101?: begin            // $2800-$2FFF
                region = R_CHR;
                sd_addr = B_CHR | {chr_cpu, addr[9:0]};
                can_read = 1'b0;
            end
            6'b001111: begin            // $3C00-$3FFF
                region = R_WORK;
                sd_addr = B_WORK | addr[9:0];
            end
            6'b0011??: begin            // $3000-$3BFF
                if (xcfg_mirror && !(xcfg_keep && addr[11:8] == 4'hB)) begin
                    region = R_WORK;
                    sd_addr = B_WORK | addr[9:0];
                end else begin
                    region = R_EXT;
                    sd_addr = B_EXT | (addr - 16'h3000);
                end
            end
            6'b11????: begin            // $C000-$FFFF
                region = R_USER;
                sd_addr = B_USER | {addr[13] ? win1 : win0, addr[12:0]};
            end
            default: begin              // $4000-$BFFF
                region = R_FIXED;
                sd_addr = B_FIXED | (addr - 16'h4000);
            end
        endcase
    end
endmodule
