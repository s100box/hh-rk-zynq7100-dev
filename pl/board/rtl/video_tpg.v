// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Registered RGB test pattern: eight color bars, a gray ramp, a one-pixel
// border and a 64-pixel bar moving one pixel per frame. H_ACT and V_ACT are
// build-time dimensions; H_ACT must be at least 64. Geometry arithmetic uses
// constant coefficients. The output is black during blanking and reset.
// Consumers must delay DE/syncs by the same one-cycle latency as RGB.

`default_nettype none

module video_tpg #(
    parameter integer H_ACT = 1280,
    parameter integer V_ACT = 720
) (
    input  wire        pix_clk,
    input  wire        rstn,

    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        frame_start,

    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

    // A frame counter, so something on screen depends on time passing.
    reg [9:0] frames;
    always @(posedge pix_clk) begin
        if (!rstn)          frames <= 10'd0;
        else if (frame_start) frames <= frames + 10'd1;
    end

    // The moving bar's left edge: one pixel per frame, so it crosses the
    // screen in about twenty seconds at 60 Hz -- slow enough to read, fast
    // enough that a frozen picture is obvious within a second or two.
    // A compare-and-reset, not a modulo, which would cost logic.
    localparam integer BAR_W   = 64;
    localparam integer BAR_MAX = H_ACT - BAR_W;
    reg [11:0] bar_x;
    always @(posedge pix_clk) begin
        if (!rstn)             bar_x <= 12'd0;
        else if (frame_start)  bar_x <= (bar_x >= BAR_MAX[11:0]) ? 12'd0
                                                                 : bar_x + 12'd1;
    end

    // Eight color bars across the top two thirds: thresholds, not division.
    wire [2:0] bar = (x >= (7*H_ACT)/8) ? 3'd7 :
                     (x >= (6*H_ACT)/8) ? 3'd6 :
                     (x >= (5*H_ACT)/8) ? 3'd5 :
                     (x >= (4*H_ACT)/8) ? 3'd4 :
                     (x >= (3*H_ACT)/8) ? 3'd3 :
                     (x >= (2*H_ACT)/8) ? 3'd2 :
                     (x >= (1*H_ACT)/8) ? 3'd1 : 3'd0;

    wire border = (x == 12'd0) || (y == 12'd0) ||
                  (x == H_ACT - 1) || (y == V_ACT - 1);

    wire in_bars = (y < (V_ACT * 2) / 3);
    wire in_move = (y >= (V_ACT * 2) / 3) &&
                   (y <  (V_ACT * 5) / 6) &&
                   (x >= bar_x) && (x < bar_x + BAR_W);

    // The gray ramp along the bottom sixth: 0 to 255 across the width, so a
    // monitor doing something odd to levels shows it here as banding. The
    // scale factor is folded into a constant multiply and a shift; dividing
    // by the width would infer a divider on the pixel clock.
    localparam integer RAMP_M = (255 * 65536) / H_ACT;
    wire [31:0] ramp_w = x * RAMP_M;
    wire [7:0]  ramp   = ramp_w[23:16];

    always @(posedge pix_clk) begin
        if (!rstn) begin
            r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end else if (!de) begin
            // ⚠ Blanking must be BLACK. The ADV7511 samples the whole line;
            // color outside the active area confuses its input formatter and
            // some sinks show it as a colored border.
            r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end else if (border) begin
            r <= 8'hFF; g <= 8'hFF; b <= 8'hFF;
        end else if (in_bars) begin
            r <= bar[2] ? 8'hFF : 8'h00;
            g <= bar[1] ? 8'hFF : 8'h00;
            b <= bar[0] ? 8'hFF : 8'h00;
        end else if (in_move) begin
            r <= 8'hFF; g <= 8'hC0; b <= 8'h00;
        end else if (y >= (V_ACT * 5) / 6) begin
            r <= ramp; g <= ramp; b <= ramp;
        end else begin
            r <= 8'h10; g <= 8'h10; b <= 8'h10;
        end
    end

endmodule

`default_nettype wire
