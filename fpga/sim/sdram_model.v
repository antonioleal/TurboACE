// =============================================================================
// Behavioural model of the Tang Nano 20K's SDRAM for simulation: 64 Mbit, 32 bits,
// 4 banks x 2048 rows x 256 columns, burst length 1, CAS latency 2. It keeps the
// data (with the byte masks) and checks what a controller must respect; each
// violation is counted in `errors` and printed:
//   start-up: 200 us of NOP, PRECHARGE ALL, at least 2 AUTO REFRESH, then LOAD MODE
//   (burst 1, CAS latency 2, single-location writes) before any READ or WRITE;
//   tRCD, tRP, tRC, tRFC, write recovery tWR, refresh at least every 15.6 us;
//   READ / WRITE only to an active bank, ACTIVE only to an idle one.
// Timings are those of a -6/-7 grade part (in ns).
// =============================================================================
`timescale 1ns / 1ps
module sdram_model (
    input        clk,                   // the chip's clock (sd_clk)
    input        cke, cs_n, ras_n, cas_n, we_n,
    input  [1:0] ba,
    input [10:0] a,
    input  [3:0] dqm,
    inout [31:0] dq
);
    parameter real T_RCD = 18, T_RP = 18, T_RC = 60, T_RFC = 60, T_WR = 12, T_AC = 5.4,
                   T_OH = 2.5, T_REFI = 15625, T_INIT = 200000;

    reg [31:0] mem [0:(1 << 21) - 1];
    integer errors = 0, refreshes = 0, reads = 0, writes = 0;
    reg     moded = 0, prechall = 0;
    integer initrefs = 0;
    real    t_lastref = -1, t_lastact = -1e9, t_ref_end = 0;
    real    t_act [0:3];
    real    t_free [0:3];               // bank idle again from here
    reg     open_ [0:3];
    reg [10:0] row [0:3];
    reg [31:0] dq_out;
    reg        dq_oe = 0;
    reg [31:0] pipe_d0, pipe_d1;        // CAS latency 2: read data two edges later
    reg        pipe_v0 = 0, pipe_v1 = 0;
    integer k;

    assign dq = dq_oe ? dq_out : 32'bz;

    initial for (k = 0; k < 4; k = k + 1) begin t_free[k] = 0; open_[k] = 0; t_act[k] = -1e9; end

    task fail(input [8*80-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("SDRAM model, %0t ns: %0s", $realtime, what);
        end
    endtask

    // refresh must keep coming once the chip is set up
    always @(posedge clk) if (moded && t_lastref >= 0 && $realtime - t_lastref > T_REFI)
        begin fail("refresh interval over 15.6 us"); t_lastref = $realtime; end

    always @(posedge clk) begin
        // read data out: valid tAC after the second edge after READ, held tOH past the next
        if (pipe_v1) begin dq_out <= #(T_AC) pipe_d1; dq_oe <= #(T_AC) 1'b1; end
        else dq_oe <= #(T_OH) 1'b0;
        pipe_d1 <= pipe_d0; pipe_v1 <= pipe_v0;
        pipe_v0 <= 1'b0;
        if (cke && !cs_n) case ({ras_n, cas_n, we_n})
        3'b011: begin                   // ACTIVE
            if (!moded) fail("ACTIVE before LOAD MODE");
            if (open_[ba]) fail("ACTIVE to an open bank");
            if ($realtime < t_free[ba]) fail("ACTIVE too soon after precharge (tRP / tWR)");
            if ($realtime - t_act[ba] < T_RC) fail("ACTIVE to ACTIVE in one bank under tRC");
            if ($realtime < t_ref_end) fail("ACTIVE during refresh (tRFC)");
            open_[ba] = 1; row[ba] = a; t_act[ba] = $realtime;
        end
        3'b101, 3'b100: begin           // READ / WRITE (A10 = auto-precharge)
            if (!moded) fail("READ/WRITE before LOAD MODE");
            if (!open_[ba]) fail("READ/WRITE to an idle bank");
            if ($realtime - t_act[ba] < T_RCD) fail("READ/WRITE under tRCD after ACTIVE");
            if (!a[10]) fail("READ/WRITE without auto-precharge (controller expects it)");
            if (we_n) begin
                reads = reads + 1;
                pipe_d0 <= mem[{ba, row[ba], a[7:0]}];
                pipe_v0 <= 1'b1;
            end else begin
                writes = writes + 1;
                if (!dqm[0]) mem[{ba, row[ba], a[7:0]}][7:0]   = dq[7:0];
                if (!dqm[1]) mem[{ba, row[ba], a[7:0]}][15:8]  = dq[15:8];
                if (!dqm[2]) mem[{ba, row[ba], a[7:0]}][23:16] = dq[23:16];
                if (!dqm[3]) mem[{ba, row[ba], a[7:0]}][31:24] = dq[31:24];
            end
            open_[ba] = 0;
            t_free[ba] = $realtime + (we_n ? 0 : T_WR) + T_RP;
        end
        3'b010: begin                   // PRECHARGE
            if (a[10]) begin
                for (k = 0; k < 4; k = k + 1) begin open_[k] = 0; t_free[k] = $realtime + T_RP; end
                if (!moded) begin
                    if ($realtime < T_INIT) fail("PRECHARGE ALL before 200 us");
                    prechall = 1;
                end
            end else begin open_[ba] = 0; t_free[ba] = $realtime + T_RP; end
        end
        3'b001: begin                   // AUTO REFRESH
            for (k = 0; k < 4; k = k + 1) begin
                if (open_[k]) fail("REFRESH with a bank open");
                if ($realtime < t_free[k]) fail("REFRESH too soon after precharge");
            end
            if ($realtime < t_ref_end) fail("REFRESH under tRFC");
            if (!moded && !prechall) fail("REFRESH before PRECHARGE ALL");
            if (!moded) initrefs = initrefs + 1;
            refreshes = refreshes + 1;
            t_lastref = $realtime;
            t_ref_end = $realtime + T_RFC;
        end
        3'b000: begin                   // LOAD MODE REGISTER
            if (!prechall || initrefs < 2) fail("LOAD MODE before PRECHARGE ALL and 2 refreshes");
            if (a[2:0] != 3'd0 || a[3] || a[6:4] != 3'd2 || a[9] != 1'b1)
                fail("mode register is not burst 1, sequential, CAS latency 2, single writes");
            moded = 1;
            t_lastref = $realtime;
        end
        default: ;
        endcase
    end
endmodule
