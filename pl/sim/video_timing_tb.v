// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for video_timing. It counts one line in each mode and a whole 640x480
// frame, and checks the numbers against CEA-861 rather than against the
// module's own parameters --
// the constants are written out here a second time, from the standard, so a
// typo in one copy disagrees with the other instead of being confirmed by it.
//
// ⚠ Sync POLARITY is checked explicitly. A generator with the right counts
// and the wrong polarity produces a picture a monitor will often still lock
// to, offset or with a black bar, and no amount of staring at `de` reveals
// it. 720p and 1080p are positive on both syncs; 640x480 is negative on both.
//
// ⚠ Hsync POSITION is checked too. Putting the pulse at the start of the line
// rather than after the front porch is the classic off-by-a-porch error, and
// it also produces a picture that nearly works.

`timescale 1ns / 1ps

module video_timing_tb;

    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] what;
        begin
            if (!cond) begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end else $display("  ok    %0s", what);
        end
    endtask
    task check_eq;
        input integer got;
        input integer want;
        input [8*64-1:0] what;
        begin
            if (got !== want) begin
                $display("  FAIL  %0s: got %0d, wanted %0d", what, got, want);
                errors = errors + 1;
            end else $display("  ok    %0s = %0d", what, got);
        end
    endtask

    reg clk = 1'b0, rstn = 1'b0;
    always #5 clk = ~clk;

    wire hs0, vs0, de0, fs0; wire [11:0] x0, y0;
    wire hs1, vs1, de1, fs1; wire [11:0] x1, y1;
    wire hs2, vs2, de2, fs2; wire [11:0] x2, y2;

    video_timing #(.MODE(0)) m720 (.pix_clk(clk), .rstn(rstn),
        .hsync(hs0), .vsync(vs0), .de(de0), .x(x0), .y(y0), .frame_start(fs0));
    video_timing #(.MODE(1)) m1080 (.pix_clk(clk), .rstn(rstn),
        .hsync(hs1), .vsync(vs1), .de(de1), .x(x1), .y(y1), .frame_start(fs1));
    video_timing #(.MODE(2)) mvga (.pix_clk(clk), .rstn(rstn),
        .hsync(hs2), .vsync(vs2), .de(de2), .x(x2), .y(y2), .frame_start(fs2));

    // CEA-861 formats 4, 16 and 1, written out again from the standard.
    integer H_ACT[0:2]; integer H_FP[0:2]; integer H_SY[0:2]; integer H_BP[0:2];
    integer V_ACT[0:2]; integer V_FP[0:2]; integer V_SY[0:2]; integer V_BP[0:2];
    integer HPOS[0:2];  integer VPOS[0:2];

    initial begin
        H_ACT[0]=1280; H_FP[0]=110; H_SY[0]= 40; H_BP[0]=220;
        V_ACT[0]= 720; V_FP[0]=  5; V_SY[0]=  5; V_BP[0]= 20;
        HPOS[0]=1; VPOS[0]=1;

        H_ACT[1]=1920; H_FP[1]= 88; H_SY[1]= 44; H_BP[1]=148;
        V_ACT[1]=1080; V_FP[1]=  4; V_SY[1]=  5; V_BP[1]= 36;
        HPOS[1]=1; VPOS[1]=1;

        H_ACT[2]= 640; H_FP[2]= 16; H_SY[2]= 96; H_BP[2]= 48;
        V_ACT[2]= 480; V_FP[2]= 10; V_SY[2]=  2; V_BP[2]= 33;
        HPOS[2]=0; VPOS[2]=0;
    end

    integer i;

    // -------- one line of each mode, then a whole frame ---------------
    integer m;
    integer hcount, vcount, act_cols, act_rows, hsw, vsw, hs_at;
    reg     last_de, last_hs, last_vs;

    initial begin
        repeat (4) @(posedge clk);
        rstn = 1'b1;

        for (m = 0; m < 3; m = m + 1) begin
            $display("[%0d] %0dx%0d", m, H_ACT[m], V_ACT[m]);

            // Wait for a frame boundary on the instance under test.
            case (m)
                0: @(posedge fs0);
                1: @(posedge fs1);
                default: @(posedge fs2);
            endcase

            hcount = 0; act_cols = 0; hsw = 0; hs_at = -1;
            last_hs = (m == 2) ? 1'b1 : 1'b0;
            // one full line
            for (i = 0; i < H_ACT[m] + H_FP[m] + H_SY[m] + H_BP[m]; i = i + 1) begin
                @(posedge clk); #1;
                case (m)
                    0: begin
                        if (de0) act_cols = act_cols + 1;
                        if (hs0 == HPOS[m][0]) begin
                            hsw = hsw + 1;
                            if (hs_at < 0) hs_at = i;
                        end
                    end
                    1: begin
                        if (de1) act_cols = act_cols + 1;
                        if (hs1 == HPOS[m][0]) begin
                            hsw = hsw + 1;
                            if (hs_at < 0) hs_at = i;
                        end
                    end
                    default: begin
                        if (de2) act_cols = act_cols + 1;
                        if (hs2 == HPOS[m][0]) begin
                            hsw = hsw + 1;
                            if (hs_at < 0) hs_at = i;
                        end
                    end
                endcase
                hcount = hcount + 1;
            end

            check_eq(act_cols, H_ACT[m], "active pixels per line");
            check_eq(hsw,      H_SY[m],  "hsync width");
            // The sync starts one clock later than the raw counter because
            // the outputs are registered; allow for that single pipeline stage.
            check(hs_at == H_ACT[m] + H_FP[m] + 1 ||
                  hs_at == H_ACT[m] + H_FP[m],
                  "hsync starts after the front porch, not at column 0");
        end

        // ------------------------------------------------ whole frames
        $display("[3] a whole 640x480 frame");
        @(posedge fs2);
        act_rows = 0; vsw = 0; last_de = 1'b0;
        for (i = 0; i < (640+16+96+48) * (480+10+2+33); i = i + 1) begin
            @(posedge clk); #1;
            if (de2 && !last_de) act_rows = act_rows + 1;
            last_de = de2;
            if (vs2 == VPOS[2][0]) vsw = vsw + 1;
        end
        check_eq(act_rows, 480, "active lines per frame");
        check_eq(vsw, 2 * (640+16+96+48), "vsync width in pixel clocks");

        $display("[4] sync polarity");
        // Outside any sync pulse, the idle level is the inactive polarity.
        @(posedge fs0);
        repeat (5) @(posedge clk); #1;
        check(hs0 === 1'b0 && vs0 === 1'b0,
              "720p idles low  (both syncs positive)");
        @(posedge fs2);
        repeat (5) @(posedge clk); #1;
        check(hs2 === 1'b1 && vs2 === 1'b1,
              "640x480 idles high (both syncs negative)");

        $display("");
        if (errors == 0) $display("video_timing_tb: PASS");
        else             $display("video_timing_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("video_timing_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
