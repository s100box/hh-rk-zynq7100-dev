// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Parallel RGB test-pattern output for the ADV7511. MODE selects timing and
// MMCM parameters together: 720p60, 1080p60 or 640x480p60. The HD pixel clocks
// are exact ratios of 200 MHz; VGA is approximately 25.1748 MHz.
// Pixel reset asserts when lock drops and releases after four pixel edges.
// DE and syncs receive the same pipeline delay as RGB. An ODDR forwards the
// pixel clock. Linux configures the ADV7511 over I2C; the chip handles TMDS,
// DDC and CEC. Its audio inputs are not routed to PL on this board.

`default_nettype none

module hdmi_out #(
    // 0 = 1280x720p60, 1 = 1920x1080p60, 2 = 640x480p60. The pixel clock is
    // a build-time constant, so the mode is too.
    parameter integer MODE = 0
) (
    input  wire        clk_200,     // the board's 200 MHz oscillator, buffered
    input  wire        rstn,        // MMCM reset; asynchronous, any domain

    output wire        locked,      // MMCM locked, for status

    // to the ADV7511
    output wire        hdmi_clk,
    output wire        hdmi_de,
    output wire        hdmi_hsync,
    output wire        hdmi_vsync,
    output wire [23:0] hdmi_d
);

    localparam integer H_ACT = (MODE == 1) ? 1920 : (MODE == 2) ?  640 : 1280;
    localparam integer V_ACT = (MODE == 1) ? 1080 : (MODE == 2) ?  480 :  720;

    // ---------------------------------------------------------------- MMCM
    //                        DIVCLK  MULT      CLKOUT0   pixel clock
    //   0  720p60              8     37.125    12.5      74.25 MHz
    //   1  1080p60             8     37.125     6.25    148.5  MHz
    //   2  640x480p60          1      4.5      35.75     25.1748 MHz
    localparam integer MMCM_D = (MODE == 2) ? 1 : 8;
    localparam real    MMCM_M = (MODE == 2) ? 4.5 : 37.125;
    localparam real    MMCM_O = (MODE == 1) ? 6.25 : (MODE == 2) ? 35.75 : 12.5;

    wire clkfb, clkfb_buf, pix_unbuf, pix_clk;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (5.000),      // 200 MHz
        .CLKFBOUT_MULT_F    (MMCM_M),
        .DIVCLK_DIVIDE      (MMCM_D),
        .CLKOUT0_DIVIDE_F   (MMCM_O),
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .STARTUP_WAIT       ("FALSE")
    ) pix_mmcm (
        .CLKIN1   (clk_200),
        .CLKFBIN  (clkfb_buf),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (pix_unbuf),
        .CLKOUT0B (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
        .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
        .CLKFBOUTB (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (~rstn)
    );

    BUFG fb_bufg  (.I(clkfb),     .O(clkfb_buf));
    BUFG pix_bufg (.I(pix_unbuf), .O(pix_clk));

    // ⚠ The video side is held in reset until the MMCM locks. Running the
    // timing generator on an unlocked clock produces sync pulses at whatever
    // frequency the VCO happens to be sweeping through, which some sinks
    // latch onto and then refuse to re-sync when the real mode arrives.
    reg [3:0] pix_rst_sr;
    always @(posedge pix_clk or negedge locked) begin
        if (!locked) pix_rst_sr <= 4'b0000;
        else         pix_rst_sr <= {pix_rst_sr[2:0], 1'b1};
    end
    wire pix_rstn = pix_rst_sr[3];

    // ------------------------------------------------------------- timing
    wire        de, hsync, vsync, frame_start;
    wire [11:0] x, y;

    video_timing #(.MODE(MODE)) timing (
        .pix_clk     (pix_clk),
        .rstn        (pix_rstn),
        .hsync       (hsync),
        .vsync       (vsync),
        .de          (de),
        .x           (x),
        .y           (y),
        .frame_start (frame_start)
    );

    wire [7:0] r, g, b;
    video_tpg #(.H_ACT(H_ACT), .V_ACT(V_ACT)) tpg (
        .pix_clk     (pix_clk),
        .rstn        (pix_rstn),
        .de          (de),
        .x           (x),
        .y           (y),
        .frame_start (frame_start),
        .r           (r),
        .g           (g),
        .b           (b)
    );

    // ------------------------------------------------------------- outputs
    // ⚠ The pixel clock leaves through an ODDR, not through a plain output.
    // Routing a clock to a pin as if it were data gives it whatever skew the
    // general fabric happens to have relative to the data pins, and the
    // ADV7511 samples RGB against that clock. An ODDR driven 1/0 puts the
    // clock on the same kind of output path as the data it must be aligned
    // with, which is what the pin is for.
    ODDR #(
        .DDR_CLK_EDGE ("OPPOSITE_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) clk_oddr (
        .Q  (hdmi_clk),
        .C  (pix_clk),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    // ⚠ The pattern is registered, so its pixel for a given x arrives one
    // clock after the DE and syncs that came with that x. The ADV7511 samples
    // all of them on the same edge, so DE and the syncs take one register
    // here to meet their pixel; without it every line starts with a blanking
    // pixel and loses its last one.
    reg de_q, hsync_q, vsync_q;
    always @(posedge pix_clk) begin
        de_q    <= de;
        hsync_q <= hsync;
        vsync_q <= vsync;
    end

    // The ADV7511 is configured for 24-bit RGB 4:4:4 input, so the lanes are
    // simply {R, G, B}. The board's wiring of HDMI_TX_D[23:0] to the chip's
    // D[35:28]/D[23:16]/D[11:4] is a PCB matter and does not change this.
    assign hdmi_d     = {r, g, b};
    assign hdmi_de    = de_q;
    assign hdmi_hsync = hsync_q;
    assign hdmi_vsync = vsync_q;

endmodule

`default_nettype wire
