// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for hdmi_out: the MMCM, the reset that waits for it, the ODDR
// clock, and video_timing and video_tpg wired together as the ADV7511 sees
// them. MODE 2 (640x480, negative syncs) keeps a frame short.
//
// What it pins is the ALIGNMENT at the pins: the ADV7511 samples data, DE
// and the syncs on the same clock edge, so the pixel that arrives with DE's
// first high sample must be the pattern's x = 0, and the pixel with its
// last high sample must be x = 639. The pattern is registered and the timing
// generator's DE is too, so the two are one clock apart inside the module
// unless something lines them up.
//
// The MMCM stub divides its input by two, so the pixel clock in simulation
// is 100 MHz whatever the MMCM is set to. The FREQUENCY is checked instead
// from the MMCM parameters each mode's instance actually carries, computed
// the way the silicon does it: 200 MHz x CLKFBOUT_MULT_F / DIVCLK_DIVIDE /
// CLKOUT0_DIVIDE_F. 720p and 1080p must be exact to 1 ppm; 640x480 within
// CEA-861's +/-0.5%.

`timescale 1ns/1ps

module hdmi_out_tb;

    localparam integer H_ACT = 640, V_ACT = 480, H_FP = 16, H_SY = 96;

    reg clk_200 = 1'b0;
    always #2.5 clk_200 = ~clk_200;

    reg         rstn = 1'b0;
    wire        locked, hdmi_clk, hdmi_de, hdmi_hsync, hdmi_vsync;
    wire [23:0] hdmi_d;

    hdmi_out #(.MODE(2)) dut (
        .clk_200 (clk_200), .rstn (rstn), .locked (locked),
        .hdmi_clk (hdmi_clk), .hdmi_de (hdmi_de),
        .hdmi_hsync (hdmi_hsync), .hdmi_vsync (hdmi_vsync), .hdmi_d (hdmi_d)
    );

    integer errors = 0;
    task fail(input [8*72-1:0] what);
        begin $display("  FAIL  %0s", what); errors = errors + 1; end
    endtask

    // The other two modes, held in reset: only their parameters are read.
    wire unused0, unused1;
    hdmi_out #(.MODE(0)) m720 (
        .clk_200 (clk_200), .rstn (1'b0), .locked (unused0), .hdmi_clk (),
        .hdmi_de (), .hdmi_hsync (), .hdmi_vsync (), .hdmi_d ()
    );
    hdmi_out #(.MODE(1)) m1080 (
        .clk_200 (clk_200), .rstn (1'b0), .locked (unused1), .hdmi_clk (),
        .hdmi_de (), .hdmi_hsync (), .hdmi_vsync (), .hdmi_d ()
    );

    task check_freq(input [8*16-1:0] name, input real mult, input real divclk,
                    input real odiv, input real nominal, input real tol_ppm);
        real f, err;
        begin
            f   = 200.0 * mult / divclk / odiv;
            err = (f - nominal) / nominal * 1.0e6;
            if (err > tol_ppm || err < -tol_ppm) begin
                $display("  FAIL  %0s pixel clock %0.4f MHz, %0.1f ppm from %0.4f",
                         name, f, err, nominal);
                errors = errors + 1;
            end else
                $display("  ok    %0s pixel clock %0.4f MHz (%0.1f ppm; VCO %0.1f MHz)",
                         name, f, err, 200.0 * mult / divclk);
            if (200.0 * mult / divclk < 600.0 || 200.0 * mult / divclk > 1440.0) begin
                $display("  FAIL  %0s VCO outside 600..1440 MHz", name);
                errors = errors + 1;
            end
            if (200.0 / divclk < 10.0) begin
                $display("  FAIL  %0s PFD below 10 MHz", name);
                errors = errors + 1;
            end
        end
    endtask

    // The pixel clock; the pins are sampled on its falling edge, mid-pixel.
    wire pix = dut.pix_clk;

    integer pclks = 0, oclks = 0;
    always @(posedge pix)      pclks = pclks + 1;
    always @(posedge hdmi_clk) oclks = oclks + 1;

    // Scan the stream: px counts pixels in the current DE run, ln the DE runs
    // since the last vsync, gap the blanking pixels from DE falling to hsync.
    // Nothing is checked until the first vsync, so every line is whole.
    integer px = 0, ln = -1000, gap = -1, hsw = 0, runs_checked = 0;
    reg     de_q = 1'b0, vs_q = 1'b1, hs_q = 1'b1;
    reg [23:0] d_prev = 24'h0;
    reg        armed = 1'b0;

    always @(negedge pix) if (armed) begin
        if (!hdmi_vsync && vs_q) ln = -1;
        if (hdmi_de && !de_q) begin
            ln = ln + 1; px = 0;
            // The last blanking pixel before the line is black.
            if (d_prev !== 24'h000000) fail("the pixel before DE rises is not black");
        end
        if (hdmi_de && ln >= 0) begin
            if (ln == 100) begin
                if (px == 0         && hdmi_d !== 24'hFFFFFF) fail("x = 0 is not the white border");
                if (px == 1         && hdmi_d !== 24'h000000) fail("x = 1 is not bar 0 (black)");
                if (px == 79        && hdmi_d !== 24'h000000) fail("x = 79 is not bar 0 (black)");
                if (px == 80        && hdmi_d !== 24'h0000FF) fail("x = 80 is not bar 1 (blue)");
                if (px == 638       && hdmi_d !== 24'hFFFFFF) fail("x = 638 is not bar 7 (white)");
                if (px == H_ACT - 1 && hdmi_d !== 24'hFFFFFF) fail("x = 639 is not the white border");
            end
            if (ln == 0 && hdmi_d !== 24'hFFFFFF) fail("line 0 is not all white");
            px = px + 1;
        end
        if (!hdmi_de && de_q && ln >= 0) begin
            if (px != H_ACT) begin
                $display("  FAIL  line %0d had %0d DE pixels", ln, px); errors = errors + 1;
            end
            if (hdmi_d !== 24'h000000) fail("the pixel after DE falls is not black");
            if (ln == 100) runs_checked = runs_checked + 1;
            gap = 1;
        end else if (gap >= 0 && hdmi_hsync) gap = gap + 1;
        if (!hdmi_hsync && hs_q && gap >= 0) begin
            if (ln == 100 && gap != H_FP) begin
                $display("  FAIL  hsync began %0d pixels after DE, expected %0d", gap, H_FP);
                errors = errors + 1;
            end
            gap = -1; hsw = 0;
        end
        if (!hdmi_hsync) hsw = hsw + 1;
        if (hdmi_hsync && !hs_q && ln == 100 && hsw != H_SY) begin
            $display("  FAIL  hsync lasted %0d pixels, expected %0d", hsw, H_SY);
            errors = errors + 1;
        end
        de_q = hdmi_de; vs_q = hdmi_vsync; hs_q = hdmi_hsync; d_prev = hdmi_d;
    end

    // The forwarded clock must be IN phase with the pixel clock: the ADV7511
    // samples the bus on its rising edge, mid-pixel only when that edge is
    // the pixel clock's. Counting edges alone passes an inverted clock.
    integer oddr_bad = 0;
    always @(posedge pix) if (armed) #0.1 if (hdmi_clk !== 1'b1) oddr_bad = oddr_bad + 1;
    always @(negedge pix) if (armed) #0.1 if (hdmi_clk !== 1'b0) oddr_bad = oddr_bad + 1;

    integer lines_seen;

    initial begin
        check_freq("720p60", m720.pix_mmcm.CLKFBOUT_MULT_F, m720.pix_mmcm.DIVCLK_DIVIDE,
                   m720.pix_mmcm.CLKOUT0_DIVIDE_F, 74.25, 1.0);
        check_freq("1080p60", m1080.pix_mmcm.CLKFBOUT_MULT_F, m1080.pix_mmcm.DIVCLK_DIVIDE,
                   m1080.pix_mmcm.CLKOUT0_DIVIDE_F, 148.5, 1.0);
        check_freq("640x480p60", dut.pix_mmcm.CLKFBOUT_MULT_F, dut.pix_mmcm.DIVCLK_DIVIDE,
                   dut.pix_mmcm.CLKOUT0_DIVIDE_F, 25.175, 5000.0);
        #100;
        if (locked !== 1'b0) fail("locked while the MMCM is in reset");
        rstn = 1'b1;
        @(posedge locked);
        $display("  ok    the MMCM locks once reset is released");
        repeat (3) @(posedge pix);
        if (dut.pix_rstn === 1'b1) fail("the video side left reset early");
        if (hdmi_de !== 1'b0) fail("DE is not low while the video side is in reset");
        repeat (3) @(posedge pix);
        if (dut.pix_rstn !== 1'b1) fail("the video side never left reset");
        else $display("  ok    the video side leaves reset four clocks after lock");

        pclks = 0; oclks = 0;
        armed = 1'b1;
        // A frame and a bit: 800 x 525 pixel clocks, then line 100 of the
        // first whole frame.
        repeat (800 * 525 + 800 * 110) @(posedge pix);
        if (oclks != pclks || pclks == 0 || oddr_bad != 0) begin
            $display("  FAIL  %0d output clocks for %0d pixel clocks, %0d edges out of phase",
                     oclks, pclks, oddr_bad);
            errors = errors + 1;
        end else $display("  ok    the ODDR clock rises with the pixel clock, %0d edges", oclks);
        if (runs_checked != 1) begin
            $display("  FAIL  line 100 was checked %0d times, expected 1", runs_checked);
            errors = errors + 1;
        end else $display("  ok    a whole frame: borders, bars, blanking and hsync on their pixels");

        if (errors == 0) $display("hdmi_out_tb: PASS");
        else             $display("hdmi_out_tb: FAIL (%0d)", errors);
        $finish;
    end

    // The run ends at about 5.1 ms. A clock that never locks must fail the
    // bench, not hang the gate.
    initial begin
        #20_000_000;
        $display("  FAIL  timed out: the MMCM never locked or the frame never finished");
        $display("hdmi_out_tb: FAIL (timeout)");
        $finish;
    end

endmodule
