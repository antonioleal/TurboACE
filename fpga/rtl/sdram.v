// =============================================================================
// TurboACE: controller for the Tang Nano 20K's SDRAM (in the GW2AR-18 package:
// 64 Mbit, 32-bit data, 4 banks x 2048 rows x 256 columns). register-map.md
// decision 31: our own, simple controller, one access at a time.
//
// Byte interface: addr is a byte address (8 MB). The requester raises req with we,
// addr and wdata, and holds them until ack (one clock); then it drops req. Each
// raise of req is one access, taken as soon as the controller is free (a refresh
// may come first). For a read, rdata is valid with ack. ready shows when the
// controller is idle (for information; req may be raised at any time).
// Byte addr[1:0] selects the byte lane (DQM), so a byte access touches nothing else.
//
// Every access is a single-word ACTIVE / READ or WRITE with auto-precharge, so no
// row is left open: simple, and far faster than the Z80 needs (a few clocks at
// tens of MHz against 300 ns per Z80 cycle). Refresh has priority: one AUTO
// REFRESH every REFRESH_US microseconds (4096 rows in 64 ms needs 15.6 us).
//
// Start-up (JEDEC): 200 us with CKE high and NOP, PRECHARGE ALL, 8 AUTO REFRESH,
// LOAD MODE REGISTER (burst length 1, sequential, CAS latency 2, single writes).
// =============================================================================
`timescale 1ns / 1ps
module sdram #(
    parameter CLK_MHZ    = 54,          // controller clock
    parameter REFRESH_US = 15           // < 15.6 us
) (
    input             clk,
    input             reset,
    // request side
    input             req,
    input             we,
    input      [22:0] addr,             // byte address
    input       [7:0] wdata,
    output reg  [7:0] rdata,
    output reg        ack,
    output            ready,            // can take a request now
    // the chip
    output            sd_clk,
    output reg        sd_cke,
    output reg        sd_cs_n,
    output reg        sd_ras_n,
    output reg        sd_cas_n,
    output reg        sd_we_n,
    output reg  [1:0] sd_ba,
    output reg [10:0] sd_addr,
    output reg  [3:0] sd_dqm,
    inout      [31:0] sd_dq
);
    // timings in clocks, rounded up (ns * MHz / 1000), at least 1
    function integer clocks(input integer ns);
        clocks = (ns * CLK_MHZ + 999) / 1000 < 1 ? 1 : (ns * CLK_MHZ + 999) / 1000;
    endfunction
    localparam T_RP   = clocks(20);     // PRECHARGE to next command
    localparam T_RCD  = clocks(20);     // ACTIVE to READ / WRITE
    localparam T_RC   = clocks(70);     // ACTIVE (or REFRESH) to the next ACTIVE / REFRESH
    localparam T_WR   = clocks(15) + 1; // write recovery before the auto-precharge
    localparam CL     = 2;              // CAS latency (mode register)
    localparam T_INIT = 200 * CLK_MHZ;  // 200 us
    localparam T_REF  = REFRESH_US * CLK_MHZ;

    assign sd_clk = ~clk;               // the chip samples on our clock's middle

    // commands: {cs_n, ras_n, cas_n, we_n}
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    localparam S_INIT = 0, S_PREALL = 1, S_INITREF = 2, S_MRS = 3, S_IDLE = 4,
               S_REF = 5, S_ACT = 6, S_RW = 7, S_RDWAIT = 8, S_DONE = 9;

    reg  [3:0]  state;
    reg  [15:0] wait_n;                 // clocks before the next step
    reg  [3:0]  init_refs;
    reg  [15:0] ref_cnt;
    reg         ref_due;
    reg         a_we;
    reg  [22:0] a_addr;
    reg  [7:0]  a_wdata;
    reg  [31:0] dq_out;
    reg         dq_oe;
    reg  [2:0]  cl_n;
    reg         taken;                  // this raise of req has been served

    assign sd_dq = dq_oe ? dq_out : 32'bz;
    assign ready = state == S_IDLE && !ref_due && wait_n == 0;

    task cmd(input [3:0] c);
        {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= c;
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state <= S_INIT;
            wait_n <= T_INIT[15:0];
            sd_cke <= 1'b1;
            cmd(C_NOP);
            sd_dqm <= 4'b1111;
            sd_ba <= 2'd0;
            sd_addr <= 11'd0;
            dq_oe <= 1'b0;
            ack <= 1'b0;
            ref_cnt <= 16'd0;
            ref_due <= 1'b0;
            init_refs <= 4'd0;
            taken <= 1'b0;
        end else begin
            if (!req) taken <= 1'b0;
            cmd(C_NOP);
            ack <= 1'b0;
            dq_oe <= 1'b0;
            if (state >= S_IDLE) begin
                if (ref_cnt == T_REF[15:0] - 1) begin
                    ref_cnt <= 16'd0;
                    ref_due <= 1'b1;
                end else
                    ref_cnt <= ref_cnt + 16'd1;
            end
            if (wait_n != 0) begin
                wait_n <= wait_n - 16'd1;
            end else case (state)
                S_INIT: begin                   // 200 us of NOP done
                    cmd(C_PRE);
                    sd_addr[10] <= 1'b1;        // all banks
                    wait_n <= T_RP - 1;
                    state <= S_PREALL;
                end
                S_PREALL, S_INITREF: begin
                    if (init_refs == 4'd8) begin
                        cmd(C_MRS);
                        sd_ba <= 2'd0;
                        // A10-A7 0: normal, single-location writes are A9 = 1
                        sd_addr <= {1'b0, 1'b1, 2'b00, 3'd2, 1'b0, 3'd0}; // CL 2, sequential, BL 1
                        wait_n <= 16'd2 - 1;    // tMRD
                        state <= S_MRS;
                    end else begin
                        cmd(C_REF);
                        init_refs <= init_refs + 4'd1;
                        wait_n <= T_RC - 1;
                        state <= S_INITREF;
                    end
                end
                S_MRS: begin
                    state <= S_IDLE;
                    sd_dqm <= 4'b1111;
                end
                S_IDLE: begin
                    if (ref_due) begin
                        cmd(C_REF);
                        ref_due <= 1'b0;
                        wait_n <= T_RC - 1;
                    end else if (req && !taken) begin
                        taken <= 1'b1;
                        a_we <= we;
                        a_addr <= addr;
                        a_wdata <= wdata;
                        cmd(C_ACT);
                        sd_ba <= addr[22:21];
                        sd_addr <= addr[20:10];     // row
                        wait_n <= T_RCD - 1;
                        state <= S_RW;
                    end
                end
                S_RW: begin
                    cmd(a_we ? C_WR : C_RD);
                    sd_ba <= a_addr[22:21];
                    sd_addr <= {1'b1, 2'b00, a_addr[9:2]};        // A10 = auto-precharge, column
                    sd_dqm <= ~(4'b0001 << a_addr[1:0]);
                    if (a_we) begin
                        dq_out <= {4{a_wdata}};
                        dq_oe <= 1'b1;
                        // write recovery, precharge and the rest of tRC before the next access
                        wait_n <= (T_WR + T_RP > T_RC - T_RCD ? T_WR + T_RP : T_RC - T_RCD) - 1;
                        state <= S_DONE;
                    end else begin
                        cl_n <= CL;
                        state <= S_RDWAIT;
                    end
                end
                S_RDWAIT: begin                 // data CL clocks after READ (+1: our sampling)
                    if (cl_n == 0) begin
                        case (a_addr[1:0])
                            2'd0: rdata <= sd_dq[7:0];
                            2'd1: rdata <= sd_dq[15:8];
                            2'd2: rdata <= sd_dq[23:16];
                            2'd3: rdata <= sd_dq[31:24];
                        endcase
                        sd_dqm <= 4'b1111;
                        ack <= 1'b1;
                        wait_n <= (T_RP > T_RC - T_RCD - CL - 1 ? T_RP : T_RC - T_RCD - CL - 1) - 1;
                        state <= S_IDLE;
                    end else
                        cl_n <= cl_n - 3'd1;
                end
                S_DONE: begin
                    sd_dqm <= 4'b1111;
                    ack <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
