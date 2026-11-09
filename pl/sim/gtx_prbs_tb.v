// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for gtx_prbs: the register window, which field reaches which
// transceiver port, the two clock crossings, and the counters.
//
// The transceiver is gtx_sfp_model.v, a behavioral model of the gtwizard
// channel's contract, not the encrypted GTXE2 model -- so this proves the
// fabric around the transceiver, and the board proves the transceiver.
//
// The checks that pin behavior EXACTLY rather than approximately:
//   - two consecutive snapshots of the cycle count differ by exactly 4096,
//     which is the snapshot period -- so the count, the snapshot and the
//     crossing all agree to the cycle
//   - one injected TX error is exactly one burst -- three counted words,
//     the model's burst length (the real checker flags two to four; see
//     gtx_sfp_model.v) -- and three
//     injections are exactly nine: a toggle crossing that loses or doubles
//     an edge shows up here
//   - with the patterns mismatched, errors equal cycles exactly, since the
//     checker flags every word and both counters count the same window
//   - both counters stop at 0xFFFFFFFF rather than wrapping
//   - a RATE change writes exactly the five RXCDR_CFG words, the two
//     PMA_RSV words and the TXOUT_DIV/RXOUT_DIV word for the new rate over
//     the DRP, keeps the bits of 0x0AC and 0x088 that belong to other
//     attributes, holds the channel in reset while it does, leaves TXRATE and
//     RXRATE at 000 (the divider is the attribute, not a port sampled on the
//     user clock the change stops), and leaves the user clock at the new
//     rate's line rate / 40; the other channel's DRP and clock are untouched

`timescale 1ns/1ps

module gtx_prbs_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;                        // 100 MHz register clock

    reg refclk = 1'b0;
    always #3.2 refclk = ~refclk;                // 156.25 MHz reference

    reg        rstn = 1'b0;
    reg  [1:0] los  = 2'b00;
    reg  [3:0] waddr = 4'd0, raddr = 4'd0;
    reg        we = 1'b0;
    reg [31:0] wdata = 32'd0;
    wire [31:0] rdata;
    wire [1:0] txp, txn;

    wire uclk1;
    integer uedges = 0;
    always @(posedge uclk1) uedges = uedges + 1;

    gtx_prbs dut (
        .clk      (clk),     .rstn     (rstn),
        .refclk   (refclk),
        .txp      (txp),     .txn      (txn),
        .rxp      (txp),     .rxn      (txn),
        .los      (los),
        .reg_waddr(waddr),   .reg_we   (we),
        .reg_wdata(wdata),   .reg_raddr(raddr),
        .reg_rdata(rdata),
        .usrclk_sfp1(uclk1)
    );

    // Register offsets, as indexes (offset / 4)
    localparam ID = 0, RESET = 1,
               CTRL0 = 2, PULSE0 = 3, STAT0 = 4, ERRS0 = 5, CYCS0 = 6,
               CTRL1 = 7, PULSE1 = 8, STAT1 = 9, ERRS1 = 10, CYCS1 = 11,
               RATE = 12, RATE_STAT = 13, DRP = 14, DRP_WDATA = 15;

    integer errors = 0;

    task check32(input [8*64-1:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL  %0s: got 0x%08x, expected 0x%08x", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok    %0s = 0x%08x", what, got);
        end
    endtask

    // A count of clock edges in a window of arbitrary phase: floor or ceiling.
    task check_edges(input [8*64-1:0] what, input integer got, input integer exp);
        begin
            if (got != exp && got != exp + 1) begin
                $display("  FAIL  %0s: got %0d, expected %0d or %0d", what, got, exp, exp + 1);
                errors = errors + 1;
            end else
                $display("  ok    %0s = %0d", what, got);
        end
    endtask

    task wr(input [3:0] a, input [31:0] d);
        begin
            @(negedge clk); waddr = a; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
        end
    endtask

    task rd(input [3:0] a, output [31:0] d);
        begin
            @(negedge clk); raddr = a; #1 d = rdata;
        end
    endtask

    // The clk-domain snapshot strobes, straight out of the design, so a read
    // can be taken immediately after a fresh copy lands.
    wire snap0 = dut.ch[0].sn_s2 ^ dut.ch[0].sn_s1;
    wire snap1 = dut.ch[1].sn_s2 ^ dut.ch[1].sn_s1;

    task next_snap(input integer c);
        begin
            @(posedge clk);
            if (c == 0) begin while (!snap0) @(posedge clk); end
            else        begin while (!snap1) @(posedge clk); end
            @(posedge clk);          // the copy lands on this edge
        end
    endtask

    // A settled read: two snapshots on, so whatever happened before the
    // call is inside the window being read.
    task settled(input integer c, output [31:0] e, output [31:0] y);
        begin
            next_snap(c); next_snap(c);
            if (c == 0) begin rd(ERRS0, e); rd(CYCS0, y); end
            else        begin rd(ERRS1, e); rd(CYCS1, y); end
        end
    endtask

    reg [31:0] v, e, y, y1, y2, e0, e1;
    integer w0, w1, n_wait;

    // DRP (0x38) reads back [16] busy, [17] done
    task drp_wait(output [31:0] d);
        integer n;
        begin
            n = 0; rd(DRP, d);
            while ((d & 32'h0001_0000) && n < 2000) begin rd(DRP, d); n = n + 1; end
            d = d & 32'h0000_FFFF;
        end
    endtask
    task drp_rd(input integer c, input [8:0] a, output [31:0] d);
        begin
            wr(DRP, 32'hD500_0000 | (c << 12) | a);
            drp_wait(d);
        end
    endtask
    task wait_rate(input integer c);
        integer n;
        begin
            n = 0; rd(RATE_STAT, v);
            while ((v & (32'h1 << c)) && n < 100000) begin rd(RATE_STAT, v); n = n + 1; end
            if (v & (32'h1 << c)) begin
                $display("  FAIL  ch%0d rate sequence never finished", c);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #100 rstn = 1'b1;

        $display("--- identity and decode");
        rd(ID, v);     check32("ID", v, 32'h4758_0003);
        rd(RATE, v);   check32("RATE resets to 3.125 Gb/s on both channels", v, 32'd0);
        rd(DRP_WDATA, v); check32("DRP_WDATA resets to 0", v, 32'd0);
        rd(PULSE0, v); check32("PULSE0 is write-only, reads 0", v, 32'd0);

        $display("--- which field reaches which port");
        // loopback 010, txprbssel 1, rxprbssel 1, txpol 1, rxpol 1
        wr(CTRL0, 32'h0000_3112);
        rd(CTRL0, v);  check32("CTRL0 reads back", v, 32'h0000_3112);
        rd(CTRL1, v);  check32("CTRL1 untouched by a CTRL0 write", v, 32'd0);
        // ch1: PRBS-7 both ways, no loopback, polarity normal
        wr(CTRL1, 32'h0000_0110);

        $display("--- status");
        repeat (400) @(posedge clk);         // CPLL lock + both FSMs
        rd(STAT0, v);  check32("STAT0 = lock, both resets done, both FSMs done", v, 32'h0000_001F);

        // The fields cross into usrclk, which is TXOUTCLK and only runs once
        // the CPLL has locked -- so they are checked here, not straight after
        // the write. That matches the transceiver: TXPRBSSEL and TXPOLARITY
        // belong to TXUSRCLK2, RXPRBSSEL and RXPOLARITY to RXUSRCLK2.
        check32("ch0 LOOPBACK port",   {29'd0, dut.ch[0].gtx_i.gt0_loopback_in},   32'd2);
        check32("ch0 TXPRBSSEL port",  {29'd0, dut.ch[0].gtx_i.gt0_txprbssel_in},  32'd1);
        check32("ch0 RXPRBSSEL port",  {29'd0, dut.ch[0].gtx_i.gt0_rxprbssel_in},  32'd1);
        check32("ch0 TXPOLARITY port", {31'd0, dut.ch[0].gtx_i.gt0_txpolarity_in}, 32'd1);
        check32("ch0 RXPOLARITY port", {31'd0, dut.ch[0].gtx_i.gt0_rxpolarity_in}, 32'd1);
        check32("ch1 LOOPBACK port", {29'd0, dut.ch[1].gtx_i.gt0_loopback_in}, 32'd0);
        check32("ch1 TXPRBSSEL port, from CTRL1", {29'd0, dut.ch[1].gtx_i.gt0_txprbssel_in}, 32'd1);
        // The drive fields: zero is the wizard's own setting (807 mV, DFE);
        // a write reaches the ports of its channel only, and the unused
        // [29:20] still read back.
        check32("ch0 TXDIFFCTRL by default", {28'd0, dut.ch[0].gtx_i.gt0_txdiffctrl_in}, 32'd8);
        check32("ch0 RXLPMEN by default",    {31'd0, dut.ch[0].gtx_i.gt0_rxlpmen_in},    32'd0);
        wr(CTRL1, 32'h4000_0110 | (32'd13 << 25) | (32'd9 << 20) | (32'h3 << 16));
        repeat (4) @(posedge clk);
        check32("ch1 TXDIFFCTRL = 3 ^ 8",  {28'd0, dut.ch[1].gtx_i.gt0_txdiffctrl_in},   32'd11);
        check32("ch1 RXLPMEN",             {31'd0, dut.ch[1].gtx_i.gt0_rxlpmen_in},      32'd1);
        check32("ch0 untouched by CTRL1",  {28'd0, dut.ch[0].gtx_i.gt0_txdiffctrl_in},   32'd8);
        rd(CTRL1, v);  check32("CTRL1 reads the drive fields back", v, 32'h4000_0110 | (32'd13 << 25) | (32'd9 << 20) | (32'h3 << 16));
        wr(CTRL1, 32'h0000_0110);
        repeat (4) @(posedge clk);
        check32("ch1 back to the default drive", {28'd0, dut.ch[1].gtx_i.gt0_txdiffctrl_in}, 32'd8);
        los = 2'b01;
        repeat (10) @(posedge clk);
        rd(STAT0, v);  check32("STAT0 bit 7 follows cage LOS", v & 32'h80, 32'h80);
        rd(STAT1, v);  check32("STAT1 bit 7 is the OTHER cage's LOS", v & 32'h80, 32'h00);
        // usrclk_sfp1 is what the top level counts as FREQ1: SFP1's user
        // clock, the line rate / 40 -- 12.8 ns at 3.125 Gb/s, so 1 us holds
        // 78 rising edges.
        uedges = 0; #1000;
        check_edges("usrclk_sfp1 = SFP1's TXOUTCLK: edges in 1 us", uedges, 78);
        los = 2'b00;

        $display("--- a clean link counts cycles and no errors");
        wr(PULSE0, 32'h2);                   // reset the counters
        next_snap(0);                        // may predate the reset
        next_snap(0); rd(CYCS0, y1);
        next_snap(0); rd(CYCS0, y2);
        check32("consecutive snapshots are exactly 4096 cycles apart", y2 - y1, 32'd4096);
        rd(ERRS0, v);  check32("no errors on a matched pattern", v, 32'd0);

        $display("--- injected TX errors are counted exactly");
        wr(PULSE0, 32'h1);
        settled(0, e, y); check32("one injected error = one burst of 3 words", e, 32'd3);
        rd(STAT0, v);  check32("STAT0 bit 6 = an error was seen", v & 32'h40, 32'h40);
        // Spaced apart: at 78 MHz two injections one register write apart
        // land a cycle and a half apart, and their bursts overlap.
        repeat (20) @(posedge clk); wr(PULSE0, 32'h1);
        repeat (20) @(posedge clk); wr(PULSE0, 32'h1);
        settled(0, e, y); check32("three injected = three bursts, 9 words", e, 32'd9);

        $display("--- counter reset");
        wr(PULSE0, 32'h2);
        settled(0, e, y); check32("errors back to zero", e, 32'd0);
        rd(STAT0, v);  check32("STAT0 bit 6 cleared by the reset", v & 32'h40, 32'h00);
        if (y > 32'd3 * 4096) begin
            $display("  FAIL  cycles after reset = %0d, expected under 3 windows", y);
            errors = errors + 1;
        end else
            $display("  ok    cycles restart from zero (%0d after two windows)", y);

        $display("--- the other channel is independent");
        dut.ch[1].gtx_i.inject = 5;
        settled(1, e1, y); check32("ch1 counts its own 5 injected errors", e1, 32'd5);
        settled(0, e0, y); check32("ch0 does not see ch1's errors", e0, 32'd0);

        $display("--- a mismatched pattern flags every word");
        wr(CTRL0, 32'h0000_3212);            // rx expects PRBS-15, tx sends PRBS-7
        repeat (10) @(posedge clk);
        wr(PULSE0, 32'h2);
        settled(0, e, y);
        check32("errors == cycles when every word is wrong", e, y);
        wr(CTRL0, 32'h0000_2112);            // patterns match, polarity does not
        repeat (10) @(posedge clk);
        wr(PULSE0, 32'h2);
        settled(0, e, y);
        check32("a polarity mismatch also flags every word", e, y);
        wr(CTRL0, 32'h0000_3112);            // matched again
        repeat (10) @(posedge clk);
        wr(PULSE0, 32'h2);
        settled(0, e, y);  check32("matched again: zero errors", e, 32'd0);

        $display("--- counting stops while the receiver is in reset");
        wr(RESET, 32'h2);                    // ch0 soft_reset_rx held
        repeat (200) @(posedge clk);
        next_snap(0); rd(CYCS0, y1);
        next_snap(0); rd(CYCS0, y2);
        check32("no cycles counted while RX is held in reset", y2 - y1, 32'd0);
        rd(STAT0, v);  check32("STAT0 bit 4 (rx fsm done) low in reset", v & 32'h10, 32'h00);
        wr(RESET, 32'h0);
        repeat (200) @(posedge clk);
        next_snap(0); rd(CYCS0, y1);
        next_snap(0); rd(CYCS0, y2);
        check32("counting resumes after the reset", y2 - y1, 32'd4096);

        $display("--- both counters saturate");
        wr(CTRL0, 32'h0000_3212);            // every word an error
        repeat (20) @(posedge clk);
        @(negedge dut.ch[0].usrclk);     // not posedge: that would race the design's own counter update
        dut.ch[0].err_cnt = 32'hFFFF_FF00;
        dut.ch[0].cyc_cnt = 32'hFFFF_FF00;
        settled(0, e, y);
        check32("error count stops at 0xFFFFFFFF", e, 32'hFFFF_FFFF);
        check32("cycle count stops at 0xFFFFFFFF", y, 32'hFFFF_FFFF);

        $display("--- the QPLL and the DRP");
        wr(CTRL0, 32'h0000_3112);            // matched patterns again
        wr(PULSE0, 32'h2);
        repeat (100) @(posedge clk);
        rd(RATE_STAT, v); check32("RATE_STAT: QPLL locked, nothing busy, both at rate 0",
                                  v, 32'h0000_0100);
        // raw DRP read of the CDR words the model starts with
        drp_rd(0, 9'h0AC, v); check32("raw DRP read, ch0 0x0AC", v, 32'h5A03);
        drp_rd(0, 9'h0A9, v); check32("raw DRP read, ch0 0x0A9", v, 32'h4020);
        wr(DRP_WDATA, 32'h1234);
        wr(DRP, 32'hD501_1100);               // write, ch1, address 0x100
        drp_wait(v);
        check32("raw DRP write lands in ch1", {16'd0, dut.ch[1].gtx_i.drp[9'h100]}, 32'h1234);
        check32("... and not in ch0", {16'd0, dut.ch[0].gtx_i.drp[9'h100]}, 32'hDEAD);
        wr(DRP, 32'h0000_0100);               // no 0xD5 key: ignored
        rd(DRP, v); check32("an unkeyed DRP write does not start", v & 32'h0001_0000, 32'd0);

        $display("--- RATE 2 on ch0: 10.3125 Gb/s from the QPLL");
        w0 = dut.ch[0].gtx_i.drp_writes; w1 = dut.ch[1].gtx_i.drp_writes;
        wr(RATE, 32'h0000_0002);
        rd(RATE_STAT, v); check32("sequence busy at once", v & 32'h1, 32'h1);
        repeat (400) @(posedge clk);
        check32("ch0 held in TX reset during the sequence",
                {31'd0, dut.ch[0].gtx_i.soft_reset_tx_in}, 32'd1);
        wait_rate(0);
        rd(RATE_STAT, v); check32("RATE_STAT: done, no failure, ch0 at rate 2",
                                  v, 32'h0002_0100);
        check32("ch0 got exactly eight DRP writes", dut.ch[0].gtx_i.drp_writes - w0, 32'd8);
        check32("TXOUT_DIV/RXOUT_DIV /1, markers kept", {16'd0, dut.ch[0].gtx_i.drp[9'h088]}, 32'hC388);
        check32("ch1 got none", dut.ch[1].gtx_i.drp_writes - w1, 32'd0);
        check32("RXCDR_CFG[15:0]",  {16'd0, dut.ch[0].gtx_i.drp[9'h0A8]}, 32'h0020);
        check32("RXCDR_CFG[31:16]", {16'd0, dut.ch[0].gtx_i.drp[9'h0A9]}, 32'h1040);
        check32("RXCDR_CFG[47:32]", {16'd0, dut.ch[0].gtx_i.drp[9'h0AA]}, 32'h23ff);
        check32("RXCDR_CFG[63:48]", {16'd0, dut.ch[0].gtx_i.drp[9'h0AB]}, 32'h0000);
        check32("RXCDR_CFG[71:64], the other byte of 0x0AC kept",
                {16'd0, dut.ch[0].gtx_i.drp[9'h0AC]}, 32'h5A0B);
        check32("PMA_RSV[15:0] above 6.6 Gb/s",  {16'd0, dut.ch[0].gtx_i.drp[9'h099]}, 32'h7080);
        check32("PMA_RSV[31:16] above 6.6 Gb/s", {16'd0, dut.ch[0].gtx_i.drp[9'h09A]}, 32'h001E);
        check32("ch1's PMA_RSV untouched", {16'd0, dut.ch[1].gtx_i.drp[9'h099]}, 32'h8480);
        check32("ch0 TXSYSCLKSEL = QPLL", {30'd0, dut.ch[0].gtx_i.gt0_txsysclksel_in}, 32'd3);
        check32("ch0 RXSYSCLKSEL = QPLL", {30'd0, dut.ch[0].gtx_i.gt0_rxsysclksel_in}, 32'd3);
        check32("ch0 TXRATE/RXRATE left at 000", {26'd0, dut.ch[0].gtx_i.gt0_txrate_in,
                dut.ch[0].gtx_i.gt0_rxrate_in}, 32'd0);
        check32("ch1 still on the CPLL", {30'd0, dut.ch[1].gtx_i.gt0_txsysclksel_in}, 32'd0);
        check32("ch1 still /2", {16'd0, dut.ch[1].gtx_i.drp[9'h088]}, 32'hC399);
        repeat (300) @(posedge clk);          // the startup FSMs finish
        rd(STAT0, v); check32("ch0 back up: both FSMs done", v & 32'h18, 32'h18);
        uedges = 0; #1000;
        check_edges("usrclk_sfp1 at 10.3125 / 40: edges in 1 us", uedges, 257);
        wr(PULSE0, 32'h2);
        next_snap(0); next_snap(0); rd(CYCS0, y1);
        next_snap(0); rd(CYCS0, y2);
        check32("snapshots still exactly 4096 cycles apart at 257.8 MHz", y2 - y1, 32'd4096);
        wr(PULSE0, 32'h1);
        settled(0, e, y); check32("an injected error is still one burst", e, 32'd3);

        $display("--- RATE 1 on ch0: 6.25 Gb/s from the CPLL, divider 1");
        wr(RATE, 32'h0000_0001);
        wait_rate(0);
        check32("RXCDR_CFG[31:16] for 6.25", {16'd0, dut.ch[0].gtx_i.drp[9'h0A9]}, 32'h2040);
        check32("RXCDR_CFG[71:64] for 6.25", {16'd0, dut.ch[0].gtx_i.drp[9'h0AC]}, 32'h5A03);
        check32("PMA_RSV back to the low-rate value", {16'd0, dut.ch[0].gtx_i.drp[9'h099]}, 32'h8480);
        check32("PMA_RSV[31:16] low-rate", {16'd0, dut.ch[0].gtx_i.drp[9'h09A]}, 32'h0001);
        check32("ch0 TXSYSCLKSEL = CPLL", {30'd0, dut.ch[0].gtx_i.gt0_txsysclksel_in}, 32'd0);
        check32("ch0 /1 for 6.25", {16'd0, dut.ch[0].gtx_i.drp[9'h088]}, 32'hC388);
        check32("ch0 TXRATE/RXRATE still 000", {26'd0, dut.ch[0].gtx_i.gt0_txrate_in,
                dut.ch[0].gtx_i.gt0_rxrate_in}, 32'd0);
        uedges = 0; #1000;
        check_edges("usrclk_sfp1 at 6.25 / 40: edges in 1 us", uedges, 156);

        $display("--- RATE 3 is refused; the same rate again does nothing");
        w0 = dut.ch[0].gtx_i.drp_writes;
        wr(RATE, 32'h0000_0003);
        rd(RATE, v); check32("RATE 3 refused: ch0 still asks for 1", v, 32'h1);
        rd(RATE_STAT, v); check32("no sequence started", v & 32'h3, 32'h0);
        wr(RATE, 32'h0000_0001);
        rd(RATE_STAT, v); check32("writing the current rate starts nothing", v & 32'h3, 32'h0);
        check32("no DRP traffic", dut.ch[0].gtx_i.drp_writes - w0, 32'd0);

        $display("--- both channels at once: ch0 back to 3.125, ch1 to 10.3125");
        wr(RATE, 32'h0000_0000);
        wr(RATE, 32'h0000_0020);              // ch0 0, ch1 2
        wait_rate(0); wait_rate(1);
        rd(RATE_STAT, v); check32("ch0 at 0, ch1 at 2", v, 32'h0020_0100);
        check32("ch1 RXCDR_CFG[31:16] for 10G", {16'd0, dut.ch[1].gtx_i.drp[9'h0A9]}, 32'h1040);
        check32("ch0 RXCDR_CFG[31:16] for 3.125", {16'd0, dut.ch[0].gtx_i.drp[9'h0A9]}, 32'h4020);
        check32("ch0 back to /2", {16'd0, dut.ch[0].gtx_i.drp[9'h088]}, 32'hC399);
        uedges = 0; #1000;
        check_edges("usrclk_sfp1 back at 3.125 / 40: edges in 1 us", uedges, 78);

        $display("--- a raw DRP access requested during a sequence's reset window");
        // ch1 goes back to 3.125, and a raw read of ch1 arrives while the
        // sequence is still counting down its 2 us reset. Each must wait for
        // the other to finish, not for the other to start.
        wr(RATE, 32'h0000_0000);
        wr(DRP, 32'hD500_1000 | 32'h0A9);     // read, ch1, 0x0A9
        rd(RATE_STAT, v); check32("the ch1 sequence is in progress", v & 32'h2, 32'h2);
        wait_rate(1);
        drp_wait(v);
        check32("the raw access waited for the sequence: it read the 3.125 word", v, 32'h4020);
        rd(DRP, v);
        check32("... and completed, without a timeout", v & 32'h0007_0000, 32'h0002_0000);
        rd(RATE_STAT, v); check32("ch1 at 0, nothing busy", v & 32'h0030_0003, 32'h0);

        $display("--- a RATE write while a sequence is running");
        // Mid-sequence, the rate asked for changes. The channel must end at
        // the rate asked for LAST, with every DRP word from that rate: not a
        // mix of the old request's words and the new one's.
        w0 = dut.ch[0].gtx_i.drp_writes;
        wr(RATE, 32'h0000_0002);
        n_wait = 0;
        while (dut.widx[0] != 3'd3 && n_wait < 100000) begin @(posedge clk); n_wait = n_wait + 1; end
        wr(RATE, 32'h0000_0001);
        n_wait = 0; rd(RATE_STAT, v);
        while (((v & 32'h1) || (v & 32'h0003_0000) != 32'h0001_0000) && n_wait < 100000) begin
            rd(RATE_STAT, v); n_wait = n_wait + 1;
        end
        check32("ch0 settles at rate 1, nothing busy", v & 32'h0003_0011, 32'h0001_0000);
        check32("RXCDR_CFG[31:16] is 6.25's", {16'd0, dut.ch[0].gtx_i.drp[9'h0A9]}, 32'h2040);
        check32("RXCDR_CFG[71:64] is 6.25's", {16'd0, dut.ch[0].gtx_i.drp[9'h0AC]}, 32'h5A03);
        check32("PMA_RSV is the low-rate value", {16'd0, dut.ch[0].gtx_i.drp[9'h099]}, 32'h8480);
        check32("ch0 /1 for 6.25", {16'd0, dut.ch[0].gtx_i.drp[9'h088]}, 32'hC388);
        check32("ch0 TXSYSCLKSEL = CPLL", {30'd0, dut.ch[0].gtx_i.gt0_txsysclksel_in}, 32'd0);

        $display("");
        if (errors == 0) $display("gtx_prbs_tb: PASS");
        else             $display("gtx_prbs_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("gtx_prbs_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
