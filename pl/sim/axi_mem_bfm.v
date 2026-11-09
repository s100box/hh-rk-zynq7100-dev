// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// An AXI3/AXI4 slave that behaves like a memory, for simulating the fabric's
// AXI masters (axi_bist, fb_reader) before a bitstream exists.
//
// ⚠ It stalls. Every channel independently refuses a handshake with a
// configurable probability, and read data comes back after a configurable
// latency. A BFM that accepts everything on the cycle it is offered is blind
// to precisely the bugs worth finding here -- a master that assumes WREADY is
// always high, or that drops a beat when READY falls mid-burst, passes
// against a zero-delay model and then hangs on the real S_AXI_HP.
//
// It is in-order and single-ID, which is what those masters issue. It is NOT a
// general AXI slave: it does not reorder by ID, does not support WRAP or
// FIXED bursts, and ignores WSTRB (the master drives all-ones). Modeling
// those would be modeling something the master never does.
//
// `corrupt_en` flips a bit in one word on the way OUT, so the bench can prove
// the checker actually checks rather than always finding zero errors.
// `dead` stops answering entirely, so the watchdog can be proven to fire.

`timescale 1ns / 1ps

module axi_mem_bfm #(
    parameter integer DW    = 64,
    parameter integer IDW   = 6,
    parameter integer LENW  = 4,
    parameter integer WORDS = 8192,      // memory depth in beats
    parameter integer STALL = 30,        // percent chance of refusing a beat
    parameter integer RLAT  = 4          // min cycles AR -> first R
) (
    input  wire            clk,
    input  wire            rstn,

    // test hooks
    input  wire            dead,         // stop answering (watchdog test)
    input  wire            corrupt_en,
    input  wire [31:0]     corrupt_addr, // byte address of the beat to spoil
    input  wire [31:0]     corrupt_xor,  // applied to the low 32 bits

    input  wire [IDW-1:0]  s_awid,
    input  wire [31:0]     s_awaddr,
    input  wire [LENW-1:0] s_awlen,
    input  wire [2:0]      s_awsize,
    input  wire [1:0]      s_awburst,
    input  wire            s_awvalid,
    output wire            s_awready,

    input  wire [IDW-1:0]  s_wid,
    input  wire [DW-1:0]   s_wdata,
    input  wire [DW/8-1:0] s_wstrb,
    input  wire            s_wlast,
    input  wire            s_wvalid,
    output wire            s_wready,

    output reg  [IDW-1:0]  s_bid,
    output reg  [1:0]      s_bresp,
    output reg             s_bvalid,
    input  wire            s_bready,

    input  wire [IDW-1:0]  s_arid,
    input  wire [31:0]     s_araddr,
    input  wire [LENW-1:0] s_arlen,
    input  wire [2:0]      s_arsize,
    input  wire [1:0]      s_arburst,
    input  wire            s_arvalid,
    output wire            s_arready,

    output reg  [IDW-1:0]  s_rid,
    output reg  [DW-1:0]   s_rdata,
    output reg  [1:0]      s_rresp,
    output reg             s_rlast,
    output reg             s_rvalid,
    input  wire            s_rready
);

    localparam integer BPB = DW / 8;     // bytes per beat

    reg [DW-1:0] mem [0:WORDS-1];
    integer i;
    initial for (i = 0; i < WORDS; i = i + 1) mem[i] = {DW{1'b0}};

    // Counts the bench can assert on
    integer wr_beats, rd_beats, wr_bursts, rd_bursts;

    integer seed = 32'h1234_5678;
    function stall_now;
        input integer dummy;
        begin
            // $random is signed: a negative remainder would always compare
            // below STALL and bias a 30% request toward roughly 65%.
            stall_now = (STALL > 0) && (($unsigned($random(seed)) % 100) < STALL);
        end
    endfunction

    // ---------------------------------------------------------------- write
    reg        aw_busy;             // a burst's data is in progress
    reg [31:0] w_addr;
    reg [31:0] aw_q  [0:15];        // pending burst addresses
    reg [3:0]  aw_wr, aw_rd;
    wire       aw_full  = ((aw_wr + 4'd1) == aw_rd);
    wire       aw_empty = (aw_wr == aw_rd);

    reg aw_stall, w_stall;
    always @(posedge clk) begin
        aw_stall <= stall_now(0);
        w_stall  <= stall_now(0);
    end

    assign s_awready = rstn && !dead && !aw_full && !aw_stall;
    assign s_wready  = rstn && !dead && (aw_busy || !aw_empty) && !w_stall;

    reg [3:0] b_pending;

    always @(posedge clk) begin
        if (!rstn) begin
            aw_wr <= 4'd0; aw_rd <= 4'd0;
            aw_busy <= 1'b0; w_addr <= 32'd0;
            s_bvalid <= 1'b0; s_bid <= {IDW{1'b0}}; s_bresp <= 2'b00;
            b_pending <= 4'd0;
            wr_beats <= 0; wr_bursts <= 0;
        end else begin
            if (s_awvalid && s_awready) begin
                aw_q[aw_wr] <= s_awaddr;
                aw_wr <= aw_wr + 4'd1;
            end

            if (s_wvalid && s_wready) begin
                if (!aw_busy) begin
                    // first beat of a burst: take the head address
                    mem[(aw_q[aw_rd] / BPB) % WORDS] <= s_wdata;
                    w_addr  <= aw_q[aw_rd] + BPB;
                    aw_busy <= 1'b1;
                end else begin
                    mem[(w_addr / BPB) % WORDS] <= s_wdata;
                    w_addr <= w_addr + BPB;
                end
                wr_beats <= wr_beats + 1;
                if (s_wlast) begin
                    aw_busy   <= 1'b0;
                    aw_rd     <= aw_rd + 4'd1;
                    b_pending <= b_pending + 4'd1;
                    wr_bursts <= wr_bursts + 1;
                end
            end

            // B channel
            if (s_bvalid && s_bready) begin
                s_bvalid  <= 1'b0;
                b_pending <= b_pending - 4'd1 +
                             ((s_wvalid && s_wready && s_wlast) ? 4'd1 : 4'd0);
            end
            if (!s_bvalid && (b_pending != 4'd0) && !dead && !stall_now(0)) begin
                s_bvalid <= 1'b1;
                s_bid    <= {IDW{1'b0}};
                s_bresp  <= 2'b00;
            end
        end
    end

    // ----------------------------------------------------------------- read
    reg [31:0] ar_q   [0:15];
    reg [8:0]  arl_q  [0:15];
    reg [3:0]  ar_wr, ar_rd;
    wire       ar_full  = ((ar_wr + 4'd1) == ar_rd);
    wire       ar_empty = (ar_wr == ar_rd);

    reg        r_busy;
    reg [31:0] r_addr;
    reg [8:0]  r_left;
    integer    r_delay;

    reg ar_stall;
    always @(posedge clk) ar_stall <= stall_now(0);

    assign s_arready = rstn && !dead && !ar_full && !ar_stall;

    wire [31:0] r_word_idx = (r_addr / BPB) % WORDS;
    wire [DW-1:0] r_raw = mem[r_word_idx];
    wire spoil = corrupt_en && (r_addr == corrupt_addr);

    always @(posedge clk) begin
        if (!rstn) begin
            ar_wr <= 4'd0; ar_rd <= 4'd0;
            r_busy <= 1'b0; r_addr <= 32'd0; r_left <= 9'd0;
            s_rvalid <= 1'b0; s_rlast <= 1'b0; s_rresp <= 2'b00;
            s_rid <= {IDW{1'b0}}; s_rdata <= {DW{1'b0}};
            r_delay <= 0;
            rd_beats <= 0; rd_bursts <= 0;
        end else begin
            if (s_arvalid && s_arready) begin
                ar_q[ar_wr]  <= s_araddr;
                arl_q[ar_wr] <= s_arlen + 1;
                ar_wr <= ar_wr + 4'd1;
            end

            if (s_rvalid && s_rready) begin
                s_rvalid <= 1'b0;
                rd_beats <= rd_beats + 1;
                if (s_rlast) begin
                    rd_bursts <= rd_bursts + 1;
                    r_busy    <= 1'b0;
                    s_rlast   <= 1'b0;
                end
            end

            if (!r_busy && !ar_empty && !dead) begin
                if (r_delay < RLAT) begin
                    r_delay <= r_delay + 1;
                end else begin
                    r_busy  <= 1'b1;
                    r_addr  <= ar_q[ar_rd];
                    r_left  <= arl_q[ar_rd];
                    ar_rd   <= ar_rd + 4'd1;
                    r_delay <= 0;
                end
            end

            if (r_busy && !dead && (!s_rvalid || s_rready) && !stall_now(0)) begin
                if (r_left != 9'd0) begin
                    s_rvalid <= 1'b1;
                    s_rid    <= {IDW{1'b0}};
                    s_rresp  <= 2'b00;
                    s_rdata  <= spoil ? (r_raw ^ {{(DW-32){1'b0}}, corrupt_xor})
                                      : r_raw;
                    s_rlast  <= (r_left == 9'd1);
                    r_addr   <= r_addr + BPB;
                    r_left   <= r_left - 9'd1;
                end
            end
        end
    end

    // Let the bench read and write memory directly.
    task poke;
        input [31:0] addr;
        input [DW-1:0] data;
        begin mem[(addr / BPB) % WORDS] = data; end
    endtask

    task peek;
        input  [31:0] addr;
        output [DW-1:0] data;
        begin data = mem[(addr / BPB) % WORDS]; end
    endtask

endmodule
