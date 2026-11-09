// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// cam_guard -- between the CSI-2 receiver's video output and the camera VDMA.
//
// ⚠ WHY THIS EXISTS. The receiver cannot be stalled. Its video frame buffer
// holds a few lines, and when back-pressure fills it, xilinx-csi2rxss answers
// the "stream line buffer full" interrupt by DISABLING THE CORE until the
// stream is stopped. One slow moment at the VDMA therefore ends the whole
// stream, with the sensor still sending and nothing arriving.
//
// So this block always accepts what the receiver sends. Beats go into a FIFO
// (2048 beats, one pixel each: a whole line at 1296x972 and below, part of
// one at 1920 and 2592 wide) and out to the VDMA as it takes them. If the
// FIFO fills anyway, the rest of that frame is dropped and the block waits
// for the next start of frame (TUSER) before passing anything again: the
// VDMA sees one short frame, which it recovers from on the next SOF, and the
// stream carries on. It starts in that waiting state and returns to it
// whenever the input has been idle for IDLE clocks -- longer than any gap
// between lines, shorter than vertical blanking -- so every stream that
// begins mid-frame, first or later, is cut to whole frames.
//
// guard_off = 1 restores plain back-pressure -- the receiver is stalled when
// the FIFO is full -- to compare the two on the same bitstream.
//
// The counters are free-running, for software to difference:
//   sof_in     frame starts that arrived from the receiver
//   sof_out    frame starts the VDMA took
//   drop_beats beats thrown away, overflow or waiting for SOF
//   stall      cycles the receiver was held off (guard_off only)
//   beats_out  beats the VDMA took

`default_nettype none

module cam_guard #(
    parameter integer DW = 16,
    parameter integer AW = 11,            // 2048 beats, one pixel each
    parameter integer IDLE = 20000        // 200 us at 100 MHz
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          guard_off,

    input  wire [DW-1:0] s_tdata,
    input  wire          s_tuser,
    input  wire          s_tlast,
    input  wire          s_tvalid,
    output wire          s_tready,

    output wire [DW-1:0] m_tdata,
    output wire          m_tuser,
    output wire          m_tlast,
    output wire          m_tvalid,
    input  wire          m_tready,

    output reg  [31:0]   sof_in,
    output reg  [31:0]   sof_out,
    output reg  [31:0]   drop_beats,
    output reg  [31:0]   stall,
    output reg  [31:0]   beats_out
);

    wire          f_wready;
    wire [DW+1:0] f_rdata;
    reg           synced;
    reg  [31:0]   idle_cnt;

    // Guarded: take every beat; write it if the frame is in step and there
    // is room. Plain: take a beat only when there is room.
    wire want  = guard_off ? 1'b1 : (synced | s_tuser);
    wire wr    = s_tvalid & want & f_wready;
    assign s_tready = guard_off ? f_wready : 1'b1;

    always @(posedge clk) begin
        if (!rstn) begin
            synced     <= 1'b0;
            idle_cnt   <= 32'd0;
            sof_in     <= 32'd0;
            sof_out    <= 32'd0;
            drop_beats <= 32'd0;
            stall      <= 32'd0;
            beats_out  <= 32'd0;
        end else begin
            if (s_tvalid && s_tready && s_tuser) sof_in <= sof_in + 32'd1;
            if (s_tvalid) idle_cnt <= 32'd0;
            else if (idle_cnt != IDLE) idle_cnt <= idle_cnt + 32'd1;
            else synced <= 1'b0;                  // a new stream starts at a SOF
            if (!guard_off && s_tvalid) begin
                if (wr && s_tuser)
                    synced <= 1'b1;               // in step from this frame
                else if (!wr) begin
                    synced     <= 1'b0;           // out of step until the next SOF
                    drop_beats <= drop_beats + 32'd1;
                end
            end
            if (guard_off && s_tvalid && !f_wready) stall <= stall + 32'd1;
            if (m_tvalid && m_tready) begin
                beats_out <= beats_out + 32'd1;
                if (m_tuser) sof_out <= sof_out + 32'd1;
            end
        end
    end

    // One clock on both sides: the FIFO's gray-code crossing is then only
    // two cycles of pessimism on full and empty.
    axis_cdc_fifo #(.DW(DW + 2), .AW(AW)) fifo (
        .wclk   (clk),
        .wdata  ({s_tuser, s_tlast, s_tdata}),
        .wvalid (wr),
        .wready (f_wready),
        .rclk   (clk),
        .rrstn  (rstn),
        .rdata  (f_rdata),
        .rvalid (m_tvalid),
        .rready (m_tready)
    );
    assign m_tuser = f_rdata[DW+1];
    assign m_tlast = f_rdata[DW];
    assign m_tdata = f_rdata[DW-1:0];

endmodule

`default_nettype wire
