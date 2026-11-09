// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Framebuffer scanout from a 64-bit AXI3 memory port to the pixel domain.
// This module is simulated but is not instantiated in either board design.
// Pixels use x8r8g8b8 (four bytes); software must use uncached memory or perform
// cache maintenance because the PS HP ports are not coherent.
//
// Two line buffers alternate between AXI writes and synchronous pixel reads.
// Even/odd pixels use separate RAM banks, allowing each 64-bit beat to write
// two pixels while preserving block-RAM inference. A Gray-coded line credit
// and frame toggle coordinate prefetch; frame_start must precede visible video
// by enough blanking to refill the first line. H_ACT must be even and the
// line allocation must cover complete BEATS*8-byte bursts. Addresses/stride
// must obey AXI burst alignment and 4 KiB boundary requirements.
//
// Disabling scanout or starting a frame flushes accepted reads and retains
// an offered AR until handshake. Reset must reset the downstream AXI path too.
// The caller supplies valid in-order memory responses; there is no RRESP
// recovery or display-underflow substitution in this scanout block.

`default_nettype none

module fb_reader #(
    parameter integer H_ACT  = 1280,   // pixels per line
    parameter integer V_ACT  = 720,
    // Beats per burst. 16 x 8 bytes = 128 bytes = 32 pixels.
    parameter integer BEATS  = 16
) (
    // ---- AXI / control domain
    input  wire        clk,
    input  wire        rstn,

    input  wire        enable,          // scanout on
    input  wire [31:0] base_addr,       // byte address of pixel (0,0)
    input  wire [31:0] stride,          // bytes per line; 0 means H_ACT*4

    output reg  [31:0] frames,          // frames fetched, for software
    output reg  [31:0] starve_cycles,   // clocks spent on a line not yet filled

    // ---- video domain
    input  wire        pix_clk,
    input  wire        pix_rstn,
    input  wire        de,              // active pixel now
    input  wire        frame_start,     // one pulse at the top left
    input  wire        line_start,      // one pulse at the left of each line
    output wire [23:0] pixel,           // {R,G,B} for this de cycle

    // ---- AXI3 master (S_AXI_HP: 64-bit, 6-bit ID)
    output wire [5:0]  m_awid,
    output wire [31:0] m_awaddr,
    output wire [3:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire [1:0]  m_awlock,
    output wire [3:0]  m_awcache,
    output wire [2:0]  m_awprot,
    output wire [3:0]  m_awqos,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [5:0]  m_wid,
    output wire [63:0] m_wdata,
    output wire [7:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [5:0]  m_bid,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    output wire [5:0]  m_arid,
    output reg  [31:0] m_araddr,
    output wire [3:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire [1:0]  m_arlock,
    output wire [3:0]  m_arcache,
    output wire [2:0]  m_arprot,
    output wire [3:0]  m_arqos,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [5:0]  m_rid,
    input  wire [63:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready
);

    localparam integer LINE_BYTES  = H_ACT * 4;
    localparam integer BURST_BYTES = BEATS * 8;
    /* verilator lint_off WIDTHTRUNC */
    localparam [3:0]   ARLEN       = BEATS - 1;
    /* verilator lint_on WIDTHTRUNC */
    localparam integer BURSTS_LINE = (LINE_BYTES + BURST_BYTES - 1) / BURST_BYTES;
    localparam integer LINE_PIX    = H_ACT;

    // This design never writes. The write channel exists because the port
    // does; it is tied off rather than left floating.
    assign m_awid = 6'd0;  assign m_awaddr = 32'd0; assign m_awlen = 4'd0;
    assign m_awsize = 3'b011; assign m_awburst = 2'b01; assign m_awlock = 2'b00;
    assign m_awcache = 4'b0011; assign m_awprot = 3'b000; assign m_awqos = 4'd0;
    assign m_awvalid = 1'b0;
    assign m_wid = 6'd0; assign m_wdata = 64'd0; assign m_wstrb = 8'd0;
    assign m_wlast = 1'b0; assign m_wvalid = 1'b0;
    assign m_bready = 1'b1;

    assign m_arid    = 6'd0;
    assign m_arlen   = ARLEN;
    assign m_arsize  = 3'b011;          // 8 bytes
    assign m_arburst = 2'b01;           // INCR
    assign m_arlock  = 2'b00;
    assign m_arcache = 4'b0011;
    assign m_arprot  = 3'b000;
    assign m_arqos   = 4'd0;
    assign m_rready  = 1'b1;

    // ----------------------------------------------------------------------
    // The line buffers: 2 x H_ACT pixels, 32 bits each. Written 2 pixels at a
    // time from the 64-bit AXI beats, read one pixel at a time by the video.
    // ----------------------------------------------------------------------
    // ⚠ EVEN and ODD pixels live in separate banks. A 64-bit beat carries
    // two adjacent pixels, and writing both into one array in one cycle asks
    // for a second write port -- which a block RAM does not have, so Vivado
    // would fall back to distributed RAM and spend thousands of LUTs on what
    // should be a few BRAMs. Split by the low address bit and each bank takes
    // exactly one write per beat.
    reg [31:0] lbuf0_e [0:H_ACT/2-1];
    reg [31:0] lbuf0_o [0:H_ACT/2-1];
    reg [31:0] lbuf1_e [0:H_ACT/2-1];
    reg [31:0] lbuf1_o [0:H_ACT/2-1];

    // ----------------------------------------------------------------------
    // The credit handshake.
    //
    // ⚠ The fill side must NOT free-run: without a credit it overwrites the
    // buffer on screen, which looks like a framebuffer at the wrong address.
    //
    // Two buffers, so at most one line may be filled ahead of the one on
    // screen. The counters are two bits and cross as GRAY CODE: a value
    // sampled mid-transition is either the old one or the new one.
    // ----------------------------------------------------------------------
    reg  [1:0] fill_cnt;                // lines filled, AXI domain
    reg  [1:0] vid_cnt;                 // lines consumed, video domain

    function [1:0] bin2gray;
        input [1:0] b;
        begin bin2gray = b ^ (b >> 1); end
    endfunction
    function [1:0] gray2bin;
        input [1:0] g;
        begin gray2bin = {g[1], g[1] ^ g[0]}; end
    endfunction

    reg [1:0] vid_gray_s1, vid_gray_s2;
    always @(posedge clk) begin
        vid_gray_s1 <= bin2gray(vid_cnt);
        vid_gray_s2 <= vid_gray_s1;
    end
    wire [1:0] vid_cnt_axi   = gray2bin(vid_gray_s2);
    wire [1:0] credits_used  = fill_cnt - vid_cnt_axi;
    // ⚠ ONE line of lookahead: one buffer is displayed while the other fills.
    // Allowing two lets fill_sel wrap onto the buffer being displayed.
    wire       have_space    = (credits_used == 2'd0);

    // frame_start, crossed as a toggle, re-aligns the two sides once a frame
    // while the video is in vertical blanking.
    reg       frame_tog;
    reg [2:0] frame_sync;
    wire frame_sync_pulse = frame_sync[2] ^ frame_sync[1];

    reg [11:0] fill_pix;                // 64-bit word index within the line
    reg [15:0] fill_burst;              // bursts issued for this line
    reg [15:0] fill_done;               // bursts whose data has arrived
    reg [11:0] fill_line;               // which line is being fetched
    reg        filling;

    wire [31:0] line_stride = (stride == 32'd0) ? LINE_BYTES : stride;
    wire        fill_sel    = fill_cnt[0];
    wire [31:0] line_base = base_addr + (fill_line * line_stride);

    // Reads the scanout has stopped caring about. At the top of a frame (or
    // when the scanout is turned off) a line in flight is abandoned, but its
    // AR cannot be withdrawn -- AXI forbids dropping ARVALID before the
    // handshake -- and its data still arrives. `flush` holds off new reads and
    // throws that data away until every accepted burst has returned; without
    // it the stale beats land at the start of the next line.
    reg  [7:0] rd_out;                  // bursts accepted, RLAST not yet seen
    reg        flush;
    wire       ar_fire  = m_arvalid & m_arready;
    wire       r_done   = m_rvalid & m_rlast;          // m_rready is always 1
    wire [7:0] rd_out_n = rd_out + {7'd0, ar_fire} - {7'd0, r_done};

    always @(posedge clk) begin
        if (!rstn) begin
            m_arvalid  <= 1'b0;
            m_araddr   <= 32'd0;
            fill_pix   <= 12'd0;
            fill_burst <= 16'd0;
            fill_done  <= 16'd0;
            fill_line  <= 12'd0;
            filling    <= 1'b0;
            fill_cnt   <= 2'd0;
            frames     <= 32'd0;
            starve_cycles <= 32'd0;
            frame_sync <= 3'b000;
            rd_out     <= 8'd0;
            flush      <= 1'b0;
        end else begin
            frame_sync <= {frame_sync[1:0], frame_tog};
            rd_out     <= rd_out_n;
            if (ar_fire) m_arvalid <= 1'b0;

            if (!enable || frame_sync_pulse) begin
                // ⚠ Re-align at the top of every frame. A line already in
                // flight is abandoned rather than displayed where it does not
                // belong (see `flush`); the vertical blanking that follows is
                // long enough to refill before the first visible line.
                filling    <= 1'b0;
                flush      <= 1'b1;
                fill_burst <= 16'd0;
                fill_done  <= 16'd0;
                fill_pix   <= 12'd0;
                fill_line  <= 12'd0;
                fill_cnt   <= vid_cnt_axi;
                if (enable) frames <= frames + 32'd1;
            end else begin
                if (flush && (rd_out_n == 8'd0) && !m_arvalid)
                    flush <= 1'b0;

                if (!filling && !flush && have_space) begin
                    filling    <= 1'b1;
                    fill_burst <= 16'd0;
                    fill_done  <= 16'd0;
                    fill_pix   <= 12'd0;
                    m_araddr   <= line_base;
                end

                if (filling && !m_arvalid && (fill_burst < BURSTS_LINE)) begin
                    m_arvalid <= 1'b1;
                end
                if (ar_fire && filling) begin
                    m_araddr   <= m_araddr + BURST_BYTES;
                    fill_burst <= fill_burst + 16'd1;
                end

                if (m_rvalid && !flush) begin
                    // fill_pix indexes the 64-bit words, which is also the
                    // index into each half-width bank.
                    if (!fill_sel) begin
                        lbuf0_e[fill_pix[10:0]] <= m_rdata[31:0];
                        lbuf0_o[fill_pix[10:0]] <= m_rdata[63:32];
                    end else begin
                        lbuf1_e[fill_pix[10:0]] <= m_rdata[31:0];
                        lbuf1_o[fill_pix[10:0]] <= m_rdata[63:32];
                    end
                    fill_pix <= fill_pix + 12'd1;
                    if (m_rlast) fill_done <= fill_done + 16'd1;
                end

                if (filling && (fill_done == BURSTS_LINE)) begin
                    filling   <= 1'b0;
                    fill_cnt  <= fill_cnt + 2'd1;
                    fill_line <= (fill_line == V_ACT - 1) ? 12'd0
                                                          : fill_line + 12'd1;
                end

                // ⚠ Clocks the video side spent on a line the fill had not
                // finished: it has consumed one line more than was filled,
                // so credits_used wraps to 3. Sustained, that separates "DRAM
                // cannot keep up" from "pointed at the wrong memory", which
                // look identical on a screen.
                if (credits_used == 2'd3) begin
                    starve_cycles <= starve_cycles + 32'd1;
                end
            end
        end
    end

    // ----------------------------------------------------------------------
    // Video side: one pixel per active clock out of the buffer the AXI side
    // is not filling.
    // ----------------------------------------------------------------------
    reg [11:0] read_pix;

    // The next values of the read counters, computed ahead of the clock so
    // the buffers can be read SYNCHRONOUSLY: a block RAM has only a
    // registered read port. Reading at the address read_pix is about to hold
    // puts that pixel on the output register during the very cycle read_pix
    // holds it -- the same timing a combinational read of read_pix would
    // give, without the distributed RAM such a read forces.
    reg [11:0] read_pix_n;
    reg [1:0]  vid_cnt_n;
    always @(*) begin
        read_pix_n = read_pix;
        vid_cnt_n  = vid_cnt;
        if (!pix_rstn) begin
            read_pix_n = 12'd0;
            vid_cnt_n  = 2'd0;
        end else if (frame_start) begin
            read_pix_n = 12'd0;
            vid_cnt_n  = 2'd0;
        end else if (line_start) begin
            read_pix_n = 12'd0;
            vid_cnt_n  = vid_cnt + 2'd1;
        end else if (de && (read_pix < LINE_PIX - 1)) begin
            read_pix_n = read_pix + 12'd1;
        end
    end

    always @(posedge pix_clk) begin
        read_pix <= read_pix_n;
        vid_cnt  <= vid_cnt_n;
        if (!pix_rstn)        frame_tog <= 1'b0;
        else if (frame_start) frame_tog <= ~frame_tog;
    end

    // One registered read port per bank, each its own block RAM; the bank
    // and buffer are picked after the registers. The buffer being displayed
    // is the one before the next to be consumed.
    wire [10:0] rd_idx_n = read_pix_n[11:1];
    reg  [31:0] q0_e, q0_o, q1_e, q1_o;
    reg         q_sel, q_odd;
    always @(posedge pix_clk) begin
        q0_e  <= lbuf0_e[rd_idx_n];
        q0_o  <= lbuf0_o[rd_idx_n];
        q1_e  <= lbuf1_e[rd_idx_n];
        q1_o  <= lbuf1_o[rd_idx_n];
        q_sel <= ~vid_cnt_n[0];
        q_odd <= read_pix_n[0];
    end

    wire [31:0] px = q_sel ? (q_odd ? q1_o : q1_e) : (q_odd ? q0_o : q0_e);
    assign pixel = px[23:0];            // x8r8g8b8: the top byte is ignored

endmodule

`default_nettype wire
