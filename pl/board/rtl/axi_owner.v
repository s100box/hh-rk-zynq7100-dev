// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Two-master AXI4 ownership switch for the MIG path. The selected master
// reaches memory; the other receives SLVERR, including every beat of a read
// burst. A requested handover blocks new addresses while preserving stalled
// offers, outstanding write data and both sides' responses. Write data and
// addresses may arrive in either order; ownership changes after all work drains.
// The switch preserves ID width because it never interleaves the two masters.

`default_nettype none

module axi_owner #(
    parameter integer DW  = 32,
    parameter integer IDW = 12,
    parameter integer LENW = 8        // AXI4
) (
    input  wire            clk,
    input  wire            rstn,

    input  wire            sel,       // 0 = master A (the CPU), 1 = master B
    output reg             owner,     // who actually has it
    output wire            switching, // a request is pending, waiting for idle
    // Why a handover is still waiting, for software: dbg_w_busy_aw_ar is
    // {0, w_busy, idle}, and dbg_aw_out/dbg_ar_out are the low four bits of
    // the outstanding counts. Without them a stuck `switching` is silent.
    output wire [2:0]      dbg_w_busy_aw_ar,
    output wire [3:0]      dbg_aw_out,
    output wire [3:0]      dbg_ar_out,

    // ---- master A (from the CPU's protocol converter)
    input  wire [IDW-1:0]  a_awid,
    input  wire [31:0]     a_awaddr,
    input  wire [LENW-1:0] a_awlen,
    input  wire [2:0]      a_awsize,
    input  wire [1:0]      a_awburst,
    input  wire [0:0]      a_awlock,
    input  wire [3:0]      a_awcache,
    input  wire [2:0]      a_awprot,
    input  wire [3:0]      a_awqos,
    input  wire            a_awvalid,
    output wire            a_awready,
    input  wire [DW-1:0]   a_wdata,
    input  wire [DW/8-1:0] a_wstrb,
    input  wire            a_wlast,
    input  wire            a_wvalid,
    output wire            a_wready,
    output wire [IDW-1:0]  a_bid,
    output wire [1:0]      a_bresp,
    output wire            a_bvalid,
    input  wire            a_bready,
    input  wire [IDW-1:0]  a_arid,
    input  wire [31:0]     a_araddr,
    input  wire [LENW-1:0] a_arlen,
    input  wire [2:0]      a_arsize,
    input  wire [1:0]      a_arburst,
    input  wire [0:0]      a_arlock,
    input  wire [3:0]      a_arcache,
    input  wire [2:0]      a_arprot,
    input  wire [3:0]      a_arqos,
    input  wire            a_arvalid,
    output wire            a_arready,
    output wire [IDW-1:0]  a_rid,
    output wire [DW-1:0]   a_rdata,
    output wire [1:0]      a_rresp,
    output wire            a_rlast,
    output wire            a_rvalid,
    input  wire            a_rready,

    // ---- master B (the BIST engine)
    input  wire [IDW-1:0]  b_awid,
    input  wire [31:0]     b_awaddr,
    input  wire [LENW-1:0] b_awlen,
    input  wire [2:0]      b_awsize,
    input  wire [1:0]      b_awburst,
    input  wire [0:0]      b_awlock,
    input  wire [3:0]      b_awcache,
    input  wire [2:0]      b_awprot,
    input  wire [3:0]      b_awqos,
    input  wire            b_awvalid,
    output wire            b_awready,
    input  wire [DW-1:0]   b_wdata,
    input  wire [DW/8-1:0] b_wstrb,
    input  wire            b_wlast,
    input  wire            b_wvalid,
    output wire            b_wready,
    output wire [IDW-1:0]  b_bid,
    output wire [1:0]      b_bresp,
    output wire            b_bvalid,
    input  wire            b_bready,
    input  wire [IDW-1:0]  b_arid,
    input  wire [31:0]     b_araddr,
    input  wire [LENW-1:0] b_arlen,
    input  wire [2:0]      b_arsize,
    input  wire [1:0]      b_arburst,
    input  wire [0:0]      b_arlock,
    input  wire [3:0]      b_arcache,
    input  wire [2:0]      b_arprot,
    input  wire [3:0]      b_arqos,
    input  wire            b_arvalid,
    output wire            b_arready,
    output wire [IDW-1:0]  b_rid,
    output wire [DW-1:0]   b_rdata,
    output wire [1:0]      b_rresp,
    output wire            b_rlast,
    output wire            b_rvalid,
    input  wire            b_rready,

    // ---- the slave (the MIG's clock converter)
    output wire [IDW-1:0]  m_awid,
    output wire [31:0]     m_awaddr,
    output wire [LENW-1:0] m_awlen,
    output wire [2:0]      m_awsize,
    output wire [1:0]      m_awburst,
    output wire [0:0]      m_awlock,
    output wire [3:0]      m_awcache,
    output wire [2:0]      m_awprot,
    output wire [3:0]      m_awqos,
    output wire            m_awvalid,
    input  wire            m_awready,
    output wire [DW-1:0]   m_wdata,
    output wire [DW/8-1:0] m_wstrb,
    output wire            m_wlast,
    output wire            m_wvalid,
    input  wire            m_wready,
    input  wire [IDW-1:0]  m_bid,
    input  wire [1:0]      m_bresp,
    input  wire            m_bvalid,
    output wire            m_bready,
    output wire [IDW-1:0]  m_arid,
    output wire [31:0]     m_araddr,
    output wire [LENW-1:0] m_arlen,
    output wire [2:0]      m_arsize,
    output wire [1:0]      m_arburst,
    output wire [0:0]      m_arlock,
    output wire [3:0]      m_arcache,
    output wire [2:0]      m_arprot,
    output wire [3:0]      m_arqos,
    output wire            m_arvalid,
    input  wire            m_arready,
    input  wire [IDW-1:0]  m_rid,
    input  wire [DW-1:0]   m_rdata,
    input  wire [1:0]      m_rresp,
    input  wire            m_rlast,
    input  wire            m_rvalid,
    output wire            m_rready
);

    // ----------------------------------------------------------------------
    // Outstanding transactions on the master side. Ownership only moves when
    // all three counts are zero: no write address without its response, no
    // write burst part-way through its data, no read without its last beat.
    // ----------------------------------------------------------------------
    reg [7:0] aw_out;      // AW accepted, B not yet returned
    reg [7:0] ar_out;      // AR accepted, RLAST not yet returned
    // Signed balance also tracks complete W bursts that precede their AW.
    reg signed [8:0] w_balance; // accepted AW minus accepted WLAST
    reg w_partial;             // a W burst has started but not reached WLAST
    wire w_busy = (w_balance != 0) || w_partial;
    reg aw_held, ar_held, w_held; // offers already sampled with READY low

    // The error responder's state (it is described below, where it runs).
    reg            e_bvalid;
    reg [IDW-1:0]  e_bid;
    reg            e_w_active;
    reg            e_rvalid;
    reg [IDW-1:0]  e_rid;
    reg [LENW:0]   e_rleft;
    wire           e_idle = !e_w_active && !e_bvalid && !e_rvalid;

    wire m_aw_fire = m_awvalid & m_awready;
    wire m_w_fire  = m_wvalid  & m_wready;
    wire m_b_fire  = m_bvalid  & m_bready;
    wire m_ar_fire = m_arvalid & m_arready;
    wire m_r_fire  = m_rvalid  & m_rready;

    wire idle = (aw_out == 8'd0) && (ar_out == 8'd0) && !w_busy;
    assign switching = (sel != owner);

    assign dbg_w_busy_aw_ar = {1'b0, w_busy, idle};
    assign dbg_aw_out       = aw_out[3:0];
    assign dbg_ar_out       = ar_out[3:0];

    always @(posedge clk) begin
        if (!rstn) begin
            aw_out <= 8'd0;
            ar_out <= 8'd0;
            w_balance <= 9'sd0;
            w_partial <= 1'b0;
            aw_held <= 1'b0;
            ar_held <= 1'b0;
            w_held <= 1'b0;
            owner  <= 1'b0;
        end else begin
            // ⚠ The decrements are CLAMPED at zero. A single unexpected B or
            // R beat -- one the slave emits while its own reset is releasing
            // -- would otherwise take a count from 0 to 255, and `idle`, and
            // with it the handover, would never come true again.
            if (m_aw_fire && !m_b_fire) aw_out <= aw_out + 8'd1;
            else if (!m_aw_fire && m_b_fire && (aw_out != 8'd0))
                aw_out <= aw_out - 8'd1;

            if (m_ar_fire && !(m_r_fire && m_rlast)) ar_out <= ar_out + 8'd1;
            else if (!m_ar_fire && (m_r_fire && m_rlast) && (ar_out != 8'd0))
                ar_out <= ar_out - 8'd1;

            aw_held <= m_awvalid && !m_awready;
            ar_held <= m_arvalid && !m_arready;
            w_held <= m_wvalid && !m_wready;
            if (m_w_fire) w_partial <= !m_wlast;
            if (m_aw_fire && !(m_w_fire && m_wlast)) w_balance <= w_balance + 9'sd1;
            else if (!m_aw_fire && m_w_fire && m_wlast)
                w_balance <= w_balance - 9'sd1;

            // The handover point. Deferring it is the whole reason this
            // module has state at all. The error responder must be quiet
            // too: a refused burst still taking write beats, or a response
            // still to deliver, belongs to the master being refused, and
            // after the switch its beats would reach the slave with no
            // address and its response would go to the other master.
            if (switching && idle && e_idle && !m_awvalid && !m_arvalid && !m_wvalid)
                owner <= sel;
        end
    end

    // ----------------------------------------------------------------------
    // The crossbar. `owner` picks which master reaches the slave; the other
    // one is answered by the error responder below.
    // ----------------------------------------------------------------------
    wire sel_b = owner;

    assign m_awid    = sel_b ? b_awid    : a_awid;
    assign m_awaddr  = sel_b ? b_awaddr  : a_awaddr;
    assign m_awlen   = sel_b ? b_awlen   : a_awlen;
    assign m_awsize  = sel_b ? b_awsize  : a_awsize;
    assign m_awburst = sel_b ? b_awburst : a_awburst;
    assign m_awlock  = sel_b ? b_awlock  : a_awlock;
    assign m_awcache = sel_b ? b_awcache : a_awcache;
    assign m_awprot  = sel_b ? b_awprot  : a_awprot;
    assign m_awqos   = sel_b ? b_awqos   : a_awqos;
    // Block new addresses during handover, but never withdraw an address
    // already offered to a stalled slave. Its master holds the payload until
    // acceptance, and ownership remains unchanged until its response drains.
    // During drain, permit the address needed by data already accepted or
    // offered. Likewise permit data for an accepted address. Neither VALID
    // depends on downstream READY, avoiding cross-channel dependency deadlock.
    wire aw_needed = (w_balance < 0) ||
                     (w_balance == 0 && (w_partial || w_held));
    wire aw_allowed = !switching || aw_held || aw_needed;
    wire ar_allowed = !switching || ar_held;
    wire w_allowed = !switching || w_held || w_partial || (w_balance > 0);
    assign m_awvalid = !aw_allowed ? 1'b0
                     : (sel_b ? b_awvalid : a_awvalid);

    assign m_wdata   = sel_b ? b_wdata : a_wdata;
    assign m_wstrb   = sel_b ? b_wstrb : a_wstrb;
    assign m_wlast   = sel_b ? b_wlast : a_wlast;
    assign m_wvalid  = w_allowed && (sel_b ? b_wvalid : a_wvalid);

    assign m_bready  = sel_b ? b_bready : a_bready;

    assign m_arid    = sel_b ? b_arid    : a_arid;
    assign m_araddr  = sel_b ? b_araddr  : a_araddr;
    assign m_arlen   = sel_b ? b_arlen   : a_arlen;
    assign m_arsize  = sel_b ? b_arsize  : a_arsize;
    assign m_arburst = sel_b ? b_arburst : a_arburst;
    assign m_arlock  = sel_b ? b_arlock  : a_arlock;
    assign m_arcache = sel_b ? b_arcache : a_arcache;
    assign m_arprot  = sel_b ? b_arprot  : a_arprot;
    assign m_arqos   = sel_b ? b_arqos   : a_arqos;
    assign m_arvalid = !ar_allowed ? 1'b0
                     : (sel_b ? b_arvalid : a_arvalid);

    assign m_rready  = sel_b ? b_rready : a_rready;

    // ----------------------------------------------------------------------
    // The error responder for whichever master does not own the bus.
    //
    // It must consume a whole write burst before answering, and return
    // exactly arlen+1 read beats, or the master it is refusing will hang
    // waiting for beats. e_rleft is one bit wider than LEN, so the longest
    // burst the bus allows -- arlen 2^LENW-1, 256 beats in AXI4 -- is counted
    // rather than wrapping to zero.
    // ----------------------------------------------------------------------

    wire e_awvalid = sel_b ? a_awvalid : b_awvalid;
    wire e_wvalid  = sel_b ? a_wvalid  : b_wvalid;
    wire e_wlast   = sel_b ? a_wlast   : b_wlast;
    wire e_bready  = sel_b ? a_bready  : b_bready;
    wire e_arvalid = sel_b ? a_arvalid : b_arvalid;
    wire e_rready  = sel_b ? a_rready  : b_rready;
    wire [IDW-1:0]  e_awid_in = sel_b ? a_awid  : b_awid;
    wire [IDW-1:0]  e_arid_in = sel_b ? a_arid  : b_arid;
    wire [LENW-1:0] e_arlen_in = sel_b ? a_arlen : b_arlen;

    // While a switch is pending the responder takes no new burst, as the
    // owner's side takes none, so both drain and the handover can happen.
    wire e_awready = !e_w_active && !e_bvalid && !switching;
    wire e_wready  = e_w_active;
    wire e_arready = (e_rleft == 0) && !e_rvalid && !switching;

    always @(posedge clk) begin
        if (!rstn) begin
            e_bvalid   <= 1'b0;
            e_bid      <= {IDW{1'b0}};
            e_w_active <= 1'b0;
            e_rvalid   <= 1'b0;
            e_rid      <= {IDW{1'b0}};
            e_rleft    <= {(LENW+1){1'b0}};
        end else begin
            if (e_awvalid && e_awready) begin
                e_w_active <= 1'b1;
                e_bid      <= e_awid_in;
            end
            if (e_wvalid && e_wready && e_wlast) begin
                e_w_active <= 1'b0;
                e_bvalid   <= 1'b1;
            end
            if (e_bvalid && e_bready) e_bvalid <= 1'b0;

            if (e_arvalid && e_arready) begin
                e_rid    <= e_arid_in;
                e_rleft  <= {1'b0, e_arlen_in} + 1'b1;
                e_rvalid <= 1'b1;
            end else if (e_rvalid && e_rready) begin
                if (e_rleft <= 1) begin
                    e_rvalid <= 1'b0;
                    e_rleft  <= {(LENW+1){1'b0}};
                end else begin
                    e_rleft <= e_rleft - 1'b1;
                end
            end
        end
    end

    wire e_rlast = (e_rleft <= 1);

    // ---- back to the two masters
    assign a_awready = sel_b ? e_awready : (aw_allowed && m_awready);
    assign a_wready  = sel_b ? e_wready  : (w_allowed && m_wready);
    assign a_bid     = sel_b ? e_bid     : m_bid;
    assign a_bresp   = sel_b ? 2'b10     : m_bresp;      // SLVERR
    assign a_bvalid  = sel_b ? e_bvalid  : m_bvalid;
    assign a_arready = sel_b ? e_arready : (ar_allowed && m_arready);
    assign a_rid     = sel_b ? e_rid     : m_rid;
    assign a_rdata   = sel_b ? {DW{1'b0}} : m_rdata;
    assign a_rresp   = sel_b ? 2'b10     : m_rresp;      // SLVERR
    assign a_rlast   = sel_b ? e_rlast   : m_rlast;
    assign a_rvalid  = sel_b ? e_rvalid  : m_rvalid;

    assign b_awready = sel_b ? (aw_allowed && m_awready) : e_awready;
    assign b_wready  = sel_b ? (w_allowed && m_wready) : e_wready;
    assign b_bid     = sel_b ? m_bid     : e_bid;
    assign b_bresp   = sel_b ? m_bresp   : 2'b10;
    assign b_bvalid  = sel_b ? m_bvalid  : e_bvalid;
    assign b_arready = sel_b ? (ar_allowed && m_arready) : e_arready;
    assign b_rid     = sel_b ? m_rid     : e_rid;
    assign b_rdata   = sel_b ? m_rdata   : {DW{1'b0}};
    assign b_rresp   = sel_b ? m_rresp   : 2'b10;
    assign b_rlast   = sel_b ? m_rlast   : e_rlast;
    assign b_rvalid  = sel_b ? m_rvalid  : e_rvalid;

endmodule

`default_nettype wire
