// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for freq_ctr. Three channels at frequencies the bench knows and the
// counter does not, plus a fourth whose clock never ticks.
//
// The scale is shrunk so the simulation finishes: REF_HZ is 1000 rather than
// 100,000,000, so the gate is 1000 reference cycles instead of a second, and
// a "Hz" reading here is cycles per 10 microseconds. The arithmetic and every
// clock crossing are identical -- only the constant changes.
//
// ⚠ The dead-clock channel is the reason this bench exists. Two of the four
// clocks on the board are GTX reference clocks that only exist if the MGT
// rails came up, so "reads zero" has to be distinguishable from "is slow",
// and `updates` is what distinguishes them.

`timescale 1ns / 1ps

module freq_ctr_tb;

    localparam integer REF_HZ = 1000;      // gate = 1000 ref cycles = 10 us

    reg ref_clk = 1'b0, ref_rstn = 1'b0;
    always #5 ref_clk = ~ref_clk;          // 100 MHz, 10 ns

    // Measured clocks. Over a 10 us gate:
    //   250 MHz (4 ns)     -> 2500
    //   125 MHz (8 ns)     -> 1250
    //    40 MHz (25 ns)    ->  400
    reg m250 = 1'b0;  always #2   m250 = ~m250;
    reg m125 = 1'b0;  always #4   m125 = ~m125;
    reg m40  = 1'b0;  always #12.5 m40 = ~m40;
    reg mdead = 1'b0;                      // never toggles

    integer errors = 0;
    task check;
        input cond;
        input [8*56-1:0] what;
        begin
            if (!cond) begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end else $display("  ok    %0s", what);
        end
    endtask

    wire gate;
    freq_gate #(.REF_HZ(REF_HZ)) g (
        .ref_clk(ref_clk), .ref_rstn(ref_rstn), .gate(gate));

    wire [31:0] hz0, hz1, hz2, hz3;
    wire [7:0]  up0, up1, up2, up3;

    freq_ctr c0 (.ref_clk(ref_clk), .ref_rstn(ref_rstn), .gate(gate),
                 .meas_clk(m250),  .hz(hz0), .updates(up0));
    freq_ctr c1 (.ref_clk(ref_clk), .ref_rstn(ref_rstn), .gate(gate),
                 .meas_clk(m125),  .hz(hz1), .updates(up1));
    freq_ctr c2 (.ref_clk(ref_clk), .ref_rstn(ref_rstn), .gate(gate),
                 .meas_clk(m40),   .hz(hz2), .updates(up2));
    freq_ctr c3 (.ref_clk(ref_clk), .ref_rstn(ref_rstn), .gate(gate),
                 .meas_clk(mdead), .hz(hz3), .updates(up3));

    // Within a couple of counts: the gate edges cross into the measured
    // domain through a synchronizer, so the window can be off by a cycle at
    // each end. Over a real one-second gate that is parts per hundred
    // million; here it is parts per thousand.
    task near;
        input [31:0] got;
        input [31:0] want;
        input [8*56-1:0] what;
        begin
            if ((got > want + 3) || (got + 3 < want)) begin
                $display("  FAIL  %0s: got %0d, wanted about %0d", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok    %0s: %0d (wanted about %0d)", what, got, want);
            end
        end
    endtask

    reg [7:0] up0_first;

    initial begin
        repeat (10) @(posedge ref_clk);
        ref_rstn = 1'b1;

        // Wait until every live channel has published twice.
        wait (up0 >= 8'd2);
        wait (up1 >= 8'd2);
        wait (up2 >= 8'd2);
        @(posedge ref_clk);

        $display("[1] three live clocks");
        near(hz0, 2500, "250 MHz channel");
        near(hz1, 1250, "125 MHz channel");
        near(hz2,  400, "40 MHz channel");

        $display("[2] a clock that never ticks");
        check(hz3 == 32'd0,  "dead channel reads 0 Hz");
        check(up3 == 8'd0,   "dead channel never published an update");
        check(up0 != 8'd0,   "a live channel did publish, so the gate runs");

        $display("[3] readings keep updating");
        up0_first = up0;
        wait (up0 != up0_first);
        @(posedge ref_clk);
        near(hz0, 2500, "250 MHz channel, second reading");
        check(up0 != up0_first, "updates advanced");

        $display("");
        if (errors == 0) $display("freq_ctr_tb: PASS");
        else             $display("freq_ctr_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("freq_ctr_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
