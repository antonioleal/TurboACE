// =============================================================================
// A microSD card in SPI mode, for simulation: answers what firmware/src/diskio_sd.c
// sends, as an SDHC card (block addressing): CMD0, CMD8, CMD55 + ACMD41 (ready on
// the second), CMD58 (OCR with CCS), CMD16, CMD9 (CSD), CMD17 (a 512-byte block),
// CMD24 (a block written, data response $05). Responses come one byte after the
// command (NCR 1). The card's sectors start from IMAGE (sim/mkcard.c: the non-zero
// sectors of a 32 MB FAT card); all others read as zeros; written ones are kept.
// errors counts commands it does not know.
// =============================================================================
`timescale 1ns / 1ps
module sdcard_model #(
    parameter IMAGE = "card.hex",
    parameter SLOTS = 256               // sectors that can hold data
) (
    input      sclk,
    input      mosi,
    output     miso,
    input      cs_n
);
    reg [7:0]  img [0:(SLOTS * 516) + 3];
    reg [31:0] slot_sector [0:SLOTS-1];
    reg [7:0]  slot_data [0:SLOTS * 512 - 1];
    integer    slots = 0, errors = 0, reads = 0, writes = 0, i, j, k;

    initial begin
        for (i = 0; i < SLOTS * 516 + 4; i = i + 1) img[i] = 8'h00;
        $readmemh(IMAGE, img);
        slots = img[0] | img[1] << 8 | img[2] << 16 | img[3] << 24;
        for (i = 0; i < slots; i = i + 1) begin
            k = 4 + i * 516;
            slot_sector[i] = img[k] | img[k + 1] << 8 | img[k + 2] << 16 | img[k + 3] << 24;
            for (j = 0; j < 512; j = j + 1) slot_data[i * 512 + j] = img[k + 4 + j];
        end
    end

    function integer find(input [31:0] s);
        integer n;
        begin
            find = -1;
            for (n = 0; n < slots; n = n + 1) if (slot_sector[n] == s) find = n;
        end
    endfunction

    // ---- bytes in and out
    reg [7:0]  in_sh, out_sh = 8'hFF;
    reg [3:0]  bitn = 0;
    reg [7:0]  q [0:1023];
    integer    qh = 0, qn = 0;
    assign miso = cs_n ? 1'b1 : out_sh[7];

    task send(input [7:0] b);
        begin q[(qh + qn) % 1024] = b; qn = qn + 1; end
    endtask

    always @(posedge cs_n) begin bitn = 0; out_sh = 8'hFF; end
    always @(posedge sclk) if (!cs_n) begin in_sh = {in_sh[6:0], mosi}; bitn = bitn + 1; end
    always @(negedge sclk) if (!cs_n) begin
        if (bitn == 8) begin
            bitn = 0;
            byte_in(in_sh);
            if (qn) begin out_sh = q[qh]; qh = (qh + 1) % 1024; qn = qn - 1; end
            else out_sh = 8'hFF;
        end else
            out_sh = {out_sh[6:0], 1'b1};
    end

    // ---- commands
    reg [7:0]  cmd [0:5];
    integer    cn = 0;
    reg        idle = 1, app = 0, receiving = 0, got_token = 0;
    integer    acmd41s = 0, rn = 0;
    reg [31:0] arg, wsector;
    reg [7:0]  wbuf [0:513];

    task byte_in(input [7:0] b);
        integer s, n;
        begin
            if (receiving) begin                // CMD24's data: token, 512 bytes, CRC
                if (!got_token) begin if (b == 8'hFE) begin got_token = 1; rn = 0; end end
                else begin
                    wbuf[rn] = b; rn = rn + 1;
                    if (rn == 514) begin
                        s = find(wsector);
                        if (s < 0) begin s = slots; slot_sector[s] = wsector; slots = slots + 1; end
                        for (n = 0; n < 512; n = n + 1) slot_data[s * 512 + n] = wbuf[n];
                        writes = writes + 1;
                        receiving = 0;
                        send(8'h05);                   // data accepted
                        send(8'h00); send(8'h00);      // busy a little
                    end
                end
            end else if (cn == 0) begin
                if (b[7:6] == 2'b01) begin cmd[0] = b; cn = 1; end
            end else begin
                cmd[cn] = b; cn = cn + 1;
                if (cn == 6) begin cn = 0; command; end
            end
        end
    endtask

    task r1(input [7:0] v); begin send(8'hFF); send(v); end endtask

    task command;
        integer s, n, c;
        begin
            c = cmd[0] & 8'h3F;
            arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
            if (app && c == 41) begin
                acmd41s = acmd41s + 1;
                if (acmd41s >= 2) idle = 0;
                r1({7'd0, idle});
                app = 0;
            end else begin
                app = 0;
                case (c)
                    0:  begin idle = 1; acmd41s = 0; r1(8'h01); end
                    8:  begin r1({7'd0, idle}); send(8'h00); send(8'h00); send(cmd[3]); send(cmd[4]); end
                    55: begin app = 1; r1({7'd0, idle}); end
                    58: begin r1({7'd0, idle}); send(8'hC0); send(8'hFF); send(8'h80); send(8'h00); end
                    16: r1(8'h00);
                    9:  begin                   // CSD version 2: C_SIZE 63, 32 MB
                        r1(8'h00); send(8'hFF); send(8'hFE);
                        send(8'h40); send(8'h0E); send(8'h00); send(8'h32); send(8'h5B); send(8'h59);
                        send(8'h00); send(8'h00); send(8'h00); send(8'h3F); send(8'h7F); send(8'h80);
                        send(8'h0A); send(8'h40); send(8'h00); send(8'h01);
                        send(8'hFF); send(8'hFF);
                    end
                    17: begin
                        r1(8'h00); send(8'hFF); send(8'hFE);
                        s = find(arg);
                        for (n = 0; n < 512; n = n + 1) send(s < 0 ? 8'h00 : slot_data[s * 512 + n]);
                        send(8'hFF); send(8'hFF);
                        reads = reads + 1;
                    end
                    24: begin r1(8'h00); wsector = arg; receiving = 1; got_token = 0; end
                    default: begin errors = errors + 1; r1(8'h04); end    // illegal command
                endcase
            end
        end
    endtask
endmodule
