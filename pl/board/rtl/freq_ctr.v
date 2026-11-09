// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Frequency measurement against the PS reference clock, with one shared gate
// and independent measured-clock counters. With a one-second gate, hz reports
// cycles per second; reference-oscillator error scales every result.
// Measured domains have configuration-time initialization because their clocks
// may stop. A toggle publishes a held count to the reference domain.
// A clock that never runs leaves hz and updates at zero. A clock that stops
// after running leaves its last sample; detect this by polling updates, an
// 8-bit wrapping count. A zero update value alone is not a liveness test.

`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// The shared gate: high for exactly REF_HZ reference cycles, so a counter
// clocked by the measured clock accumulates its frequency in Hz. The low
// period is REF_HZ/256 cycles (at least 16); it only has to outlast the
// latch and the toggle's crossing back, which take a handful of cycles.
// ---------------------------------------------------------------------------
`default_nettype none

module freq_gate #(
    parameter integer REF_HZ = 100_000_000
) (
    input  wire ref_clk,
    input  wire ref_rstn,
    output reg  gate
);
    localparam integer LOW_CYCLES = (REF_HZ / 256) < 16 ? 16 : (REF_HZ / 256);

    reg [31:0] c;
    always @(posedge ref_clk) begin
        if (!ref_rstn) begin
            c    <= 32'd0;
            gate <= 1'b0;
        end else if (gate) begin
            if (c == REF_HZ - 1) begin
                gate <= 1'b0;
                c    <= 32'd0;
            end else begin
                c <= c + 32'd1;
            end
        end else begin
            if (c == LOW_CYCLES - 1) begin
                gate <= 1'b1;
                c    <= 32'd0;
            end else begin
                c <= c + 32'd1;
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------
// One channel. Everything before the toggle handshake runs on the measured
// clock, which may not exist at all.
// ---------------------------------------------------------------------------
module freq_ctr (
    input  wire        ref_clk,
    input  wire        ref_rstn,
    input  wire        gate,        // from freq_gate, in the ref domain
    input  wire        meas_clk,    // the unknown clock

    output reg  [31:0] hz,          // ref domain: cycles counted in one gate
    output reg  [7:0]  updates      // ref domain: completed measurements
);

    // ---------------- measured clock domain ----------------
    // No reset here on purpose: a reset in this domain would need a release
    // synchronized to a clock that might not be running. The counters are
    // self-correcting -- the first gate edge starts a clean window -- and
    // every flop has an initial value for simulation and for the bitstream.
    reg [2:0]  gsync   = 3'b000;
    reg [31:0] cnt     = 32'd0;
    reg [31:0] latched = 32'd0;
    reg        tog     = 1'b0;

    wire g_now  = gsync[1];
    wire g_prev = gsync[2];

    always @(posedge meas_clk) begin
        gsync <= {gsync[1:0], gate};
        if (g_now) begin
            cnt <= cnt + 32'd1;
        end else begin
            if (g_prev) begin           // the gate just fell: publish
                latched <= cnt;
                tog     <= ~tog;
            end
            cnt <= 32'd0;
        end
    end

    // ---------------- reference clock domain ----------------
    // `latched` is written in the other domain, but it only changes when
    // `tog` flips, and it then holds still for a whole gate period -- about a
    // second. Sampling it two reference clocks after the toggle has crossed
    // is therefore reading a value that has been stable for far longer than
    // any conceivable skew across the bus. The XDC marks it as such.
    reg [2:0] tsync;
    always @(posedge ref_clk) begin
        if (!ref_rstn) begin
            tsync   <= 3'b000;
            hz      <= 32'd0;
            updates <= 8'd0;
        end else begin
            tsync <= {tsync[1:0], tog};
            if (tsync[2] != tsync[1]) begin
                hz      <= latched;
                updates <= updates + 8'd1;
            end
        end
    end

endmodule

`default_nettype wire
