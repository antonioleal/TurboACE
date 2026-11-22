// =============================================================================
// TurboACE: the Z80's bus cycles turned into SDRAM accesses and I/O strobes, for
// the standalone build's T80 (register-map.md sections 1-5, decision 25).
//
//   memory read   (MREQ and RD low, not a refresh; an opcode fetch already from M1
//                 and the address at T1's start): read through memmap.v and the
//                 arbiter's CPU port. A byte the CPU cannot read reads $FF.
//                 No WAIT unless needed: WAIT is sampled at T2's middle, but the
//                 byte is taken half a T-state later in an opcode fetch (T3's start)
//                 and a whole one later in a read (T3's middle). A read takes at most
//                 L_MAX clocks (a video access in progress, a refresh, its own access),
//                 so WAIT is held only if the byte could still be late then. late
//                 (sticky) shows a read that took longer than L_MAX: never, if the
//                 bound is right; the tests check it.
//   memory write  (MREQ and WR low): posted. The address and data are kept and the
//                 CPU goes on; the SDRAM write happens behind it. For the BG window
//                 the second write, PAPER:INK into colour RAM, waits in a one-byte
//                 buffer until the next opcode fetch has been served (an instruction
//                 that writes is followed by one; the fetch's refresh half then
//                 leaves 1.5 T-states free) or 32 quiet clocks have passed, so it
//                 never delays a read; a read of that very byte gets it from the
//                 buffer, and a new write lets it go first. ROM is not written.
//   contention    an access to a video-priority copy ($2400-$27FF, $2C00-$2FFF)
//                 while picture_time is high waits until it ends, as on the stock Ace.
//   I/O           io_wr: a one-clock strobe on IORQ and WR; io_rd high while IORQ
//                 and RD are low. An interrupt acknowledge (M1 with IORQ, MREQ high)
//                 is not I/O; its byte is $FF (IM 1 does not use it). A cycle with MREQ
//                 low is memory whatever IORQ does: T80pa's interrupt-cycle register
//                 has no reset, starts at 0 on the FPGA, and so drives IORQ low with
//                 MREQ in the first two opcode fetches after power-up.
//   refresh       (RFSH low) is ignored.
// cpu_din: what the CPU reads (the memory byte, or io_dout during I/O).
// =============================================================================
`timescale 1ns / 1ps
module cpubus (
    input             clk,
    input             reset,
    // the Z80
    input             mreq_n,
    input             iorq_n,
    input             rd_n,
    input             wr_n,
    input             m1_n,
    input             rfsh_n,
    input      [15:0] addr,
    input       [7:0] cpu_dout,
    output reg  [7:0] cpu_din,
    output            wait_n,
    output reg        late,
    input             picture_time,     // acetiming.v
    // registers the memory map needs (ports.v)
    input       [2:0] rompage,
    input       [4:0] bg_cpu,
    input       [4:0] chr_cpu,
    input             xcfg_attr,
    input             xcfg_mirror,
    input             xcfg_keep,
    input       [5:0] win0,
    input       [5:0] win1,
    input       [7:0] colour,           // AY R14: PAPER:INK, written with each BG byte
    // I/O
    output            io_wr,
    output            io_rd,
    input       [7:0] io_dout,
    // the arbiter's CPU port
    output reg        m_req,
    output reg        m_we,
    output reg [22:0] m_addr,
    output reg  [7:0] m_wdata,
    input             m_ack,
    input       [7:0] m_rdata
);
    wire [2:0]  region;
    wire [22:0] sd_addr, col_addr;
    wire        can_read, can_write, col_write, vidpri;
    memmap map (.addr(addr), .rompage(rompage), .bg_cpu(bg_cpu), .chr_cpu(chr_cpu),
        .xcfg_attr(xcfg_attr), .xcfg_mirror(xcfg_mirror), .xcfg_keep(xcfg_keep), .win0(win0), .win1(win1),
        .region(region), .sd_addr(sd_addr), .can_read(can_read), .can_write(can_write),
        .col_write(col_write), .col_addr(col_addr), .vidpri(vidpri));

    localparam L_MAX  = 24;             // clocks from issue to the byte, at most
    localparam D_M1   = 8;              // WAIT sample to data sample: opcode fetch
    localparam D_READ = 16;             //                              memory read

    wire fetch1 = !m1_n && rfsh_n && (iorq_n || !mreq_n);   // an opcode fetch, from T1's start
    wire mem_rd = (!mreq_n && !rd_n && rfsh_n) || fetch1;
    wire mem_wr = !mreq_n && !wr_n;
    wire mem    = mem_rd || mem_wr;
    wire iorq   = !iorq_n && m1_n;      // not an interrupt acknowledge

    reg  iorq_wr_q;
    always @(posedge clk) iorq_wr_q <= iorq && !wr_n;
    assign io_wr = iorq && !wr_n && !iorq_wr_q;
    assign io_rd = iorq && !rd_n;

    // the current memory cycle, and the work behind it
    localparam S_IDLE = 0, S_READ = 1, S_WRITE = 2, S_COLOUR = 3;
    reg  [1:0] state;
    reg        seen;                    // this memory cycle has been taken
    reg  [5:0] age;                     // clocks since the read was issued
    reg        r_m1;
    reg  [7:0] rd_byte;
    reg        w_col;                   // the posted write has a colour byte to follow
    reg [22:0] w_coladdr;
    reg  [7:0] w_colour;

    // WAIT has to be decided from MREQ alone: in a write cycle WR falls only at T2,
    // the edge where the Z80 samples WAIT
    wire mcyc      = !mreq_n && rfsh_n;
    reg        col_pending;             // the colour byte waits in the buffer ...
    reg        col_go;                  // ... and may go now
    reg  [4:0] col_wait;
    wire busy      = state != S_IDLE;
    wire contended = mcyc && vidpri && picture_time;
    // WAIT: contention; a read that could still be late when the byte is taken; a
    // new access that cannot start yet (behind a write in flight, or a write behind
    // the colour byte)
    wire rd_late   = state == S_READ && age + (r_m1 ? D_M1 : D_READ) < L_MAX;
    wire blocked   = busy || (mem_wr && col_pending);
    assign wait_n  = !(contended || rd_late || (mcyc && !seen && blocked));

    always @(*) begin
        if (iorq_n == 1'b0 && mreq_n) cpu_din = m1_n ? io_dout : 8'hFF;
        else cpu_din = rd_byte;
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            seen <= 1'b0;
            m_req <= 1'b0;
            rd_byte <= 8'hFF;
            late <= 1'b0;
            age <= 6'd0;
            col_pending <= 1'b0;
            col_go <= 1'b0;
            col_wait <= 5'd0;
        end else begin
            if (col_pending && !col_go) begin
                col_wait <= col_wait + 5'd1;
                if (col_wait == 5'd31) col_go <= 1'b1;
            end
            if (!mem) seen <= 1'b0;
            if (state == S_READ && age != 6'd63) age <= age + 6'd1;
            case (state)
                S_IDLE:
                    if (mem && !seen && !contended && !(mem_wr && col_pending)) begin
                        seen <= 1'b1;               // a new memory cycle
                        if (mem_rd) begin
                            if (!can_read) rd_byte <= 8'hFF;
                            else if (col_pending && sd_addr == w_coladdr) rd_byte <= w_colour;
                            else begin
                                state <= S_READ;
                                age <= 6'd0;
                                r_m1 <= fetch1;
                                m_req <= 1'b1; m_we <= 1'b0; m_addr <= sd_addr;
                            end
                        end else if (can_write) begin
                            state <= S_WRITE;
                            m_req <= 1'b1; m_we <= 1'b1; m_addr <= sd_addr; m_wdata <= cpu_dout;
                            w_col <= col_write; w_coladdr <= col_addr; w_colour <= colour;
                        end
                    end else if (col_pending && (col_go || (mem_wr && !seen)) && !m_req) begin   // the colour byte (a new write: first)
                        state <= S_COLOUR;
                        col_pending <= 1'b0;
                        m_req <= 1'b1; m_we <= 1'b1; m_addr <= w_coladdr; m_wdata <= w_colour;
                    end
                S_READ:
                    if (m_ack) begin
                        if (age >= L_MAX) late <= 1'b1;
                        m_req <= 1'b0;
                        rd_byte <= m_rdata;
                        if (col_pending && r_m1) col_go <= 1'b1;   // after a fetch: the colour may go
                        state <= S_IDLE;
                    end
                S_WRITE:
                    if (m_ack) begin
                        m_req <= 1'b0;
                        if (w_col) begin col_pending <= 1'b1; col_go <= 1'b0; col_wait <= 5'd0; end
                        state <= S_IDLE;
                    end
                S_COLOUR:
                    if (m_ack) begin
                        m_req <= 1'b0;
                        state <= S_IDLE;
                    end
            endcase
        end
    end
endmodule
