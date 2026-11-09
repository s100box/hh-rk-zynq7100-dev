// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Fan pin logic: the PWM output stage and the tachometer counter. The PWM
// itself comes from the PS (TTC1_WAVE0_OUT over EMIO), so Linux runs the fan
// with the mainline pwm-cadence and pwm-fan drivers and it appears under
// hwmon like any other.
//
// Board wiring (user guide section 9):
//   FAN_PWM  W21, bank 11. NPN Q7 pulls the fan's PWM line LOW when this pin
//            is 1, so the pin is INVERTED: fan speed follows the time it is
//            low, and pwm_in high (pwm-fan asking for more) comes out low.
//   FAN_TACH Y21, bank 11. Open collector from the fan, 33R in series, 4.7K
//            pull-up to 3.3V, Schottky clamp.
//
// ⚠ Inverting alone makes the idle state the dangerous one: with nothing
// driving TTC1 (Linux not up, crashed, or no pwm-fan) `pwm_in` sits at 0 and
// the fan would be held off. So if `pwm_in` has no edge for FALLBACK_MS, the
// pin is driven low: full speed, decided in the fabric. A static-high
// `pwm_in` (100%) also lands on full speed, which is what it asked for.
// Stopping the fan therefore takes its own bit, FAN_CTRL[1] (see force_off).
//
// ⚠ Before configuration the fan is OFF: PUDC_B is strapped low, so W21 is
// pulled high and Q7 holds the PWM line down. Nothing in the PL can change
// that (measurements in the user guide, section 9).

`default_nettype none

module fan_ctrl #(
    // Clock period is fclk_clk0 = 100 MHz in both designs that use this.
    parameter integer CLK_HZ      = 100_000_000,
    // How long pwm_in may sit still before the fabric forces full speed.
    parameter integer FALLBACK_MS = 100
) (
    input  wire        clk,
    input  wire        rstn,

    // From the PS: TTC1_WAVE0_OUT, asynchronous to clk.
    input  wire        pwm_in,

    // To and from the board.
    output wire        fan_pwm,
    input  wire        fan_tach,

    // The tachometer, synchronized, for the PS to count as an interrupt
    // (EMIO GPIO 0). Linux's pwm-fan turns the edge rate into fan1_input;
    // the register below is the same signal counted in the fabric, and the
    // two are independent readings of the same wire.
    output wire        tach_sync_o,

    // FAN_CTRL, written by software.
    //   [0] no_fallback: stop forcing the fan on when pwm_in stands still.
    //   [1] force_off:   hold the fan off, whatever pwm_in is doing.
    input  wire [31:0] ctrl,

    // FAN_STATUS, read by software.
    //   [15:0]  tach pulses (falling edges) in the last second
    //           (RPM = pulses * 60 / pulses-per-rev)
    //   [16]    tach input, live
    //   [17]    pwm_in, live
    //   [18]    the fallback is driving the fan
    //   [19]    force_off is holding the fan off
    output wire [31:0] status
);

    localparam integer FALLBACK_CYCLES = (CLK_HZ / 1000) * FALLBACK_MS;
    localparam integer SECOND_CYCLES   = CLK_HZ;

    // ---------------------------------------------------------------------
    // Both inputs cross into this clock domain: two flops each, and an edge
    // is a change between the last two synchronized samples.
    // ---------------------------------------------------------------------
    reg [2:0] pwm_sync;
    reg [2:0] tach_sync;
    always @(posedge clk) begin
        pwm_sync  <= {pwm_sync[1:0],  pwm_in};
        tach_sync <= {tach_sync[1:0], fan_tach};
    end

    wire pwm_level   = pwm_sync[1];
    wire pwm_edge    = pwm_sync[2] ^ pwm_sync[1];
    // Count falling edges only, so tach_per_sec is pulses, not transitions.
    wire tach_fall   = tach_sync[2] & ~tach_sync[1];

    // ---------------------------------------------------------------------
    // Fallback: has pwm_in moved recently?
    // ---------------------------------------------------------------------
    reg [$clog2(FALLBACK_CYCLES+1)-1:0] idle_count;
    wire idle_expired = (idle_count == FALLBACK_CYCLES);

    always @(posedge clk) begin
        if (!rstn)          idle_count <= 0;
        else if (pwm_edge)  idle_count <= 0;
        else if (!idle_expired) idle_count <= idle_count + 1;
    end

    wire fallback = idle_expired & ~ctrl[0];

    // Full speed is the pin LOW, so the fallback forces 0 and otherwise the
    // pin is the inverse of what the PS is asking for.
    //
    // ⚠ `force_off` is an explicit bit because pwm1 = 0 does not reliably
    // rest the TTC waveform low (it depends on how the duty got to 0), and a
    // waveform resting high is indistinguishable from 100% duty.
    assign fan_pwm = ctrl[1] ? 1'b1            // force off
                   : fallback ? 1'b0           // no waveform: full speed
                   : ~pwm_level;

    // ---------------------------------------------------------------------
    // Tachometer: pulses in the last full second. A whole-second window is
    // the cheapest honest measurement -- no period reciprocal, no division,
    // and its resolution (1 pulse/s = 30 rpm on a 2-pulse fan) is finer than
    // a fan's own speed regulation.
    // ---------------------------------------------------------------------
    reg [$clog2(SECOND_CYCLES)-1:0] window;
    reg [15:0] tach_count;
    reg [15:0] tach_per_sec;

    always @(posedge clk) begin
        if (!rstn) begin
            window       <= 0;
            tach_count   <= 16'd0;
            tach_per_sec <= 16'd0;
        end else if (window == SECOND_CYCLES - 1) begin
            window       <= 0;
            // Include a pulse on the boundary without wrapping a full count.
            tach_per_sec <= (tach_fall && tach_count != 16'hFFFF)
                            ? tach_count + 16'd1 : tach_count;
            tach_count   <= 16'd0;
        end else begin
            window <= window + 1;
            // Saturate rather than wrap: a wrapped count reads like a slow
            // fan, which is the one wrong answer that looks plausible.
            if (tach_fall && tach_count != 16'hFFFF)
                tach_count <= tach_count + 16'd1;
        end
    end

    assign tach_sync_o = tach_sync[1];

    assign status = {12'd0, ctrl[1], fallback, pwm_level, tach_sync[1], tach_per_sec};

endmodule

`default_nettype wire
