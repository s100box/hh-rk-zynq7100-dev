// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Standalone byte-stream Ethernet receiver, not instantiated in either top.
// ce enables byte times. After preamble/SFD, every body and FCS byte is
// forwarded with m_valid; the consumer must retain or discard the final four
// FCS bytes. m_last is a separate enabled-byte-time indication after data,
// with m_valid low. m_good then reports minimum length, body PHY errors and
// CRC residue 0xC704DD7B. This interface has no output backpressure and an
// 11-bit length counter; consumers must bound supported frame sizes.

`timescale 1ns / 1ps

`default_nettype none

module eth_mac_rx (
    input  logic       clk,
    input  logic       rstn,
    input  logic       ce,

    // GMII-ish in
    input  logic [7:0] rxd,
    input  logic       rx_dv,
    input  logic       rx_er,

    // frame out
    output logic [7:0] m_data,
    output logic       m_valid,
    output logic       m_last,

    // asserted with m_last: the frame passed the FCS check and was long
    // enough to be a frame at all
    output logic       m_good,
    output logic [10:0] m_len,      // bytes delivered, FCS included

    output logic       busy
);

    localparam logic [7:0]  SFD      = 8'hD5;
    localparam logic [31:0] RESIDUE  = 32'hC704_DD7B;
    localparam int          MIN_RX   = 64;   // 60 + FCS

    typedef enum logic [1:0] { R_IDLE, R_PRE, R_DATA, R_END } state_t;

    state_t      state;
    logic [10:0] len;
    logic        saw_err;

    logic        crc_rst, crc_en;
    logic [31:0] crc_out, fcs_unused;

    eth_crc32 crc (
        .clk  (clk),
        .rst  (crc_rst),
        .en   (crc_en & ce),
        .data (rxd),
        .crc  (crc_out),
        .fcs  (fcs_unused)
    );

    assign busy = (state != R_IDLE);

    always_comb begin
        crc_rst = (state == R_IDLE) || (state == R_PRE);
        crc_en  = (state == R_DATA) && rx_dv;
    end

    always_ff @(posedge clk) begin
        if (!rstn) begin
            state   <= R_IDLE;
            len     <= 11'd0;
            saw_err <= 1'b0;
            m_data  <= 8'h00;
            m_valid <= 1'b0;
            m_last  <= 1'b0;
            m_good  <= 1'b0;
            m_len   <= 11'd0;
        end else if (ce) begin
            m_valid <= 1'b0;
            m_last  <= 1'b0;

            case (state)
                R_IDLE: begin
                    m_good  <= 1'b0;
                    len     <= 11'd0;
                    saw_err <= 1'b0;
                    // Any carrier at all starts the preamble hunt. Waiting
                    // for a specific preamble byte would lose frames whose
                    // first bytes the PHY ate while recovering the clock,
                    // which is normal and allowed.
                    if (rx_dv) state <= R_PRE;
                end

                R_PRE: begin
                    if (!rx_dv) begin
                        state <= R_IDLE;          // carrier lost: no frame
                    end else if (rxd == SFD) begin
                        state <= R_DATA;          // the frame starts next byte
                    end else if (rx_er) begin
                        saw_err <= 1'b1;
                    end
                    // anything else is preamble, or junk the PHY passed on;
                    // either way keep hunting until the carrier drops.
                end

                R_DATA: begin
                    if (rx_dv) begin
                        m_data  <= rxd;
                        m_valid <= 1'b1;
                        len     <= len + 11'd1;
                        if (rx_er) saw_err <= 1'b1;
                    end else begin
                        // Carrier dropped: that was the end of the frame. The
                        // verdict is available now because the residue covers
                        // the FCS bytes already consumed.
                        m_last <= 1'b1;
                        m_len  <= len;
                        m_good <= (crc_out == RESIDUE) && !saw_err &&
                                  (len >= MIN_RX);
                        state  <= R_END;
                    end
                end

                R_END: begin
                    // One idle byte-time before looking for the next frame,
                    // so m_last is never adjacent to the next m_valid.
                    state <= R_IDLE;
                end

                default: state <= R_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
