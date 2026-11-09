// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// The same engine in its other shape: 32-bit data, 12-bit ID, AXI4 (8-bit
// LEN, no WID). That is how the MIG's slave port is generated, so this is
// the configuration that tests PL DDR3 from inside the fabric.
//
// It is a smaller bench than axi_bist_tb because the logic is the same
// module; what is being checked here is that the PARAMETERS work -- the
// narrower data path, the wider ID port, and the 8-bit burst length. A pattern
// that assumed 64-bit lanes, or a LEN field that overflowed at 4 bits, would
// show up as a mismatch or a hang. The bursts are 32 beats, twice what the
// designs use, because 16 beats still fit in four bits of LEN.

`timescale 1ns / 1ps

module axi_bist_axi4_tb;

    localparam integer DW    = 32;     // the MIG slave is 32 bits wide
    localparam integer IDW   = 12;
    localparam integer LENW  = 8;      // AXI4
    localparam integer BEATS = 32;     // BEATS-1 needs more than four bits

    reg clk = 1'b0, rstn = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    task check;
        input cond;
        input [8*48-1:0] what;
        begin
            if (!cond) begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end else $display("  ok    %0s", what);
        end
    endtask

    reg  [3:0]  reg_waddr = 4'd0;
    reg  [3:0]  reg_raddr = 4'd0;
    reg         reg_we = 1'b0;
    reg  [31:0] reg_wdata = 32'd0;
    wire [31:0] reg_rdata;
    wire        irq;

    task wr;
        input [3:0] a; input [31:0] d;
        begin
            @(posedge clk); reg_waddr <= a; reg_wdata <= d; reg_we <= 1'b1;
            @(posedge clk); reg_we <= 1'b0;
        end
    endtask
    task rd;
        input [3:0] a; output [31:0] d;
        begin @(posedge clk); reg_raddr <= a; @(posedge clk); #1 d = reg_rdata; end
    endtask

    wire [IDW-1:0]  awid, wid, bid, arid, rid;
    wire [31:0]     awaddr, araddr;
    wire [LENW-1:0] awlen, arlen;
    wire [2:0]      awsize, arsize, awprot, arprot;
    wire [1:0]      awburst, arburst, awlock, arlock, bresp, rresp;
    wire [3:0]      awcache, arcache, awqos, arqos;
    wire [DW-1:0]   wdata, rdata;
    wire [DW/8-1:0] wstrb;
    wire awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire arvalid, arready, rvalid, rready, rlast;

    reg        corrupt_en = 1'b0;
    reg [31:0] corrupt_addr = 32'd0, corrupt_xor = 32'd0;

    axi_bist #(.DW(DW), .IDW(IDW), .LENW(LENW), .BEATS(BEATS),
               .MAXOUT(4), .WDOG(12)) dut (
        .clk(clk), .rstn(rstn),
        .reg_waddr(reg_waddr), .reg_we(reg_we), .reg_wdata(reg_wdata),
        .reg_raddr(reg_raddr),
        .reg_rdata(reg_rdata), .irq(irq),
        .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awlock(awlock), .m_awcache(awcache),
        .m_awprot(awprot), .m_awqos(awqos), .m_awvalid(awvalid),
        .m_awready(awready),
        .m_wid(wid), .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast),
        .m_wvalid(wvalid), .m_wready(wready),
        .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arlock(arlock), .m_arcache(arcache),
        .m_arprot(arprot), .m_arqos(arqos), .m_arvalid(arvalid),
        .m_arready(arready),
        .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast),
        .m_rvalid(rvalid), .m_rready(rready)
    );

    axi_mem_bfm #(.DW(DW), .IDW(IDW), .LENW(LENW), .WORDS(4096),
                  .STALL(25), .RLAT(6)) mem (
        .clk(clk), .rstn(rstn),
        .dead(1'b0), .corrupt_en(corrupt_en),
        .corrupt_addr(corrupt_addr), .corrupt_xor(corrupt_xor),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
        .s_awburst(awburst), .s_awvalid(awvalid), .s_awready(awready),
        .s_wid(wid), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
        .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
        .s_arburst(arburst), .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast),
        .s_rvalid(rvalid), .s_rready(rready)
    );

    localparam [31:0]  BASE   = 32'h0000_0800;
    localparam integer BURSTS = 12;

    reg [31:0] st, ec, bt, ba;
    integer timeout;

    task run_and_wait;
        input [31:0] ctrl;
        begin
            wr(4'd0, ctrl);
            timeout = 0; st = 32'd0;
            while (!st[1] && timeout < 200000) begin
                rd(4'd4, st); timeout = timeout + 1;
            end
            if (timeout >= 200000) begin
                $display("  FAIL  engine never reported done");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        $display("[1] 32-bit AXI4 write then read, %0d bursts", BURSTS);
        wr(4'd1, BASE);
        wr(4'd2, BURSTS);
        wr(4'd3, 32'hDEAD_BEEF);
        run_and_wait({22'd0, 2'd2, 3'd0, 1'b0, 3'd0, 1'b1});
        rd(4'd5, ec); rd(4'd11, bt);
        check(ec == 32'd0, "no errors");
        check(bt == BURSTS*BEATS*2, "every beat accounted for");

        // AWLEN must carry BEATS-1 in eight bits, not wrap at four
        check(awlen == (BEATS-1), "AWLEN holds BEATS-1");

        $display("[2] a flipped bit is still caught at 32 bits");
        corrupt_addr = BASE + 5*4;
        corrupt_xor  = 32'h8000_0000;
        corrupt_en   = 1'b1;
        run_and_wait({22'd0, 2'd1, 3'd0, 1'b0, 3'd0, 1'b1});
        rd(4'd5, ec); rd(4'd8, ba);
        check(ec > 32'd0, "detected");
        check(ba == corrupt_addr, "at the right address");
        corrupt_en = 1'b0;

        $display("");
        if (errors == 0) $display("axi_bist_axi4_tb: PASS");
        else             $display("axi_bist_axi4_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("axi_bist_axi4_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
