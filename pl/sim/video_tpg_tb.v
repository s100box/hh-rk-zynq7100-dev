// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for video_tpg, the HDMI output's test pattern. It is driven with
// pixel coordinates directly rather than through video_timing, so every
// region boundary can be probed on the exact pixel either side of it.
//
// Small geometry: H_ACT = 128, V_ACT = 96. The bars switch at k*16, the bar
// region ends at line 64, the moving bar occupies lines 64-79, and the ramp
// lines 80-95.
//
// The pattern is registered: what the inputs select on one clock appears on
// r/g/b after that clock edge.

`timescale 1ns/1ps

module video_tpg_tb;

    localparam integer H = 128, V = 96;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rstn = 1'b0;
    reg        de = 1'b0;
    reg [11:0] x = 12'd0, y = 12'd0;
    reg        frame_start = 1'b0;
    wire [7:0] r, g, b;

    video_tpg #(.H_ACT(H), .V_ACT(V)) dut (
        .pix_clk (clk), .rstn (rstn), .de (de), .x (x), .y (y),
        .frame_start (frame_start), .r (r), .g (g), .b (b)
    );

    integer errors = 0;

    // Present one pixel and return what the pattern makes of it.
    task pixel(input d, input integer px, input integer py);
        begin
            @(negedge clk); de = d; x = px; y = py;
            @(posedge clk); #1;
        end
    endtask

    task expect_px(input [8*48-1:0] what, input integer px, input integer py,
                input [23:0] exp);
        begin
            pixel(1'b1, px, py);
            if ({r, g, b} !== exp) begin
                $display("  FAIL  %0s (%0d,%0d): got %06h, expected %06h",
                         what, px, py, {r, g, b}, exp);
                errors = errors + 1;
            end else
                $display("  ok    %0s (%0d,%0d) = %06h", what, px, py, exp);
        end
    endtask

    task frame; begin
        @(negedge clk); frame_start = 1'b1; @(negedge clk); frame_start = 1'b0;
    end endtask

    integer k;
    reg [23:0] col;

    initial begin
        repeat (3) @(posedge clk); rstn = 1'b1;

        $display("--- blanking is black, even where the border would be white");
        pixel(1'b0, 0, 0);
        if ({r, g, b} !== 24'h000000) begin
            $display("  FAIL  de=0 at (0,0): got %06h", {r, g, b}); errors = errors + 1;
        end else $display("  ok    de=0 at (0,0) = 000000");

        $display("--- the one-pixel white border");
        expect_px("top left",     0,     0,     24'hFFFFFF);
        expect_px("top edge",     50,    0,     24'hFFFFFF);
        expect_px("left edge",    0,     40,    24'hFFFFFF);
        expect_px("right edge",   H - 1, 40,    24'hFFFFFF);
        expect_px("bottom edge",  50,    V - 1, 24'hFFFFFF);

        $display("--- eight bars, each switching on its exact pixel");
        for (k = 0; k < 8; k = k + 1) begin
            col = {{8{k[2]}}, {8{k[1]}}, {8{k[0]}}};
            if (k > 0) expect_px("first pixel of bar", k * 16, 30, col);
            expect_px("last pixel of bar", k * 16 + 15 - (k == 7), 30, col);
        end
        expect_px("last line of the bars", 20, 63, 24'h0000FF);

        $display("--- below the bars: background, the moving bar, the ramp");
        expect_px("background at x = 100", 100, 64, 24'h101010);
        expect_px("moving bar starts at 0", 1, 64, 24'hFFC000);
        expect_px("moving bar, last pixel", 63, 70, 24'hFFC000);
        expect_px("right of the moving bar", 64, 70, 24'h101010);
        expect_px("moving bar, last line", 10, 79, 24'hFFC000);
        expect_px("ramp, first line", 10, 80, {3{8'd19}});
        expect_px("ramp mid-width", 64, 88, {3{8'd127}});
        expect_px("ramp at the right", 126, 88, {3{8'd251}});

        $display("--- the moving bar steps one pixel per frame, and wraps");
        frame;
        expect_px("after one frame, x = 64 is bar", 64, 70, 24'hFFC000);
        expect_px("... and x = 65 is background", 65, 70, 24'h101010);
        for (k = 1; k < H - 64; k = k + 1) frame;
        expect_px("at bar_x = 64, x = 63 is background", 63, 70, 24'h101010);
        expect_px("x = 126 is bar", 126, 70, 24'hFFC000);
        frame;
        expect_px("one more frame wraps it to 0", 1, 70, 24'hFFC000);
        expect_px("... and x = 64 is background again", 64, 70, 24'h101010);

        if (errors == 0) $display("video_tpg_tb: PASS");
        else             $display("video_tpg_tb: FAIL (%0d)", errors);
        $finish;
    end

endmodule
