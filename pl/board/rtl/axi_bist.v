// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// An AXI master that fills a region of memory with an address-derived
// pattern, reads it back, checks it, and says how long it took.
//
// It exercises S_AXI_HP (the wide port into PS DRAM) and the fabric
// interrupt, and measures bandwidth that CPU-driven accesses through
// M_AXI_GP0 cannot, since there the CPU would be the bottleneck.
//
// One instance is pointed at each memory worth testing:
//
//   S_AXI_HP1 -> PS DRAM    64-bit AXI3, ID width 6
//   S_AXI_HP2 -> PS DRAM    64-bit AXI3, ID width 6
//   MIG       -> PL DDR3    32-bit AXI4, ID width 12   (both designs)
//
// Hence the parameters. AXI3 carries a 4-bit LEN and a WID on the write data
// channel; AXI4 carries an 8-bit LEN and no WID. The PS7's HP slaves are
// AXI3 and the generated MIG slave is AXI4, so a master that spoke only one
// of them would need a protocol converter to reach the other.
//
// ⚠ THE PATTERN IS A FUNCTION OF THE ADDRESS, and that is the whole point.
// A pattern from a free-running LFSR would be written and read back in the
// same order, so a design that put every burst at the same wrong place, or
// that dropped the top address bits, would still pass. Deriving each 32-bit
// lane from the byte address OF THAT LANE means data that lands anywhere
// other than where it was aimed reads back as a mismatch.
//
// ⚠ Caches. The HP ports are not coherent with the CPU's caches. Nothing in
// here can tell a bad memory from a stale cache line, so software that wants
// to look at what this wrote has to map the region uncached -- see the
// reserved-memory node in the device tree and linux/README.md.

`default_nettype none

module axi_bist #(
    parameter integer DW     = 64,   // data width: 64 for HP, 32 for the MIG
    parameter integer IDW    = 6,    // ID width:    6 for HP, 12 for the MIG
    parameter integer LENW   = 4,    // 4 = AXI3, 8 = AXI4
    parameter integer BEATS  = 16,   // beats per burst (AXI3 allows at most 16)
    parameter integer MAXOUT = 4,    // bursts in flight
    // log2 of the clocks with no AXI handshake before a run gives up (2^24 =
    // 168 ms at 100 MHz). A slave that never responds would otherwise leave
    // `busy` set forever with nothing to read out. STATUS[3] says it was this.
    parameter integer WDOG   = 24
) (
    input  wire            clk,
    input  wire            rstn,

    // Register window: 16 words, addressed by word index (see the map below).
    // Reads and writes carry their own index because the AXI slave upstream
    // can present a write beat and a read beat on the same cycle.
    input  wire [3:0]      reg_waddr,
    input  wire            reg_we,
    input  wire [31:0]     reg_wdata,
    input  wire [3:0]      reg_raddr,
    output reg  [31:0]     reg_rdata,
    output wire            irq,

    output wire [IDW-1:0]  m_awid,
    output wire [31:0]     m_awaddr,
    output wire [LENW-1:0] m_awlen,
    output wire [2:0]      m_awsize,
    output wire [1:0]      m_awburst,
    output wire [1:0]      m_awlock,
    output wire [3:0]      m_awcache,
    output wire [2:0]      m_awprot,
    output wire [3:0]      m_awqos,
    output wire            m_awvalid,
    input  wire            m_awready,

    output wire [IDW-1:0]  m_wid,      // AXI3 only; leave unconnected when LENW == 8
    output wire [DW-1:0]   m_wdata,
    output wire [DW/8-1:0] m_wstrb,
    output wire            m_wlast,
    output wire            m_wvalid,
    input  wire            m_wready,

    input  wire [IDW-1:0]  m_bid,
    input  wire [1:0]      m_bresp,
    input  wire            m_bvalid,
    output wire            m_bready,

    output wire [IDW-1:0]  m_arid,
    output wire [31:0]     m_araddr,
    output wire [LENW-1:0] m_arlen,
    output wire [2:0]      m_arsize,
    output wire [1:0]      m_arburst,
    output wire [1:0]      m_arlock,
    output wire [3:0]      m_arcache,
    output wire [2:0]      m_arprot,
    output wire [3:0]      m_arqos,
    output wire            m_arvalid,
    input  wire            m_arready,

    input  wire [IDW-1:0]  m_rid,
    input  wire [DW-1:0]   m_rdata,
    input  wire [1:0]      m_rresp,
    input  wire            m_rlast,
    input  wire            m_rvalid,
    output wire            m_rready
);

    // ----------------------------------------------------------------------
    // Register map (word index within this engine's 64-byte window)
    //
    //   0  CTRL     RW  [0] start (a pulse; reads back 0)
    //                   [1] stop -- stop issuing, let outstanding drain
    //                   [4] irq_en
    //                   [9:8] mode: 0 = write, 1 = read+check, 2 = both
    //   1  ADDR     RW  base byte address; must be burst-aligned
    //   2  BURSTS   RW  number of bursts to move
    //   3  SEED     RW  pattern seed
    //   4  STATUS   RO  [0] busy [1] done [2] irq pending [3] watchdog fired
    //                   [6:4] state [7] stopped early
    //   5  ERRORS   RO  mismatching beats plus error responses, saturating
    //   6  CYCLES   RO  clocks from start to done
    //   7  ERRBITS  RO  sticky OR of (expected ^ got), folded onto 32 bits
    //   8  BADADDR  RO  byte address of the first mismatching beat
    //   9  BADEXP   RO  what that beat should have been (low 32 bits)
    //  10  BADGOT   RO  what it was (low 32 bits). A write-response error
    //                   records the burst address, 0 and BRESP.
    //  11  BEATS    RO  beats actually transferred
    //  12  ACK      W   write 1 to clear done and irq pending (a start clears
    //                   the rest)
    // ----------------------------------------------------------------------
    localparam integer BYTES_PER_BEAT = DW / 8;
    localparam integer BURST_BYTES    = BEATS * BYTES_PER_BEAT;
    // BEATS - 1 is a 32-bit integer; only its low LENW bits are the field.
    /* verilator lint_off WIDTHTRUNC */
    localparam [LENW-1:0] AXLEN       = BEATS - 1;
    /* verilator lint_on WIDTHTRUNC */
    localparam [2:0]   AXSIZE         = (DW == 32) ? 3'b010 :
                                        (DW == 64) ? 3'b011 : 3'b100;

    localparam [2:0] S_IDLE = 3'd0, S_WRITE = 3'd1, S_WDRAIN = 3'd2,
                     S_READ = 3'd3, S_RDRAIN = 3'd4, S_DONE  = 3'd5;

    reg [2:0]  state;
    reg [31:0] cfg_addr, cfg_bursts, cfg_seed;
    reg [1:0]  cfg_mode;
    reg        cfg_irq_en;
    reg        stop_req, stopped;

    reg [31:0] err_count, err_bits, bad_addr, bad_exp, bad_got, cycles, beats;
    reg        busy, done, irq_pend, wdog_fired, bad_seen;

    // ----------------------------------------------------------------------
    // The pattern: xorshift32 of the lane's own byte address, mixed with the
    // seed, so every 32-bit lane in memory holds a different and
    // address-dependent value.
    // ----------------------------------------------------------------------
    function [31:0] mix;
        input [31:0] x;
        reg [31:0] v;
        begin
            v = x ^ 32'h9E37_79B9;
            v = v ^ (v << 13);
            v = v ^ (v >> 17);
            v = v ^ (v << 5);
            mix = v;
        end
    endfunction

    function [DW-1:0] pattern;
        input [31:0] addr;          // byte address of the beat
        input [31:0] seed;
        integer j;
        reg [DW-1:0] p;
        begin
            p = {DW{1'b0}};
            for (j = 0; j < DW/32; j = j + 1)
                p[j*32 +: 32] = mix((addr + j*4) ^ seed);
            pattern = p;
        end
    endfunction

    // ----------------------------------------------------------------------
    // Issue and completion counters
    // ----------------------------------------------------------------------
    reg [31:0] aw_cnt, w_burst, b_cnt;      // write phase
    reg [31:0] ar_cnt, r_burst;             // read phase
    reg [31:0] aw_addr, w_addr, ar_addr, r_addr;
    reg [15:0] w_beat;

    wire more_aw = (state == S_WRITE) && !stop_req && (aw_cnt < cfg_bursts) &&
                   ((aw_cnt - b_cnt) < MAXOUT);
    wire more_ar = (state == S_READ)  && !stop_req && (ar_cnt < cfg_bursts) &&
                   ((ar_cnt - r_burst) < MAXOUT);

    // STOP prevents new bursts but cannot withdraw an address already offered
    // while READY was low. Keep that offer through the drain phase. A watchdog
    // is an emergency abort; reset the AXI path before reuse if work was in flight.
    reg aw_held, ar_held;
    always @(posedge clk) begin
        if (!rstn || state == S_DONE) begin
            aw_held <= 1'b0;
            ar_held <= 1'b0;
        end else begin
            aw_held <= m_awvalid && !m_awready;
            ar_held <= m_arvalid && !m_arready;
        end
    end

    // Data follows address order, but can be offered alongside a stalled AW.
    // A slave may wait for WVALID before asserting AWREADY, so waiting for
    // address acceptance here would deadlock that legal channel dependency.
    // At most one data burst may lead its address; the held AW then drains.
    wire more_w  = ((state == S_WRITE) || (state == S_WDRAIN)) &&
                   ((w_burst < aw_cnt) || (w_burst == aw_cnt && m_awvalid));

    assign m_awid    = {IDW{1'b0}};
    assign m_awaddr  = aw_addr;
    assign m_awlen   = AXLEN;
    assign m_awsize  = AXSIZE;
    assign m_awburst = 2'b01;               // INCR
    assign m_awlock  = 2'b00;
    assign m_awcache = 4'b0011;             // bufferable, modifiable
    assign m_awprot  = 3'b000;
    assign m_awqos   = 4'b0000;
    assign m_awvalid = more_aw || (aw_held && state != S_DONE);

    assign m_wid     = {IDW{1'b0}};
    assign m_wdata   = pattern(w_addr, cfg_seed);
    assign m_wstrb   = {(DW/8){1'b1}};
    assign m_wlast   = (w_beat == BEATS - 1);
    assign m_wvalid  = more_w;

    assign m_bready  = 1'b1;

    assign m_arid    = {IDW{1'b0}};
    assign m_araddr  = ar_addr;
    assign m_arlen   = AXLEN;
    assign m_arsize  = AXSIZE;
    assign m_arburst = 2'b01;
    assign m_arlock  = 2'b00;
    assign m_arcache = 4'b0011;
    assign m_arprot  = 3'b000;
    assign m_arqos   = 4'b0000;
    assign m_arvalid = more_ar || (ar_held && state != S_DONE);

    assign m_rready  = 1'b1;

    assign irq = cfg_irq_en & irq_pend;

    wire aw_fire  = m_awvalid & m_awready;
    wire w_fire   = m_wvalid  & m_wready;
    wire b_fire   = m_bvalid  & m_bready;
    wire ar_fire  = m_arvalid & m_arready;
    wire r_fire   = m_rvalid  & m_rready;
    wire any_fire = aw_fire | w_fire | b_fire | ar_fire | r_fire;

    wire [DW-1:0] r_expect = pattern(r_addr, cfg_seed);
    wire [DW-1:0] r_diff   = r_expect ^ m_rdata;
    wire          r_bad    = r_fire && ((|r_diff) || (m_rresp != 2'b00));

    // (expected ^ got) folded onto 32 bits, so a data line stuck across the
    // whole port shows up as one bit here however wide the port is.
    integer f;
    reg [31:0] diff_fold;
    always @(*) begin
        diff_fold = 32'd0;
        for (f = 0; f < DW/32; f = f + 1)
            diff_fold = diff_fold | r_diff[f*32 +: 32];
    end

    // Any handshake resets the watchdog; it only runs while busy.
    reg [WDOG:0] wdog;
    wire wdog_trip = wdog[WDOG];

    // ----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            state      <= S_IDLE;
            cfg_addr   <= 32'd0;
            cfg_bursts <= 32'd0;
            cfg_seed   <= 32'd0;
            cfg_mode   <= 2'd0;
            cfg_irq_en <= 1'b0;
            stop_req   <= 1'b0;
            stopped    <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            irq_pend   <= 1'b0;
            wdog_fired <= 1'b0;
            bad_seen   <= 1'b0;
            err_count  <= 32'd0;
            err_bits   <= 32'd0;
            bad_addr   <= 32'd0;
            bad_exp    <= 32'd0;
            bad_got    <= 32'd0;
            cycles     <= 32'd0;
            beats      <= 32'd0;
            aw_cnt     <= 32'd0;
            w_burst    <= 32'd0;
            b_cnt      <= 32'd0;
            ar_cnt     <= 32'd0;
            r_burst    <= 32'd0;
            aw_addr    <= 32'd0;
            w_addr     <= 32'd0;
            ar_addr    <= 32'd0;
            r_addr     <= 32'd0;
            w_beat     <= 16'd0;
            wdog       <= 0;
        end else begin
            // -------------------------- register writes
            if (reg_we) begin
                case (reg_waddr)
                    4'd0: begin
                        cfg_irq_en <= reg_wdata[4];
                        cfg_mode   <= reg_wdata[9:8];
                        if (reg_wdata[1]) stop_req <= 1'b1;
                        if (reg_wdata[0] && !busy) begin
                            busy       <= 1'b1;
                            done       <= 1'b0;
                            irq_pend   <= 1'b0;
                            stop_req   <= 1'b0;
                            stopped    <= 1'b0;
                            wdog_fired <= 1'b0;
                            bad_seen   <= 1'b0;
                            err_count  <= 32'd0;
                            err_bits   <= 32'd0;
                            bad_addr   <= 32'd0;
                            bad_exp    <= 32'd0;
                            bad_got    <= 32'd0;
                            cycles     <= 32'd0;
                            beats      <= 32'd0;
                            aw_cnt     <= 32'd0;
                            w_burst    <= 32'd0;
                            b_cnt      <= 32'd0;
                            ar_cnt     <= 32'd0;
                            r_burst    <= 32'd0;
                            w_beat     <= 16'd0;
                            aw_addr    <= cfg_addr;
                            w_addr     <= cfg_addr;
                            ar_addr    <= cfg_addr;
                            r_addr     <= cfg_addr;
                            wdog       <= 0;
                            // mode 1 checks what is already in memory
                            state      <= (reg_wdata[9:8] == 2'd1) ? S_READ
                                                                   : S_WRITE;
                        end
                    end
                    4'd1:  if (!busy) cfg_addr   <= reg_wdata;
                    4'd2:  if (!busy) cfg_bursts <= reg_wdata;
                    4'd3:  if (!busy) cfg_seed   <= reg_wdata;
                    4'd12: if (reg_wdata[0]) begin
                        done     <= 1'b0;
                        irq_pend <= 1'b0;
                    end
                    default: ;
                endcase
            end

            // -------------------------- the run
            if (busy) begin
                cycles <= cycles + 32'd1;
                wdog   <= any_fire ? 0 : wdog + 1'b1;
            end

            if (aw_fire) begin
                aw_cnt  <= aw_cnt + 32'd1;
                aw_addr <= aw_addr + BURST_BYTES;
            end

            if (w_fire) begin
                beats  <= beats + 32'd1;
                w_addr <= w_addr + BYTES_PER_BEAT;
                if (m_wlast) begin
                    w_beat  <= 16'd0;
                    w_burst <= w_burst + 32'd1;
                end else begin
                    w_beat <= w_beat + 16'd1;
                end
            end

            if (b_fire) begin
                b_cnt <= b_cnt + 32'd1;
                if (m_bresp != 2'b00) begin
                    if (err_count != 32'hFFFF_FFFF)
                        err_count <= err_count + 32'd1;
                    if (!bad_seen) begin
                        bad_seen <= 1'b1;
                        bad_addr <= cfg_addr + (b_cnt * BURST_BYTES);
                        bad_exp  <= 32'd0;
                        bad_got  <= {30'd0, m_bresp};
                    end
                end
            end

            if (ar_fire) begin
                ar_cnt  <= ar_cnt + 32'd1;
                ar_addr <= ar_addr + BURST_BYTES;
            end

            if (r_fire) begin
                beats  <= beats + 32'd1;
                r_addr <= r_addr + BYTES_PER_BEAT;
                if (m_rlast) r_burst <= r_burst + 32'd1;
                if (r_bad) begin
                    if (err_count != 32'hFFFF_FFFF)
                        err_count <= err_count + 32'd1;
                    err_bits <= err_bits | diff_fold;
                    if (!bad_seen) begin
                        bad_seen <= 1'b1;
                        bad_addr <= r_addr;
                        bad_exp  <= r_expect[31:0];
                        bad_got  <= m_rdata[31:0];
                    end
                end
            end

            // -------------------------- phase sequencing
            case (state)
                S_WRITE: begin
                    if (wdog_trip) begin
                        wdog_fired <= 1'b1;
                        state      <= S_DONE;
                    end else if (stop_req) begin
                        stopped <= 1'b1;
                        state   <= S_WDRAIN;
                    end else if (aw_cnt == cfg_bursts) begin
                        state <= S_WDRAIN;
                    end
                end
                S_WDRAIN: begin
                    // every issued burst has had its data sent AND answered
                    if (wdog_trip) begin
                        wdog_fired <= 1'b1;
                        state      <= S_DONE;
                    end else if ((w_burst == aw_cnt) && (b_cnt == aw_cnt) && !m_awvalid) begin
                        state <= (cfg_mode == 2'd2 && !stop_req) ? S_READ
                                                                 : S_DONE;
                    end
                end
                S_READ: begin
                    if (wdog_trip) begin
                        wdog_fired <= 1'b1;
                        state      <= S_DONE;
                    end else if (stop_req) begin
                        stopped <= 1'b1;
                        state   <= S_RDRAIN;
                    end else if (ar_cnt == cfg_bursts) begin
                        state <= S_RDRAIN;
                    end
                end
                S_RDRAIN: begin
                    if (wdog_trip) begin
                        wdog_fired <= 1'b1;
                        state      <= S_DONE;
                    end else if (r_burst == ar_cnt && !m_arvalid) begin
                        state <= S_DONE;
                    end
                end
                S_DONE: begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    irq_pend <= 1'b1;
                    state    <= S_IDLE;
                end
                default: ;      // S_IDLE waits for a start
            endcase
        end
    end

    // ----------------------------------------------------------------------
    always @(*) begin
        case (reg_raddr)
            4'd0:  reg_rdata = {22'd0, cfg_mode, 3'd0, cfg_irq_en, 4'd0};
            4'd1:  reg_rdata = cfg_addr;
            4'd2:  reg_rdata = cfg_bursts;
            4'd3:  reg_rdata = cfg_seed;
            4'd4:  reg_rdata = {24'd0, stopped, state, wdog_fired,
                                irq_pend, done, busy};
            4'd5:  reg_rdata = err_count;
            4'd6:  reg_rdata = cycles;
            4'd7:  reg_rdata = err_bits;
            4'd8:  reg_rdata = bad_addr;
            4'd9:  reg_rdata = bad_exp;
            4'd10: reg_rdata = bad_got;
            4'd11: reg_rdata = beats;
            default: reg_rdata = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
