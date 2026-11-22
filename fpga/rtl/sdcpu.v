// =============================================================================
// TurboACE: the soft CPU and its peripherals (register-map.md section 2.7,
// decisions 30, 31; firmware/src/hal.h is the register list it must match).
//
//   $0000_0000  48K block RAM: the firmware (FIRMWARE, a $readmemh file of words),
//               its data and stack
//   $1000_0000  the SD mailbox (in ace_core.v; this passes the accesses on)
//   $2000_0000  SPI_DATA (W: send a byte, R: the byte received), SPI_STAT (b0 busy),
//               SPI_CTRL (W: b0 card selected, b1 fast clock): the SD card
//   $3000_0000  TIMER_MS: milliseconds since reset
//   $4000_0000  KBD_DATA, KBD_SEND (PS/2: kbd_* ports), KBD_ROWS03, KBD_ROWS47 (the
//               Ace's key matrix, a byte per row, bit set = pressed), SYS_CTRL (b0
//               Z80 held in reset, set at power-up; b1 ROM ready), SYS_INFO (b0
//               standalone build)
//   $5000_0000  ROM_ADDR, ROM_DATA (a byte into the 64K ROM in the SDRAM, then the
//               next), FLASH_ADDR, FLASH_DATA (bytes from the board's SPI flash, read
//               command $03, then the next), SCREEN_ADDR, SCREEN_DATA (a character
//               into text page 0, with white on black in its colour byte)
// PicoRV32 with compressed instructions (RV32IC), no multiply or divide, no
// interrupts (the firmware polls).
// =============================================================================
`timescale 1ns / 1ps
module sdcpu #(
    parameter FIRMWARE   = "firmware.hex",
    parameter STANDALONE = 1
) (
    input             clk,              // 54 MHz
    input             reset,
    // the mailbox (ace_core.v)
    output            mb_rd,
    output            mb_wr,
    output      [5:2] mb_addr,
    output     [31:0] mb_wdata,
    input      [31:0] mb_rdata,
    // SD card
    output            sd_sclk,
    output            sd_mosi,
    input             sd_miso,
    output            sd_cs_n,
    // the board's SPI flash
    output            fl_sclk,
    output            fl_mosi,
    input             fl_miso,
    output reg        fl_cs_n,
    // PS/2 keyboard (a receiver FIFO and a sender, outside)
    input       [8:0] kbd_in,           // b8 set: no byte
    output            kbd_take,         // one clock: the byte is taken
    output reg        kbd_send,         // one clock: send kbd_out
    output reg  [7:0] kbd_out,
    input             kbd_busy,
    // to the Ace
    output reg [39:0] kbd_rows,         // row r in bits 5r+4..5r
    output            z80_reset,
    output            rom_ready,
    // the arbiter's port for the ROM and screen bytes
    output reg        w_req,
    output reg [22:0] w_addr,
    output reg  [7:0] w_data,
    input             w_ack
);
    // ---- PicoRV32
    wire        mem_valid, mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    picorv32 #(
        .COMPRESSED_ISA(1), .ENABLE_COUNTERS(0), .ENABLE_COUNTERS64(0), .BARREL_SHIFTER(1),
        .ENABLE_MUL(0), .ENABLE_DIV(0), .ENABLE_IRQ(0), .CATCH_MISALIGN(1), .CATCH_ILLINSN(1),
        .PROGADDR_RESET(32'h0000_0000), .STACKADDR(32'h0000_C000)
    ) cpu (
        .clk(clk), .resetn(!reset), .trap(),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(), .pcpi_wr(1'b0), .pcpi_rd(32'd0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0), .irq(32'd0), .eoi(),
        .trace_valid(), .trace_data()
    );

    // ---- the block RAM
    reg [31:0] ram [0:12287];
    initial $readmemh(FIRMWARE, ram);

    // ---- one access at a time: first, the clock it starts in
    reg  busy;
    wire start = mem_valid && !mem_ready && !busy;
    wire wr    = |mem_wstrb;
    wire [3:0] dev = mem_addr[31:28];
    wire [5:2] reg_n = mem_addr[5:2];

    assign mb_rd    = start && dev == 4'h1 && !wr;
    assign mb_wr    = start && dev == 4'h1 && wr;
    assign mb_addr  = reg_n;
    assign mb_wdata = mem_wdata;

    // SD card SPI
    reg        sd_sel, sd_fast;
    wire [7:0] sd_rx;
    wire       sd_busy;
    wire       sd_start = start && dev == 4'h2 && wr && reg_n == 4'h0;
    spi_master sdspi (.clk(clk), .reset(reset), .start(sd_start), .tx(mem_wdata[7:0]),
        .half(sd_fast ? 8'd2 : 8'd68), .rx(sd_rx), .busy(sd_busy), .sclk(sd_sclk),
        .mosi(sd_mosi), .miso(sd_miso));
    assign sd_cs_n = !sd_sel;

    // timer
    reg [15:0] ms_div;
    reg [31:0] ms;

    // system
    reg [1:0] sys_ctrl;
    assign z80_reset = sys_ctrl[0];
    assign rom_ready = sys_ctrl[1];
    assign kbd_take = start && dev == 4'h4 && !wr && reg_n == 4'h0 && !kbd_in[8];

    // ROM, flash, screen
    reg [15:0] rom_a;
    reg [9:0]  scr_a;
    reg [23:0] fl_a;
    reg        fl_restart;                     // FLASH_ADDR written: a new read command
    reg [2:0]  fl_step;                        // command, 3 address bytes, then data
    reg        fl_start;
    reg [7:0]  fl_tx;
    wire [7:0] fl_rx;
    wire       fl_busy;
    spi_master flspi (.clk(clk), .reset(reset), .start(fl_start), .tx(fl_tx), .half(8'd2),
        .rx(fl_rx), .busy(fl_busy), .sclk(fl_sclk), .mosi(fl_mosi), .miso(fl_miso));

    localparam A_NONE = 0, A_SPI = 1, A_ROM = 2, A_SCR = 3, A_SCRCOL = 4, A_FLASH = 5;
    reg [2:0] act;

    always @(posedge clk) begin
        mem_ready <= 1'b0;
        kbd_send <= 1'b0;
        fl_start <= 1'b0;
        if (reset) begin
            busy <= 1'b0;
            act <= A_NONE;
            sd_sel <= 1'b0; sd_fast <= 1'b0;
            ms_div <= 16'd0; ms <= 32'd0;
            sys_ctrl <= 2'b01;                  // the Z80 held until the ROM is in
            kbd_rows <= 40'd0;
            w_req <= 1'b0;
            fl_cs_n <= 1'b1; fl_restart <= 1'b1;
            rom_a <= 0; scr_a <= 0; fl_a <= 0;
        end else begin
            if (ms_div == 16'd53999) begin ms_div <= 16'd0; ms <= ms + 32'd1; end
            else ms_div <= ms_div + 16'd1;

            if (start) begin
                busy <= 1'b1;
                case (dev)
                    4'h0: begin                 // RAM
                        if (wr) begin
                            if (mem_wstrb[0]) ram[mem_addr[15:2]][7:0]   <= mem_wdata[7:0];
                            if (mem_wstrb[1]) ram[mem_addr[15:2]][15:8]  <= mem_wdata[15:8];
                            if (mem_wstrb[2]) ram[mem_addr[15:2]][23:16] <= mem_wdata[23:16];
                            if (mem_wstrb[3]) ram[mem_addr[15:2]][31:24] <= mem_wdata[31:24];
                        end
                        mem_rdata <= ram[mem_addr[15:2]];
                        mem_ready <= 1'b1;
                    end
                    4'h1: begin mem_rdata <= mb_rdata; mem_ready <= 1'b1; end
                    4'h2: begin
                        case (reg_n)
                            4'h0: if (wr) act <= A_SPI;             // wait for the byte
                                  else begin mem_rdata <= {24'd0, sd_rx}; mem_ready <= 1'b1; end
                            4'h1: begin mem_rdata <= {31'd0, sd_busy}; mem_ready <= 1'b1; end
                            default: begin
                                if (wr) {sd_fast, sd_sel} <= mem_wdata[1:0];
                                mem_rdata <= {30'd0, sd_fast, sd_sel}; mem_ready <= 1'b1;
                            end
                        endcase
                    end
                    4'h3: begin mem_rdata <= ms; mem_ready <= 1'b1; end
                    4'h4: begin
                        case (reg_n)
                            4'h0: mem_rdata <= {23'd0, kbd_in};
                            4'h1: begin
                                mem_rdata <= {23'd0, kbd_busy, 8'd0};
                                if (wr && !kbd_busy) begin kbd_out <= mem_wdata[7:0]; kbd_send <= 1'b1; end
                            end
                            4'h2: if (wr) begin
                                kbd_rows[19:0] <= {mem_wdata[28:24], mem_wdata[20:16], mem_wdata[12:8], mem_wdata[4:0]};
                            end
                            4'h3: if (wr) begin
                                kbd_rows[39:20] <= {mem_wdata[28:24], mem_wdata[20:16], mem_wdata[12:8], mem_wdata[4:0]};
                            end
                            4'h4: begin if (wr) sys_ctrl <= mem_wdata[1:0]; mem_rdata <= {30'd0, sys_ctrl}; end
                            4'h5: mem_rdata <= STANDALONE ? 32'd1 : 32'd0;
                            default: mem_rdata <= 32'd0;
                        endcase
                        mem_ready <= 1'b1;
                    end
                    4'h5: begin
                        case (reg_n)
                            4'h0: begin if (wr) rom_a <= mem_wdata[15:0]; mem_ready <= 1'b1; end
                            4'h1: if (wr) begin
                                act <= A_ROM; w_req <= 1'b1; w_addr <= 23'h090000 + rom_a; w_data <= mem_wdata[7:0];
                            end else mem_ready <= 1'b1;
                            4'h2: begin if (wr) begin fl_a <= mem_wdata[23:0]; fl_restart <= 1'b1; end mem_ready <= 1'b1; end
                            4'h3: begin
                                act <= A_FLASH;
                                if (fl_restart) begin   // CS high, then low, then $03 and the address
                                    fl_cs_n <= 1'b1; fl_restart <= 1'b0; fl_step <= 3'd6;
                                end else fl_step <= 3'd4;
                            end
                            4'h4: begin if (wr) scr_a <= mem_wdata[9:0]; mem_ready <= 1'b1; end
                            4'h5: if (wr) begin
                                act <= A_SCR; w_req <= 1'b1; w_addr <= 23'h0A0000 + scr_a; w_data <= mem_wdata[7:0];
                            end else mem_ready <= 1'b1;
                            default: mem_ready <= 1'b1;
                        endcase
                    end
                    default: begin mem_rdata <= 32'd0; mem_ready <= 1'b1; end
                endcase
            end

            // accesses that take longer
            case (act)
                A_SPI: if (!sd_busy && !sd_start) begin act <= A_NONE; mem_ready <= 1'b1; end
                A_ROM: if (w_ack) begin
                    w_req <= 1'b0; rom_a <= rom_a + 16'd1; act <= A_NONE; mem_ready <= 1'b1;
                end
                A_SCR: if (w_ack) begin            // then its colour: white on black
                    w_req <= 1'b0; w_addr <= 23'h0A8000 + scr_a; w_data <= 8'h0F; act <= A_SCRCOL;
                end
                A_SCRCOL: if (!w_req) w_req <= 1'b1;
                    else if (w_ack) begin
                        w_req <= 1'b0; scr_a <= scr_a + 10'd1; act <= A_NONE; mem_ready <= 1'b1;
                    end
                A_FLASH: if (!fl_busy && !fl_start) begin
                    case (fl_step)
                        3'd6: fl_step <= 3'd7;          // CS high for three clocks first
                        3'd7: fl_step <= 3'd0;
                        3'd0: begin fl_cs_n <= 1'b0; fl_tx <= 8'h03; fl_start <= 1'b1; fl_step <= 3'd1; end
                        3'd1: begin fl_tx <= fl_a[23:16]; fl_start <= 1'b1; fl_step <= 3'd2; end
                        3'd2: begin fl_tx <= fl_a[15:8];  fl_start <= 1'b1; fl_step <= 3'd3; end
                        3'd3: begin fl_tx <= fl_a[7:0];   fl_start <= 1'b1; fl_step <= 3'd4; end
                        3'd4: begin fl_tx <= 8'hFF;       fl_start <= 1'b1; fl_step <= 3'd5; end
                        3'd5: begin
                            mem_rdata <= {24'd0, fl_rx}; fl_a <= fl_a + 24'd1;
                            act <= A_NONE; mem_ready <= 1'b1;
                        end
                    endcase
                end
                default: ;
            endcase
            if (mem_ready) busy <= 1'b0;
        end
    end
endmodule
