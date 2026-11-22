// =============================================================================
// TurboACE: the Gowin GW2AR-18 parts behind small wrappers, so the rest of the
// design is plain Verilog. With `define SIM (simulation) each wrapper is a simple
// model instead of the vendor primitive.
//
//   clocks         rPLL: 27 MHz x 10 = 270 MHz (VCO 540 MHz); CLKDIV /5: 54 MHz,
//                  CLKDIV /2: 135 MHz, then CLKDIV /5: 27 MHz. All from the one PLL.
//                  The rPLL settings follow Gowin's formulas (FCLKIN x (FBDIV_SEL+1) /
//                  (IDIV_SEL+1) = CLKOUT, VCO = CLKOUT x ODIV_SEL): confirm them with
//                  Gowin's IP generator when the project is first built.
//   ddr_clock_out  ODDR with D0 = 0, D1 = 1: a clean copy of clk, inverted, on a pin
//   tmds_out       TLVDS_OBUF (true LVDS, as Sipeed's HDMI example): the TMDS pairs
// =============================================================================
`timescale 1ns / 1ps

module clocks (
    input  clk27,
    output clk54,
    output clk135,
    output clk27_pixel,
    output locked
);
`ifdef SIM
    // models: 270 MHz is not needed; 135, 54 and 27 MHz with the right phases
    reg c135 = 0, c54 = 0, c27 = 0, lk = 0;
    always #(1000.0 / 270) c135 = ~c135;
    initial begin
        #1;
        forever begin                   // 54 MHz: rising together with every 2.5th 135 MHz edge
            c54 = 1; #(1000.0 / 108); c54 = 0; #(1000.0 / 108);
        end
    end
    always @(posedge c54) c27 = ~c27;
    initial #2000 lk = 1;
    assign clk135 = c135, clk54 = c54, clk27_pixel = c27, locked = lk;
`else
    wire clk270;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(0),                   // /1
        .FBDIV_SEL(9),                  // x10: 270 MHz
        .ODIV_SEL(2),                   // VCO 540 MHz
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"), .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) pll (
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(clk270), .LOCK(locked), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3()
    );
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) div54  (.HCLKIN(clk270), .RESETN(locked), .CALIB(1'b0), .CLKOUT(clk54));
    CLKDIV #(.DIV_MODE("2"), .GSREN("false")) div135 (.HCLKIN(clk270), .RESETN(locked), .CALIB(1'b0), .CLKOUT(clk135));
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) div27  (.HCLKIN(clk135), .RESETN(locked), .CALIB(1'b0), .CLKOUT(clk27_pixel));
`endif
endmodule

module ddr_clock_out (
    input  clk,
    output q
);
`ifdef SIM
    assign q = ~clk;
`else
    ODDR #(.INIT(1'b0), .TXCLK_POL(1'b0)) oddr (.D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(clk), .Q0(q), .Q1());
`endif
endmodule

module tmds_out (
    input  [2:0] tmds,
    input        tmds_clock,
    output       clk_p, clk_n,
    output [2:0] d_p, d_n
);
`ifdef SIM
    assign clk_p = tmds_clock, clk_n = ~tmds_clock;
    assign d_p = tmds, d_n = ~tmds;
`else
    TLVDS_OBUF ck (.I(tmds_clock), .O(clk_p), .OB(clk_n));
    TLVDS_OBUF d0 (.I(tmds[0]), .O(d_p[0]), .OB(d_n[0]));
    TLVDS_OBUF d1 (.I(tmds[1]), .O(d_p[1]), .OB(d_n[1]));
    TLVDS_OBUF d2 (.I(tmds[2]), .O(d_p[2]), .OB(d_n[2]));
`endif
endmodule
