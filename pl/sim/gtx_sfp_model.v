// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Behavioral model of the gtwizard `gtx_sfp` channel, for gtx_prbs_tb only.
//
// The GTXE2_CHANNEL itself cannot be simulated by Icarus (its model is
// encrypted), and the stub in stubs/board exists only to check port widths.
// This is enough of the transceiver's CONTRACT to exercise everything
// gtx_prbs.v builds around it, which is where the bugs would be: the register
// decode, which field reaches which port, the clock crossings, the counters,
// and the rate sequence's DRP traffic.
//
// What it keeps from the real thing:
//   - TXOUTCLK only runs once the CPLL has locked, is not related to sysclk,
//     and runs at the line rate / 40 for the PLL and divider selected:
//     12.8 ns (3.125 Gb/s), 6.4 ns (6.25) or 3.88 ns (10.3125) against
//     sysclk's 10 ns, so the crossings are exercised at three ratios
//   - tx/rx_fsm_reset_done come out on SYSCLK, as the startup FSMs do,
//     drop while soft_reset is held and rise a while after it is released
//   - the DRP: a 512-word register file answering DRPRDY a few DRPCLK cycles
//     after DRPEN, preloaded with the 3.125 Gb/s RXCDR_CFG at 0x0A8-0x0AC,
//     a marker in 0x0AC's high byte, which belongs to another attribute and
//     must survive a rate change, PMA_RSV's low-rate value at 0x099-0x09A,
//     and TXOUT_DIV [6:4] / RXOUT_DIV [2:0] at 0x088 (both /2), with marker
//     bits around them
//   - the divider comes from TXRATE when that port is non-zero and from the
//     TXOUT_DIV attribute when it is 000, as UG476 describes
//   - the PRBS checker is off when RXPRBSSEL is 0, and flags EVERY word when
//     the received pattern or polarity does not match what was sent -- here
//     "what was sent" is this channel's own TX, i.e. a loopback
//   - TXPRBSFORCEERR produces a short BURST of flagged words, not one: the
//     real checker is self-synchronizing, so one bad bit is flagged again
//     each time it is used as a tap. The board counts 2 to 4 words,
//     depending on the link's word alignment (pl/tools/gtxtest.sh); this
//     model flags 3
//
// What it does not model: the serial lanes (txp/rxp are left alone), and any
// real bit errors. The bench can inject word errors through `inject`.

`timescale 1ns/1ps

module gtx_sfp (
    input  wire        sysclk_in,
    input  wire        soft_reset_tx_in,
    input  wire        soft_reset_rx_in,
    input  wire        dont_reset_on_data_error_in,
    output reg         gt0_tx_fsm_reset_done_out = 1'b0,
    output reg         gt0_rx_fsm_reset_done_out = 1'b0,
    input  wire        gt0_data_valid_in,

    output wire        gt0_cpllfbclklost_out,
    output reg         gt0_cplllock_out = 1'b0,
    input  wire        gt0_cplllockdetclk_in,
    input  wire        gt0_cpllreset_in,
    input  wire        gt0_gtrefclk0_in,
    input  wire        gt0_gtrefclk1_in,

    input  wire [8:0]  gt0_drpaddr_in,
    input  wire        gt0_drpclk_in,
    input  wire [15:0] gt0_drpdi_in,
    output reg  [15:0] gt0_drpdo_out = 16'd0,
    input  wire        gt0_drpen_in,
    output reg         gt0_drprdy_out = 1'b0,
    input  wire        gt0_drpwe_in,

    input  wire [1:0]  gt0_rxsysclksel_in,
    input  wire [1:0]  gt0_txsysclksel_in,
    input  wire [2:0]  gt0_rxrate_in,
    input  wire [2:0]  gt0_txrate_in,
    output wire        gt0_rxratedone_out,
    output wire        gt0_txratedone_out,

    output wire [7:0]  gt0_dmonitorout_out,
    input  wire [2:0]  gt0_loopback_in,

    input  wire        gt0_eyescanreset_in,
    input  wire        gt0_rxuserrdy_in,
    output wire        gt0_eyescandataerror_out,
    input  wire        gt0_eyescantrigger_in,

    input  wire        gt0_rxusrclk_in,
    input  wire        gt0_rxusrclk2_in,
    output wire [39:0] gt0_rxdata_out,
    output reg         gt0_rxprbserr_out = 1'b0,
    input  wire [2:0]  gt0_rxprbssel_in,
    input  wire        gt0_rxprbscntreset_in,
    input  wire        gt0_gtxrxp_in,
    input  wire        gt0_gtxrxn_in,
    input  wire        gt0_rxdfelpmreset_in,
    output wire [6:0]  gt0_rxmonitorout_out,
    input  wire [1:0]  gt0_rxmonitorsel_in,
    output wire        gt0_rxoutclkfabric_out,
    input  wire        gt0_gtrxreset_in,
    input  wire        gt0_rxpmareset_in,
    input  wire        gt0_rxpolarity_in,
    input  wire        gt0_rxslide_in,
    output wire        gt0_rxresetdone_out,

    input  wire        gt0_gttxreset_in,
    input  wire        gt0_txuserrdy_in,
    input  wire        gt0_txusrclk_in,
    input  wire        gt0_txusrclk2_in,
    input  wire        gt0_txprbsforceerr_in,
    input  wire [39:0] gt0_txdata_in,
    output wire        gt0_gtxtxn_out,
    output wire        gt0_gtxtxp_out,
    output reg         gt0_txoutclk_out = 1'b0,
    output wire        gt0_txoutclkfabric_out,
    output wire        gt0_txoutclkpcs_out,
    output wire        gt0_txresetdone_out,
    input  wire        gt0_txpolarity_in,
    input  wire [3:0]  gt0_txdiffctrl_in,      // driver settings: recorded, not modeled
    input  wire        gt0_rxlpmen_in,
    input  wire [2:0]  gt0_txprbssel_in,

    input  wire        gt0_qplloutclk_in,
    input  wire        gt0_qplloutrefclk_in
);

    assign gt0_cpllfbclklost_out    = 1'b0;
    assign gt0_dmonitorout_out      = 8'd0;
    assign gt0_eyescandataerror_out = 1'b0;
    assign gt0_rxdata_out           = 40'd0;
    assign gt0_rxmonitorout_out     = 7'd0;
    assign gt0_rxoutclkfabric_out   = 1'b0;
    assign gt0_gtxtxn_out           = 1'b1;
    assign gt0_gtxtxp_out           = 1'b0;
    assign gt0_txoutclkfabric_out   = 1'b0;
    assign gt0_txoutclkpcs_out      = 1'b0;
    assign gt0_txresetdone_out      = gt0_tx_fsm_reset_done_out;
    assign gt0_rxresetdone_out      = gt0_rx_fsm_reset_done_out;
    assign gt0_rxratedone_out       = 1'b0;
    assign gt0_txratedone_out       = 1'b0;

    reg [15:0] drp [0:511];               // the DRP register file (below)

    // CPLL lock after 500 ns; TXOUTCLK only runs once locked, at the line
    // rate / 40 for the selected PLL and divider.
    initial begin
        #500 gt0_cplllock_out = 1'b1;
    end
    wire qpll = (gt0_txsysclksel_in == 2'b11);
    wire div2 = (gt0_txrate_in == 3'b010) ||
                (gt0_txrate_in == 3'b000 && drp[9'h088][6:4] == 3'd1);
    real half = 6.4;
    always @* half = qpll ? 1.94 : (div2 ? 6.4 : 3.2);
    always begin
        #(half);
        if (gt0_cplllock_out) gt0_txoutclk_out = ~gt0_txoutclk_out;
    end

    // Startup FSMs, on sysclk: done drops while soft reset is held and rises
    // a fixed number of sysclk cycles after it is released.
    integer tx_wait = 0, rx_wait = 0;
    always @(posedge sysclk_in) begin
        if (soft_reset_tx_in || !gt0_cplllock_out) begin
            gt0_tx_fsm_reset_done_out <= 1'b0; tx_wait <= 0;
        end else if (tx_wait < 50) tx_wait <= tx_wait + 1;
        else gt0_tx_fsm_reset_done_out <= 1'b1;

        if (soft_reset_rx_in || !gt0_cplllock_out) begin
            gt0_rx_fsm_reset_done_out <= 1'b0; rx_wait <= 0;
        end else if (rx_wait < 80) rx_wait <= rx_wait + 1;
        else gt0_rx_fsm_reset_done_out <= 1'b1;
    end

    // The DRP. `drp_writes` counts accepted writes, for the bench.
    integer k, drp_writes = 0;
    initial begin
        for (k = 0; k < 512; k = k + 1) drp[k] = 16'hDEAD;
        drp[9'h0A8] = 16'h0020;              // RXCDR_CFG, 3.125 Gb/s
        drp[9'h0A9] = 16'h4020;
        drp[9'h0AA] = 16'h23ff;
        drp[9'h0AB] = 16'h0000;
        drp[9'h0AC] = 16'h5A03;              // 0x5A: someone else's byte
        drp[9'h099] = 16'h8480;              // PMA_RSV, below 6.6 Gb/s
        drp[9'h09A] = 16'h0001;
        drp[9'h088] = 16'hC399;              // TXOUT_DIV and RXOUT_DIV /2, markers
    end
    reg [2:0] drp_busy = 3'd0;
    reg [8:0] drp_a;
    reg       drp_w;
    reg [15:0] drp_d;
    always @(posedge gt0_drpclk_in) begin
        gt0_drprdy_out <= 1'b0;
        if (gt0_drpen_in) begin
            drp_a <= gt0_drpaddr_in; drp_w <= gt0_drpwe_in; drp_d <= gt0_drpdi_in;
            drp_busy <= 3'd4;
        end else if (drp_busy != 3'd0) begin
            drp_busy <= drp_busy - 3'd1;
            if (drp_busy == 3'd1) begin
                if (drp_w) begin drp[drp_a] <= drp_d; drp_writes = drp_writes + 1; end
                gt0_drpdo_out  <= drp[drp_a];
                gt0_drprdy_out <= 1'b1;
            end
        end
    end

    // The checker. `inject` is set by the bench, hierarchically, to add that
    // many single-word errors.
    integer inject = 0;
    reg [11:0] force_pipe = 12'd0;
    wire checking = (gt0_rxprbssel_in != 3'd0);
    wire mismatch = (gt0_rxprbssel_in != gt0_txprbssel_in) ||
                    (gt0_rxpolarity_in != gt0_txpolarity_in);
    always @(posedge gt0_rxusrclk2_in) begin
        force_pipe <= {force_pipe[10:0], gt0_txprbsforceerr_in};
        gt0_rxprbserr_out <= 1'b0;
        if (checking) begin
            // a burst of three flagged words; the spacing is arbitrary
            if (mismatch || force_pipe[7] || force_pipe[9] || force_pipe[11])
                gt0_rxprbserr_out <= 1'b1;
            else if (inject > 0) begin
                gt0_rxprbserr_out <= 1'b1;
                inject = inject - 1;
            end
        end
    end

endmodule
