// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Asynchronous AXI4-Stream FIFO with first-word fall-through reads.
// Pointers include a wrap bit and cross as registered Gray code through two
// flops. Constrain inter-bit skew as well as the asynchronous clock groups.
// The write clock may stop, so write-side state uses configuration-time
// initialization. Read reset discards queued data by following the synchronized
// write pointer; quiesce the writer and hold reset for at least three read
// edges before restarting traffic. Read outputs are ignored during reset.
// Used for HDMI LLC-to-FCLK capture and, with a shared clock, by cam_guard.
// AW must be at least 2; DW and the memory depth are build-time constants.

`timescale 1ns / 1ps

`default_nettype none

module axis_cdc_fifo #(
    parameter integer DW    = 26,   // tuser + tlast + 24 bits of pixel
    parameter integer AW    = 10    // 1024 entries
) (
    // ---------------------------------------------------------- write side
    input  wire          wclk,
    input  wire [DW-1:0] wdata,
    input  wire          wvalid,
    output wire          wready,

    // ----------------------------------------------------------- read side
    input  wire          rclk,
    input  wire          rrstn,
    output wire [DW-1:0] rdata,
    output wire          rvalid,
    input  wire          rready
);

    localparam integer DEPTH = (1 << AW);

    // Dual-port memory. No reset and no initial contents: a word is only ever
    // read after it has been written, which the pointers guarantee.
    reg [DW-1:0] mem [0:DEPTH-1];

    // ⚠ Pointers are one bit WIDER than the address: with the addresses
    // equal, only the wrap bit tells full from empty.
    reg [AW:0] wbin  = {(AW+1){1'b0}};
    reg [AW:0] wgray = {(AW+1){1'b0}};
    reg [AW:0] rbin  = {(AW+1){1'b0}};
    reg [AW:0] rgray = {(AW+1){1'b0}};

    // Gray-coded copies crossing the boundary, so a sample taken mid-change
    // is the old value or the new one, never a third.
    reg [AW:0] wgray_r1 = {(AW+1){1'b0}}, wgray_r2 = {(AW+1){1'b0}};
    reg [AW:0] rgray_w1 = {(AW+1){1'b0}}, rgray_w2 = {(AW+1){1'b0}};

    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // Needed only by the read-side reset below, which has to land the read
    // pointer on wherever the writer has got to.
    function [AW:0] gray2bin(input [AW:0] g);
        integer k;
        begin
            gray2bin[AW] = g[AW];
            for (k = AW - 1; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    // ------------------------------------------------------- write domain
    wire [AW:0] wbin_next  = wbin + {{AW{1'b0}}, (wvalid & wready)};
    wire        wfull      = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    assign wready = ~wfull;

    always @(posedge wclk) begin
        rgray_w1 <= rgray;
        rgray_w2 <= rgray_w1;
        if (wvalid & wready) mem[wbin[AW-1:0]] <= wdata;
        wbin  <= wbin_next;
        wgray <= bin2gray(wbin_next);
    end

    // -------------------------------------------------------- read domain
    wire        rempty     = (rgray == wgray_r2);
    wire [AW:0] rbin_next  = rbin + {{AW{1'b0}}, (rvalid & rready)};

    assign rvalid = ~rempty;
    assign rdata  = mem[rbin[AW-1:0]];

    // ⚠ The synchronizers keep running through reset, and the read pointer
    // resets to WHERE THE WRITER HAS GOT TO, not to zero: the unreset writer
    // may sit anywhere, and a zeroed reader would replay up to DEPTH stale
    // words. Allow the write-pointer synchronizer to settle during reset
    // before restarting traffic (see the reset contract above).
    always @(posedge rclk) begin
        wgray_r1 <= wgray;
        wgray_r2 <= wgray_r1;
        if (!rrstn) begin
            rbin  <= gray2bin(wgray_r2);
            rgray <= wgray_r2;
        end else begin
            rbin  <= rbin_next;
            rgray <= bin2gray(rbin_next);
        end
    end

endmodule

`default_nettype wire
