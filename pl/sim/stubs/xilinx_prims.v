// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Behavioral stand-ins for the Xilinx primitives the PL designs instantiate,
// so the RTL can be simulated with iverilog before it ever reaches Vivado.
//
// ⚠ These model enough of each primitive's function to simulate the logic
// around it -- not its timing, its placement rules, or (for the MMCM) its
// output frequency. A bench that passes here says the logic is right; it says nothing
// about whether Vivado will place an IBUFDS_GTE2 where the design asks for
// one, or about setup and hold anywhere. Those answers only come from a
// build and from the board.

`timescale 1ns / 1ps

module IOBUF (
    output wire O,
    inout  wire IO,
    input  wire I,
    input  wire T
);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule

module IBUF (output wire O, input wire I);
    assign O = I;
endmodule

module OBUF (output wire O, input wire I);
    assign O = I;
endmodule

module BUFG (output wire O, input wire I);
    assign O = I;
endmodule

module IBUFDS #(
    parameter DIFF_TERM = "FALSE",
    parameter IBUF_LOW_PWR = "TRUE",
    parameter IOSTANDARD = "DEFAULT"
) (
    output wire O,
    input  wire I,
    input  wire IB
);
    assign O = I;
endmodule

// The GTX reference-clock buffer. O feeds the transceiver quad and is not
// usable in the fabric; ODIV2 is O divided by two and is, which is why the
// frequency counters measure half of what the oscillator produces.
module IBUFDS_GTE2 #(
    parameter CLKCM_CFG = "TRUE",
    parameter CLKRCV_TRST = "TRUE",
    parameter [1:0] CLKSWING_CFG = 2'b11
) (
    output wire O,
    output wire ODIV2,
    input  wire CEB,
    input  wire I,
    input  wire IB
);
    reg div = 1'b0;
    always @(posedge I) if (!CEB) div <= ~div;
    assign O     = CEB ? 1'b0 : I;
    assign ODIV2 = div;
endmodule

// A clock the fabric makes for itself. The stub divides rather than
// multiplies -- it produces A clock so the video logic can be simulated, not
// the RIGHT one; the frequency only exists in the real MMCM.
module MMCME2_BASE #(
    parameter BANDWIDTH = "OPTIMIZED",
    parameter real CLKIN1_PERIOD = 0.0,
    parameter real CLKFBOUT_MULT_F = 5.0,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter real CLKOUT0_DUTY_CYCLE = 0.5,
    parameter real CLKOUT0_PHASE = 0.0,
    parameter STARTUP_WAIT = "FALSE"
) (
    output wire CLKOUT0, output wire CLKOUT0B,
    output wire CLKOUT1, output wire CLKOUT1B,
    output wire CLKOUT2, output wire CLKOUT2B,
    output wire CLKOUT3, output wire CLKOUT3B,
    output wire CLKOUT4, output wire CLKOUT5, output wire CLKOUT6,
    output wire CLKFBOUT, output wire CLKFBOUTB,
    output reg  LOCKED,
    input  wire CLKIN1, input wire CLKFBIN,
    input  wire PWRDWN, input wire RST
);
    reg div = 1'b0;
    always @(posedge CLKIN1) if (!RST) div <= ~div;
    assign CLKOUT0  = div;
    assign CLKFBOUT = CLKIN1;
    assign CLKOUT0B = ~div;
    assign CLKOUT1 = 1'b0; assign CLKOUT1B = 1'b0;
    assign CLKOUT2 = 1'b0; assign CLKOUT2B = 1'b0;
    assign CLKOUT3 = 1'b0; assign CLKOUT3B = 1'b0;
    assign CLKOUT4 = 1'b0; assign CLKOUT5 = 1'b0; assign CLKOUT6 = 1'b0;
    assign CLKFBOUTB = 1'b0;
    // LOCKED falls from X to 0 one step after time zero, so logic reset
    // asynchronously by !LOCKED sees an edge and starts in reset -- the
    // state the fabric's own power-up gives it on the board.
    initial #1 LOCKED = 1'b0;
    always @(posedge CLKIN1) if (RST) LOCKED <= 1'b0; else LOCKED <= 1'b1;
endmodule

// The IDELAY calibration block. RDY rises some cycles after RST is released,
// as the real one does once its reference clock has been counted; here that
// is a fixed 16 REFCLK cycles, enough for a bench to see RDY low, then high.
module IDELAYCTRL (output reg RDY, input wire REFCLK, input wire RST);
    reg [4:0] n = 5'd0;
    initial RDY = 1'b0;
    always @(posedge REFCLK or posedge RST)
        if (RST)            begin n <= 5'd0; RDY <= 1'b0; end
        else if (!n[4])     n <= n + 5'd1;
        else                RDY <= 1'b1;
endmodule

// The GTX quad's shared PLL. QPLLLOCK rises 64 lock-detect clocks after
// QPLLRESET is released, as a PLL takes a while to lock; the output clocks
// are not modeled (gtx_sfp_model.v makes its own user clock).
module GTXE2_COMMON #(
    parameter         SIM_RESET_SPEEDUP        = "FALSE",
    parameter [2:0]   SIM_QPLLREFCLK_SEL       = 3'b001,
    parameter         SIM_VERSION              = "4.0",
    parameter [63:0]  BIAS_CFG                 = 64'h0,
    parameter [31:0]  COMMON_CFG               = 32'h0,
    parameter [26:0]  QPLL_CFG                 = 27'h0,
    parameter [3:0]   QPLL_CLKOUT_CFG          = 4'h0,
    parameter [5:0]   QPLL_COARSE_FREQ_OVRD    = 6'h0,
    parameter [0:0]   QPLL_COARSE_FREQ_OVRD_EN = 1'b0,
    parameter [9:0]   QPLL_CP                  = 10'h0,
    parameter [0:0]   QPLL_CP_MONITOR_EN       = 1'b0,
    parameter [0:0]   QPLL_DMONITOR_SEL        = 1'b0,
    parameter [9:0]   QPLL_FBDIV               = 10'h0,
    parameter [0:0]   QPLL_FBDIV_MONITOR_EN    = 1'b0,
    parameter [0:0]   QPLL_FBDIV_RATIO         = 1'b0,
    parameter [23:0]  QPLL_INIT_CFG            = 24'h0,
    parameter [15:0]  QPLL_LOCK_CFG            = 16'h0,
    parameter [3:0]   QPLL_LPF                 = 4'h0,
    parameter integer QPLL_REFCLK_DIV          = 1
) (
    input  wire [7:0]  DRPADDR,
    input  wire        DRPCLK,
    input  wire [15:0] DRPDI,
    output wire [15:0] DRPDO,
    input  wire        DRPEN,
    output wire        DRPRDY,
    input  wire        DRPWE,
    input  wire        GTGREFCLK,
    input  wire        GTNORTHREFCLK0,
    input  wire        GTNORTHREFCLK1,
    input  wire        GTREFCLK0,
    input  wire        GTREFCLK1,
    input  wire        GTSOUTHREFCLK0,
    input  wire        GTSOUTHREFCLK1,
    output wire [7:0]  QPLLDMONITOR,
    output wire        QPLLOUTCLK,
    output wire        QPLLOUTREFCLK,
    output wire        REFCLKOUTMONITOR,
    output wire        QPLLFBCLKLOST,
    output reg         QPLLLOCK,
    input  wire        QPLLLOCKDETCLK,
    input  wire        QPLLLOCKEN,
    input  wire        QPLLOUTRESET,
    input  wire        QPLLPD,
    output wire        QPLLREFCLKLOST,
    input  wire [2:0]  QPLLREFCLKSEL,
    input  wire        QPLLRESET,
    input  wire [15:0] QPLLRSVD1,
    input  wire [4:0]  QPLLRSVD2,
    input  wire        BGBYPASSB,
    input  wire        BGMONITORENB,
    input  wire        BGPDB,
    input  wire [4:0]  BGRCALOVRD,
    input  wire [7:0]  PMARSVD,
    input  wire        RCALENB
);
    assign DRPDO = 16'd0;
    assign DRPRDY = 1'b0;
    assign QPLLDMONITOR = 8'd0;
    assign QPLLOUTCLK = 1'b0;
    assign QPLLOUTREFCLK = 1'b0;
    assign REFCLKOUTMONITOR = 1'b0;
    assign QPLLFBCLKLOST = 1'b0;
    assign QPLLREFCLKLOST = 1'b0;
    reg [6:0] n = 7'd0;
    initial QPLLLOCK = 1'b0;
    always @(posedge QPLLLOCKDETCLK or posedge QPLLRESET)
        if (QPLLRESET)   begin n <= 7'd0; QPLLLOCK <= 1'b0; end
        else if (!n[6])  n <= n + 7'd1;
        else             QPLLLOCK <= 1'b1;
endmodule

module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output reg Q,
    input wire C, input wire CE, input wire D1, input wire D2,
    input wire R, input wire S
);
    initial Q = INIT;
    always @(posedge C or negedge C) if (R) Q <= 1'b0; else if (CE) Q <= C ? D1 : D2;
endmodule
