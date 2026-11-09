// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for fan_ctrl, the fan's PWM output stage and tachometer counter.
//
// Scaled down: CLK_HZ = 10000 and FALLBACK_MS = 2, so the fallback fires
// after 20 clocks of a still PWM input (23 from the edge itself, counting
// the synchronizer) and the tachometer window is 10000 clocks. The logic is
// the same at 100 MHz; only the constants move.
//
// The checks that pin behavior exactly:
//   - the pin is the INVERSE of pwm_in (the board's NPN inverts again)
//   - a still pwm_in drives the pin LOW -- full speed -- after exactly the
//     fallback time, and the next edge hands control back
//   - FAN_CTRL[0] disables the fallback, FAN_CTRL[1] holds the fan off
//     whatever else is happening, and FAN_STATUS reports each
//   - the tachometer counts falling edges exactly: 37 pulses in a window
//     read as 37, an empty window as 0

`timescale 1ns/1ps

module fan_ctrl_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rstn = 1'b0;
    reg         pwm_in = 1'b0;
    reg         fan_tach = 1'b1;
    reg  [31:0] ctrl = 32'd0;
    wire        fan_pwm, tach_sync_o;
    wire [31:0] status;

    fan_ctrl #(.CLK_HZ(10000), .FALLBACK_MS(2)) dut (
        .clk (clk), .rstn (rstn), .pwm_in (pwm_in),
        .fan_pwm (fan_pwm), .fan_tach (fan_tach),
        .tach_sync_o (tach_sync_o), .ctrl (ctrl), .status (status)
    );

    integer errors = 0;
    task check(input [8*64-1:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL  %0s: got 0x%0h, expected 0x%0h", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok    %0s = 0x%0h", what, got);
        end
    endtask

    task clocks(input integer n); repeat (n) @(posedge clk); endtask

    // A PWM input that keeps moving: toggle every 4 clocks for n toggles,
    // on the falling edge so no sample races a change.
    task wiggle(input integer n);
        integer i;
        for (i = 0; i < n; i = i + 1) begin clocks(4); @(negedge clk); pwm_in = ~pwm_in; end
    endtask

    integer i, t;

    initial begin
        clocks(3); rstn = 1'b1;

        $display("--- the pin is the inverse of the PS's PWM");
        pwm_in = 1'b1; clocks(4);
        check("pwm_in 1 -> pin 0", fan_pwm, 0);
        pwm_in = 1'b0; clocks(4);
        check("pwm_in 0 -> pin 1", fan_pwm, 1);
        check("status[17] follows pwm_in", status[17], 0);

        $display("--- a still pwm_in falls back to full speed");
        // Clocks from the last pwm_in edge to the pin: two to synchronize,
        // one to register the edge that clears the idle count, then the 20
        // the count takes to expire.
        wiggle(3); clocks(4);
        @(negedge clk); pwm_in = 1'b0;        // the last edge, then stand still
        t = 0;
        while (status[18] !== 1'b1 && t < 100) begin @(negedge clk); t = t + 1; end
        check("clocks from the last edge to full speed", t, 23);
        check("pin LOW: full speed", fan_pwm, 0);
        check("status[18]: the fallback is driving", status[18], 1);
        pwm_in = 1'b1; clocks(4);
        check("the next edge hands control back (pwm 1 -> pin 0)", fan_pwm, 0);
        check("status[18] clear again", status[18], 0);
        pwm_in = 1'b0; clocks(4);
        check("and it follows pwm_in again (pwm 0 -> pin 1)", fan_pwm, 1);

        $display("--- FAN_CTRL[0]: no fallback");
        ctrl = 32'h1; clocks(60);
        check("still pwm_in 0, no fallback: pin 1 (off)", fan_pwm, 1);
        check("status[18] stays clear", status[18], 0);

        $display("--- FAN_CTRL[1]: force off, whatever pwm_in does");
        ctrl = 32'h2;
        wiggle(4); pwm_in = 1'b1; clocks(4);
        check("pwm_in 1 but forced off: pin 1", fan_pwm, 1);
        clocks(60);
        check("and the fallback cannot override it", fan_pwm, 1);
        check("status[19]: force_off", status[19], 1);
        ctrl = 32'h0; clocks(4);

        $display("--- the tachometer counts falling edges per window");
        // Start at a window boundary: wait for the counter to publish.
        @(posedge clk); while (dut.window != 0) @(posedge clk);
        for (i = 0; i < 37; i = i + 1) begin
            fan_tach = 1'b0; clocks(40); fan_tach = 1'b1; clocks(40);
        end
        @(posedge clk); while (dut.window != 0) @(posedge clk);
        clocks(2);
        check("37 pulses in a window read as 37", status[15:0], 37);
        @(posedge clk); while (dut.window != 0) @(posedge clk);
        clocks(2);
        check("a window with none reads 0", status[15:0], 0);
        check("status[16] is the tach level", status[16], 1);

        // Seed near saturation rather than simulating 65,535 physical pulses.
        // Include the publication edge: that pulse belongs to this window.
        @(negedge clk);
        dut.tach_count = 16'hFFFE;
        dut.window = 9999;
        force dut.tach_fall = 1'b1;
        @(negedge clk);
        check("last pulse reaches saturation at publication", status[15:0], 65535);
        dut.tach_count = 16'hFFFF;
        dut.window = 9998;
        @(negedge clk);
        check("interior pulse keeps saturated count", dut.tach_count, 65535);
        @(negedge clk);
        check("publication pulse cannot wrap saturated count", status[15:0], 65535);
        release dut.tach_fall;

        if (errors == 0) $display("fan_ctrl_tb: PASS");
        else             $display("fan_ctrl_tb: FAIL (%0d)", errors);
        $finish;
    end

endmodule
