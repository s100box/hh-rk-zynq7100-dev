// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for axi_bist, against the stalling memory BFM.
//
// ⚠ The bench deliberately does NOT reimplement the pattern function. If it
// did, and the pattern were wrong, both copies would be wrong together and
// every comparison would pass -- the checker would be comparing X to X. What
// it checks instead are properties the pattern must have whatever it is:
//
//   * memory does not end up holding the same word everywhere
//   * two different addresses hold different words
//   * moving a VALID word from one address to another is detected, which is
//     what proves the pattern really depends on the address and that the
//     checker really looks -- an LFSR pattern would sail through this
//   * flipping a bit is detected, and reported at the right address
//   * a slave that stops answering trips the watchdog instead of hanging
//
// Run: pl/sim/run.sh

`timescale 1ns / 1ps

module axi_bist_tb;

    localparam integer DW    = 64;
    localparam integer IDW   = 6;
    localparam integer LENW  = 4;      // AXI3, like S_AXI_HP
    localparam integer BEATS = 16;

    reg clk = 1'b0, rstn = 1'b0;
    always #5 clk = ~clk;              // 100 MHz

    integer errors = 0;

    task check;
        input cond;
        input [8*48-1:0] what;
        begin
            if (!cond) begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end else begin
                $display("  ok    %0s", what);
            end
        end
    endtask

    // ------------------------------------------------------------ registers
    reg  [3:0]  reg_waddr = 4'd0;
    reg  [3:0]  reg_raddr = 4'd0;
    reg         reg_we   = 1'b0;
    reg  [31:0] reg_wdata = 32'd0;
    wire [31:0] reg_rdata;
    wire        irq;

    task wr;
        input [3:0] a;
        input [31:0] d;
        begin
            @(posedge clk);
            reg_waddr <= a;
            reg_wdata <= d;
            reg_we    <= 1'b1;
            @(posedge clk);
            reg_we    <= 1'b0;
        end
    endtask

    task rd;
        input [3:0] a;
        output [31:0] d;
        begin
            @(posedge clk);
            reg_raddr <= a;
            @(posedge clk);
            #1 d = reg_rdata;
        end
    endtask

    // ------------------------------------------------------------- the pair
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

    reg        dead = 1'b0, corrupt_en = 1'b0;
    reg [31:0] corrupt_addr = 32'd0, corrupt_xor = 32'd0;

    axi_bist #(.DW(DW), .IDW(IDW), .LENW(LENW), .BEATS(BEATS),
               .MAXOUT(4), .WDOG(10)) dut (
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
                  .STALL(30), .RLAT(4)) mem (
        .clk(clk), .rstn(rstn),
        .dead(dead), .corrupt_en(corrupt_en),
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

    localparam [31:0] BASE   = 32'h0000_1000;
    localparam integer BURSTS = 8;
    localparam integer BB     = BEATS * (DW/8);     // bytes per burst

    reg [31:0] st, ec, bt, cy, ba, eb;
    reg [DW-1:0] w0, w1, w2;
    integer timeout;
    integer stop_mode, bursts_before, stall_samples, sample_index;

    task run_and_wait;
        input [31:0] ctrl;
        begin
            wr(4'd0, ctrl);
            timeout = 0;
            st = 32'd0;
            while (!st[1] && timeout < 200000) begin
                rd(4'd4, st);
                timeout = timeout + 1;
            end
            if (timeout >= 200000) begin
                $display("  FAIL  engine never reported done");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("axi_bist_tb.vcd");
        $dumpvars(0, axi_bist_tb);

        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        // STALL=30 is a percentage, not a signed-random comparison bias.
        // A broad bound checks its meaning without depending on RNG details.
        stall_samples = 0;
        for (sample_index = 0; sample_index < 20000; sample_index = sample_index + 1)
            if (mem.stall_now(0)) stall_samples = stall_samples + 1;
        check(stall_samples > 4000 && stall_samples < 8000,
              "memory STALL=30 gives about thirty percent stalls");

        // ---------------------------------------------------- 1. write+read
        $display("[1] write then read back, %0d bursts of %0d beats", BURSTS, BEATS);
        wr(4'd1, BASE);
        wr(4'd2, BURSTS);
        wr(4'd3, 32'h1234_5678);
        run_and_wait({22'd0, 2'd2, 3'd0, 1'b1, 3'd0, 1'b1});   // mode 2, irq_en, start

        rd(4'd5, ec); rd(4'd11, bt); rd(4'd6, cy);
        check(ec == 32'd0, "no errors on a clean write+read");
        check(bt == BURSTS*BEATS*2, "beat count = writes + reads");
        check(cy > BURSTS*BEATS, "cycle counter ran");
        check(irq === 1'b1, "irq asserted after done");

        // the pattern must actually vary with address
        mem.peek(BASE,        w0);
        mem.peek(BASE + 8,    w1);
        mem.peek(BASE + BB,   w2);
        check(w0 !== w1, "adjacent beats differ");
        check(w0 !== w2, "beats a burst apart differ");
        check(w0 !== {DW{1'b0}}, "memory is not still zero");

        // irq clears on ack
        wr(4'd12, 32'd1);
        @(posedge clk);
        check(irq === 1'b0, "irq cleared by ACK");

        // ------------------------------------------- 2. a moved (valid) word
        // Put a word that is legitimate SOMEWHERE ELSE at BASE. An
        // address-independent pattern would not notice; this one must.
        $display("[2] a valid word moved to the wrong address");
        mem.peek(BASE + BB, w2);
        mem.poke(BASE, w2);
        run_and_wait({22'd0, 2'd1, 3'd0, 1'b0, 3'd0, 1'b1});   // mode 1, read+check
        rd(4'd5, ec); rd(4'd8, ba);
        check(ec > 32'd0, "moved word detected");
        check(ba == BASE, "reported at the address it was moved to");

        // put it back
        mem.poke(BASE, w0);
        run_and_wait({22'd0, 2'd1, 3'd0, 1'b0, 3'd0, 1'b1});
        rd(4'd5, ec);
        check(ec == 32'd0, "clean again once restored");

        // ------------------------------------------------ 3. a flipped bit
        $display("[3] a single flipped bit on the way out");
        corrupt_addr = BASE + 3*8;
        corrupt_xor  = 32'h0000_0040;
        corrupt_en   = 1'b1;
        run_and_wait({22'd0, 2'd1, 3'd0, 1'b0, 3'd0, 1'b1});
        rd(4'd5, ec); rd(4'd8, ba); rd(4'd7, eb);
        check(ec > 32'd0, "flipped bit detected");
        check(ba == corrupt_addr, "reported at the right address");
        check(eb == corrupt_xor, "ERRBITS names the bit that flipped");
        corrupt_en = 1'b0;

        // STOP must drain an address already offered to a stalled slave.
        for (stop_mode = 0; stop_mode < 2; stop_mode = stop_mode + 1) begin
            wr(4'd2, 1);
            @(negedge clk);
            if (stop_mode == 0) begin
                force awready = 1'b0;
                bursts_before = mem.wr_bursts;
            end else begin
                force arready = 1'b0;
                bursts_before = mem.rd_bursts;
            end
            wr(4'd0, (stop_mode << 8) | 1);
            wait(stop_mode == 0 ? awvalid : arvalid);
            repeat (2) @(negedge clk);
            if (stop_mode == 0)
                check(wvalid === 1'b1, "WVALID is offered without waiting for AWREADY");
            wr(4'd0, (stop_mode << 8) | 2);
            repeat (5) @(negedge clk);
            check((stop_mode == 0 ? awvalid : arvalid) === 1'b1,
                  "STOP retains an already offered address");
            check(dut.busy === 1'b1, "STOP waits for stalled address to drain");
            release awready; release arready;
            timeout = 0;
            st = 0;
            while (!st[1] && timeout < 5000) begin rd(4'd4, st); timeout = timeout + 1; end
            check(st[1] === 1'b1 && st[3] === 1'b0, "STOP finishes without watchdog");
            check((stop_mode == 0 ? mem.wr_bursts : mem.rd_bursts) == bursts_before + 1,
                  "exactly the offered burst completes after STOP");
        end
        wr(4'd2, BURSTS);

        // -------------------------------------------------- 4. the watchdog
        $display("[4] a slave that stops answering");
        dead = 1'b1;
        run_and_wait({22'd0, 2'd0, 3'd0, 1'b0, 3'd0, 1'b1});   // mode 0, write
        rd(4'd4, st);
        check(st[3] === 1'b1, "watchdog fired");
        check(st[0] === 1'b0, "engine left busy state");
        dead = 1'b0;

        // ------------------------------------------------ 5. clean re-run
        // After a watchdog abort the engine must still work.
        $display("[5] a clean run after the watchdog abort");
        run_and_wait({22'd0, 2'd2, 3'd0, 1'b0, 3'd0, 1'b1});
        rd(4'd5, ec); rd(4'd4, st);
        check(ec == 32'd0, "no errors");
        check(st[3] === 1'b0, "watchdog flag cleared by the new run");

        $display("");
        if (errors == 0) $display("axi_bist_tb: PASS");
        else             $display("axi_bist_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    // A bench that never ends is a bench that never fails.
    initial begin
        #5_000_000;
        $display("axi_bist_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
