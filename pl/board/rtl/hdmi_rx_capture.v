// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// ADV7611 parallel video (LLC, DE, HS, VS, P[23:0]) -> AXI4-Stream video as
// UG934 defines it, for the AXI VDMA and the mainline V4L2 pipeline behind it
// (xilinx-vipp + xilinx-dma): TUSER on a frame's first pixel, TLAST on a
// line's last.
//
// ⚠ Frames are found from DE ALONE. VS polarity changes with the mode and is
// programmed by the adv7604 driver, and a wrong guess yields frames offset by
// a vertical blanking interval -- a picture rolled a few lines, which looks
// like a fault in the source. DE has no polarity: lines are runs of DE, and
// a frame boundary is a DE gap longer than two confirmed line periods, which
// every CEA-861 vertical blank (at least five lines) exceeds. HS and VS are
// only watched, for the status registers.
//
// ⚠ The source cannot be stalled: the ADV7611 sends pixels whether or not the
// VDMA is ready, and the VDMA counts beats, so a dropped pixel would shear
// every frame after it. A refused beat therefore abandons the rest of the
// frame; the stream resumes at the next start of frame, the VDMA loses one
// frame, and the stall is counted.

`timescale 1ns / 1ps

`default_nettype none

module hdmi_rx_capture (
    // ----------------------------------------------------------------- pixel
    // Everything here runs on the ADV7611's LLC, which does not exist when
    // nothing is plugged into the HDMI input. No reset in this domain: a
    // reset needs a release synchronized to a clock that may not be running.
    // Every flop has an initial value instead, for simulation and for the
    // bitstream, and `enable` arrives through a synchronizer.
    input  wire        pclk,
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [23:0] d,

    // AXI4-Stream video, in the pclk domain. The top level crosses it into
    // FCLK_CLK0 through axis_cdc_fifo.
    output reg  [23:0] m_tdata,
    output reg         m_tvalid,
    input  wire        m_tready,
    output reg         m_tuser,     // start of frame
    output reg         m_tlast,     // end of line

    // ------------------------------------------------------------- registers
    input  wire        ref_clk,
    input  wire        ref_rstn,
    input  wire        enable,      // ref domain, crossed below
    output reg  [31:0] stat0,       // {h_total, h_active}
    output reg  [31:0] stat1,       // {v_total, v_active}
    output reg  [31:0] stat2,       // {stalls,  frames}
    output reg  [31:0] stat3        // flags and the snapshot counter
);

    // =====================================================================
    // pixel clock domain
    // =====================================================================
    reg [1:0] en_sync = 2'b00;
    wire      en = en_sync[1];
    always @(posedge pclk) en_sync <= {en_sync[0], enable};

    // One stage of input pipeline: stage 0 is the pixel being emitted, and
    // the input itself is one pixel AHEAD of it, which is the only way to
    // know that the pixel being emitted is the last of its line. de1, one
    // behind, gives the edges of DE.
    reg [23:0] d0 = 24'd0;
    reg        de0 = 1'b0, de1 = 1'b0;
    reg        hs0 = 1'b0, vs0 = 1'b0;

    always @(posedge pclk) begin
        d0  <= d;
        de0 <= de;  de1 <= de0;
        hs0 <= hs;  vs0 <= vs;
    end

    // --------------------------------------------------------------- timing
    // Gap since DE last fell, and the period between DE rising edges. Both
    // saturate rather than wrap: a wrapped counter would read as a SHORT gap
    // and invent a frame boundary in the middle of the picture.
    reg [23:0] gap       = 24'd0;   // pclk since DE fell
    reg [23:0] since_r   = 24'd0;   // pclk since DE last rose
    reg [23:0] h_total_m = 24'd0;   // last measured DE-rise to DE-rise
    reg [23:0] h_good    = 24'd0;   // ... and only once two in a row agreed
    reg [15:0] h_run     = 16'd0;   // DE high run length, this line
    reg [15:0] h_act_m   = 16'd0;
    reg [15:0] v_act_c   = 16'd0;   // lines with DE so far, this frame
    reg [15:0] frames    = 16'd0;
    reg [15:0] stalls    = 16'd0;

    wire de_rise = de0 & ~de1;
    wire de_fall = ~de0 & de1;

    // Two line periods, or a large default until a line period is CONFIRMED
    // by two consecutive equal intervals. ⚠ The first interval runs from
    // reset to the first DE and means nothing; trusting it can put the
    // threshold below h-blank and make every line a frame boundary. Two
    // agreeing intervals also re-confirm within two lines of a mode change.
    //
    // ⚠ The default is what judges the first frame after configuration, so
    // it must sit between the largest horizontal blank and the smallest
    // vertical one of any CEA-861 progressive mode: above 2,680 clocks
    // (720p25's h-blank) and below 36,000 (640x480p's v-blank, 45 lines of 800).
    // 16,383 leaves margin both ways.
    localparam [24:0] GAP_DEFAULT = 25'd16383;
    wire [24:0] gap_limit = (h_good == 24'd0) ? GAP_DEFAULT : {h_good, 1'b0};
    wire        new_frame = de_rise & ({1'b0, gap} > gap_limit);

    always @(posedge pclk) begin
        if (de1) gap <= 24'd0;
        else if (~&gap) gap <= gap + 24'd1;

        if (de_rise) begin
            h_total_m <= since_r;
            if (since_r == h_total_m) h_good <= since_r;
            since_r <= 24'd1;
        end else if (~&since_r) begin
            since_r <= since_r + 24'd1;
        end

        // Active pixels in this line. ⚠ The +1: de_fall is asserted on the
        // LAST cycle de1 is high, and h_run has not yet counted that cycle,
        // so the run length is one more than the counter reads. Publishing
        // h_run itself gives 1279 for a 1280-pixel line -- close enough to
        // look right in a log and wrong enough to mis-size every buffer.
        if (de1) h_run <= h_run + 16'd1;
        else     h_run <= 16'd0;
        if (de_fall) h_act_m <= h_run + 16'd1;

        // lines and frames
        if (new_frame) begin
            v_act_c <= 16'd1;
            frames  <= frames + 16'd1;
        end else if (de_rise) begin
            v_act_c <= v_act_c + 16'd1;
        end
    end

    // ------------------------------------------------------- HS / VS watchers
    // Nothing in the datapath depends on these. They exist so that "no
    // picture" can be told apart from "no signal at all", and so a polarity
    // surprise is a number rather than a mystery.
    //
    // v_total counts HS transitions and halves them -- two per line, so a
    // shift and no divider. If HS is dead it reads zero, which is the honest
    // answer and costs nothing, because nothing downstream uses it.
    reg [23:0] vs_hi = 24'd0, vs_lo = 24'd0;
    reg [23:0] hs_hi = 24'd0, hs_lo = 24'd0;
    reg        vs_pol_hi = 1'b0, hs_pol_hi = 1'b0;
    reg        hs_seen = 1'b0, vs_seen = 1'b0, de_seen = 1'b0;
    reg        hs_last = 1'b0, vs_last = 1'b0;
    reg [16:0] hs_edges = 17'd0;
    reg [15:0] v_tot_m  = 16'd0;

    always @(posedge pclk) begin
        hs_last <= hs0;
        vs_last <= vs0;
        if (hs0 != hs_last) begin
            hs_seen  <= 1'b1;
            if (~&hs_edges) hs_edges <= hs_edges + 17'd1;
        end
        if (vs0 != vs_last) vs_seen <= 1'b1;
        if (de1)            de_seen <= 1'b1;

        if (vs0) begin if (~&vs_hi) vs_hi <= vs_hi + 24'd1; end
        else     begin if (~&vs_lo) vs_lo <= vs_lo + 24'd1; end
        if (hs0) begin if (~&hs_hi) hs_hi <= hs_hi + 24'd1; end
        else     begin if (~&hs_lo) hs_lo <= hs_lo + 24'd1; end

        // Decide once a frame, on the same event everything else uses.
        if (new_frame) begin
            vs_pol_hi <= (vs_hi < vs_lo);   // the short level is the active one
            hs_pol_hi <= (hs_hi < hs_lo);
            v_tot_m   <= hs_edges[16:1];    // two transitions per line
            vs_hi <= 24'd0; vs_lo <= 24'd0;
            hs_hi <= 24'd0; hs_lo <= 24'd0;
            hs_edges <= 17'd0;
        end
    end

    // ------------------------------------------------------------- the stream
    // `armed` is high from a start of frame until either the frame ends or a
    // stall abandons it. Emitting only while armed is what makes a stall cost
    // one frame instead of every frame after it.
    reg armed = 1'b0;
    reg bad   = 1'b0;   // sticky: at least one frame was abandoned

    wire stall = m_tvalid & ~m_tready;

    // ⚠ A stall is only an ERROR if it happened inside a frame this block was
    // already streaming. Before the VDMA is started its TREADY sits low, so
    // the first beat of every frame is refused; counting those would report
    // 60 overflows a second at idle and leave the sticky flag set forever,
    // which is exactly the kind of noise that gets a real counter ignored.
    // Both kinds still abandon the frame -- the difference is only whether
    // anyone is told something went wrong.
    wire stall_mid = stall & armed;

    // The beat about to be launched. `new_frame` is computed from de0 and
    // de1, and de0 is the pixel about to be emitted, so the first pixel of a
    // frame and its TUSER are the same beat.
    //
    // A stall suppresses the beat unconditionally, INCLUDING one that would
    // have been a start of frame. Letting a stalled SOF through would emit a
    // TUSER and then immediately go quiet, handing the VDMA a frame one pixel
    // long; waiting for the next SOF costs one more frame and nothing else.
    wire emit = ~stall & (armed | new_frame) & de0;

    always @(posedge pclk) begin
        if (!en) begin
            armed    <= 1'b0;
            bad      <= 1'b0;
            stalls   <= 16'd0;
            m_tvalid <= 1'b0;
            m_tuser  <= 1'b0;
            m_tlast  <= 1'b0;
            m_tdata  <= 24'd0;
        end else begin
            if (stall) begin
                armed <= 1'b0;           // abandon the rest of this frame
                if (stall_mid) begin
                    stalls <= stalls + 16'd1;
                    bad    <= 1'b1;
                end
            end else if (new_frame) begin
                armed <= 1'b1;           // and resynchronize here
            end

            m_tvalid <= emit;
            m_tuser  <= emit & new_frame;
            m_tlast  <= emit & ~de;      // de is one clock ahead of de0
            m_tdata  <= d0;
        end
    end

    // =====================================================================
    // publish to the register domain
    //
    // One toggle carries a whole snapshot. The snapshot is written once a
    // frame and then holds still for the rest of it -- 16 ms at 60 Hz -- so
    // sampling it two reference clocks after the toggle arrives is reading a
    // value that has been stable for six orders of magnitude longer than any
    // skew across the fabric. The XDC says so.
    // =====================================================================
    reg [31:0] snap0 = 32'd0, snap1 = 32'd0, snap2 = 32'd0;
    reg [7:0]  snap3 = 8'd0;
    reg        tog = 1'b0;

    always @(posedge pclk) begin
        if (new_frame) begin
            snap0 <= {h_total_m[15:0], h_act_m};
            snap1 <= {v_tot_m,         v_act_c};
            snap2 <= {stalls,          frames};
            snap3 <= {en, bad, armed, hs_pol_hi,
                      vs_pol_hi, vs_seen, hs_seen, de_seen};
            tog   <= ~tog;
        end
    end

    reg [2:0] tsync;
    reg [7:0] updates;
    always @(posedge ref_clk) begin
        if (!ref_rstn) begin
            tsync   <= 3'b000;
            updates <= 8'd0;
            stat0   <= 32'd0;
            stat1   <= 32'd0;
            stat2   <= 32'd0;
            stat3   <= 32'd0;
        end else begin
            tsync <= {tsync[1:0], tog};
            if (tsync[2] != tsync[1]) begin
                // ⚠ `updates` is the reason a dead LLC cannot be mistaken for
                // a black picture: with no pixel clock nothing here ever
                // fires, so every status register keeps its reset value AND
                // this counter stays at zero. Zeroes alone would be
                // ambiguous.
                updates <= updates + 8'd1;
                stat0   <= snap0;
                stat1   <= snap1;
                stat2   <= snap2;
                stat3   <= {16'd0, updates + 8'd1, snap3};
            end
        end
    end

endmodule

`default_nettype wire
