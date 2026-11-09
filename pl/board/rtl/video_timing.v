// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Registered progressive video timing for CEA-861 formats 4, 16 and 1.
// MODE is fixed at synthesis and must match the pixel-clock source:
// 0: 1280x720p60 at 74.25 MHz, positive syncs;
// 1: 1920x1080p60 at 148.5 MHz, positive syncs;
// 2: 640x480p60 at 25.175 MHz nominal, negative syncs.
// Coordinates are valid during DE. frame_start leads registered pixel (0,0)
// by one cycle. No runtime mode switching or interlace support is provided.

`default_nettype none

module video_timing #(
    parameter integer MODE = 0
) (
    input  wire        pix_clk,
    input  wire        rstn,

    output reg         hsync,
    output reg         vsync,
    output reg         de,          // data enable: inside the active area
    output reg  [11:0] x,           // 0 .. H_ACT-1 while de
    output reg  [11:0] y,           // 0 .. V_ACT-1 while de
    output wire        frame_start  // one pulse, the clock before pixel (0,0)
);

    // --------------------------------------------------------------- modes
    // active, front porch, sync width, back porch, sync polarity (1 = positive)
    localparam integer H_ACT = (MODE == 1) ? 1920 : (MODE == 2) ?  640 : 1280;
    localparam integer H_FP  = (MODE == 1) ?   88 : (MODE == 2) ?   16 :  110;
    localparam integer H_SY  = (MODE == 1) ?   44 : (MODE == 2) ?   96 :   40;
    localparam integer H_BP  = (MODE == 1) ?  148 : (MODE == 2) ?   48 :  220;

    localparam integer V_ACT = (MODE == 1) ? 1080 : (MODE == 2) ?  480 :  720;
    localparam integer V_FP  = (MODE == 1) ?    4 : (MODE == 2) ?   10 :    5;
    localparam integer V_SY  = (MODE == 1) ?    5 : (MODE == 2) ?    2 :    5;
    localparam integer V_BP  = (MODE == 1) ?   36 : (MODE == 2) ?   33 :   20;

    localparam H_POS = (MODE == 2) ? 1'b0 : 1'b1;
    localparam V_POS = (MODE == 2) ? 1'b0 : 1'b1;

    localparam integer H_TOTAL = H_ACT + H_FP + H_SY + H_BP;
    localparam integer V_TOTAL = V_ACT + V_FP + V_SY + V_BP;

    // ------------------------------------------------------------ counters
    reg [11:0] hcnt;
    reg [11:0] vcnt;

    wire h_last = (hcnt == H_TOTAL - 1);
    wire v_last = (vcnt == V_TOTAL - 1);

    always @(posedge pix_clk) begin
        if (!rstn) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
        end else begin
            if (h_last) begin
                hcnt <= 12'd0;
                vcnt <= v_last ? 12'd0 : (vcnt + 12'd1);
            end else begin
                hcnt <= hcnt + 12'd1;
            end
        end
    end

    // ⚠ Sync pulses sit AFTER the front porch, not at the start of the line.
    // Putting them at zero is the classic off-by-a-porch: the monitor locks,
    // and the image sits shifted by the back porch with a black bar down one
    // side. Everything below is counted from the end of the active area.
    wire h_sync_on = (hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SY);
    wire v_sync_on = (vcnt >= V_ACT + V_FP) && (vcnt < V_ACT + V_FP + V_SY);
    wire active    = (hcnt < H_ACT) && (vcnt < V_ACT);

    always @(posedge pix_clk) begin
        if (!rstn) begin
            hsync <= ~H_POS;
            vsync <= ~V_POS;
            de    <= 1'b0;
            x     <= 12'd0;
            y     <= 12'd0;
        end else begin
            hsync <= H_POS ? h_sync_on : ~h_sync_on;
            vsync <= V_POS ? v_sync_on : ~v_sync_on;
            de    <= active;
            x     <= (hcnt < H_ACT) ? hcnt : 12'd0;
            y     <= (vcnt < V_ACT) ? vcnt : 12'd0;
        end
    end

    assign frame_start = (hcnt == 12'd0) && (vcnt == 12'd0);

endmodule

`default_nettype wire
