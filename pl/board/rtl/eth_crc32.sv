// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Byte-parallel IEEE 802.3 CRC-32. Reset loads all ones; enabled bytes enter
// LSB first into a non-reflected register with polynomial 0x04C11DB7.
// fcs is the inverted bit reversal of that register, sent low byte first.
// A correct frame including FCS leaves residue 0xC704DD7B (the bit reversal
// of 0xDEBB20E3). The bench checks the independent "123456789" known answer.
// Used by the standalone frame-layer modules, which are not in either top.

`timescale 1ns / 1ps

`default_nettype none

module eth_crc32 (
    input  logic        clk,
    input  logic        rst,        // synchronous, active high: reload all ones
    input  logic        en,         // consume `data` this cycle
    input  logic [7:0]  data,
    output logic [31:0] crc,        // the running register
    output logic [31:0] fcs         // what to transmit, ready to send LSB first
);

    logic [31:0] c;

    // Eight bits of the shift, unrolled. Written as a function so the loop is
    // visible rather than as 32 hand-derived XOR terms, which is where
    // hand-written CRCs usually go wrong.
    function automatic logic [31:0] step8(input logic [31:0] cur,
                                          input logic [7:0]  d);
        logic [31:0] v;
        logic        fb;
        int          i;
        begin
            v = cur;
            for (i = 0; i < 8; i++) begin
                fb = v[31] ^ d[i];              // LSB of the byte first
                v  = {v[30:0], 1'b0};
                if (fb) v = v ^ 32'h04C1_1DB7;
            end
            return v;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst)      c <= 32'hFFFF_FFFF;
        else if (en)  c <= step8(c, data);
    end

    assign crc = c;

    // Transmitted inverted and bit-reversed within the register, so that
    // sending fcs[7:0] then [15:8] then [23:16] then [31:24] puts the bits on
    // the wire in the order the standard wants.
    function automatic logic [31:0] bitrev32(input logic [31:0] v);
        logic [31:0] o;
        int i;
        begin
            for (i = 0; i < 32; i++) o[i] = v[31 - i];
            return o;
        end
    endfunction

    assign fcs = ~bitrev32(c);

endmodule

`default_nettype wire
