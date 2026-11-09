// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Standalone byte-stream Ethernet transmitter, not instantiated in either
// board design. ce sets the byte rate; input handshakes occur only when
// s_ready is high. The producer must provide continuous data through s_last.
// Output adds seven preamble bytes, SFD, padding to 60 bytes, four FCS bytes
// and at least twelve enabled byte-times of inter-frame gap.
// An input underrun emits an uncovered zero and continues; this is not a
// buffered transmitter or a guaranteed error-signaling interface. Buffer a
// complete frame before starting if the producer can stall.

`timescale 1ns / 1ps

`default_nettype none

module eth_mac_tx (
    input  logic       clk,          // the byte-rate clock
    input  logic       rstn,
    input  logic       ce,           // byte enable, so one clock can serve
                                     // 1000/100/10 by gating the byte rate

    // frame in
    input  logic [7:0] s_data,
    input  logic       s_valid,
    input  logic       s_last,
    output logic       s_ready,

    // GMII-ish out
    output logic [7:0] txd,
    output logic       tx_en,

    output logic       busy
);

    localparam logic [7:0] PREAMBLE = 8'h55;
    localparam logic [7:0] SFD      = 8'hD5;
    localparam int         MIN_LEN  = 60;   // before the FCS
    localparam int         IFG      = 12;

    typedef enum logic [2:0] {
        S_IDLE, S_PRE, S_SFD, S_DATA, S_PAD, S_FCS, S_IFG
    } state_t;

    state_t      state;
    logic [3:0]  cnt;        // preamble / FCS / IFG counter
    logic [10:0] len;        // bytes of frame emitted so far
    logic [31:0] fcs_shift;

    logic        crc_rst, crc_en;
    logic [7:0]  crc_data;
    logic [31:0] crc_out, fcs_out;

    eth_crc32 crc (
        .clk  (clk),
        .rst  (crc_rst),
        .en   (crc_en & ce),
        .data (crc_data),
        .crc  (crc_out),
        .fcs  (fcs_out)
    );

    // The payload is consumed only in S_DATA, and only when the byte rate
    // allows it.
    assign s_ready = (state == S_DATA) && ce;
    assign busy    = (state != S_IDLE);

    always_comb begin
        crc_rst  = (state == S_IDLE) || (state == S_PRE) || (state == S_SFD);
        crc_en   = 1'b0;
        crc_data = 8'h00;
        if (state == S_DATA && s_valid) begin
            crc_en   = 1'b1;
            crc_data = s_data;
        end else if (state == S_PAD) begin
            crc_en   = 1'b1;
            crc_data = 8'h00;
        end
    end

    always_ff @(posedge clk) begin
        if (!rstn) begin
            state     <= S_IDLE;
            cnt       <= 4'd0;
            len       <= 11'd0;
            txd       <= 8'h00;
            tx_en     <= 1'b0;
            fcs_shift <= 32'd0;
        end else if (ce) begin
            case (state)
                S_IDLE: begin
                    tx_en <= 1'b0;
                    txd   <= 8'h00;
                    len   <= 11'd0;
                    cnt   <= 4'd0;
                    if (s_valid) begin
                        state <= S_PRE;
                        tx_en <= 1'b1;
                        txd   <= PREAMBLE;
                        cnt   <= 4'd1;
                    end
                end

                S_PRE: begin
                    txd <= PREAMBLE;
                    if (cnt == 4'd6) begin      // seven altogether
                        state <= S_SFD;
                    end else begin
                        cnt <= cnt + 4'd1;
                    end
                end

                S_SFD: begin
                    txd   <= SFD;
                    state <= S_DATA;
                end

                S_DATA: begin
                    // s_ready is high here, so a valid byte is taken now.
                    if (s_valid) begin
                        txd <= s_data;
                        len <= len + 11'd1;
                        if (s_last) begin
                            // if/else rather than a ternary: assigning an
                            // enum from a conditional expression needs an
                            // explicit cast in strict SystemVerilog.
                            if ((len + 11'd1) < MIN_LEN) state <= S_PAD;
                            else                         state <= S_FCS;
                            cnt   <= 4'd0;
                            // The FCS is sampled a cycle later, once the CRC
                            // has taken this byte.
                        end
                    end else begin
                        // ⚠ A gap in the middle of a frame cannot be stalled
                        // on the wire -- Ethernet has no flow control inside a
                        // frame. This sends a zero that the FCS does not
                        // cover. The producer must prevent underruns; this
                        // interface does not guarantee an invalid FCS for
                        // every possible insertion and payload.
                        txd <= 8'h00;
                        len <= len + 11'd1;
                    end
                end

                S_PAD: begin
                    txd <= 8'h00;
                    len <= len + 11'd1;
                    if ((len + 11'd1) >= MIN_LEN) begin
                        state <= S_FCS;
                        cnt   <= 4'd0;
                    end
                end

                S_FCS: begin
                    // fcs_out is valid one cycle after the last byte entered
                    // the CRC, which is exactly now for cnt == 0.
                    if (cnt == 4'd0) begin
                        txd       <= fcs_out[7:0];
                        fcs_shift <= {8'h00, fcs_out[31:8]};
                    end else begin
                        txd       <= fcs_shift[7:0];
                        fcs_shift <= {8'h00, fcs_shift[31:8]};
                    end
                    if (cnt == 4'd3) begin
                        state <= S_IFG;
                        cnt   <= 4'd0;
                    end else begin
                        cnt <= cnt + 4'd1;
                    end
                end

                S_IFG: begin
                    tx_en <= 1'b0;
                    txd   <= 8'h00;
                    if (cnt == IFG - 1) begin
                        state <= S_IDLE;
                        cnt   <= 4'd0;
                    end else begin
                        cnt <= cnt + 4'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
