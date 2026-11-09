// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for axi_owner: two masters, one slave, and a handover that has to not
// break either of them.
//
// The masters are two real axi_bist engines rather than a hand-rolled traffic
// generator, which buys two things. They issue proper AXI4 with outstanding
// bursts, so the handover logic meets realistic traffic; and each one has a
// watchdog, so "the error responder hung the master it was refusing" shows up
// as STATUS[3] instead of as a simulation that never ends.
//
// What is checked:
//   1. the owner reaches memory and verifies its own pattern
//   2. the one that does NOT own it gets SLVERR -- and, more importantly,
//      gets it promptly rather than hanging
//   3. a handover requested mid-burst is DEFERRED until the bus is idle;
//      switching immediately would leave the slave waiting for write beats
//      from a master that no longer owns the data channel
//   4. after the handover the new owner works and the old one errors
//   5. ownership returns to A and A works again
//   6. a B response arriving with nothing outstanding leaves the counts at
//      zero, and a handover after it still completes
//   7. a refused read of 256 beats, the AXI4 maximum, gets exactly 256 beats
//   8. a handover waits for the error responder too: a refused master part
//      way through a write burst finishes it, and gets its SLVERR, before
//      the bus moves -- and no write beat ever reaches the slave without
//      the address it belongs to
//
// Run: pl/sim/run.sh

`timescale 1ns / 1ps

module axi_owner_tb;

    localparam integer DW   = 32;
    localparam integer IDW  = 12;
    localparam integer LENW = 8;
    localparam integer BEATS = 16;

    reg clk = 1'b0, rstn = 1'b0;
    always #5 clk = ~clk;

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

    // ------------------------------------------------------- register buses
    reg  [3:0]  aw_ = 0, ar_ = 0, bw_ = 0, br_ = 0;
    reg         awe = 0, bwe = 0;
    reg  [31:0] awd = 0, bwd = 0;
    wire [31:0] ard, brd;
    wire        airq, birq;

    task wra; input [3:0] a; input [31:0] d;
        begin @(posedge clk); aw_ <= a; awd <= d; awe <= 1'b1;
              @(posedge clk); awe <= 1'b0; end
    endtask
    task rda; input [3:0] a; output [31:0] d;
        begin @(posedge clk); ar_ <= a; @(posedge clk); #1 d = ard; end
    endtask
    task wrb; input [3:0] a; input [31:0] d;
        begin @(posedge clk); bw_ <= a; bwd <= d; bwe <= 1'b1;
              @(posedge clk); bwe <= 1'b0; end
    endtask
    task rdb; input [3:0] a; output [31:0] d;
        begin @(posedge clk); br_ <= a; @(posedge clk); #1 d = brd; end
    endtask

    // ------------------------------------------------------------ the buses
    `define AXI_BUNDLE(p) \
        wire [IDW-1:0]  p``_awid, p``_wid, p``_bid, p``_arid, p``_rid; \
        wire [31:0]     p``_awaddr, p``_araddr; \
        wire [LENW-1:0] p``_awlen, p``_arlen; \
        wire [2:0]      p``_awsize, p``_arsize, p``_awprot, p``_arprot; \
        wire [1:0]      p``_awburst, p``_arburst, p``_awlock, p``_arlock, \
                        p``_bresp, p``_rresp; \
        wire [3:0]      p``_awcache, p``_arcache, p``_awqos, p``_arqos; \
        wire [DW-1:0]   p``_wdata, p``_rdata; \
        wire [DW/8-1:0] p``_wstrb; \
        wire            p``_awvalid, p``_awready, p``_wvalid, p``_wready, \
                        p``_wlast, p``_bvalid, p``_bready, p``_arvalid, \
                        p``_arready, p``_rvalid, p``_rready, p``_rlast;

    `AXI_BUNDLE(a)
    `AXI_BUNDLE(b)
    `AXI_BUNDLE(m)

    `define BIST(inst, p, rwa, rwe, rwd, rra, rrd, irqo) \
        axi_bist #(.DW(DW), .IDW(IDW), .LENW(LENW), .BEATS(BEATS), \
                   .MAXOUT(4), .WDOG(11)) inst ( \
            .clk(clk), .rstn(rstn), \
            .reg_waddr(rwa), .reg_we(rwe), .reg_wdata(rwd), \
            .reg_raddr(rra), .reg_rdata(rrd), .irq(irqo), \
            .m_awid(p``_awid), .m_awaddr(p``_awaddr), .m_awlen(p``_awlen), \
            .m_awsize(p``_awsize), .m_awburst(p``_awburst), \
            .m_awlock(p``_awlock), .m_awcache(p``_awcache), \
            .m_awprot(p``_awprot), .m_awqos(p``_awqos), \
            .m_awvalid(p``_awvalid), .m_awready(p``_awready), \
            .m_wid(p``_wid), .m_wdata(p``_wdata), .m_wstrb(p``_wstrb), \
            .m_wlast(p``_wlast), .m_wvalid(p``_wvalid), .m_wready(p``_wready), \
            .m_bid(p``_bid), .m_bresp(p``_bresp), .m_bvalid(p``_bvalid), \
            .m_bready(p``_bready), \
            .m_arid(p``_arid), .m_araddr(p``_araddr), .m_arlen(p``_arlen), \
            .m_arsize(p``_arsize), .m_arburst(p``_arburst), \
            .m_arlock(p``_arlock), .m_arcache(p``_arcache), \
            .m_arprot(p``_arprot), .m_arqos(p``_arqos), \
            .m_arvalid(p``_arvalid), .m_arready(p``_arready), \
            .m_rid(p``_rid), .m_rdata(p``_rdata), .m_rresp(p``_rresp), \
            .m_rlast(p``_rlast), .m_rvalid(p``_rvalid), .m_rready(p``_rready) \
        );

    `BIST(mstr_a, a, aw_, awe, awd, ar_, ard, airq)
    `BIST(mstr_b, b, bw_, bwe, bwd, br_, brd, birq)

    reg  sel = 1'b0;
    wire owner, switching;
    wire [2:0] dbg;
    wire [3:0] dbg_aw, dbg_ar;

    axi_owner #(.DW(DW), .IDW(IDW), .LENW(LENW)) dut (
        .clk(clk), .rstn(rstn), .sel(sel), .owner(owner),
        .switching(switching),
        .dbg_w_busy_aw_ar(dbg), .dbg_aw_out(dbg_aw), .dbg_ar_out(dbg_ar),
        .a_awid(a_awid), .a_awaddr(a_awaddr), .a_awlen(a_awlen),
        .a_awsize(a_awsize), .a_awburst(a_awburst), .a_awlock(a_awlock[0]),
        .a_awcache(a_awcache), .a_awprot(a_awprot), .a_awqos(a_awqos),
        .a_awvalid(a_awvalid), .a_awready(a_awready),
        .a_wdata(a_wdata), .a_wstrb(a_wstrb), .a_wlast(a_wlast),
        .a_wvalid(a_wvalid), .a_wready(a_wready),
        .a_bid(a_bid), .a_bresp(a_bresp), .a_bvalid(a_bvalid),
        .a_bready(a_bready),
        .a_arid(a_arid), .a_araddr(a_araddr), .a_arlen(a_arlen),
        .a_arsize(a_arsize), .a_arburst(a_arburst), .a_arlock(a_arlock[0]),
        .a_arcache(a_arcache), .a_arprot(a_arprot), .a_arqos(a_arqos),
        .a_arvalid(a_arvalid), .a_arready(a_arready),
        .a_rid(a_rid), .a_rdata(a_rdata), .a_rresp(a_rresp),
        .a_rlast(a_rlast), .a_rvalid(a_rvalid), .a_rready(a_rready),

        .b_awid(b_awid), .b_awaddr(b_awaddr), .b_awlen(b_awlen),
        .b_awsize(b_awsize), .b_awburst(b_awburst), .b_awlock(b_awlock[0]),
        .b_awcache(b_awcache), .b_awprot(b_awprot), .b_awqos(b_awqos),
        .b_awvalid(b_awvalid), .b_awready(b_awready),
        .b_wdata(b_wdata), .b_wstrb(b_wstrb), .b_wlast(b_wlast),
        .b_wvalid(b_wvalid), .b_wready(b_wready),
        .b_bid(b_bid), .b_bresp(b_bresp), .b_bvalid(b_bvalid),
        .b_bready(b_bready),
        .b_arid(b_arid), .b_araddr(b_araddr), .b_arlen(b_arlen),
        .b_arsize(b_arsize), .b_arburst(b_arburst), .b_arlock(b_arlock[0]),
        .b_arcache(b_arcache), .b_arprot(b_arprot), .b_arqos(b_arqos),
        .b_arvalid(b_arvalid), .b_arready(b_arready),
        .b_rid(b_rid), .b_rdata(b_rdata), .b_rresp(b_rresp),
        .b_rlast(b_rlast), .b_rvalid(b_rvalid), .b_rready(b_rready),

        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awlock(m_awlock[0]),
        .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awqos(m_awqos),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arlock(m_arlock[0]),
        .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arqos(m_arqos),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp),
        .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    // The final protocol fixture supplies a legal write-first slave directly;
    // the memory BFM only accepts write data after queueing an address.
    reg direct_slave = 1'b0;
    axi_mem_bfm #(.DW(DW), .IDW(IDW), .LENW(LENW), .WORDS(8192),
                  .STALL(20), .RLAT(5)) mem (
        .clk(clk), .rstn(rstn && !direct_slave),
        .dead(1'b0), .corrupt_en(1'b0),
        .corrupt_addr(32'd0), .corrupt_xor(32'd0),
        .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen),
        .s_awsize(m_awsize), .s_awburst(m_awburst),
        .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wid(m_wid), .s_wdata(m_wdata), .s_wstrb(m_wstrb),
        .s_wlast(m_wlast), .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bid(m_bid), .s_bresp(m_bresp), .s_bvalid(m_bvalid),
        .s_bready(m_bready),
        .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen),
        .s_arsize(m_arsize), .s_arburst(m_arburst),
        .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp),
        .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready)
    );

    localparam [31:0]  BASE   = 32'h0000_0400;
    localparam integer BURSTS = 6;

    reg [31:0] st, ec;
    integer timeout;

    task start_a; input [31:0] ctrl;
        begin wra(4'd1, BASE); wra(4'd2, BURSTS); wra(4'd3, 32'hC0FFEE00);
              wra(4'd0, ctrl); end
    endtask
    task start_b; input [31:0] ctrl;
        begin wrb(4'd1, BASE); wrb(4'd2, BURSTS); wrb(4'd3, 32'hC0FFEE00);
              wrb(4'd0, ctrl); end
    endtask

    task wait_a;
        begin
            timeout = 0; st = 0;
            while (!st[1] && timeout < 100000) begin rda(4'd4, st); timeout = timeout + 1; end
            if (timeout >= 100000) begin
                $display("  FAIL  master A never finished"); errors = errors + 1;
            end
        end
    endtask
    task wait_b;
        begin
            timeout = 0; st = 0;
            while (!st[1] && timeout < 100000) begin rdb(4'd4, st); timeout = timeout + 1; end
            if (timeout >= 100000) begin
                $display("  FAIL  master B never finished"); errors = errors + 1;
            end
        end
    endtask

    localparam [31:0] GO_WR = {22'd0, 2'd2, 3'd0, 1'b0, 3'd0, 1'b1};

    // ---------------------------------------------------------- monitors
    // A handover made while the error responder was mid-transaction: its
    // remaining write beats would reach the slave with no address, and its
    // pending response would go to the other master. owner_q and ebusy_q
    // hold the state the handover on the previous edge was decided from.
    reg     owner_q = 1'b0, ebusy_q = 1'b0;
    integer handover_busy = 0;
    always @(posedge clk) begin
        if (rstn && owner !== owner_q && ebusy_q) handover_busy = handover_busy + 1;
        owner_q <= owner;
        ebusy_q <= dut.e_w_active | dut.e_bvalid | dut.e_rvalid;
    end

    // Write beats reaching the slave with no accepted address to belong to.
    integer m_open = 0, orphan_w = 0, open_now;
    always @(posedge clk) if (rstn) begin
        open_now = m_open + ((m_awvalid && m_awready) ? 1 : 0);
        if (m_wvalid && m_wready) begin
            if (open_now == 0) orphan_w = orphan_w + 1;
            else if (m_wlast)  open_now = open_now - 1;
        end
        m_open = open_now;
    end

    // Master B's handshakes, for section 8, which drives B's channels itself.
    integer b_aws = 0, b_ws = 0, b_resps = 0;
    reg [IDW-1:0] b_last_bid = 0;
    reg [1:0]     b_last_bresp = 0;
    always @(posedge clk) begin
        if (b_awvalid && b_awready) b_aws = b_aws + 1;
        if (b_wvalid && b_wready)   b_ws  = b_ws + 1;
        if (b_bvalid && b_bready) begin
            b_resps = b_resps + 1; b_last_bid <= b_bid; b_last_bresp <= b_bresp;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        $display("[1] master A owns the bus");
        check(owner === 1'b0, "owner starts at A");
        start_a(GO_WR); wait_a;
        rda(4'd5, ec);  check(ec == 32'd0, "A wrote and verified cleanly");
        rda(4'd4, st);  check(st[3] === 1'b0, "A did not trip its watchdog");

        $display("[2] master B is refused, and is refused promptly");
        start_b(GO_WR); wait_b;
        rdb(4'd5, ec);  check(ec > 32'd0, "B saw errors (SLVERR), not silence");
        rdb(4'd4, st);  check(st[3] === 1'b0,
                              "B did NOT hang -- the error responder answered");

        $display("[3] the handover waits for the bus to go idle");
        start_a(GO_WR);
        // Ask for the switch while A is definitely mid-run.
        repeat (20) @(posedge clk);
        rda(4'd4, st);
        check(st[0] === 1'b1, "A is still busy when the switch is requested");
        sel = 1'b1;
        // Two edges and a step past them, so a switch that ignored idle has
        // had time to land; A must still have work outstanding.
        repeat (2) @(posedge clk);
        #1;
        check(owner === 1'b0 && switching === 1'b1 && dbg[0] === 1'b0,
              "ownership has NOT moved while A has transactions outstanding");
        wait_a;
        rda(4'd5, ec);
        rda(4'd4, st);
        // ⚠ A does NOT finish cleanly, and should not. It loses the bus part
        // way through, so every burst it had not yet issued is answered
        // SLVERR and counted. What matters is the SHAPE of the failure: the
        // run ENDS, with errors, instead of hanging -- a master left waiting
        // on a READY that never comes is the thing this module exists to
        // prevent, and on this board it means a JTAG reset.
        check(ec > 32'd0, "A reports errors for the work it lost the bus for");
        check(st[3] === 1'b0, "A still did not hang -- it was refused, not ignored");
        // once idle, it moves
        timeout = 0;
        while (owner !== 1'b1 && timeout < 1000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check(owner === 1'b1, "ownership moved to B once the bus went idle");

        $display("[4] now B works and A is refused");
        start_b(GO_WR); wait_b;
        rdb(4'd5, ec);  check(ec == 32'd0, "B wrote and verified cleanly");
        rdb(4'd4, st);  check(st[3] === 1'b0, "B did not trip its watchdog");

        start_a(GO_WR); wait_a;
        rda(4'd5, ec);  check(ec > 32'd0, "A now sees SLVERR");
        rda(4'd4, st);  check(st[3] === 1'b0, "A did not hang either");

        $display("[5] and back again");
        sel = 1'b0;
        timeout = 0;
        while (owner !== 1'b0 && timeout < 1000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check(owner === 1'b0, "ownership returned to A");
        start_a(GO_WR); wait_a;
        rda(4'd5, ec);  check(ec == 32'd0, "A works again");

        // ------------------------------- 6. an unexpected response
        // ⚠ A B beat arriving while nothing is outstanding must not take the
        // counter from 0 to 255: `idle` could then never be true again, and
        // the switch would never happen while the bus worked perfectly. The
        // decrements clamp at zero. This drives exactly that: a B response with no
        // matching AW, then a handover that must still complete.
        $display("[6] a response arriving with nothing outstanding");
        sel = 1'b1;
        while (owner !== 1'b1) @(posedge clk);
        sel = 1'b0;
        while (owner !== 1'b0) @(posedge clk);
        check(dbg_aw == 4'd0 && dbg_ar == 4'd0,
              "the outstanding counts are back to zero");
        // There is no legal way to make the BFM emit an unsolicited B, and
        // the whole question is what happens if one ever arrives -- so it is
        // forced onto the wire for a cycle with nothing outstanding.
        force m_bvalid = 1'b1;
        @(posedge clk);
        release m_bvalid;
        repeat (3) @(posedge clk);
        check(dbg_aw == 4'd0,
              "the count clamped at zero instead of wrapping to 255");
        sel = 1'b1;
        timeout = 0;
        while (owner !== 1'b1 && timeout < 1000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check(owner === 1'b1,
              "and the handover still completes -- no permanent wedge");
        sel = 1'b0;
        while (owner !== 1'b0) @(posedge clk);

        // ------------------------------- 7. the longest read, refused
        // The error responder must return exactly arlen+1 beats for every
        // arlen the bus allows, including the AXI4 maximum of 255 (256
        // beats). B is idle and does not own the bus, so its AR and R
        // channels are driven here directly.
        $display("[7] a refused 256-beat read gets 256 beats, RLAST on the last");
        begin : longest
            integer beats, lasts, last_at;
            beats = 0; lasts = 0; last_at = -1;
            force b_arlen   = 8'd255;
            force b_arid    = 12'h5A5;
            force b_rready  = 1'b1;
            force b_arvalid = 1'b1;
            @(posedge clk);
            while (b_arready !== 1'b1) @(posedge clk);
            #1 force b_arvalid = 1'b0;
            timeout = 0;
            while (timeout < 2000 && last_at < 0) begin
                @(posedge clk);
                if (b_rvalid === 1'b1) begin
                    beats = beats + 1;
                    if (b_rlast === 1'b1) begin lasts = lasts + 1; last_at = beats; end
                end
                timeout = timeout + 1;
            end
            repeat (20) @(posedge clk);
            if (b_rvalid === 1'b1) beats = beats + 1000;   // still talking
            release b_arlen; release b_arid; release b_rready; release b_arvalid;
            $display("        beats %0d, RLAST at beat %0d", beats, last_at);
            check(beats == 256, "exactly 256 beats came back");
            check(lasts == 1 && last_at == 256, "RLAST on beat 256 and no other");
        end

        // ------------------------------- 8. a handover with a refusal in flight
        // A owns the bus and is idle, so by the outstanding counts alone the
        // switch could happen at once. But B, refused, is two beats into a
        // four-beat write burst in the error responder. The bus must not move
        // until that burst is finished and answered.
        $display("[8] a handover while the refused master is mid-burst");
        begin : midburst
            integer aws0, ws0, resps0;
            check(owner === 1'b0 && dbg[0] === 1'b1, "A owns the bus and is idle");
            aws0 = b_aws; ws0 = b_ws; resps0 = b_resps;
            @(negedge clk);
            force b_awid = 12'h3C3; force b_awlen = 8'd3; force b_bready = 1'b1;
            force b_wlast = 1'b0; force b_wvalid = 1'b0; force b_awvalid = 1'b1;
            timeout = 0;
            while (b_aws == aws0 && timeout < 100) begin @(negedge clk); timeout = timeout + 1; end
            force b_awvalid = 1'b0;
            force b_wvalid = 1'b1;
            while (b_ws < ws0 + 2 && timeout < 200) begin @(negedge clk); timeout = timeout + 1; end
            force b_wvalid = 1'b0;
            sel = 1'b1;
            repeat (10) @(negedge clk);
            check(owner === 1'b0, "the bus waits for B's refused burst to finish");
            force b_wvalid = 1'b1;
            while (b_ws < ws0 + 4 && timeout < 300) begin
                if (b_ws == ws0 + 3) force b_wlast = 1'b1;
                @(negedge clk); timeout = timeout + 1;
            end
            force b_wvalid = 1'b0; force b_wlast = 1'b0;
            timeout = 0;
            while (b_resps == resps0 && timeout < 100) begin @(negedge clk); timeout = timeout + 1; end
            check(b_resps == resps0 + 1 && b_last_bresp == 2'b10 && b_last_bid == 12'h3C3,
                  "B's burst is answered: SLVERR, with its own ID");
            timeout = 0;
            while (owner !== 1'b1 && timeout < 100) begin @(negedge clk); timeout = timeout + 1; end
            check(owner === 1'b1, "then the bus moves to B");
            release b_awid; release b_awlen; release b_bready;
            release b_wlast; release b_wvalid; release b_awvalid;
            sel = 1'b0;
            timeout = 0;
            while (owner !== 1'b0 && timeout < 100) begin @(negedge clk); timeout = timeout + 1; end
        end
        check(orphan_w == 0, "no write beat reached the slave without its address");
        check(handover_busy == 0, "the bus never moved with the error responder mid-transaction");

        $display("[9] handover preserves stalled address offers and their responses");
        @(negedge clk);
        force a_awvalid = 1'b1; force a_awaddr = 32'h1000;
        // The memory BFM models the single ID zero used by the BIST engines.
        force a_awlen = 0; force a_awid = 0;
        force a_arvalid = 1'b1; force a_araddr = 32'h1000;
        force a_arlen = 0; force a_arid = 0;
        force a_wvalid = 1'b0; force a_wlast = 1'b1;
        force a_bready = 1'b0; force a_rready = 1'b0;
        force m_awready = 1'b0; force m_arready = 1'b0;
        repeat (2) @(negedge clk);
        sel = 1'b1;
        repeat (5) begin
            #1;
            check(m_awvalid === 1'b1 && m_arvalid === 1'b1,
                  "offered address VALID survives switch request");
            check(owner === 1'b0, "owner holds while addresses await READY");
            @(negedge clk);
        end
        release m_awready; release m_arready;
        fork
            begin
                wait(a_awready === 1'b1); @(posedge clk);
                #1 force a_awvalid = 1'b0;
                force a_wvalid = 1'b1;
                wait(a_wready === 1'b1); @(posedge clk);
                #1 force a_wvalid = 1'b0;
            end
            begin
                wait(a_arready === 1'b1); @(posedge clk);
                #1 force a_arvalid = 1'b0;
            end
        join
        wait(a_bvalid === 1'b1 && a_rvalid === 1'b1);
        repeat (3) @(negedge clk);
        check(owner === 1'b0 && a_bvalid === 1'b1 && a_rvalid === 1'b1 &&
              b_bvalid === 1'b0 && b_rvalid === 1'b0,
              "responses stay with original master until accepted");
        force a_bready = 1'b1; force a_rready = 1'b1;
        repeat (5) @(negedge clk);
        check(owner === 1'b1, "switch follows completion of held offers");
        release a_awvalid; release a_awaddr; release a_awlen; release a_awid;
        release a_arvalid; release a_araddr; release a_arlen; release a_arid;
        release a_wvalid; release a_wlast; release a_bready; release a_rready;
        sel = 1'b0;
        repeat (3) @(negedge clk);

        $display("[10] AWREADY may depend on WVALID, including during handover");
        force a_wvalid = 1'b1; force a_wlast = 1'b1;
        force a_awvalid = 1'b0; force a_awlen = 0; force a_awaddr = 32'h1004;
        force a_bready = 1'b0;
        // Legal slave dependency: the address waits until data is offered.
        force m_awready = m_wvalid;
        repeat (2) @(negedge clk);
        check(m_wvalid === 1'b1, "WVALID does not wait for AWREADY");
        sel = 1'b1;
        repeat (3) @(negedge clk);
        check(owner === 1'b0 && m_wvalid === 1'b1,
              "offered write data holds owner and VALID during handover");
        force a_awvalid = 1'b1;
        timeout = 0;
        while (a_awready !== 1'b1 && timeout < 100) begin @(negedge clk); timeout = timeout + 1; end
        check(a_awready === 1'b1, "matching address can drain during handover");
        @(posedge clk); #1 force a_awvalid = 1'b0;
        wait(a_wready === 1'b1); @(posedge clk); #1;
        force a_wvalid = 1'b0;
        wait(a_bvalid === 1'b1);
        @(negedge clk);
        check(owner === 1'b0, "write response drains before ownership moves");
        force a_bready = 1'b1;
        repeat (5) @(negedge clk);
        check(owner === 1'b1, "write-first handover completes");
        release a_wvalid; release a_wlast; release m_awready;
        release a_awvalid; release a_awlen; release a_awaddr; release a_bready;

        $display("[11] accepted write data can precede its address");
        sel = 1'b0;
        repeat (3) @(negedge clk);
        direct_slave = 1'b1;
        force m_awready = 1'b0; force m_wready = 1'b1;
        force m_bvalid = 1'b0;
        force a_awvalid = 1'b0; force a_wvalid = 1'b1;
        force a_wlast = 1'b0; force a_bready = 1'b0;
        @(negedge clk);
        check(dut.w_partial === 1'b1, "first data beat accepted before AW");
        force a_wvalid = 1'b0;
        sel = 1'b1;
        repeat (3) @(negedge clk);
        check(owner === 1'b0, "partial write data prevents handover");
        force a_wvalid = 1'b1; force a_wlast = 1'b1;
        @(negedge clk);
        force a_wvalid = 1'b0;
        repeat (3) @(negedge clk);
        check(owner === 1'b0 && dut.w_balance == -1,
              "complete write data still awaits its address");
        force a_awvalid = 1'b1; force m_awready = 1'b1;
        @(negedge clk);
        force a_awvalid = 1'b0; force m_awready = 1'b0;
        check(owner === 1'b0 && dut.w_balance == 0,
              "matching AW balances data without switching before response");
        force m_bvalid = 1'b1;
        repeat (3) @(negedge clk);
        check(owner === 1'b0, "write-first response holds original owner");
        force a_bready = 1'b1;
        @(negedge clk); force m_bvalid = 1'b0;
        repeat (3) @(negedge clk);
        check(owner === 1'b1, "write-first transaction drains and handover completes");
        release m_awready; release m_wready; release m_bvalid;
        release a_awvalid; release a_wvalid; release a_wlast; release a_bready;

        $display("");
        if (errors == 0) $display("axi_owner_tb: PASS");
        else             $display("axi_owner_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("axi_owner_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
