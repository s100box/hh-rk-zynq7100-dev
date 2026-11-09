// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// GTX PRBS exerciser for the two SFP+ cages (quad 112, channels 2 and 3):
// each channel runs the transceiver's own PRBS generator and checker, with
// the line rate and loopback chosen per channel at run time.
//
//   LOOPBACK  000 normal (external loop)   001 near-end PCS   010 near-end PMA
//             100 far-end PMA              110 far-end PCS
//   With a passive DAC between J1 and J4, use 000 and the same rate on both:
//   each checker then grades the other cage's transmitter.
//
//   RATE  line rate     PLL                      divider   user clock
//   0     3.125 Gb/s    CPLL, VCO 3.125 GHz      /2        78.125 MHz
//   1     6.25 Gb/s     CPLL, VCO 3.125 GHz      /1        156.25 MHz
//   2     10.3125 Gb/s  QPLL, VCO 10.3125 GHz    /1        257.8125 MHz
//   Both PLLs run all the time from the 156.25 MHz reference on MGTREFCLK1_112.
//
// ⚠ A rate change also rewrites RXCDR_CFG and PMA_RSV over the DRP -- the
// only attributes in which the wizard's configurations of the three rates
// differ (PMA_RSV: 0x00018480 below 6.6 Gb/s, 0x001E7080 at 10.3125). PMA_RSV
// is a wrapper PARAMETER default, invisible in a diff of the channel's
// attributes, and without it 10.3125 Gb/s fails even in near-end loopback.
// Writing a channel's RATE field runs the whole sequence -- DRP writes,
// TX/RXSYSCLKSEL, a reset through the wizard's startup FSMs -- and RATE_STAT
// says when it is done.
//
// ⚠ The divider is the TXOUT_DIV/RXOUT_DIV ATTRIBUTE, rewritten over the DRP
// while the channel is held in reset; TXRATE and RXRATE stay at 000 ("use the
// attribute"). Those ports are sampled on TXUSRCLK2/RXUSRCLK2, which here is
// TXOUTCLK -- the clock the change itself stops and restarts -- and a change
// on them starts the GTX's own rate-change reset, which would overlap the
// startup FSMs' reset (UG476, "TX Rate Change").
//
// ⚠ Known issue: a receiver can intermittently fail to leave reset at a CPLL
// rate (STAT 0x8B: rxresetdone and rx_fsm_reset_done never set), after a
// long run at 10.3125 Gb/s or as the first access after a PL load. Writing
// RATE 2 and then RATE 0 recovers it; so does a reload. Cause not known.
//
// The datapath is 40 bits, so TXOUTCLK through one BUFG (line rate / 40)
// drives all four USRCLK inputs; there is no MMCM.
//
// `errs` counts 40-bit WORDS with a PRBS error and `cycs` counts words; both
// saturate, and errs/(cycs*40) is a lower bound on the bit error rate. The
// pair is copied every 4096 user clocks and handed to the register domain by
// a toggle. Separate MMIO reads can span snapshots; stop RX and wait for the
// final copy when a stable pair is required. End measurement before either
// counter saturates (about 16.7 seconds for cycs at the fastest rate).
//
// ⚠ After changing LOOPBACK or the PRBS selects, pulse the receiver reset
// (RESET bit), then reset the counters (PULSE bit 1); after a RATE change,
// reset the counters once RATE_STAT clears. gtxtest.sh does this.

`default_nettype none

module gtx_prbs #(
    parameter [31:0] ID_MAGIC = 32'h4758_0003    // "GX", two channels, rates
) (
    input  wire        clk,        // 100 MHz: registers, DRP, the startup FSMs
    input  wire        rstn,

    // 156.25 MHz from Y8 on MGTREFCLK1_112, ALREADY through its
    // IBUFDS_GTE2. The top level owns that buffer; this module takes its O
    // output.
    input  wire        refclk,

    // [0] = SFP1 (112 channel 2), [1] = SFP2 (112 channel 3)
    output wire [1:0]  txp,
    output wire [1:0]  txn,
    input  wire [1:0]  rxp,
    input  wire [1:0]  rxn,

    input  wire [1:0]  los,        // cage LOS, already synchronized to clk

    // Register window: block 3 of axi4_regs, so 0x100 + these offsets
    //
    //   0x00  ID        RO  ID_MAGIC
    //   0x04  RESET     RW  [0] ch0 soft_reset_tx  [1] ch0 soft_reset_rx
    //                       [2] ch1 soft_reset_tx  [3] ch1 soft_reset_rx
    //                       levels: write 1, then write 0
    //   0x08  CH0_CTRL  RW  [2:0]  loopback (table above)
    //                       [6:4]  txprbssel: 0 off, 1 PRBS-7, 2 PRBS-15,
    //                              3 PRBS-23, 4 PRBS-31
    //                       [10:8] rxprbssel, same encoding
    //                       [12]   txpolarity   [13] rxpolarity
    //                       [19:16] TXDIFFCTRL XOR 4'b1000 (0: the
    //                              wizard's 807 mV)  [30] RXLPMEN (0: DFE)
    //                       Both go straight to their ports, which are
    //                       asynchronous (UG476): a swing change takes
    //                       effect at once; RXLPMEN wants a receiver reset
    //                       after it. [29:20] are stored and read back but
    //                       drive nothing: the wizard (3.6) keeps its TX
    //                       cursor ports tied off whatever the options say.
    //   0x0C  CH0_PULSE WO  [0] inject one TX bit error  [1] reset counters
    //   0x10  CH0_STAT  RO  [0] cplllock          [1] txresetdone
    //                       [2] rxresetdone       [3] tx_fsm_reset_done
    //                       [4] rx_fsm_reset_done [5] cpllfbclklost
    //                       [6] PRBS error seen since the last counter reset
    //                       [7] cage LOS
    //   0x14  CH0_ERRS  RO  erroneous words
    //   0x18  CH0_CYCS  RO  RXUSRCLK2 cycles counted
    //   0x1C..0x2C          CH1_CTRL, CH1_PULSE, CH1_STAT, CH1_ERRS, CH1_CYCS
    //   0x30  RATE      RW  [1:0] ch0 RATE, [5:4] ch1 RATE (table above; 3 is
    //                       refused and reads back as the old value). A
    //                       write that changes a channel's RATE starts its
    //                       rate sequence; one written while a sequence runs
    //                       starts another when it ends.
    //   0x34  RATE_STAT RO  [0] ch0 sequence busy  [1] ch1 busy
    //                       [4] ch0 last sequence failed (DRP timeout)
    //                       [5] ch1 failed
    //                       [8] QPLL locked  [9] QPLL refclk lost
    //                       [17:16] ch0 rate in effect  [21:20] ch1
    //   0x38  DRP       RW  raw DRP access, for experiments. Write:
    //                       [8:0] address, [12] channel, [16] 1 = write,
    //                       [31:24] must be 0xD5 to start. Read:
    //                       [15:0] the data read (or written), [16] busy,
    //                       [17] done, [18] timed out
    //   0x3C  DRP_WDATA RW  [15:0] the data a DRP write sends
    //
    // ⚠ The DRP port also carries the rate sequence's writes: a raw access
    // while a channel's RATE sequence is busy waits until it has finished.
    input  wire [3:0]  reg_waddr,
    input  wire        reg_we,
    input  wire [31:0] reg_wdata,
    input  wire [3:0]  reg_raddr,
    output reg  [31:0] reg_rdata,

    // SFP1's user clock, for the top level's frequency counter: the line
    // rate / 40, so 78.125 MHz at the reset rate.
    output wire        usrclk_sfp1
);

    localparam integer NCH = 2;

    // RXCDR_CFG per RATE, from the wizard's configurations of each rate.
    localparam [71:0] CDR_3G  = 72'h03_0000_23ff_4020_0020;
    localparam [71:0] CDR_6G  = 72'h03_0000_23ff_2040_0020;
    localparam [71:0] CDR_10G = 72'h0b_0000_23ff_1040_0020;
    // PMA_RSV per RATE: the wizard's value below 6.6 Gb/s, and above.
    localparam [31:0] PMA_LO  = 32'h0001_8480;
    localparam [31:0] PMA_HI  = 32'h001E_7080;
    // In the GTXE2_CHANNEL DRP map, read back on this board: RXCDR_CFG [15:0]
    // at 0x0A8 up to [63:48] at 0x0AB and [71:64] in the low byte of 0x0AC;
    // PMA_RSV [15:0] at 0x099 and [31:16] at 0x09A. From UG476's map:
    // TXOUT_DIV [6:4] and RXOUT_DIV [2:0] at 0x088, coded 1 -> 0, 2 -> 1.
    localparam [8:0] DRP_CDR0 = 9'h0A8;
    localparam [8:0] DRP_PMA0 = 9'h099;
    localparam [8:0] DRP_DIV  = 9'h088;

    // ---------------------------------------------------------------------
    // Control registers (clk domain)
    // ---------------------------------------------------------------------
    reg  [3:0]     softrst;
    reg  [13:0]    ctrl0, ctrl1;
    reg  [14:0]    drv0, drv1;             // CTRL [30:16]
    wire [15*NCH-1:0] drv_all = {drv1, drv0};
    wire [14*NCH-1:0] ctrl_all = {ctrl1, ctrl0};
    reg  [NCH-1:0] force_tog;
    reg  [NCH-1:0] cntrst_tog;
    reg  [1:0]     rate_req [0:NCH-1];     // what software asked for
    reg  [NCH-1:0] rate_go;                 // one clk: start the sequence
    reg  [31:0]    drp_cmd;
    reg            drp_go;
    reg  [15:0]    drp_wdata;

    always @(posedge clk) begin
        rate_go <= {NCH{1'b0}};
        drp_go  <= 1'b0;
        if (!rstn) begin
            softrst     <= 4'd0;
            force_tog   <= {NCH{1'b0}};
            cntrst_tog  <= {NCH{1'b0}};
            ctrl0       <= 14'd0;
            ctrl1       <= 14'd0;
            drv0        <= 15'd0;
            drv1        <= 15'd0;
            rate_req[0] <= 2'd0;
            rate_req[1] <= 2'd0;
            drp_cmd     <= 32'd0;
            drp_wdata   <= 16'd0;
        end else if (reg_we) begin
            case (reg_waddr)
                4'd1: softrst <= reg_wdata[3:0];
                4'd2: begin ctrl0 <= reg_wdata[13:0]; drv0 <= reg_wdata[30:16]; end
                4'd3: begin
                    if (reg_wdata[0]) force_tog[0]  <= ~force_tog[0];
                    if (reg_wdata[1]) cntrst_tog[0] <= ~cntrst_tog[0];
                end
                4'd7: begin ctrl1 <= reg_wdata[13:0]; drv1 <= reg_wdata[30:16]; end
                4'd8: begin
                    if (reg_wdata[0]) force_tog[1]  <= ~force_tog[1];
                    if (reg_wdata[1]) cntrst_tog[1] <= ~cntrst_tog[1];
                end
                4'd12: begin
                    if (reg_wdata[1:0] != 2'd3 && reg_wdata[1:0] != rate_req[0]) begin
                        rate_req[0] <= reg_wdata[1:0];
                        rate_go[0]  <= 1'b1;
                    end
                    if (reg_wdata[5:4] != 2'd3 && reg_wdata[5:4] != rate_req[1]) begin
                        rate_req[1] <= reg_wdata[5:4];
                        rate_go[1]  <= 1'b1;
                    end
                end
                4'd14: if (reg_wdata[31:24] == 8'hD5) begin
                    drp_cmd <= reg_wdata;
                    drp_go  <= 1'b1;
                end
                4'd15: drp_wdata <= reg_wdata[15:0];
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // The QPLL, shared by both channels: 156.25 MHz x 66 = 10.3125 GHz,
    // which is 10.3125 Gb/s at divider 1. The settings are the wizard's own
    // for that rate, from its example design's common block.
    // ---------------------------------------------------------------------
    wire qplloutclk, qplloutrefclk, qplllock, qpllrefclklost;
    // A reset after the reference is up: the fabric reset, stretched.
    reg [7:0] qrst_cnt = 8'd0;
    always @(posedge clk)
        if (!rstn)             qrst_cnt <= 8'd0;
        else if (!qrst_cnt[7]) qrst_cnt <= qrst_cnt + 8'd1;
    wire qpllreset = !qrst_cnt[7];

    GTXE2_COMMON #(
        .SIM_RESET_SPEEDUP        ("FALSE"),
        .SIM_QPLLREFCLK_SEL       (3'b010),
        .SIM_VERSION              ("4.0"),
        .BIAS_CFG                 (64'h0000040000001000),
        .COMMON_CFG               (32'h00000000),
        .QPLL_CFG                 (27'h0680181),
        .QPLL_CLKOUT_CFG          (4'b0000),
        .QPLL_COARSE_FREQ_OVRD    (6'b010000),
        .QPLL_COARSE_FREQ_OVRD_EN (1'b0),
        .QPLL_CP                  (10'b0000011111),
        .QPLL_CP_MONITOR_EN       (1'b0),
        .QPLL_DMONITOR_SEL        (1'b0),
        .QPLL_FBDIV               (10'b0101000000),   // x66
        .QPLL_FBDIV_MONITOR_EN    (1'b0),
        .QPLL_FBDIV_RATIO         (1'b0),             // 0 for x66
        .QPLL_INIT_CFG            (24'h000006),
        .QPLL_LOCK_CFG            (16'h21E8),
        .QPLL_LPF                 (4'b1111),
        .QPLL_REFCLK_DIV          (1)
    ) qpll (
        .DRPADDR          (8'd0),
        .DRPCLK           (1'b0),
        .DRPDI            (16'd0),
        .DRPDO            (),
        .DRPEN            (1'b0),
        .DRPRDY           (),
        .DRPWE            (1'b0),
        .GTGREFCLK        (1'b0),
        .GTNORTHREFCLK0   (1'b0),
        .GTNORTHREFCLK1   (1'b0),
        .GTREFCLK0        (1'b0),
        .GTREFCLK1        (refclk),
        .GTSOUTHREFCLK0   (1'b0),
        .GTSOUTHREFCLK1   (1'b0),
        .QPLLDMONITOR     (),
        .QPLLOUTCLK       (qplloutclk),
        .QPLLOUTREFCLK    (qplloutrefclk),
        .REFCLKOUTMONITOR (),
        .QPLLFBCLKLOST    (),
        .QPLLLOCK         (qplllock),
        .QPLLLOCKDETCLK   (clk),
        .QPLLLOCKEN       (1'b1),
        .QPLLOUTRESET     (1'b0),
        .QPLLPD           (1'b0),
        .QPLLREFCLKLOST   (qpllrefclklost),
        .QPLLREFCLKSEL    (3'b010),                   // GTREFCLK1
        .QPLLRESET        (qpllreset),
        .QPLLRSVD1        (16'b0000000000000000),
        .QPLLRSVD2        (5'b11111),
        .BGBYPASSB        (1'b1),
        .BGMONITORENB     (1'b1),
        .BGPDB            (1'b1),
        .BGRCALOVRD       (5'b11111),
        .PMARSVD          (8'b00000000),
        .RCALENB          (1'b1)
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] ql_s0 = 2'd0, ql_s1 = 2'd0;
    always @(posedge clk) begin
        ql_s0 <= {qpllrefclklost, qplllock};
        ql_s1 <= ql_s0;
    end

    // ---------------------------------------------------------------------
    // DRP: one master per channel, shared between the rate sequence and the
    // raw access register. Neither interrupts the other: a raw access waits
    // for a running sequence, and a sequence waits for a raw access already
    // ISSUED on its channel -- never for one still queued, which is itself
    // waiting for the sequence.
    // ---------------------------------------------------------------------
    wire [NCH-1:0] drp_rdy;
    wire [15:0]    drp_do [0:NCH-1];
    reg  [8:0]     drp_addr [0:NCH-1];
    reg  [15:0]    drp_di [0:NCH-1];
    reg  [NCH-1:0] drp_en, drp_we;

    // Raw access state
    reg        raw_busy, raw_done, raw_to;
    reg [15:0] raw_data;
    reg        raw_ch;
    reg [9:0]  raw_timer;

    // Rate sequence state, per channel
    localparam [3:0] S_IDLE = 4'd0, S_RST = 4'd1, S_RD4 = 4'd2, S_WR = 4'd3,
                     S_WAIT = 4'd4, S_SEL = 4'd5, S_SETTLE = 4'd6,
                     S_REL = 4'd7, S_RD8 = 4'd8;
    reg [3:0]  st [0:NCH-1];
    reg [2:0]  widx [0:NCH-1];
    reg [15:0] w4keep [0:NCH-1];            // 0x0AC as read, for its other byte
    reg [15:0] w8keep [0:NCH-1];            // 0x088 as read, for its other fields
    reg [15:0] timer [0:NCH-1];
    reg [1:0]  rate_eff [0:NCH-1];         // what the channel is running at
    reg [1:0]  seq_rate [0:NCH-1];         // the rate this sequence is setting
    reg [NCH-1:0] seq_rst;                  // holds the channel in soft reset
    reg [NCH-1:0] seq_fail;
    reg [9:0]  dto [0:NCH-1];               // DRP timeout

    // The eight DRP writes of a rate change, by index: RXCDR_CFG in five,
    // PMA_RSV in two, then the dividers.
    function [8:0] seq_addr (input [2:0] i);
        seq_addr = (i < 3'd5) ? DRP_CDR0 + {6'd0, i} :
                   (i < 3'd7) ? DRP_PMA0 + {6'd0, i - 3'd5} : DRP_DIV;
    endfunction

    function [15:0] seq_word (input [1:0] r, input [2:0] i, input [15:0] keep,
                              input [15:0] keep8);
        reg [71:0] c;
        reg [31:0] m;
        reg [2:0]  d;
        begin
            d = (r == 2'd0) ? 3'd1 : 3'd0;    // /2 at 3.125, /1 above
            c = (r == 2'd2) ? CDR_10G : (r == 2'd1) ? CDR_6G : CDR_3G;
            m = (r == 2'd2) ? PMA_HI : PMA_LO;
            case (i)
                3'd0:    seq_word = c[15:0];
                3'd1:    seq_word = c[31:16];
                3'd2:    seq_word = c[47:32];
                3'd3:    seq_word = c[63:48];
                3'd4:    seq_word = {keep[15:8], c[71:64]};
                3'd5:    seq_word = m[15:0];
                3'd6:    seq_word = m[31:16];
                default: seq_word = {keep8[15:7], d, keep8[3], d};
            endcase
        end
    endfunction

    wire [NCH-1:0] seq_busy;
    integer c;
    always @(posedge clk) begin
        drp_en <= {NCH{1'b0}};
        drp_we <= {NCH{1'b0}};
        if (!rstn) begin
            for (c = 0; c < NCH; c = c + 1) begin
                st[c] <= S_IDLE; rate_eff[c] <= 2'd0; widx[c] <= 3'd0;
                timer[c] <= 16'd0; dto[c] <= 10'd0; w4keep[c] <= 16'd0; w8keep[c] <= 16'd0;
                seq_rate[c] <= 2'd0;
                drp_addr[c] <= 9'd0; drp_di[c] <= 16'd0;
            end
            seq_rst  <= {NCH{1'b0}};
            seq_fail <= {NCH{1'b0}};
            raw_busy <= 1'b0; raw_done <= 1'b0; raw_to <= 1'b0;
            raw_data <= 16'd0; raw_ch <= 1'b0; raw_timer <= 10'd0;
        end else begin
            for (c = 0; c < NCH; c = c + 1) begin
                case (st[c])
                    // A sequence runs for the rate asked for when it starts;
                    // a RATE write during one is taken up when it ends,
                    // because the request then differs from the rate in
                    // effect.
                    S_IDLE: if (rate_go[c] || rate_req[c] != rate_eff[c]) begin
                        seq_rate[c] <= rate_req[c];
                        seq_rst[c]  <= 1'b1;         // hold TX and RX in reset
                        seq_fail[c] <= 1'b0;
                        timer[c]    <= 16'd200;      // 2 us for the FSMs to see it
                        st[c]       <= S_RST;
                    end
                    S_RST: if (timer[c] != 16'd0) timer[c] <= timer[c] - 16'd1;
                           else if (!(raw_busy && raw_timer != 10'd0 && raw_ch == c)) begin
                        // read 0x0AC first: its high byte is another field
                        drp_addr[c] <= DRP_CDR0 + 9'd4;
                        drp_en[c]   <= 1'b1;
                        dto[c]      <= 10'd0;
                        st[c]       <= S_RD4;
                    end
                    S_RD4: if (drp_rdy[c]) begin
                        w4keep[c]   <= drp_do[c];
                        drp_addr[c] <= DRP_DIV;      // then 0x088, for the same reason
                        drp_en[c]   <= 1'b1;
                        dto[c]      <= 10'd0;
                        st[c]       <= S_RD8;
                    end else if (dto[c] == 10'd1023) begin
                        seq_fail[c] <= 1'b1; st[c] <= S_SEL;
                    end else dto[c] <= dto[c] + 10'd1;
                    S_RD8: if (drp_rdy[c]) begin
                        w8keep[c] <= drp_do[c];
                        widx[c]   <= 3'd0;
                        st[c]     <= S_WR;
                    end else if (dto[c] == 10'd1023) begin
                        seq_fail[c] <= 1'b1; st[c] <= S_SEL;
                    end else dto[c] <= dto[c] + 10'd1;
                    S_WR: begin
                        drp_addr[c] <= seq_addr(widx[c]);
                        drp_di[c]   <= seq_word(seq_rate[c], widx[c], w4keep[c], w8keep[c]);
                        drp_en[c]   <= 1'b1;
                        drp_we[c]   <= 1'b1;
                        dto[c]      <= 10'd0;
                        st[c]       <= S_WAIT;
                    end
                    S_WAIT: if (drp_rdy[c]) begin
                        if (widx[c] == 3'd7) st[c] <= S_SEL;
                        else begin widx[c] <= widx[c] + 3'd1; st[c] <= S_WR; end
                    end else if (dto[c] == 10'd1023) begin
                        seq_fail[c] <= 1'b1; st[c] <= S_SEL;
                    end else dto[c] <= dto[c] + 10'd1;
                    S_SEL: begin
                        // the PLL and divider change here; the transceiver
                        // is still held in reset
                        rate_eff[c] <= seq_rate[c];
                        timer[c]    <= 16'd10000;    // 100 us: the rate change
                        st[c]       <= S_SETTLE;
                    end
                    S_SETTLE: if (timer[c] != 16'd0) timer[c] <= timer[c] - 16'd1;
                              else st[c] <= S_REL;
                    S_REL: begin
                        seq_rst[c] <= 1'b0;          // the startup FSMs run
                        st[c]      <= S_IDLE;
                    end
                    default: st[c] <= S_IDLE;
                endcase
            end

            // raw access: a single transfer on one channel
            if (!raw_busy) begin
                if (drp_go) begin
                    raw_busy  <= 1'b1;
                    raw_done  <= 1'b0;
                    raw_to    <= 1'b0;
                    raw_ch    <= drp_cmd[12];
                    raw_timer <= 10'd0;
                end
            end else if (raw_timer == 10'd0 && st[raw_ch] != S_IDLE) begin
                ;                                     // wait for the sequence
            end else if (raw_timer == 10'd0) begin
                drp_addr[raw_ch] <= drp_cmd[8:0];
                drp_di[raw_ch]   <= drp_wdata;
                drp_en[raw_ch]   <= 1'b1;
                drp_we[raw_ch]   <= drp_cmd[16];
                raw_timer        <= 10'd1;
            end else if (drp_rdy[raw_ch]) begin
                raw_data <= drp_cmd[16] ? drp_wdata : drp_do[raw_ch];
                raw_busy <= 1'b0;
                raw_done <= 1'b1;
            end else if (raw_timer == 10'd1023) begin
                raw_busy <= 1'b0;
                raw_done <= 1'b1;
                raw_to   <= 1'b1;
            end else raw_timer <= raw_timer + 10'd1;
        end
    end

    genvar b;
    generate for (b = 0; b < NCH; b = b + 1) begin : busy
        assign seq_busy[b] = (st[b] != S_IDLE);
    end endgenerate

    // Read-back of each channel, in the clk domain, packed one channel per
    // slice so the read mux below has no array to be sensitive to.
    wire [32*NCH-1:0] errs_q;
    wire [32*NCH-1:0] cycs_q;
    wire [8*NCH-1:0]  stat_q;
    wire [2*NCH-1:0]  rate_q = {rate_eff[1], rate_eff[0]};
    wire [2*NCH-1:0]  req_q  = {rate_req[1], rate_req[0]};

    // ---------------------------------------------------------------------
    // Per channel
    // ---------------------------------------------------------------------
    genvar g;
    generate
    for (g = 0; g < NCH; g = g + 1) begin : ch
        wire txoutclk, usrclk;
        wire cplllock, cpllfbclklost;
        wire txresetdone, rxresetdone, tx_fsm_done, rx_fsm_done;
        wire rxprbserr;

        // The line rate / 40. With the wizard's default clocking TXOUTCLK
        // also drives RXUSRCLK; the RX elastic buffer takes up the phase
        // difference, and both PLLs share one reference, so there is no
        // frequency difference to take up.
        BUFG usrclk_buf (.I(txoutclk), .O(usrclk));

        // The PLL for this channel's rate: SYSCLKSEL is 2'b00 for the CPLL and
        // 2'b11 for the QPLL, and changes only while the channel is held in
        // reset. The divider is the attribute the rate sequence writes; the
        // TXRATE/RXRATE ports stay at 000 (see the header).
        wire [1:0] sysclksel = (rate_q[2*g +: 2] == 2'd2) ? 2'b11 : 2'b00;
        wire [2:0] outrate   = 3'b000;

        // -- control into the usrclk domain ------------------------------
        // Quasi-static fields: two flops per bit. The bits of one field are
        // not guaranteed to land on the same cycle, and do not need to: a
        // field is only ever changed before a receiver reset.
        (* ASYNC_REG = "TRUE" *) reg [13:0] ct_s0 = 14'd0, ct_s1 = 14'd0;
        (* ASYNC_REG = "TRUE" *) reg        fo_s0 = 1'b0, fo_s1 = 1'b0;
        (* ASYNC_REG = "TRUE" *) reg        cr_s0 = 1'b0, cr_s1 = 1'b0;
        (* ASYNC_REG = "TRUE" *) reg        rd_s0 = 1'b0, rd_s1 = 1'b0;
        reg fo_s2 = 1'b0, cr_s2 = 1'b0;
        always @(posedge usrclk) begin
            ct_s0 <= ctrl_all[14*g +: 14]; ct_s1 <= ct_s0;
            fo_s0 <= force_tog[g]; fo_s1 <= fo_s0; fo_s2 <= fo_s1;
            cr_s0 <= cntrst_tog[g];cr_s1 <= cr_s0; cr_s2 <= cr_s1;
            // RX_FSM_RESET_DONE comes out of the startup FSM, which runs on
            // the stable 100 MHz clock, not on usrclk.
            rd_s0 <= rx_fsm_done;  rd_s1 <= rd_s0;
        end
        wire [2:0] loopback  = ct_s1[2:0];
        wire [2:0] txprbssel = ct_s1[6:4];
        wire [2:0] rxprbssel = ct_s1[10:8];
        wire       txpol     = ct_s1[12];
        wire       rxpol     = ct_s1[13];
        wire       force_pulse  = fo_s2 ^ fo_s1;
        wire       cntrst_pulse = cr_s2 ^ cr_s1;
        wire       rx_up        = rd_s1;

        // -- counters (usrclk domain) -------------------------------------
        // Counting only while the receiver is up keeps the reset sequence
        // out of the denominator.
        reg [31:0] err_cnt = 32'd0, cyc_cnt = 32'd0;
        reg        err_seen = 1'b0;
        always @(posedge usrclk) begin
            if (cntrst_pulse) begin
                err_cnt  <= 32'd0;
                cyc_cnt  <= 32'd0;
                err_seen <= 1'b0;
            end else if (rx_up) begin
                if (rxprbserr) begin
                    err_seen <= 1'b1;
                    if (err_cnt != 32'hFFFF_FFFF) err_cnt <= err_cnt + 32'd1;
                end
                if (cyc_cnt != 32'hFFFF_FFFF) cyc_cnt <= cyc_cnt + 32'd1;
            end
        end

        // -- snapshot across to clk ---------------------------------------
        reg [11:0] presc = 12'd0;
        reg [31:0] err_hold = 32'd0, cyc_hold = 32'd0;
        reg        snap_tog = 1'b0;
        always @(posedge usrclk) begin
            presc <= presc + 12'd1;
            if (presc == 12'd0) begin
                err_hold <= err_cnt;
                cyc_hold <= cyc_cnt;
                snap_tog <= ~snap_tog;
            end
        end

        (* ASYNC_REG = "TRUE" *) reg sn_s0 = 1'b0, sn_s1 = 1'b0;
        reg sn_s2 = 1'b0;
        reg [31:0] errs_r = 32'd0, cycs_r = 32'd0;
        always @(posedge clk) begin
            sn_s0 <= snap_tog; sn_s1 <= sn_s0; sn_s2 <= sn_s1;
            if (sn_s2 ^ sn_s1) begin
                errs_r <= err_hold;
                cycs_r <= cyc_hold;
            end
        end
        assign errs_q[32*g +: 32] = errs_r;
        assign cycs_q[32*g +: 32] = cycs_r;

        // -- status into clk ----------------------------------------------
        (* ASYNC_REG = "TRUE" *) reg [6:0] st_s0 = 7'd0, st_s1 = 7'd0;
        always @(posedge clk) begin
            st_s0 <= {err_seen, cpllfbclklost, rx_fsm_done, tx_fsm_done,
                      rxresetdone, txresetdone, cplllock};
            st_s1 <= st_s0;
        end
        assign stat_q[8*g +: 8] = {los[g], st_s1};

        gtx_sfp gtx_i (
            .sysclk_in                   (clk),
            .soft_reset_tx_in            (softrst[2*g]   | seq_rst[g]),
            .soft_reset_rx_in            (softrst[2*g+1] | seq_rst[g]),
            // Errors are the measurement here. A receiver that reset itself
            // on bad data would hide them and restart the denominator.
            .dont_reset_on_data_error_in (1'b1),
            .gt0_data_valid_in           (1'b1),
            .gt0_tx_fsm_reset_done_out   (tx_fsm_done),
            .gt0_rx_fsm_reset_done_out   (rx_fsm_done),

            .gt0_cpllfbclklost_out       (cpllfbclklost),
            .gt0_cplllock_out            (cplllock),
            .gt0_cplllockdetclk_in       (clk),
            // The generated wrapper sets EXAMPLE_USE_CHIPSCOPE = 0, where the
            // startup FSM drives every one of these itself and the inputs are
            // not read. (The other branch ANDs the userrdy inputs, so a design
            // that did drive them would have to send 1 for "ready".)
            .gt0_cpllreset_in            (1'b0),
            .gt0_gttxreset_in            (1'b0),
            .gt0_gtrxreset_in            (1'b0),
            .gt0_txuserrdy_in            (1'b0),
            .gt0_rxuserrdy_in            (1'b0),
            .gt0_rxpmareset_in           (1'b0),
            .gt0_rxdfelpmreset_in        (1'b0),

            // REFCLK1 of quad 112 is the 156.25 MHz SFP oscillator; REFCLK0
            // is the 150 MHz SATA one.
            .gt0_gtrefclk0_in            (1'b0),
            .gt0_gtrefclk1_in            (refclk),

            .gt0_drpaddr_in              (drp_addr[g]),
            .gt0_drpclk_in               (clk),
            .gt0_drpdi_in                (drp_di[g]),
            .gt0_drpdo_out               (drp_do[g]),
            .gt0_drpen_in                (drp_en[g]),
            .gt0_drprdy_out              (drp_rdy[g]),
            .gt0_drpwe_in                (drp_we[g]),

            .gt0_rxsysclksel_in          (sysclksel),
            .gt0_txsysclksel_in          (sysclksel),
            .gt0_rxrate_in               (outrate),
            .gt0_txrate_in               (outrate),
            .gt0_rxratedone_out          (),
            .gt0_txratedone_out          (),

            .gt0_dmonitorout_out         (),
            .gt0_loopback_in             (loopback),

            .gt0_eyescanreset_in         (1'b0),
            .gt0_eyescandataerror_out    (),
            .gt0_eyescantrigger_in       (1'b0),

            .gt0_rxusrclk_in             (usrclk),
            .gt0_rxusrclk2_in            (usrclk),
            .gt0_rxdata_out              (),
            .gt0_rxprbserr_out           (rxprbserr),
            .gt0_rxprbssel_in            (rxprbssel),
            .gt0_rxprbscntreset_in       (cntrst_pulse),
            .gt0_gtxrxp_in               (rxp[g]),
            .gt0_gtxrxn_in               (rxn[g]),
            .gt0_rxmonitorout_out        (),
            .gt0_rxmonitorsel_in         (2'b00),
            .gt0_rxoutclkfabric_out      (),
            .gt0_rxpolarity_in           (rxpol),
            .gt0_rxslide_in              (1'b0),
            .gt0_rxresetdone_out         (rxresetdone),

            .gt0_txusrclk_in             (usrclk),
            .gt0_txusrclk2_in            (usrclk),
            // With TXPRBSSEL non-zero the generator replaces this entirely.
            .gt0_txdata_in               (40'd0),
            .gt0_txprbssel_in            (txprbssel),
            .gt0_txprbsforceerr_in       (force_pulse),
            .gt0_txpolarity_in           (txpol),
            .gt0_txdiffctrl_in           (drv_all[15*g +: 4] ^ 4'b1000),
            .gt0_rxlpmen_in              (drv_all[15*g+14]),
            .gt0_gtxtxn_out              (txn[g]),
            .gt0_gtxtxp_out              (txp[g]),
            .gt0_txoutclk_out            (txoutclk),
            .gt0_txoutclkfabric_out      (),
            .gt0_txoutclkpcs_out         (),
            .gt0_txresetdone_out         (txresetdone),

            .gt0_qplloutclk_in           (qplloutclk),
            .gt0_qplloutrefclk_in        (qplloutrefclk)
        );
    end
    endgenerate

    assign usrclk_sfp1 = ch[0].usrclk;

    // ---------------------------------------------------------------------
    // Register read: always @(*), not a function in a continuous assign --
    // see axi4_regs.v for why.
    // ---------------------------------------------------------------------
    always @(*) begin
        case (reg_raddr)
            4'd0:    reg_rdata = ID_MAGIC;
            4'd1:    reg_rdata = {28'd0, softrst};
            4'd2:    reg_rdata = {1'b0, drv0, 2'd0, ctrl0};
            4'd4:    reg_rdata = {24'd0, stat_q[7:0]};
            4'd5:    reg_rdata = errs_q[31:0];
            4'd6:    reg_rdata = cycs_q[31:0];
            4'd7:    reg_rdata = {1'b0, drv1, 2'd0, ctrl1};
            4'd9:    reg_rdata = {24'd0, stat_q[15:8]};
            4'd10:   reg_rdata = errs_q[63:32];
            4'd11:   reg_rdata = cycs_q[63:32];
            4'd12:   reg_rdata = {26'd0, req_q[3:2], 2'd0, req_q[1:0]};
            4'd13:   reg_rdata = {10'd0, rate_q[3:2], 2'd0, rate_q[1:0],
                                  6'd0, ql_s1[1], ql_s1[0],
                                  2'd0, seq_fail, 2'd0, seq_busy};
            4'd14:   reg_rdata = {13'd0, raw_to, raw_done, raw_busy, raw_data};
            4'd15:   reg_rdata = {16'd0, drp_wdata};
            default: reg_rdata = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
