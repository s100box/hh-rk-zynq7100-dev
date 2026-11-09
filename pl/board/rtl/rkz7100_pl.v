// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// RK-ZYNQ7100 PL design: the PS7 and everything on the PL's pins -- the
// 1 GB of PL DDR3 behind a MIG; the register file (LED8, keys, fan,
// frequency counters, sub-block windows); the I2C buses, J8, LED1-4, the
// keys and the SFP control pins as EMIO GPIOs; HDMI out and in; the MIPI
// camera; the SFP+ transceivers; the PL Ethernet port; and three BIST
// engines, two on HP1/HP2 into PS DRAM and one on the MIG.
//
// The PS gives the fabric two 1 GB master windows, and the PL DRAM is
// exactly 1 GB, so it takes all of M_AXI_GP0 at 0x4000_0000 and everything
// else hangs off M_AXI_GP1 through a crossbar:
//
//   0x8000_0000  the HDMI capture VDMA      0x8002_0000  the CSI-2 receiver
//   0x8001_0000  the camera VDMA            0x8010_0000  the register file
//
// The PS7 is instantiated from the IP directly (create_ip, not a block
// design), with the same board/ps7_config.tcl the Linux PS init is generated
// from, so there is one source of truth for the PS configuration.
//
// The MIO, DDR_* and PS_* ports are the PS7's dedicated pins: they need no
// XDC, but they must exist at the top level for the tools to bind them.

`default_nettype none

module rkz7100_pl (
    // PS7 dedicated pins
    inout  wire [53:0] MIO,
    inout  wire        DDR_CAS_n,
    inout  wire        DDR_CKE,
    inout  wire        DDR_Clk_n,
    inout  wire        DDR_Clk,
    inout  wire        DDR_CS_n,
    inout  wire        DDR_DRSTB,
    inout  wire        DDR_ODT,
    inout  wire        DDR_RAS_n,
    inout  wire        DDR_WEB,
    inout  wire [2:0]  DDR_BankAddr,
    inout  wire [14:0] DDR_Addr,
    inout  wire        DDR_VRN,
    inout  wire        DDR_VRP,
    inout  wire [3:0]  DDR_DM,
    inout  wire [31:0] DDR_DQ,
    inout  wire [3:0]  DDR_DQS_n,
    inout  wire [3:0]  DDR_DQS,
    inout  wire        PS_SRSTB,
    inout  wire        PS_CLK,
    inout  wire        PS_PORB,

    // Board
    output wire [5:0]  led,
    input  wire [3:0]  key_n,
    output wire        fan_pwm,
    input  wire        fan_tach,

    // I2C buses that live on PL pins, handed to the PS as EMIO GPIOs for
    // Linux's i2c-gpio to bit-bang. See emio_pads.v.
    inout  wire        hdmi_tx_scl,
    inout  wire        hdmi_tx_sda,
    inout  wire        hdmi_rx_scl,
    inout  wire        hdmi_rx_sda,
    inout  wire        cam_scl,
    inout  wire        cam_sda,
    // The ADV7611 is held in reset by a pull-down until this is driven high.
    inout  wire        hdmi_rx_rst_n,

    // The camera connector's two control lines, J9 pins 5 and 4. J9 is a
    // Raspberry Pi camera connector numbered in reverse, so these are the
    // Pi's CAM_IO0 and CAM_IO1: on a Pi-style module IO0 is the power
    // enable, and IO1 an LED or spare line. The board calls pin 4 CAM_CLK,
    // but a Pi-style module carries its own sensor clock. Both are Linux
    // GPIOs, like everything else here on EMIO.
    inout  wire        cam_gpio,
    inout  wire        cam_clk,

    // The camera's MIPI D-PHY, bank 35, through the board's passive network
    // (XAPP894 style): each lane's HS pair goes straight to an LVDS input,
    // and the same two wires, through 100R each, to a pair of HSUL_12 inputs
    // that watch the low-power states.
    input  wire        mipi_clk_hs_p,
    input  wire        mipi_clk_hs_n,
    input  wire [1:0]  mipi_d_hs_p,
    input  wire [1:0]  mipi_d_hs_n,
    input  wire        mipi_clk_lp_p,
    input  wire        mipi_clk_lp_n,
    input  wire [1:0]  mipi_d_lp_p,
    input  wire [1:0]  mipi_d_lp_n,

    // The PL Ethernet PHY (U19, RJ2), bank 11. Its MAC is the PS's second
    // Ethernet controller, GEM1, brought out over EMIO as GMII and turned into
    // RGMII by Xilinx's gmii_to_rgmii core, which also carries GEM1's MDIO to
    // the PHY. See "The PL Ethernet port" in pl/README.md.
    output wire        phy2_mdc,
    inout  wire        phy2_mdio,
    output wire        phy2_txc,
    output wire        phy2_tx_ctl,
    output wire [3:0]  phy2_txd,
    input  wire        phy2_rxc,
    input  wire        phy2_rx_ctl,
    input  wire [3:0]  phy2_rxd,

    // The board's oscillators. Each clocks a counter Linux can read back
    // (see freq_ctr.v); Y7 and Y8 also clock the logic below.
    input  wire        pl_clk,          // 50 MHz osc Y2, bank 9
    input  wire        sys_clk_p,       // 200 MHz osc Y7, bank 34 (the MIG's)
    input  wire        sys_clk_n,
    input  wire        gtx_clk156_p,    // 156.25 MHz osc Y8, MGTREFCLK1_112
    input  wire        gtx_clk156_n,
    input  wire        gtx_sataclk_p,   // 150 MHz osc Y9, MGTREFCLK0_112
    input  wire        gtx_sataclk_n,

    // PL DDR3, 2x MT41J256M16 = 32-bit, 1 GB
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_cas_n,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_cke,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n,
    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,


    // The 40-pin header J8, all 34 pins, handed to the PS as EMIO GPIOs so
    // Linux owns them: direction and value per pin through the ordinary
    // gpiochip, with no register poking and no driver to write. See the
    // mapping table at the j8_pads instance.
    inout  wire [33:0] j8,

    // HDMI output: 24-bit parallel video into the ADV7511 (U22) on bank 35 at
    // 1.8 V. The chip does TMDS, DDC and CEC itself; Linux configures it over
    // the bit-banged I2C bus that already exists. See hdmi_out.v.
    output wire        hdmi_tx_clk,
    output wire        hdmi_tx_de,
    output wire        hdmi_tx_hsync,
    output wire        hdmi_tx_vsync,
    output wire [23:0] hdmi_tx_d,

    // HDMI input: 24-bit parallel video out of the ADV7611 (U23) on bank 11
    // at 3.3 V. The receiver drives its own clock, LLC, so this is a
    // source-synchronous bus and everything on it is captured on that clock.
    //
    // ⚠ hdmi_rx_vs is the ADV7611's VS/FIELD/ALSB pin, which the chip samples
    // out of reset to pick its own I2C address: low gives 0x4C, high 0x4D.
    // It must stay an INPUT here, or the receiver moves off the address the
    // device tree names and the whole bus looks dead.
    input  wire        hdmi_rx_pclk,
    input  wire        hdmi_rx_de,
    input  wire        hdmi_rx_hs,
    input  wire        hdmi_rx_vs,
    input  wire [23:0] hdmi_rx_d,

    // The SFP+ cages' low-speed pins, bank 9 at 3.3 V. These four are the
    // ONLY ones that reach the FPGA -- the module I2C, the presence detect
    // and the rate selects all end at a pull-up and go nowhere, and TX_FAULT
    // is tied to ground (user guide section 15). So the fabric can enable a
    // module and read its loss-of-signal, and nothing else.
    //
    // ⚠ TX_DISABLE has a 4.7K PULL-UP: a module's transmitter is OFF until
    // something drives the pin low (see the SFP block below).
    inout  wire [1:0]  sfp_tx_disable,   // [0] = SFP1 (J1), [1] = SFP2 (J4)
    input  wire [1:0]  sfp_los,

    // The SFP+ cages' high-speed lanes: GTX quad 112, SFP1 on channel 2 and
    // SFP2 on channel 3. Dedicated transceiver pins, so no I/O standard
    // applies. Their reference is gtx_clk156, above. See gtx_prbs.v.
    output wire [1:0]  sfp_txp,
    output wire [1:0]  sfp_txn,
    input  wire [1:0]  sfp_rxp,
    input  wire [1:0]  sfp_rxn
);

    // ---------------------------------------------------------------------
    // PS7 <-> PL
    // ---------------------------------------------------------------------
    wire        fclk_clk0;
    wire        fclk_reset0_n;
    wire        ttc1_wave0;
    wire [31:0] fan_status;
    wire [31:0] fan_ctrl_w;
    wire        tach_sync;

    // EMIO GPIO, 64 bits wide in the PS configuration; the bit map is at the
    // PS7 instance below. In Linux these are gpio 54 + bit.
    wire [63:0] gpio_o_w, gpio_t_w;
    wire [8:0]  emio_pad_i;

    // GEM1 <-> gmii_to_rgmii, and the core's view of the link
    wire [7:0]  gmii_txd, gmii_rxd;
    wire        gmii_tx_en, gmii_tx_er, gmii_tx_clk;
    wire        gmii_rx_dv, gmii_rx_er, gmii_rx_clk, gmii_col, gmii_crs;
    wire        gem1_mdc, gem1_mdio_o, gem1_mdio_t, gem1_mdio_i;
    wire        phy2_mdio_o, phy2_mdio_t, phy2_mdio_i;
    wire        eth_link, eth_duplex, eth_mmcm_locked;
    wire [1:0]  eth_clock_speed, eth_speed_mode;
    reg  [6:0]  eth_st_s0, eth_st_s1;
    wire [33:0] j8_pad_i;
    wire [1:0]  sfp_txdis_i;     // read back through the IOBUF
    reg  [1:0]  sfp_los_sync;    // LOS is an asynchronous module output

    // ---------------------------------------------------------------------
    // The board's four oscillators, buffered for the logic and the counters.
    //
    // ⚠ The two GTX references cannot be used directly: an MGTREFCLK pin
    // feeds the transceiver quad, not the fabric.
    //
    // SATA's 150 MHz reaches its counter through IBUFDS_GTE2's ODIV2 -- the
    // reference divided by two, which CAN drive a BUFG -- so that reading is
    // HALF the oscillator, 75 MHz.
    //
    // Y8's 156.25 MHz cannot do the same, because the SFP transceivers need
    // it in the fabric too: each gtwizard channel sequences its CPLL power-up
    // from the reference through a BUFH, and an IBUFDS_GTE2 has ONE route
    // into the fabric clock network, which O and ODIV2 cannot share:
    // connecting both leaves O with two unroutable pins. So Y8 is counted
    // through SFP1's user clock instead: its TXOUTCLK, the line rate / 40, phase-locked to Y8
    // through whichever PLL SFP1's RATE selects, so it carries Y8's ppm
    // unchanged -- 78.125 MHz, Y8 / 2, at the reset rate -- and a reading also
    // proves that PLL locked.
    //
    // Either way these only exist if the MGT rails came up. MGTAVCC,
    // MGTAVTT and MGTVCCAUX are all regulated on this board (user guide
    // section 3), so a reading of zero here is a finding, not an expectation.
    // ---------------------------------------------------------------------
    wire pl_clk_i, pl_clk_g;
    IBUF pl_clk_ibuf (.I(pl_clk), .O(pl_clk_i));
    BUFG pl_clk_bufg (.I(pl_clk_i), .O(pl_clk_g));

    wire sys_clk_i, sys_clk_g;
    IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE"))
        sys_clk_ibuf (.I(sys_clk_p), .IB(sys_clk_n), .O(sys_clk_i));
    BUFG sys_clk_bufg (.I(sys_clk_i), .O(sys_clk_g));

    // O feeds the SFP transceivers. ODIV2 stays unconnected: see above.
    wire gtx_refclk156;
    IBUFDS_GTE2 clk156_ibuf (
        .I(gtx_clk156_p), .IB(gtx_clk156_n), .CEB(1'b0),
        .O(gtx_refclk156), .ODIV2());

    wire sataclk_odiv2, sataclk_g;
    IBUFDS_GTE2 sataclk_ibuf (
        .I(gtx_sataclk_p), .IB(gtx_sataclk_n), .CEB(1'b0),
        .O(), .ODIV2(sataclk_odiv2));
    BUFG sataclk_bufg (.I(sataclk_odiv2), .O(sataclk_g));

    // KEY1-4 into the PS as EMIO GPIOs, synchronized. gpio-keys debounces in
    // software and the device tree marks them active low, so the raw pin
    // level is what the PS wants to see.
    reg [1:0] key_sync [3:0];
    wire [3:0] key_emio;
    integer ki;
    always @(posedge fclk_clk0) begin
        for (ki = 0; ki < 4; ki = ki + 1)
            key_sync[ki] <= {key_sync[ki][0], key_n[ki]};
    end
    assign key_emio = {key_sync[3][1], key_sync[2][1],
                       key_sync[1][1], key_sync[0][1]};

    // The two HP masters' AXI bundles.

    wire [5:0] hp1_awid;
    wire [31:0] hp1_awaddr;
    wire [3:0] hp1_awlen;
    wire [2:0] hp1_awsize;
    wire [1:0] hp1_awburst;
    wire [1:0] hp1_awlock;
    wire [3:0] hp1_awcache;
    wire [2:0] hp1_awprot;
    wire [3:0] hp1_awqos;
    wire hp1_awvalid;
    wire hp1_awready;
    wire [5:0] hp1_wid;
    wire [63:0] hp1_wdata;
    wire [7:0] hp1_wstrb;
    wire hp1_wlast;
    wire hp1_wvalid;
    wire hp1_wready;
    wire [5:0] hp1_bid;
    wire [1:0] hp1_bresp;
    wire hp1_bvalid;
    wire hp1_bready;
    wire [5:0] hp1_arid;
    wire [31:0] hp1_araddr;
    wire [3:0] hp1_arlen;
    wire [2:0] hp1_arsize;
    wire [1:0] hp1_arburst;
    wire [1:0] hp1_arlock;
    wire [3:0] hp1_arcache;
    wire [2:0] hp1_arprot;
    wire [3:0] hp1_arqos;
    wire hp1_arvalid;
    wire hp1_arready;
    wire [5:0] hp1_rid;
    wire [63:0] hp1_rdata;
    wire [1:0] hp1_rresp;
    wire hp1_rlast;
    wire hp1_rvalid;
    wire hp1_rready;

    wire [5:0] hp2_awid;
    wire [31:0] hp2_awaddr;
    wire [3:0] hp2_awlen;
    wire [2:0] hp2_awsize;
    wire [1:0] hp2_awburst;
    wire [1:0] hp2_awlock;
    wire [3:0] hp2_awcache;
    wire [2:0] hp2_awprot;
    wire [3:0] hp2_awqos;
    wire hp2_awvalid;
    wire hp2_awready;
    wire [5:0] hp2_wid;
    wire [63:0] hp2_wdata;
    wire [7:0] hp2_wstrb;
    wire hp2_wlast;
    wire hp2_wvalid;
    wire hp2_wready;
    wire [5:0] hp2_bid;
    wire [1:0] hp2_bresp;
    wire hp2_bvalid;
    wire hp2_bready;
    wire [5:0] hp2_arid;
    wire [31:0] hp2_araddr;
    wire [3:0] hp2_arlen;
    wire [2:0] hp2_arsize;
    wire [1:0] hp2_arburst;
    wire [1:0] hp2_arlock;
    wire [3:0] hp2_arcache;
    wire [2:0] hp2_arprot;
    wire [3:0] hp2_arqos;
    wire hp2_arvalid;
    wire hp2_arready;
    wire [5:0] hp2_rid;
    wire [63:0] hp2_rdata;
    wire [1:0] hp2_rresp;
    wire hp2_rlast;
    wire hp2_rvalid;
    wire hp2_rready;


    wire [11:0] cpu_awid;
    wire [31:0] cpu_awaddr;
    wire [7:0] cpu_awlen;
    wire [2:0] cpu_awsize;
    wire [1:0] cpu_awburst;
    // AXI4 carries a one-bit LOCK (cpu_awlock and cpu_arlock); AXI3's two
    // bits do not survive the protocol converter, and declaring it wider
    // leaves the top bit undriven.
    wire cpu_awlock;
    wire [3:0] cpu_awcache;
    wire [2:0] cpu_awprot;
    wire [3:0] cpu_awqos;
    wire cpu_awvalid;
    wire cpu_awready;
    wire [31:0] cpu_wdata;
    wire [3:0] cpu_wstrb;
    wire cpu_wlast;
    wire cpu_wvalid;
    wire cpu_wready;
    wire [11:0] cpu_bid;
    wire [1:0] cpu_bresp;
    wire cpu_bvalid;
    wire cpu_bready;
    wire [11:0] cpu_arid;
    wire [31:0] cpu_araddr;
    wire [7:0] cpu_arlen;
    wire [2:0] cpu_arsize;
    wire [1:0] cpu_arburst;
    wire cpu_arlock;
    wire [3:0] cpu_arcache;
    wire [2:0] cpu_arprot;
    wire [3:0] cpu_arqos;
    wire cpu_arvalid;
    wire cpu_arready;
    wire [11:0] cpu_rid;
    wire [31:0] cpu_rdata;
    wire [1:0] cpu_rresp;
    wire cpu_rlast;
    wire cpu_rvalid;
    wire cpu_rready;

    wire [11:0] bst_awid;
    wire [31:0] bst_awaddr;
    wire [7:0] bst_awlen;
    wire [2:0] bst_awsize;
    wire [1:0] bst_awburst;
    wire [1:0] bst_awlock;
    wire [3:0] bst_awcache;
    wire [2:0] bst_awprot;
    wire [3:0] bst_awqos;
    wire bst_awvalid;
    wire bst_awready;
    wire [11:0] bst_wid;
    wire [31:0] bst_wdata;
    wire [3:0] bst_wstrb;
    wire bst_wlast;
    wire bst_wvalid;
    wire bst_wready;
    wire [11:0] bst_bid;
    wire [1:0] bst_bresp;
    wire bst_bvalid;
    wire bst_bready;
    wire [11:0] bst_arid;
    wire [31:0] bst_araddr;
    wire [7:0] bst_arlen;
    wire [2:0] bst_arsize;
    wire [1:0] bst_arburst;
    wire [1:0] bst_arlock;
    wire [3:0] bst_arcache;
    wire [2:0] bst_arprot;
    wire [3:0] bst_arqos;
    wire bst_arvalid;
    wire bst_arready;
    wire [11:0] bst_rid;
    wire [31:0] bst_rdata;
    wire [1:0] bst_rresp;
    wire bst_rlast;
    wire bst_rvalid;
    wire bst_rready;

    wire [11:0] gp0_awid,  gp0_arid,  gp0_wid;
    wire [31:0] gp0_awaddr, gp0_araddr, gp0_wdata;
    wire [3:0]  gp0_awlen,  gp0_arlen,  gp0_wstrb;
    // The rest of the GP0 bus, which the MIG path needs.
    wire [3:0]  gp0_awcache, gp0_arcache, gp0_awqos, gp0_arqos;
    wire [2:0]  gp0_awsize, gp0_arsize, gp0_awprot, gp0_arprot;
    wire [1:0]  gp0_awburst, gp0_arburst, gp0_awlock, gp0_arlock;
    wire        gp0_awvalid, gp0_awready;
    wire        gp0_wvalid,  gp0_wready, gp0_wlast;
    wire        gp0_bvalid,  gp0_bready;
    wire [11:0] gp0_bid;
    wire [1:0]  gp0_bresp;
    wire        gp0_arvalid, gp0_arready;
    wire        gp0_rvalid,  gp0_rready, gp0_rlast;
    wire [11:0] gp0_rid;
    wire [31:0] gp0_rdata;
    wire [1:0]  gp0_rresp;

    // Frequency counters, and the BIST engines' register windows.
    wire        freq_gate_w;
    wire [31:0] freq0, freq1, freq2, freq3;
    wire        sfp1_usrclk;     // SFP1's TXOUTCLK, counted as FREQ1
    wire [7:0]  up0, up1, up2, up3;

    wire [3:0]  blk_waddr, blk_raddr;
    wire [4:0]  blk_we;

    // The register file's own port on the GP1 crossbar, declared here
    // because the file is instantiated before the crossbar.
    wire [31:0] rlite_awaddr, rlite_araddr, rlite_wdata, rlite_rdata;
    wire [3:0]  rlite_wstrb;
    wire [1:0]  rlite_bresp, rlite_rresp;
    wire        rlite_awvalid, rlite_awready, rlite_wvalid, rlite_wready;
    wire        rlite_bvalid, rlite_bready;
    wire        rlite_arvalid, rlite_arready, rlite_rvalid, rlite_rready;

    wire [31:0] blk_wdata, blk_rdata0, blk_rdata1, blk_rdata3, blk_rdata4;
    wire [5:0]  bist_irq;
    wire        mig_owner, mig_switching;
    wire [2:0]  mig_dbg;
    wire [3:0]  mig_aw_out, mig_ar_out;
    // AUX (0x3C) low half, written by software: [0] asks for the MIG to be
    // handed to BIST engine 2, [15] turns cam_guard's frame dropping off;
    // [14:1] are unused.
    wire [15:0] aux_ctrl;
    wire        cam_dlyctrl_rdy;
    // Sub-block 2 is the HDMI capture, camera and Ethernet status window;
    // driven far below, declared here because the register file is
    // instantiated first.
    reg  [31:0] blk_rdata2_r;

    // The MMCM's LOCKED is both the asynchronous reset of the pixel domain
    // (inside hdmi_out) and, synchronized below, a STATUS bit; both uses are
    // meant.
    /* verilator lint_off SYNCASYNCNET */
    wire        hdmi_locked;
    /* verilator lint_on SYNCASYNCNET */

    // M_AXI_GP1: the CPU reaching the register file, the two VDMAs and the
    // CSI-2 receiver, through one crossbar.
    // AXI3, 32-bit, 12-bit IDs, exactly like GP0.
    wire [11:0] gp1_awid,  gp1_arid,  gp1_wid;
    wire [11:0] gp1_bid,   gp1_rid;
    wire [31:0] gp1_awaddr, gp1_araddr, gp1_wdata, gp1_rdata;
    wire [3:0]  gp1_awlen, gp1_arlen, gp1_wstrb;
    wire [2:0]  gp1_awsize, gp1_arsize, gp1_awprot, gp1_arprot;
    wire [1:0]  gp1_awburst, gp1_arburst, gp1_awlock, gp1_arlock;
    wire [1:0]  gp1_bresp, gp1_rresp;
    wire [3:0]  gp1_awcache, gp1_arcache, gp1_awqos, gp1_arqos;
    wire        gp1_awvalid, gp1_awready, gp1_wvalid, gp1_wready, gp1_wlast;
    wire        gp1_bvalid,  gp1_bready;
    wire        gp1_arvalid, gp1_arready, gp1_rvalid, gp1_rready, gp1_rlast;

    // S_AXI_HP0: the HDMI capture VDMA writing frames into PS DRAM. AXI3, 64-bit,
    // 6-bit IDs, the same shape as the HP1 and HP2 bundles above.
    wire [5:0]  hp0_awid, hp0_wid, hp0_bid, hp0_arid, hp0_rid;
    wire [31:0] hp0_awaddr, hp0_araddr;
    wire [63:0] hp0_wdata, hp0_rdata;
    wire [7:0]  hp0_wstrb;
    wire [3:0]  hp0_awlen, hp0_arlen, hp0_awcache, hp0_arcache;
    wire [3:0]  hp0_awqos, hp0_arqos;
    wire [2:0]  hp0_awsize, hp0_arsize, hp0_awprot, hp0_arprot;
    wire [1:0]  hp0_awburst, hp0_arburst, hp0_awlock, hp0_arlock;
    wire [1:0]  hp0_bresp, hp0_rresp;
    wire        hp0_awvalid, hp0_awready, hp0_wvalid, hp0_wready, hp0_wlast;
    wire        hp0_bvalid, hp0_bready;
    wire        hp0_arvalid, hp0_arready, hp0_rvalid, hp0_rready, hp0_rlast;

    // S_AXI_HP3: the camera VDMA, the same shape as HP0.
    wire [5:0]  hp3_awid, hp3_wid, hp3_bid, hp3_arid, hp3_rid;
    wire [31:0] hp3_awaddr, hp3_araddr;
    wire [63:0] hp3_wdata, hp3_rdata;
    wire [7:0]  hp3_wstrb;
    wire [3:0]  hp3_awlen, hp3_arlen, hp3_awcache, hp3_arcache;
    wire [3:0]  hp3_awqos, hp3_arqos;
    wire [2:0]  hp3_awsize, hp3_arsize, hp3_awprot, hp3_arprot;
    wire [1:0]  hp3_awburst, hp3_arburst, hp3_awlock, hp3_arlock;
    wire [1:0]  hp3_bresp, hp3_rresp;
    wire        hp3_awvalid, hp3_awready, hp3_wvalid, hp3_wready, hp3_wlast;
    wire        hp3_bvalid, hp3_bready;
    wire        hp3_arvalid, hp3_arready, hp3_rvalid, hp3_rready, hp3_rlast;

    // The clock the AXI master and the register file share.
    wire clk = fclk_clk0;

    // LOCKED comes straight out of the MMCM, asynchronous to FCLK_CLK0, so
    // it crosses into the register clock through two flops before STATUS
    // reads it.
    (* ASYNC_REG = "TRUE" *) reg [1:0] hdmi_locked_s = 2'b00;
    always @(posedge clk) hdmi_locked_s <= {hdmi_locked_s[0], hdmi_locked};

    // ---------------------------------------------------------------------
    // The MIG's own clock and its two status bits. ui_clk only exists once
    // the MIG's MMCM has locked, so nothing the CPU can reach is clocked by
    // it -- the register file keeps answering and says why the memory is not
    // there yet.
    // ---------------------------------------------------------------------
    wire ui_clk;
    wire ui_clk_sync_rst;         // active high, in the ui_clk domain
    wire mmcm_locked;
    wire init_calib_complete;
    wire ui_rstn = ~ui_clk_sync_rst;

    (* ASYNC_REG = "TRUE" *) reg [1:0] calib_sync, locked_sync;
    always @(posedge clk) begin
        calib_sync  <= {calib_sync[0],  init_calib_complete};
        locked_sync <= {locked_sync[0], mmcm_locked};
    end

    // FCLK_RESET0_N is asynchronous to FCLK_CLK0: synchronize its release.
    reg [1:0] rst_sync;
    always @(posedge clk or negedge fclk_reset0_n) begin
        if (!fclk_reset0_n) rst_sync <= 2'b00;
        else                rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rstn = rst_sync[1];

    // ---------------------------------------------------------------------
    ps7_rkz7100 ps7 (
        // EMIO GPIO carries everything on PL pins that the PS needs to
        // reach: bit 0 the fan tachometer, 1..7 the I2C buses and the ADV7611
        // reset, 8..9 the camera connector's two control lines, 10..13
        // LED1-4 (read back from GPIO_O), 14..17 the keys, 18..51 the J8
        // header, 52..55 the SFP cages (two TX_DISABLE readbacks, two LOS
        // inputs; gpio 106..109) and 56 (gpio 110) the CSI-2 receiver's video
        // reset, an output read back. 57..63 read 0. EMIO SPI0 is enabled
        // because the shared PS configuration has it, and nothing drives it.
        .GPIO_I              ({7'd0, gpio_o_w[56], sfp_los_sync, sfp_txdis_i,
                               j8_pad_i, key_emio, gpio_o_w[13:10],
                               emio_pad_i, tach_sync}),
        .GPIO_O              (gpio_o_w),
        .GPIO_T              (gpio_t_w),
        .SPI0_SCLK_I         (1'b0),
        .SPI0_SCLK_O         (),
        .SPI0_SCLK_T         (),
        .SPI0_MOSI_I         (1'b0),
        .SPI0_MOSI_O         (),
        .SPI0_MOSI_T         (),
        .SPI0_MISO_I         (1'b0),
        .SPI0_MISO_O         (),
        .SPI0_MISO_T         (),
        .SPI0_SS_I           (1'b0),
        .SPI0_SS_O           (),
        .SPI0_SS1_O          (),
        .SPI0_SS2_O          (),
        .SPI0_SS_T           (),
        .USB0_PORT_INDCTL    (),
        .USB0_VBUS_PWRSELECT (),
        .USB0_VBUS_PWRFAULT  (1'b0),

        // TTC1 waveform outputs on EMIO. Channel 0 is the fan PWM; Linux
        // drives it through pwm-cadence. Channels 1 and 2 are unused.
        .TTC1_WAVE0_OUT      (ttc1_wave0),
        .TTC1_WAVE1_OUT      (),
        .TTC1_WAVE2_OUT      (),

        .M_AXI_GP0_ACLK      (clk),
        .M_AXI_GP0_AWID      (gp0_awid),
        .M_AXI_GP0_AWADDR    (gp0_awaddr),
        .M_AXI_GP0_AWLEN     (gp0_awlen),
        .M_AXI_GP0_AWSIZE    (gp0_awsize),
        .M_AXI_GP0_AWBURST   (gp0_awburst),
        .M_AXI_GP0_AWLOCK    (gp0_awlock),
        .M_AXI_GP0_AWCACHE   (gp0_awcache),
        .M_AXI_GP0_AWPROT    (gp0_awprot),
        .M_AXI_GP0_AWQOS     (gp0_awqos),
        .M_AXI_GP0_AWVALID   (gp0_awvalid),
        .M_AXI_GP0_AWREADY   (gp0_awready),
        .M_AXI_GP0_WID       (gp0_wid),
        .M_AXI_GP0_WDATA     (gp0_wdata),
        .M_AXI_GP0_WSTRB     (gp0_wstrb),
        .M_AXI_GP0_WLAST     (gp0_wlast),
        .M_AXI_GP0_WVALID    (gp0_wvalid),
        .M_AXI_GP0_WREADY    (gp0_wready),
        .M_AXI_GP0_BID       (gp0_bid),
        .M_AXI_GP0_BRESP     (gp0_bresp),
        .M_AXI_GP0_BVALID    (gp0_bvalid),
        .M_AXI_GP0_BREADY    (gp0_bready),
        .M_AXI_GP0_ARID      (gp0_arid),
        .M_AXI_GP0_ARADDR    (gp0_araddr),
        .M_AXI_GP0_ARLEN     (gp0_arlen),
        .M_AXI_GP0_ARSIZE    (gp0_arsize),
        .M_AXI_GP0_ARBURST   (gp0_arburst),
        .M_AXI_GP0_ARLOCK    (gp0_arlock),
        .M_AXI_GP0_ARCACHE   (gp0_arcache),
        .M_AXI_GP0_ARPROT    (gp0_arprot),
        .M_AXI_GP0_ARQOS     (gp0_arqos),
        .M_AXI_GP0_ARVALID   (gp0_arvalid),
        .M_AXI_GP0_ARREADY   (gp0_arready),
        .M_AXI_GP0_RID       (gp0_rid),
        .M_AXI_GP0_RDATA     (gp0_rdata),
        .M_AXI_GP0_RRESP     (gp0_rresp),
        .M_AXI_GP0_RLAST     (gp0_rlast),
        .M_AXI_GP0_RVALID    (gp0_rvalid),
        .M_AXI_GP0_RREADY    (gp0_rready),

        // GP1 reaches the register file, both VDMAs' control ports and the
        // CSI-2 receiver, through a protocol converter and a crossbar (below).
        .M_AXI_GP1_ACLK      (clk),
        .M_AXI_GP1_AWID      (gp1_awid),
        .M_AXI_GP1_AWADDR    (gp1_awaddr),
        .M_AXI_GP1_AWLEN     (gp1_awlen),
        .M_AXI_GP1_AWSIZE    (gp1_awsize),
        .M_AXI_GP1_AWBURST   (gp1_awburst),
        .M_AXI_GP1_AWLOCK    (gp1_awlock),
        .M_AXI_GP1_AWCACHE   (gp1_awcache),
        .M_AXI_GP1_AWPROT    (gp1_awprot),
        .M_AXI_GP1_AWQOS     (gp1_awqos),
        .M_AXI_GP1_AWVALID   (gp1_awvalid),
        .M_AXI_GP1_AWREADY   (gp1_awready),
        .M_AXI_GP1_WID       (gp1_wid),
        .M_AXI_GP1_WDATA     (gp1_wdata),
        .M_AXI_GP1_WSTRB     (gp1_wstrb),
        .M_AXI_GP1_WLAST     (gp1_wlast),
        .M_AXI_GP1_WVALID    (gp1_wvalid),
        .M_AXI_GP1_WREADY    (gp1_wready),
        .M_AXI_GP1_BID       (gp1_bid),
        .M_AXI_GP1_BRESP     (gp1_bresp),
        .M_AXI_GP1_BVALID    (gp1_bvalid),
        .M_AXI_GP1_BREADY    (gp1_bready),
        .M_AXI_GP1_ARID      (gp1_arid),
        .M_AXI_GP1_ARADDR    (gp1_araddr),
        .M_AXI_GP1_ARLEN     (gp1_arlen),
        .M_AXI_GP1_ARSIZE    (gp1_arsize),
        .M_AXI_GP1_ARBURST   (gp1_arburst),
        .M_AXI_GP1_ARLOCK    (gp1_arlock),
        .M_AXI_GP1_ARCACHE   (gp1_arcache),
        .M_AXI_GP1_ARPROT    (gp1_arprot),
        .M_AXI_GP1_ARQOS     (gp1_arqos),
        .M_AXI_GP1_ARVALID   (gp1_arvalid),
        .M_AXI_GP1_ARREADY   (gp1_arready),
        .M_AXI_GP1_RID       (gp1_rid),
        .M_AXI_GP1_RDATA     (gp1_rdata),
        .M_AXI_GP1_RRESP     (gp1_rresp),
        .M_AXI_GP1_RLAST     (gp1_rlast),
        .M_AXI_GP1_RVALID    (gp1_rvalid),
        .M_AXI_GP1_RREADY    (gp1_rready),

        // HP0 is the capture VDMA's data master. Write-only: the read
        // channel is tied off in the fabric.
        .S_AXI_HP0_ACLK(clk),
        .S_AXI_HP0_AWID(hp0_awid),
        .S_AXI_HP0_AWADDR(hp0_awaddr),
        .S_AXI_HP0_AWLEN(hp0_awlen),
        .S_AXI_HP0_AWSIZE(hp0_awsize),
        .S_AXI_HP0_AWBURST(hp0_awburst),
        .S_AXI_HP0_AWLOCK(hp0_awlock),
        .S_AXI_HP0_AWCACHE(hp0_awcache),
        .S_AXI_HP0_AWPROT(hp0_awprot),
        .S_AXI_HP0_AWQOS(hp0_awqos),
        .S_AXI_HP0_AWVALID(hp0_awvalid),
        .S_AXI_HP0_AWREADY(hp0_awready),
        .S_AXI_HP0_WID(hp0_wid),
        .S_AXI_HP0_WDATA(hp0_wdata),
        .S_AXI_HP0_WSTRB(hp0_wstrb),
        .S_AXI_HP0_WLAST(hp0_wlast),
        .S_AXI_HP0_WVALID(hp0_wvalid),
        .S_AXI_HP0_WREADY(hp0_wready),
        .S_AXI_HP0_BID(hp0_bid),
        .S_AXI_HP0_BRESP(hp0_bresp),
        .S_AXI_HP0_BVALID(hp0_bvalid),
        .S_AXI_HP0_BREADY(hp0_bready),
        .S_AXI_HP0_ARID(hp0_arid),
        .S_AXI_HP0_ARADDR(hp0_araddr),
        .S_AXI_HP0_ARLEN(hp0_arlen),
        .S_AXI_HP0_ARSIZE(hp0_arsize),
        .S_AXI_HP0_ARBURST(hp0_arburst),
        .S_AXI_HP0_ARLOCK(hp0_arlock),
        .S_AXI_HP0_ARCACHE(hp0_arcache),
        .S_AXI_HP0_ARPROT(hp0_arprot),
        .S_AXI_HP0_ARQOS(hp0_arqos),
        .S_AXI_HP0_ARVALID(hp0_arvalid),
        .S_AXI_HP0_ARREADY(hp0_arready),
        .S_AXI_HP0_RID(hp0_rid),
        .S_AXI_HP0_RDATA(hp0_rdata),
        .S_AXI_HP0_RRESP(hp0_rresp),
        .S_AXI_HP0_RLAST(hp0_rlast),
        .S_AXI_HP0_RVALID(hp0_rvalid),
        .S_AXI_HP0_RREADY(hp0_rready),
        .S_AXI_HP0_RCOUNT(),
        .S_AXI_HP0_WCOUNT(),
        .S_AXI_HP0_RACOUNT(),
        .S_AXI_HP0_WACOUNT(),
        .S_AXI_HP0_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP0_WRISSUECAP1_EN(1'b0),

        // HP3 is the camera VDMA's data master, write-only like HP0.
        .S_AXI_HP3_ACLK(clk),
        .S_AXI_HP3_AWID(hp3_awid),
        .S_AXI_HP3_AWADDR(hp3_awaddr),
        .S_AXI_HP3_AWLEN(hp3_awlen),
        .S_AXI_HP3_AWSIZE(hp3_awsize),
        .S_AXI_HP3_AWBURST(hp3_awburst),
        .S_AXI_HP3_AWLOCK(hp3_awlock),
        .S_AXI_HP3_AWCACHE(hp3_awcache),
        .S_AXI_HP3_AWPROT(hp3_awprot),
        .S_AXI_HP3_AWQOS(hp3_awqos),
        .S_AXI_HP3_AWVALID(hp3_awvalid),
        .S_AXI_HP3_AWREADY(hp3_awready),
        .S_AXI_HP3_WID(hp3_wid),
        .S_AXI_HP3_WDATA(hp3_wdata),
        .S_AXI_HP3_WSTRB(hp3_wstrb),
        .S_AXI_HP3_WLAST(hp3_wlast),
        .S_AXI_HP3_WVALID(hp3_wvalid),
        .S_AXI_HP3_WREADY(hp3_wready),
        .S_AXI_HP3_BID(hp3_bid),
        .S_AXI_HP3_BRESP(hp3_bresp),
        .S_AXI_HP3_BVALID(hp3_bvalid),
        .S_AXI_HP3_BREADY(hp3_bready),
        .S_AXI_HP3_ARID(hp3_arid),
        .S_AXI_HP3_ARADDR(hp3_araddr),
        .S_AXI_HP3_ARLEN(hp3_arlen),
        .S_AXI_HP3_ARSIZE(hp3_arsize),
        .S_AXI_HP3_ARBURST(hp3_arburst),
        .S_AXI_HP3_ARLOCK(hp3_arlock),
        .S_AXI_HP3_ARCACHE(hp3_arcache),
        .S_AXI_HP3_ARPROT(hp3_arprot),
        .S_AXI_HP3_ARQOS(hp3_arqos),
        .S_AXI_HP3_ARVALID(hp3_arvalid),
        .S_AXI_HP3_ARREADY(hp3_arready),
        .S_AXI_HP3_RID(hp3_rid),
        .S_AXI_HP3_RDATA(hp3_rdata),
        .S_AXI_HP3_RRESP(hp3_rresp),
        .S_AXI_HP3_RLAST(hp3_rlast),
        .S_AXI_HP3_RVALID(hp3_rvalid),
        .S_AXI_HP3_RREADY(hp3_rready),
        .S_AXI_HP3_RCOUNT(),
        .S_AXI_HP3_WCOUNT(),
        .S_AXI_HP3_RACOUNT(),
        .S_AXI_HP3_WACOUNT(),
        .S_AXI_HP3_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP3_WRISSUECAP1_EN(1'b0),

        .S_AXI_HP1_ACLK(clk),
        .S_AXI_HP1_AWID(hp1_awid),
        .S_AXI_HP1_AWADDR(hp1_awaddr),
        .S_AXI_HP1_AWLEN(hp1_awlen),
        .S_AXI_HP1_AWSIZE(hp1_awsize),
        .S_AXI_HP1_AWBURST(hp1_awburst),
        .S_AXI_HP1_AWLOCK(hp1_awlock),
        .S_AXI_HP1_AWCACHE(hp1_awcache),
        .S_AXI_HP1_AWPROT(hp1_awprot),
        .S_AXI_HP1_AWQOS(hp1_awqos),
        .S_AXI_HP1_AWVALID(hp1_awvalid),
        .S_AXI_HP1_AWREADY(hp1_awready),
        .S_AXI_HP1_WID(hp1_wid),
        .S_AXI_HP1_WDATA(hp1_wdata),
        .S_AXI_HP1_WSTRB(hp1_wstrb),
        .S_AXI_HP1_WLAST(hp1_wlast),
        .S_AXI_HP1_WVALID(hp1_wvalid),
        .S_AXI_HP1_WREADY(hp1_wready),
        .S_AXI_HP1_BID(hp1_bid),
        .S_AXI_HP1_BRESP(hp1_bresp),
        .S_AXI_HP1_BVALID(hp1_bvalid),
        .S_AXI_HP1_BREADY(hp1_bready),
        .S_AXI_HP1_ARID(hp1_arid),
        .S_AXI_HP1_ARADDR(hp1_araddr),
        .S_AXI_HP1_ARLEN(hp1_arlen),
        .S_AXI_HP1_ARSIZE(hp1_arsize),
        .S_AXI_HP1_ARBURST(hp1_arburst),
        .S_AXI_HP1_ARLOCK(hp1_arlock),
        .S_AXI_HP1_ARCACHE(hp1_arcache),
        .S_AXI_HP1_ARPROT(hp1_arprot),
        .S_AXI_HP1_ARQOS(hp1_arqos),
        .S_AXI_HP1_ARVALID(hp1_arvalid),
        .S_AXI_HP1_ARREADY(hp1_arready),
        .S_AXI_HP1_RID(hp1_rid),
        .S_AXI_HP1_RDATA(hp1_rdata),
        .S_AXI_HP1_RRESP(hp1_rresp),
        .S_AXI_HP1_RLAST(hp1_rlast),
        .S_AXI_HP1_RVALID(hp1_rvalid),
        .S_AXI_HP1_RREADY(hp1_rready),
        .S_AXI_HP1_RCOUNT(),
        .S_AXI_HP1_WCOUNT(),
        .S_AXI_HP1_RACOUNT(),
        .S_AXI_HP1_WACOUNT(),
        .S_AXI_HP1_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP1_WRISSUECAP1_EN(1'b0),
        .S_AXI_HP2_ACLK(clk),
        .S_AXI_HP2_AWID(hp2_awid),
        .S_AXI_HP2_AWADDR(hp2_awaddr),
        .S_AXI_HP2_AWLEN(hp2_awlen),
        .S_AXI_HP2_AWSIZE(hp2_awsize),
        .S_AXI_HP2_AWBURST(hp2_awburst),
        .S_AXI_HP2_AWLOCK(hp2_awlock),
        .S_AXI_HP2_AWCACHE(hp2_awcache),
        .S_AXI_HP2_AWPROT(hp2_awprot),
        .S_AXI_HP2_AWQOS(hp2_awqos),
        .S_AXI_HP2_AWVALID(hp2_awvalid),
        .S_AXI_HP2_AWREADY(hp2_awready),
        .S_AXI_HP2_WID(hp2_wid),
        .S_AXI_HP2_WDATA(hp2_wdata),
        .S_AXI_HP2_WSTRB(hp2_wstrb),
        .S_AXI_HP2_WLAST(hp2_wlast),
        .S_AXI_HP2_WVALID(hp2_wvalid),
        .S_AXI_HP2_WREADY(hp2_wready),
        .S_AXI_HP2_BID(hp2_bid),
        .S_AXI_HP2_BRESP(hp2_bresp),
        .S_AXI_HP2_BVALID(hp2_bvalid),
        .S_AXI_HP2_BREADY(hp2_bready),
        .S_AXI_HP2_ARID(hp2_arid),
        .S_AXI_HP2_ARADDR(hp2_araddr),
        .S_AXI_HP2_ARLEN(hp2_arlen),
        .S_AXI_HP2_ARSIZE(hp2_arsize),
        .S_AXI_HP2_ARBURST(hp2_arburst),
        .S_AXI_HP2_ARLOCK(hp2_arlock),
        .S_AXI_HP2_ARCACHE(hp2_arcache),
        .S_AXI_HP2_ARPROT(hp2_arprot),
        .S_AXI_HP2_ARQOS(hp2_arqos),
        .S_AXI_HP2_ARVALID(hp2_arvalid),
        .S_AXI_HP2_ARREADY(hp2_arready),
        .S_AXI_HP2_RID(hp2_rid),
        .S_AXI_HP2_RDATA(hp2_rdata),
        .S_AXI_HP2_RRESP(hp2_rresp),
        .S_AXI_HP2_RLAST(hp2_rlast),
        .S_AXI_HP2_RVALID(hp2_rvalid),
        .S_AXI_HP2_RREADY(hp2_rready),
        .S_AXI_HP2_RCOUNT(),
        .S_AXI_HP2_WCOUNT(),
        .S_AXI_HP2_RACOUNT(),
        .S_AXI_HP2_WACOUNT(),
        .S_AXI_HP2_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP2_WRISSUECAP1_EN(1'b0),

        // The fabric interrupts. IRQ_F2P[5:0] are GIC 61..66 -- SPI 29..34
        // in a device tree: [1:0] the BIST engines on the HP ports, [2] the
        // HDMI capture VDMA, [3] the camera VDMA, [4] the CSI-2 receiver and
        // [5] the BIST engine on the MIG.
        .IRQ_F2P             (bist_irq),

        .FCLK_CLK0           (fclk_clk0),

        // GEM1 over EMIO, as GMII, to the gmii_to_rgmii core for PHY2.
        .ENET1_GMII_TX_CLK   (gmii_tx_clk),
        .ENET1_GMII_TXD      (gmii_txd),
        .ENET1_GMII_TX_EN    (gmii_tx_en),
        .ENET1_GMII_TX_ER    (gmii_tx_er),
        .ENET1_GMII_RX_CLK   (gmii_rx_clk),
        .ENET1_GMII_RXD      (gmii_rxd),
        .ENET1_GMII_RX_DV    (gmii_rx_dv),
        .ENET1_GMII_RX_ER    (gmii_rx_er),
        .ENET1_GMII_COL      (gmii_col),
        .ENET1_GMII_CRS      (gmii_crs),
        .ENET1_MDIO_MDC      (gem1_mdc),
        .ENET1_MDIO_O        (gem1_mdio_o),
        .ENET1_MDIO_T        (gem1_mdio_t),
        .ENET1_MDIO_I        (gem1_mdio_i),
        .ENET1_EXT_INTIN     (1'b0),
        .FCLK_CLK1           (),
        .FCLK_RESET0_N       (fclk_reset0_n),

        .MIO                 (MIO),
        .DDR_CAS_n           (DDR_CAS_n),
        .DDR_CKE             (DDR_CKE),
        .DDR_Clk_n           (DDR_Clk_n),
        .DDR_Clk             (DDR_Clk),
        .DDR_CS_n            (DDR_CS_n),
        .DDR_DRSTB           (DDR_DRSTB),
        .DDR_ODT             (DDR_ODT),
        .DDR_RAS_n           (DDR_RAS_n),
        .DDR_WEB             (DDR_WEB),
        .DDR_BankAddr        (DDR_BankAddr),
        .DDR_Addr            (DDR_Addr),
        .DDR_VRN             (DDR_VRN),
        .DDR_VRP             (DDR_VRP),
        .DDR_DM              (DDR_DM),
        .DDR_DQ              (DDR_DQ),
        .DDR_DQS_n           (DDR_DQS_n),
        .DDR_DQS             (DDR_DQS),
        .PS_SRSTB            (PS_SRSTB),
        .PS_CLK              (PS_CLK),
        .PS_PORB             (PS_PORB)
    );

    // LED1-4 are outputs always, so they take GPIO_O straight -- no IOBUF and
    // no tristate. EMIO bits 10..13 are Linux gpio 64..67, and the same bits
    // are fed back into GPIO_I above so a read returns what was written.
    assign led[3:0] = gpio_o_w[13:10];

    // ---------------------------------------------------------------------
    axi4_regs #(.ID_W(12), .BIST_CAPS(3'b111)) regs (
        .clk       (clk),
        .rstn      (rstn),

        // ⚠ Behind an AXI4-Lite crossbar port, so the master issues single
        // beats: AWLEN is 0, WLAST is 1, and the IDs and RLAST go nowhere.
        // The protocol converter in front of the crossbar is what splits a
        // CPU burst into those singles, so the file still answers a memcpy.
        .s_awid    (12'd0),
        .s_awaddr  (rlite_awaddr),
        .s_awlen   (4'd0),
        .s_awvalid (rlite_awvalid),
        .s_awready (rlite_awready),

        .s_wdata   (rlite_wdata),
        .s_wstrb   (rlite_wstrb),
        .s_wlast   (1'b1),
        .s_wvalid  (rlite_wvalid),
        .s_wready  (rlite_wready),

        .s_bid     (),
        .s_bresp   (rlite_bresp),
        .s_bvalid  (rlite_bvalid),
        .s_bready  (rlite_bready),

        .s_arid    (12'd0),
        .s_araddr  (rlite_araddr),
        .s_arlen   (4'd0),
        .s_arvalid (rlite_arvalid),
        .s_arready (rlite_arready),

        .s_rid     (),
        .s_rdata   (rlite_rdata),
        .s_rresp   (rlite_rresp),
        .s_rlast   (),
        .s_rvalid  (rlite_rvalid),
        .s_rready  (rlite_rready),

        .led8      (led[5:4]),
        .key_n     (key_n),
        // [0] PL DDR3 calibrated, which also turns LED8 solid; [1] the MIG's
        // MMCM; [2] the HDMI pixel clock's MMCM. All three are synchronized
        // into this clock domain.
        .status    ({29'd0, hdmi_locked_s[1], locked_sync[1], calib_sync[1]}),
        .fan_status (fan_status),
        .fan_ctrl   (fan_ctrl_w),

        .freq0     (freq0),
        .freq1     (freq1),
        .freq2     (freq2),
        .freq3     (freq3),
        .freq_updates ({up3, up2, up1, up0}),

        // AUX: [0] asks for the MIG to be handed to its BIST engine and
        // [15] turns cam_guard's frame dropping off; the high half is
        // axi_owner's (see the MIG block). The PL Ethernet core's status is
        // sub-block 2, index 13.
        .aux_ctrl  (aux_ctrl),
        // [0] owner [1] switching [2] idle [3] w_busy
        // [7:4] outstanding AW  [11:8] outstanding AR
        .aux_status ({4'd0, mig_ar_out, mig_aw_out,
                      mig_dbg[1], mig_dbg[0], mig_switching, mig_owner}),

        .blk_waddr (blk_waddr),
        .blk_raddr (blk_raddr),
        .blk_we    (blk_we),
        .blk_wdata (blk_wdata),
        .blk_rdata0 (blk_rdata0),
        .blk_rdata1 (blk_rdata1),
        // Sub-block 2, at 0xC0: the HDMI capture and camera status words,
        // and at index 13 the PL Ethernet core's. Sub-block 4, at 0x140, is
        // the BIST engine on the MIG.
        .blk_rdata2 (blk_rdata2_r),
        // Block 3, at 0x100: the GTX PRBS exerciser on the SFP lanes.
        .blk_rdata3 (blk_rdata3),
        .blk_rdata4 (blk_rdata4),
        .blk_irq   ({bist_irq[5], bist_irq[1:0]})
    );

    // ---------------------------------------------------------------------
    fan_ctrl fan (
        .tach_sync_o (tach_sync),
        .clk      (clk),
        .rstn     (rstn),
        .pwm_in   (ttc1_wave0),
        .fan_pwm  (fan_pwm),
        .fan_tach (fan_tach),
        .ctrl     (fan_ctrl_w),
        .status   (fan_status)
    );

    // ---------------------------------------------------------------------
    // The PL pins the PS drives as GPIOs. Order here fixes the Linux gpio
    // numbers, which the device tree's i2c-gpio nodes name:
    //   55 hdmi_tx_scl   56 hdmi_tx_sda   57 hdmi_rx_scl   58 hdmi_rx_sda
    //   59 cam_scl       60 cam_sda       61 hdmi_rx_rst_n
    //   62 cam_gpio      63 cam_clk        (J9 pins 5 and 4)
    // ---------------------------------------------------------------------
    emio_pads #(.N(9)) emio_bitbang (
        .gpio_o (gpio_o_w[9:1]),
        .gpio_t (gpio_t_w[9:1]),
        .gpio_i (emio_pad_i),
        .pad    ({cam_clk, cam_gpio,
                  hdmi_rx_rst_n, cam_sda, cam_scl,
                  hdmi_rx_sda, hdmi_rx_scl, hdmi_tx_sda, hdmi_tx_scl})
    );

    // ---------------------------------------------------------------------
    // GP0 -> AXI3-to-AXI4 -> axi_owner (shared with BIST engine 2) -> clock
    // crossing -> MIG
    //
    // Two single-slave/single-master converters rather than one interconnect:
    // the MIG is GP0's only slave, so there is nothing to decode, and the one
    // arbitration there is -- the CPU or BIST engine 2 -- is axi_owner's.
    // ---------------------------------------------------------------------
    wire [11:0] c_awid, c_arid, c_bid, c_rid;
    wire [31:0] c_awaddr, c_araddr, c_wdata, c_rdata;
    wire [7:0]  c_awlen, c_arlen;
    wire [3:0]  c_wstrb, c_awcache, c_arcache, c_awqos, c_arqos;
    wire [3:0]  c_awregion, c_arregion;
    wire [2:0]  c_awsize, c_arsize, c_awprot, c_arprot;
    wire [1:0]  c_awburst, c_arburst, c_bresp, c_rresp;
    wire [0:0]  c_awlock, c_arlock;
    wire        c_awvalid, c_awready, c_wvalid, c_wready, c_wlast;
    wire        c_bvalid, c_bready, c_arvalid, c_arready;
    wire        c_rvalid, c_rready, c_rlast;

    apc gp0_to_axi4 (
        .aclk            (clk),
        .aresetn         (rstn),

        .s_axi_awid      (gp0_awid),
        .s_axi_awaddr    (gp0_awaddr),
        .s_axi_awlen     (gp0_awlen),
        .s_axi_awsize    (gp0_awsize),
        .s_axi_awburst   (gp0_awburst),
        .s_axi_awlock    (gp0_awlock),
        .s_axi_awcache   (gp0_awcache),
        .s_axi_awprot    (gp0_awprot),
        .s_axi_awqos     (gp0_awqos),
        .s_axi_awvalid   (gp0_awvalid),
        .s_axi_awready   (gp0_awready),
        .s_axi_wid       (gp0_wid),
        .s_axi_wdata     (gp0_wdata),
        .s_axi_wstrb     (gp0_wstrb),
        .s_axi_wlast     (gp0_wlast),
        .s_axi_wvalid    (gp0_wvalid),
        .s_axi_wready    (gp0_wready),
        .s_axi_bid       (gp0_bid),
        .s_axi_bresp     (gp0_bresp),
        .s_axi_bvalid    (gp0_bvalid),
        .s_axi_bready    (gp0_bready),
        .s_axi_arid      (gp0_arid),
        .s_axi_araddr    (gp0_araddr),
        .s_axi_arlen     (gp0_arlen),
        .s_axi_arsize    (gp0_arsize),
        .s_axi_arburst   (gp0_arburst),
        .s_axi_arlock    (gp0_arlock),
        .s_axi_arcache   (gp0_arcache),
        .s_axi_arprot    (gp0_arprot),
        .s_axi_arqos     (gp0_arqos),
        .s_axi_arvalid   (gp0_arvalid),
        .s_axi_arready   (gp0_arready),
        .s_axi_rid       (gp0_rid),
        .s_axi_rdata     (gp0_rdata),
        .s_axi_rresp     (gp0_rresp),
        .s_axi_rlast     (gp0_rlast),
        .s_axi_rvalid    (gp0_rvalid),
        .s_axi_rready    (gp0_rready),

        .m_axi_awid      (cpu_awid),
        .m_axi_awaddr    (cpu_awaddr),
        .m_axi_awlen     (cpu_awlen),
        .m_axi_awsize    (cpu_awsize),
        .m_axi_awburst   (cpu_awburst),
        .m_axi_awlock    (cpu_awlock),
        .m_axi_awcache   (cpu_awcache),
        .m_axi_awprot    (cpu_awprot),
        .m_axi_awregion  (),
        .m_axi_awqos     (cpu_awqos),
        .m_axi_awvalid   (cpu_awvalid),
        .m_axi_awready   (cpu_awready),
        .m_axi_wdata     (cpu_wdata),
        .m_axi_wstrb     (cpu_wstrb),
        .m_axi_wlast     (cpu_wlast),
        .m_axi_wvalid    (cpu_wvalid),
        .m_axi_wready    (cpu_wready),
        .m_axi_bid       (cpu_bid),
        .m_axi_bresp     (cpu_bresp),
        .m_axi_bvalid    (cpu_bvalid),
        .m_axi_bready    (cpu_bready),
        .m_axi_arid      (cpu_arid),
        .m_axi_araddr    (cpu_araddr),
        .m_axi_arlen     (cpu_arlen),
        .m_axi_arsize    (cpu_arsize),
        .m_axi_arburst   (cpu_arburst),
        .m_axi_arlock    (cpu_arlock),
        .m_axi_arcache   (cpu_arcache),
        .m_axi_arprot    (cpu_arprot),
        .m_axi_arregion  (),
        .m_axi_arqos     (cpu_arqos),
        .m_axi_arvalid   (cpu_arvalid),
        .m_axi_arready   (cpu_arready),
        .m_axi_rid       (cpu_rid),
        .m_axi_rdata     (cpu_rdata),
        .m_axi_rresp     (cpu_rresp),
        .m_axi_rlast     (cpu_rlast),
        .m_axi_rvalid    (cpu_rvalid),
        .m_axi_rready    (cpu_rready)
    );

    wire [11:0] m_awid, m_arid, m_bid, m_rid;
    wire [31:0] m_awaddr, m_araddr, m_wdata, m_rdata;
    wire [7:0]  m_awlen, m_arlen;
    wire [3:0]  m_wstrb, m_awcache, m_arcache, m_awqos, m_arqos;
    wire [2:0]  m_awsize, m_arsize, m_awprot, m_arprot;
    wire [1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
    wire [0:0]  m_awlock, m_arlock;
    wire        m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
    wire        m_bvalid, m_bready, m_arvalid, m_arready;
    wire        m_rvalid, m_rready, m_rlast;

    acc fclk_to_ui (
        .s_axi_aclk      (clk),
        .s_axi_aresetn   (rstn),
        .s_axi_awid      (c_awid),
        .s_axi_awaddr    (c_awaddr),
        .s_axi_awlen     (c_awlen),
        .s_axi_awsize    (c_awsize),
        .s_axi_awburst   (c_awburst),
        .s_axi_awlock    (c_awlock),
        .s_axi_awcache   (c_awcache),
        .s_axi_awprot    (c_awprot),
        .s_axi_awregion  (c_awregion),
        .s_axi_awqos     (c_awqos),
        .s_axi_awvalid   (c_awvalid),
        .s_axi_awready   (c_awready),
        .s_axi_wdata     (c_wdata),
        .s_axi_wstrb     (c_wstrb),
        .s_axi_wlast     (c_wlast),
        .s_axi_wvalid    (c_wvalid),
        .s_axi_wready    (c_wready),
        .s_axi_bid       (c_bid),
        .s_axi_bresp     (c_bresp),
        .s_axi_bvalid    (c_bvalid),
        .s_axi_bready    (c_bready),
        .s_axi_arid      (c_arid),
        .s_axi_araddr    (c_araddr),
        .s_axi_arlen     (c_arlen),
        .s_axi_arsize    (c_arsize),
        .s_axi_arburst   (c_arburst),
        .s_axi_arlock    (c_arlock),
        .s_axi_arcache   (c_arcache),
        .s_axi_arprot    (c_arprot),
        .s_axi_arregion  (c_arregion),
        .s_axi_arqos     (c_arqos),
        .s_axi_arvalid   (c_arvalid),
        .s_axi_arready   (c_arready),
        .s_axi_rid       (c_rid),
        .s_axi_rdata     (c_rdata),
        .s_axi_rresp     (c_rresp),
        .s_axi_rlast     (c_rlast),
        .s_axi_rvalid    (c_rvalid),
        .s_axi_rready    (c_rready),

        .m_axi_aclk      (ui_clk),
        .m_axi_aresetn   (ui_rstn),
        .m_axi_awid      (m_awid),
        .m_axi_awaddr    (m_awaddr),
        .m_axi_awlen     (m_awlen),
        .m_axi_awsize    (m_awsize),
        .m_axi_awburst   (m_awburst),
        .m_axi_awlock    (m_awlock),
        .m_axi_awcache   (m_awcache),
        .m_axi_awprot    (m_awprot),
        .m_axi_awregion  (),          // MIG has no AWREGION
        .m_axi_awqos     (m_awqos),
        .m_axi_awvalid   (m_awvalid),
        .m_axi_awready   (m_awready),
        .m_axi_wdata     (m_wdata),
        .m_axi_wstrb     (m_wstrb),
        .m_axi_wlast     (m_wlast),
        .m_axi_wvalid    (m_wvalid),
        .m_axi_wready    (m_wready),
        .m_axi_bid       (m_bid),
        .m_axi_bresp     (m_bresp),
        .m_axi_bvalid    (m_bvalid),
        .m_axi_bready    (m_bready),
        .m_axi_arid      (m_arid),
        .m_axi_araddr    (m_araddr),
        .m_axi_arlen     (m_arlen),
        .m_axi_arsize    (m_arsize),
        .m_axi_arburst   (m_arburst),
        .m_axi_arlock    (m_arlock),
        .m_axi_arcache   (m_arcache),
        .m_axi_arprot    (m_arprot),
        .m_axi_arregion  (),
        .m_axi_arqos     (m_arqos),
        .m_axi_arvalid   (m_arvalid),
        .m_axi_arready   (m_arready),
        .m_axi_rid       (m_rid),
        .m_axi_rdata     (m_rdata),
        .m_axi_rresp     (m_rresp),
        .m_axi_rlast     (m_rlast),
        .m_axi_rvalid    (m_rvalid),
        .m_axi_rready    (m_rready)
    );

    // The GP0 window is 0x4000_0000..0x7FFF_FFFF, so the low 30 address bits
    // are already the offset into the 1 GB of DRAM. No subtraction needed.
    mig_rkz7100 mig (
        .ddr3_addr           (ddr3_addr),
        .ddr3_ba             (ddr3_ba),
        .ddr3_cas_n          (ddr3_cas_n),
        .ddr3_ck_n           (ddr3_ck_n),
        .ddr3_ck_p           (ddr3_ck_p),
        .ddr3_cke            (ddr3_cke),
        .ddr3_ras_n          (ddr3_ras_n),
        .ddr3_reset_n        (ddr3_reset_n),
        .ddr3_we_n           (ddr3_we_n),
        .ddr3_dq             (ddr3_dq),
        .ddr3_dqs_n          (ddr3_dqs_n),
        .ddr3_dqs_p          (ddr3_dqs_p),
        .ddr3_cs_n           (ddr3_cs_n),
        .ddr3_dm             (ddr3_dm),
        .ddr3_odt            (ddr3_odt),
        .init_calib_complete (init_calib_complete),

        .ui_clk              (ui_clk),
        .ui_clk_sync_rst     (ui_clk_sync_rst),
        .mmcm_locked         (mmcm_locked),
        .aresetn             (ui_rstn),
        .app_sr_req          (1'b0),
        .app_ref_req         (1'b0),
        .app_zq_req          (1'b0),
        .app_sr_active       (),
        .app_ref_ack         (),
        .app_zq_ack          (),

        .s_axi_awid          (m_awid),
        .s_axi_awaddr        (m_awaddr[29:0]),
        .s_axi_awlen         (m_awlen),
        .s_axi_awsize        (m_awsize),
        .s_axi_awburst       (m_awburst),
        .s_axi_awlock        (m_awlock),
        .s_axi_awcache       (m_awcache),
        .s_axi_awprot        (m_awprot),
        .s_axi_awqos         (m_awqos),
        .s_axi_awvalid       (m_awvalid),
        .s_axi_awready       (m_awready),
        .s_axi_wdata         (m_wdata),
        .s_axi_wstrb         (m_wstrb),
        .s_axi_wlast         (m_wlast),
        .s_axi_wvalid        (m_wvalid),
        .s_axi_wready        (m_wready),
        .s_axi_bid           (m_bid),
        .s_axi_bresp         (m_bresp),
        .s_axi_bvalid        (m_bvalid),
        .s_axi_bready        (m_bready),
        .s_axi_arid          (m_arid),
        .s_axi_araddr        (m_araddr[29:0]),
        .s_axi_arlen         (m_arlen),
        .s_axi_arsize        (m_arsize),
        .s_axi_arburst       (m_arburst),
        .s_axi_arlock        (m_arlock),
        .s_axi_arcache       (m_arcache),
        .s_axi_arprot        (m_arprot),
        .s_axi_arqos         (m_arqos),
        .s_axi_arvalid       (m_arvalid),
        .s_axi_arready       (m_arready),
        .s_axi_rid           (m_rid),
        .s_axi_rdata         (m_rdata),
        .s_axi_rresp         (m_rresp),
        .s_axi_rlast         (m_rlast),
        .s_axi_rvalid        (m_rvalid),
        .s_axi_rready        (m_rready),

        .sys_clk_i           (sys_clk_g),
        .sys_rst             (rstn)     // ACTIVE LOW, per the MIG project
    );
    // ---------------------------------------------------------------------
    // BIST engine 2, on the MIG -- the PL's own gigabyte, tested from inside
    // the fabric instead of one `devmem` at a time.
    //
    // ⚠ It shares the MIG's single AXI port with the CPU through axi_owner,
    // one owner at a time, because an interconnect would widen the ID by a
    // bit and the MIG's slave is generated for 12. Whoever does not own it is
    // answered SLVERR rather than left waiting -- on this board a master that
    // hangs on the PL bus means a JTAG reset.
    // ---------------------------------------------------------------------
    axi_bist #(.DW(32), .IDW(12), .LENW(8), .BEATS(16),
               .MAXOUT(4)) bist_mig (
        .clk(clk), .rstn(rstn),
        .reg_waddr(blk_waddr), .reg_we(blk_we[4]),
        .reg_wdata(blk_wdata), .reg_raddr(blk_raddr),
        .reg_rdata(blk_rdata4), .irq(bist_irq[5]),
        .m_awid(bst_awid),
        .m_awaddr(bst_awaddr),
        .m_awlen(bst_awlen),
        .m_awsize(bst_awsize),
        .m_awburst(bst_awburst),
        .m_awlock(bst_awlock),
        .m_awcache(bst_awcache),
        .m_awprot(bst_awprot),
        .m_awqos(bst_awqos),
        .m_awvalid(bst_awvalid),
        .m_awready(bst_awready),
        .m_wid(bst_wid),
        .m_wdata(bst_wdata),
        .m_wstrb(bst_wstrb),
        .m_wlast(bst_wlast),
        .m_wvalid(bst_wvalid),
        .m_wready(bst_wready),
        .m_bid(bst_bid),
        .m_bresp(bst_bresp),
        .m_bvalid(bst_bvalid),
        .m_bready(bst_bready),
        .m_arid(bst_arid),
        .m_araddr(bst_araddr),
        .m_arlen(bst_arlen),
        .m_arsize(bst_arsize),
        .m_arburst(bst_arburst),
        .m_arlock(bst_arlock),
        .m_arcache(bst_arcache),
        .m_arprot(bst_arprot),
        .m_arqos(bst_arqos),
        .m_arvalid(bst_arvalid),
        .m_arready(bst_arready),
        .m_rid(bst_rid),
        .m_rdata(bst_rdata),
        .m_rresp(bst_rresp),
        .m_rlast(bst_rlast),
        .m_rvalid(bst_rvalid),
        .m_rready(bst_rready)
    );

    axi_owner #(.DW(32), .IDW(12), .LENW(8)) mig_arb (
        .clk(clk), .rstn(rstn),
        .sel(aux_ctrl[0]), .owner(mig_owner), .switching(mig_switching),
        .dbg_w_busy_aw_ar(mig_dbg), .dbg_aw_out(mig_aw_out),
        .dbg_ar_out(mig_ar_out),

        .a_awid(cpu_awid), .a_awaddr(cpu_awaddr), .a_awlen(cpu_awlen),
        .a_awsize(cpu_awsize), .a_awburst(cpu_awburst),
        .a_awlock(cpu_awlock), .a_awcache(cpu_awcache),
        .a_awprot(cpu_awprot), .a_awqos(cpu_awqos),
        .a_awvalid(cpu_awvalid), .a_awready(cpu_awready),
        .a_wdata(cpu_wdata), .a_wstrb(cpu_wstrb), .a_wlast(cpu_wlast),
        .a_wvalid(cpu_wvalid), .a_wready(cpu_wready),
        .a_bid(cpu_bid), .a_bresp(cpu_bresp), .a_bvalid(cpu_bvalid),
        .a_bready(cpu_bready),
        .a_arid(cpu_arid), .a_araddr(cpu_araddr), .a_arlen(cpu_arlen),
        .a_arsize(cpu_arsize), .a_arburst(cpu_arburst),
        .a_arlock(cpu_arlock), .a_arcache(cpu_arcache),
        .a_arprot(cpu_arprot), .a_arqos(cpu_arqos),
        .a_arvalid(cpu_arvalid), .a_arready(cpu_arready),
        .a_rid(cpu_rid), .a_rdata(cpu_rdata), .a_rresp(cpu_rresp),
        .a_rlast(cpu_rlast), .a_rvalid(cpu_rvalid), .a_rready(cpu_rready),

        .b_awid(bst_awid), .b_awaddr(bst_awaddr), .b_awlen(bst_awlen),
        .b_awsize(bst_awsize), .b_awburst(bst_awburst),
        .b_awlock(bst_awlock[0]), .b_awcache(bst_awcache),
        .b_awprot(bst_awprot), .b_awqos(bst_awqos),
        .b_awvalid(bst_awvalid), .b_awready(bst_awready),
        .b_wdata(bst_wdata), .b_wstrb(bst_wstrb), .b_wlast(bst_wlast),
        .b_wvalid(bst_wvalid), .b_wready(bst_wready),
        .b_bid(bst_bid), .b_bresp(bst_bresp), .b_bvalid(bst_bvalid),
        .b_bready(bst_bready),
        .b_arid(bst_arid), .b_araddr(bst_araddr), .b_arlen(bst_arlen),
        .b_arsize(bst_arsize), .b_arburst(bst_arburst),
        .b_arlock(bst_arlock[0]), .b_arcache(bst_arcache),
        .b_arprot(bst_arprot), .b_arqos(bst_arqos),
        .b_arvalid(bst_arvalid), .b_arready(bst_arready),
        .b_rid(bst_rid), .b_rdata(bst_rdata), .b_rresp(bst_rresp),
        .b_rlast(bst_rlast), .b_rvalid(bst_rvalid), .b_rready(bst_rready),

        .m_awid(c_awid), .m_awaddr(c_awaddr), .m_awlen(c_awlen),
        .m_awsize(c_awsize), .m_awburst(c_awburst), .m_awlock(c_awlock[0]),
        .m_awcache(c_awcache), .m_awprot(c_awprot), .m_awqos(c_awqos),
        .m_awvalid(c_awvalid), .m_awready(c_awready),
        .m_wdata(c_wdata), .m_wstrb(c_wstrb), .m_wlast(c_wlast),
        .m_wvalid(c_wvalid), .m_wready(c_wready),
        .m_bid(c_bid), .m_bresp(c_bresp), .m_bvalid(c_bvalid),
        .m_bready(c_bready),
        .m_arid(c_arid), .m_araddr(c_araddr), .m_arlen(c_arlen),
        .m_arsize(c_arsize), .m_arburst(c_arburst), .m_arlock(c_arlock[0]),
        .m_arcache(c_arcache), .m_arprot(c_arprot), .m_arqos(c_arqos),
        .m_arvalid(c_arvalid), .m_arready(c_arready),
        .m_rid(c_rid), .m_rdata(c_rdata), .m_rresp(c_rresp),
        .m_rlast(c_rlast), .m_rvalid(c_rvalid), .m_rready(c_rready)
    );

    // AXI4 regions mean nothing with one slave behind the converter.
    assign c_awregion = 4'd0;
    assign c_arregion = 4'd0;

    // ---------------------------------------------------------------------
    // HDMI output. Its pixel clock comes from an MMCM on the 200 MHz
    // oscillator (see hdmi_out.v).
    // ---------------------------------------------------------------------
    hdmi_out #(.MODE(0)) hdmi (
        .clk_200    (sys_clk_g),
        .rstn       (rstn),
        .locked     (hdmi_locked),
        .hdmi_clk   (hdmi_tx_clk),
        .hdmi_de    (hdmi_tx_de),
        .hdmi_hsync (hdmi_tx_hsync),
        .hdmi_vsync (hdmi_tx_vsync),
        .hdmi_d     (hdmi_tx_d)
    );

    // ---------------------------------------------------------------------
    // Frequency counters: one gate, published on fclk_clk0. Four channels
    // here for the oscillators; the camera byte clock (fc_cam) is the fifth.
    // ---------------------------------------------------------------------
    freq_gate #(.REF_HZ(100_000_000)) fgate (
        .ref_clk(clk), .ref_rstn(rstn), .gate(freq_gate_w));

    freq_ctr fc_plclk (.ref_clk(clk), .ref_rstn(rstn), .gate(freq_gate_w),
                       .meas_clk(pl_clk_g),  .hz(freq0), .updates(up0));
    freq_ctr fc_156   (.ref_clk(clk), .ref_rstn(rstn), .gate(freq_gate_w),
                       .meas_clk(sfp1_usrclk), .hz(freq1), .updates(up1));
    freq_ctr fc_sata  (.ref_clk(clk), .ref_rstn(rstn), .gate(freq_gate_w),
                       .meas_clk(sataclk_g), .hz(freq2), .updates(up2));
    freq_ctr fc_sys   (.ref_clk(clk), .ref_rstn(rstn), .gate(freq_gate_w),
                       .meas_clk(sys_clk_g), .hz(freq3), .updates(up3));

    // ---------------------------------------------------------------------
    // Two BIST engines on the PS's high-performance ports HP1 and HP2, each
    // with its own interrupt (IRQ_F2P[1:0]).
    //
    // ⚠ They write wherever ADDR points, with NO bounds check of any kind. A
    // run aimed at an address Linux is using will corrupt it, silently and
    // at 64 bits a clock. The device tree reserves a region to aim them at;
    // see "The BIST engines" in linux/README.md.
    // ---------------------------------------------------------------------
    axi_bist #(.DW(64), .IDW(6), .LENW(4), .BEATS(16),
               .MAXOUT(4)) bist_hp1 (
        .clk(clk), .rstn(rstn),
        .reg_waddr(blk_waddr), .reg_we(blk_we[0]),
        .reg_wdata(blk_wdata), .reg_raddr(blk_raddr),
        .reg_rdata(blk_rdata0), .irq(bist_irq[0]),
        .m_awid(hp1_awid),
        .m_awaddr(hp1_awaddr),
        .m_awlen(hp1_awlen),
        .m_awsize(hp1_awsize),
        .m_awburst(hp1_awburst),
        .m_awlock(hp1_awlock),
        .m_awcache(hp1_awcache),
        .m_awprot(hp1_awprot),
        .m_awqos(hp1_awqos),
        .m_awvalid(hp1_awvalid),
        .m_awready(hp1_awready),
        .m_wid(hp1_wid),
        .m_wdata(hp1_wdata),
        .m_wstrb(hp1_wstrb),
        .m_wlast(hp1_wlast),
        .m_wvalid(hp1_wvalid),
        .m_wready(hp1_wready),
        .m_bid(hp1_bid),
        .m_bresp(hp1_bresp),
        .m_bvalid(hp1_bvalid),
        .m_bready(hp1_bready),
        .m_arid(hp1_arid),
        .m_araddr(hp1_araddr),
        .m_arlen(hp1_arlen),
        .m_arsize(hp1_arsize),
        .m_arburst(hp1_arburst),
        .m_arlock(hp1_arlock),
        .m_arcache(hp1_arcache),
        .m_arprot(hp1_arprot),
        .m_arqos(hp1_arqos),
        .m_arvalid(hp1_arvalid),
        .m_arready(hp1_arready),
        .m_rid(hp1_rid),
        .m_rdata(hp1_rdata),
        .m_rresp(hp1_rresp),
        .m_rlast(hp1_rlast),
        .m_rvalid(hp1_rvalid),
        .m_rready(hp1_rready)
    );

    axi_bist #(.DW(64), .IDW(6), .LENW(4), .BEATS(16),
               .MAXOUT(4)) bist_hp2 (
        .clk(clk), .rstn(rstn),
        .reg_waddr(blk_waddr), .reg_we(blk_we[1]),
        .reg_wdata(blk_wdata), .reg_raddr(blk_raddr),
        .reg_rdata(blk_rdata1), .irq(bist_irq[1]),
        .m_awid(hp2_awid),
        .m_awaddr(hp2_awaddr),
        .m_awlen(hp2_awlen),
        .m_awsize(hp2_awsize),
        .m_awburst(hp2_awburst),
        .m_awlock(hp2_awlock),
        .m_awcache(hp2_awcache),
        .m_awprot(hp2_awprot),
        .m_awqos(hp2_awqos),
        .m_awvalid(hp2_awvalid),
        .m_awready(hp2_awready),
        .m_wid(hp2_wid),
        .m_wdata(hp2_wdata),
        .m_wstrb(hp2_wstrb),
        .m_wlast(hp2_wlast),
        .m_wvalid(hp2_wvalid),
        .m_wready(hp2_wready),
        .m_bid(hp2_bid),
        .m_bresp(hp2_bresp),
        .m_bvalid(hp2_bvalid),
        .m_bready(hp2_bready),
        .m_arid(hp2_arid),
        .m_araddr(hp2_araddr),
        .m_arlen(hp2_arlen),
        .m_arsize(hp2_arsize),
        .m_arburst(hp2_arburst),
        .m_arlock(hp2_arlock),
        .m_arcache(hp2_arcache),
        .m_arprot(hp2_arprot),
        .m_arqos(hp2_arqos),
        .m_arvalid(hp2_arvalid),
        .m_arready(hp2_arready),
        .m_rid(hp2_rid),
        .m_rdata(hp2_rdata),
        .m_rresp(hp2_rresp),
        .m_rlast(hp2_rlast),
        .m_rvalid(hp2_rvalid),
        .m_rready(hp2_rready)
    );

    // =====================================================================
    // HDMI input: ADV7611 -> AXI4-Stream -> AXI VDMA -> S_AXI_HP0 -> PS DRAM
    //
    // Linux sees an ordinary V4L2 capture device. xilinx-vipp binds the
    // ADV7611 -- which the adv7604 driver reaches over the bit-banged I2C
    // bus this design already provides -- to this VDMA and creates
    // /dev/video0. Nothing in that path needs a driver written.
    // =====================================================================
    wire hdmi_rx_pclk_i, rx_pclk;
    IBUF hdmi_rx_pclk_ibuf (.I(hdmi_rx_pclk), .O(hdmi_rx_pclk_i));
    BUFG hdmi_rx_pclk_bufg (.I(hdmi_rx_pclk_i), .O(rx_pclk));

    wire [23:0] cap_tdata;
    wire        cap_tvalid, cap_tready, cap_tuser, cap_tlast;
    wire [23:0] vid_tdata;
    wire        vid_tvalid, vid_tready, vid_tuser, vid_tlast;
    wire [31:0] rxs0, rxs1, rxs2, rxs3;
    reg         awlen_overflow = 1'b0;
    reg         cam_awlen_overflow = 1'b0;
    // The camera receiver's reset synchronizer and byte-clock count, read
    // here and driven in the camera block below.
    reg  [1:0]  csi_vrst_meta = 2'b00;
    wire [31:0] cam_byteclk_hz;
    wire [7:0]  cam_byteclk_up;
    // cam_guard's counters: frame starts in and out, beats dropped, cycles
    // the receiver was held off, beats the VDMA took.
    wire [31:0] cg_sof_in, cg_sof_out, cg_drop, cg_stall, cg_beats;

    hdmi_rx_capture hdmi_rx (
        .pclk     (rx_pclk),
        .de       (hdmi_rx_de),
        .hs       (hdmi_rx_hs),
        .vs       (hdmi_rx_vs),
        .d        (hdmi_rx_d),
        .m_tdata  (cap_tdata),
        .m_tvalid (cap_tvalid),
        .m_tready (cap_tready),
        .m_tuser  (cap_tuser),
        .m_tlast  (cap_tlast),
        .ref_clk  (clk),
        .ref_rstn (rstn),
        // Always streaming. The VDMA decides whether anything reaches
        // memory; with it stopped the block simply finds no taker and
        // abandons each frame, which costs nothing and keeps the status
        // registers live so "no signal" can be told from "not started".
        .enable   (1'b1),
        .stat0    (rxs0),
        .stat1    (rxs1),
        .stat2    (rxs2),
        .stat3    (rxs3)
    );

    // Sub-block 2's words 0..3 report what the capture block sees, which is
    // independent of anything the VDMA or the V4L2 driver believes. With no
    // signal on the connector those four read 0 AND rxs3's update counter
    // stays at 0, which is what separates a dead pixel clock from a black
    // picture. Words 4..11 are the camera path's: the two sticky burst-length
    // overflow bits, the byte-clock count, and cam_guard's counters.
    //
    // An always @(*) block, not a function in a continuous assign: see
    // axi4_regs.v for why.
    always @(*) begin
        case (blk_raddr)
            4'd0:    blk_rdata2_r = rxs0;   // {h_total, h_active}
            4'd1:    blk_rdata2_r = rxs1;   // {v_total, v_active}
            4'd2:    blk_rdata2_r = rxs2;   // {stalls,  frames}
            4'd3:    blk_rdata2_r = rxs3;   // {updates, flags}
            4'd4:    blk_rdata2_r = {30'd0, cam_awlen_overflow, awlen_overflow};
            4'd5:    blk_rdata2_r = cam_byteclk_hz;
            4'd6:    blk_rdata2_r = {22'd0, cam_dlyctrl_rdy, csi_vrst_meta[1], cam_byteclk_up};
            4'd7:    blk_rdata2_r = cg_sof_in;
            4'd8:    blk_rdata2_r = cg_sof_out;
            4'd9:    blk_rdata2_r = cg_drop;
            4'd10:   blk_rdata2_r = cg_stall;
            4'd11:   blk_rdata2_r = cg_beats;
            4'd13:   blk_rdata2_r = {25'd0, eth_st_s1};   // the PL Ethernet core
            default: blk_rdata2_r = 32'd0;
        endcase
    end

    // ---- the pixel clock stops here
    //
    // ⚠ EVERYTHING DOWNSTREAM RUNS ON FCLK_CLK0, INCLUDING THE VDMA'S STREAM
    // SIDE, even though the VDMA is perfectly able to cross clocks itself.
    //
    // A VDMA whose stream clock is not running does not answer its AXI-Lite
    // CONTROL port either. Handing it the ADV7611's LLC directly means that
    // with no HDMI source there is no LLC, and the DMA driver's first
    // register read during probe is a bus access nothing completes: the
    // kernel hangs mid-boot, with no console past the PL330 driver and no way
    // back but a JTAG reset. With the receiver locked and LLC running, the
    // same register answers immediately.
    //
    // The control plane of a capture device cannot depend on a clock that
    // arrives over a cable. So the crossing happens here, in the one place
    // that is allowed to stop when the cable is unplugged.
    wire [25:0] fifo_rdata;
    axis_cdc_fifo #(.DW(26), .AW(10)) hdmi_rx_cdc (
        .wclk   (rx_pclk),
        .wdata  ({cap_tuser, cap_tlast, cap_tdata}),
        .wvalid (cap_tvalid),
        .wready (cap_tready),
        .rclk   (clk),
        .rrstn  (rstn),
        .rdata  (fifo_rdata),
        .rvalid (vid_tvalid),
        .rready (vid_tready)
    );
    assign vid_tuser = fifo_rdata[25];
    assign vid_tlast = fifo_rdata[24];
    assign vid_tdata = fifo_rdata[23:0];

    // ---- M_AXI_GP1, through a protocol converter
    // GP1 is AXI3 with 12-bit IDs; the slaves behind it are AXI4-Lite,
    // which has no IDs and no bursts at all. The converter is here for the
    // ID reflection: AXI3 requires every BID and RID to match the AWID or
    // ARID that asked, and an AXI4-Lite slave cannot supply one, so
    // something has to remember them. Splitting a burst is the easy half.
    wire [31:0] vlite_awaddr, vlite_araddr, vlite_wdata, vlite_rdata;
    wire [3:0]  vlite_wstrb;
    wire [1:0]  vlite_bresp, vlite_rresp;
    wire        vlite_awvalid, vlite_awready, vlite_wvalid, vlite_wready;
    wire        vlite_bvalid, vlite_bready;
    wire        vlite_arvalid, vlite_arready, vlite_rvalid, vlite_rready;

    // The converter's AXI-Lite side, into the crossbar below.
    wire [31:0] glite_awaddr, glite_araddr, glite_wdata, glite_rdata;
    wire [3:0]  glite_wstrb;
    wire [1:0]  glite_bresp, glite_rresp;
    wire        glite_awvalid, glite_awready, glite_wvalid, glite_wready;
    wire        glite_bvalid, glite_bready;
    wire        glite_arvalid, glite_arready, glite_rvalid, glite_rready;
    wire [2:0]  glite_awprot, glite_arprot;

    apc_vdma_lite vdma_lite_conv (
        .aclk          (clk),
        .aresetn       (rstn),
        .s_axi_awid    (gp1_awid),
        .s_axi_awaddr  (gp1_awaddr),
        .s_axi_awlen   (gp1_awlen),
        .s_axi_awsize  (gp1_awsize),
        .s_axi_awburst (gp1_awburst),
        .s_axi_awlock  (gp1_awlock),
        .s_axi_awcache (gp1_awcache),
        .s_axi_awprot  (gp1_awprot),
        .s_axi_awqos   (gp1_awqos),
        .s_axi_awvalid (gp1_awvalid),
        .s_axi_awready (gp1_awready),
        .s_axi_wid     (gp1_wid),
        .s_axi_wdata   (gp1_wdata),
        .s_axi_wstrb   (gp1_wstrb),
        .s_axi_wlast   (gp1_wlast),
        .s_axi_wvalid  (gp1_wvalid),
        .s_axi_wready  (gp1_wready),
        .s_axi_bid     (gp1_bid),
        .s_axi_bresp   (gp1_bresp),
        .s_axi_bvalid  (gp1_bvalid),
        .s_axi_bready  (gp1_bready),
        .s_axi_arid    (gp1_arid),
        .s_axi_araddr  (gp1_araddr),
        .s_axi_arlen   (gp1_arlen),
        .s_axi_arsize  (gp1_arsize),
        .s_axi_arburst (gp1_arburst),
        .s_axi_arlock  (gp1_arlock),
        .s_axi_arcache (gp1_arcache),
        .s_axi_arprot  (gp1_arprot),
        .s_axi_arqos   (gp1_arqos),
        .s_axi_arvalid (gp1_arvalid),
        .s_axi_arready (gp1_arready),
        .s_axi_rid     (gp1_rid),
        .s_axi_rdata   (gp1_rdata),
        .s_axi_rresp   (gp1_rresp),
        .s_axi_rlast   (gp1_rlast),
        .s_axi_rvalid  (gp1_rvalid),
        .s_axi_rready  (gp1_rready),
        .m_axi_awaddr  (glite_awaddr),
        .m_axi_awprot  (glite_awprot),
        .m_axi_awvalid (glite_awvalid),
        .m_axi_awready (glite_awready),
        .m_axi_wdata   (glite_wdata),
        .m_axi_wstrb   (glite_wstrb),
        .m_axi_wvalid  (glite_wvalid),
        .m_axi_wready  (glite_wready),
        .m_axi_bresp   (glite_bresp),
        .m_axi_bvalid  (glite_bvalid),
        .m_axi_bready  (glite_bready),
        .m_axi_araddr  (glite_araddr),
        .m_axi_arprot  (glite_arprot),
        .m_axi_arvalid (glite_arvalid),
        .m_axi_arready (glite_arready),
        .m_axi_rdata   (glite_rdata),
        .m_axi_rresp   (glite_rresp),
        .m_axi_rvalid  (glite_rvalid),
        .m_axi_rready  (glite_rready)
    );

    // ---- and from there to four AXI-Lite slaves, by address
    //   0x8000_0000  the HDMI capture VDMA
    //   0x8001_0000  the camera VDMA
    //   0x8002_0000  the CSI-2 receiver: the controller, and its D-PHY's
    //                registers at +0x1000
    //   0x8010_0000  the register file (axi4_regs)
    // An address in the GP1 window outside those gets DECERR from the
    // crossbar -- a bus error in the kernel, not a hung CPU.
    wire [31:0] clite_awaddr, clite_araddr, clite_wdata, clite_rdata;
    wire [3:0]  clite_wstrb;
    wire [1:0]  clite_bresp, clite_rresp;
    wire        clite_awvalid, clite_awready, clite_wvalid, clite_wready;
    wire        clite_bvalid, clite_bready;
    wire        clite_arvalid, clite_arready, clite_rvalid, clite_rready;

    wire [31:0] slite_awaddr, slite_araddr, slite_wdata, slite_rdata;
    wire [3:0]  slite_wstrb;
    wire [1:0]  slite_bresp, slite_rresp;
    wire        slite_awvalid, slite_awready, slite_wvalid, slite_wready;
    wire        slite_bvalid, slite_bready;
    wire        slite_arvalid, slite_arready, slite_rvalid, slite_rready;

    xbar_gp1 gp1_xbar (
        .aclk          (clk),
        .aresetn       (rstn),
        .s_axi_awaddr  (glite_awaddr),
        .s_axi_awprot  (glite_awprot),
        .s_axi_awvalid (glite_awvalid),
        .s_axi_awready (glite_awready),
        .s_axi_wdata   (glite_wdata),
        .s_axi_wstrb   (glite_wstrb),
        .s_axi_wvalid  (glite_wvalid),
        .s_axi_wready  (glite_wready),
        .s_axi_bresp   (glite_bresp),
        .s_axi_bvalid  (glite_bvalid),
        .s_axi_bready  (glite_bready),
        .s_axi_araddr  (glite_araddr),
        .s_axi_arprot  (glite_arprot),
        .s_axi_arvalid (glite_arvalid),
        .s_axi_arready (glite_arready),
        .s_axi_rdata   (glite_rdata),
        .s_axi_rresp   (glite_rresp),
        .s_axi_rvalid  (glite_rvalid),
        .s_axi_rready  (glite_rready),
        .m_axi_awaddr  ({rlite_awaddr, slite_awaddr, clite_awaddr, vlite_awaddr}),
        .m_axi_awprot  (),
        .m_axi_awvalid ({rlite_awvalid, slite_awvalid, clite_awvalid, vlite_awvalid}),
        .m_axi_awready ({rlite_awready, slite_awready, clite_awready, vlite_awready}),
        .m_axi_wdata   ({rlite_wdata, slite_wdata, clite_wdata, vlite_wdata}),
        .m_axi_wstrb   ({rlite_wstrb, slite_wstrb, clite_wstrb, vlite_wstrb}),
        .m_axi_wvalid  ({rlite_wvalid, slite_wvalid, clite_wvalid, vlite_wvalid}),
        .m_axi_wready  ({rlite_wready, slite_wready, clite_wready, vlite_wready}),
        .m_axi_bresp   ({rlite_bresp, slite_bresp, clite_bresp, vlite_bresp}),
        .m_axi_bvalid  ({rlite_bvalid, slite_bvalid, clite_bvalid, vlite_bvalid}),
        .m_axi_bready  ({rlite_bready, slite_bready, clite_bready, vlite_bready}),
        .m_axi_araddr  ({rlite_araddr, slite_araddr, clite_araddr, vlite_araddr}),
        .m_axi_arprot  (),
        .m_axi_arvalid ({rlite_arvalid, slite_arvalid, clite_arvalid, vlite_arvalid}),
        .m_axi_arready ({rlite_arready, slite_arready, clite_arready, vlite_arready}),
        .m_axi_rdata   ({rlite_rdata, slite_rdata, clite_rdata, vlite_rdata}),
        .m_axi_rresp   ({rlite_rresp, slite_rresp, clite_rresp, vlite_rresp}),
        .m_axi_rvalid  ({rlite_rvalid, slite_rvalid, clite_rvalid, vlite_rvalid}),
        .m_axi_rready  ({rlite_rready, slite_rready, clite_rready, vlite_rready})
    );

    // ---- the VDMA itself
    wire [31:0] s2mm_awaddr;
    wire [7:0]  s2mm_awlen;
    wire [2:0]  s2mm_awsize;
    wire [1:0]  s2mm_awburst;
    wire [2:0]  s2mm_awprot;
    wire [3:0]  s2mm_awcache;
    wire        s2mm_awvalid, s2mm_awready;
    wire [63:0] s2mm_wdata;
    wire [7:0]  s2mm_wstrb;
    wire        s2mm_wlast, s2mm_wvalid, s2mm_wready;
    wire        s2mm_bvalid, s2mm_bready;
    wire        s2mm_introut;

    vdma_hdmirx vdma (
        .s_axi_lite_aclk    (clk),
        .m_axi_s2mm_aclk    (clk),
        .s_axis_s2mm_aclk   (clk),
        .axi_resetn         (rstn),

        .s_axi_lite_awvalid (vlite_awvalid),
        .s_axi_lite_awready (vlite_awready),
        .s_axi_lite_awaddr  (vlite_awaddr[8:0]),
        .s_axi_lite_wvalid  (vlite_wvalid),
        .s_axi_lite_wready  (vlite_wready),
        .s_axi_lite_wdata   (vlite_wdata),
        .s_axi_lite_bresp   (vlite_bresp),
        .s_axi_lite_bvalid  (vlite_bvalid),
        .s_axi_lite_bready  (vlite_bready),
        .s_axi_lite_arvalid (vlite_arvalid),
        .s_axi_lite_arready (vlite_arready),
        .s_axi_lite_araddr  (vlite_araddr[8:0]),
        .s_axi_lite_rvalid  (vlite_rvalid),
        .s_axi_lite_rready  (vlite_rready),
        .s_axi_lite_rdata   (vlite_rdata),
        .s_axi_lite_rresp   (vlite_rresp),

        .s2mm_frame_ptr_in  (6'd0),
        .s2mm_frame_ptr_out (),

        .m_axi_s2mm_awaddr  (s2mm_awaddr),
        .m_axi_s2mm_awlen   (s2mm_awlen),
        .m_axi_s2mm_awsize  (s2mm_awsize),
        .m_axi_s2mm_awburst (s2mm_awburst),
        .m_axi_s2mm_awprot  (s2mm_awprot),
        .m_axi_s2mm_awcache (s2mm_awcache),
        .m_axi_s2mm_awvalid (s2mm_awvalid),
        .m_axi_s2mm_awready (s2mm_awready),
        .m_axi_s2mm_wdata   (s2mm_wdata),
        .m_axi_s2mm_wstrb   (s2mm_wstrb),
        .m_axi_s2mm_wlast   (s2mm_wlast),
        .m_axi_s2mm_wvalid  (s2mm_wvalid),
        .m_axi_s2mm_wready  (s2mm_wready),
        .m_axi_s2mm_bresp   (hp0_bresp),
        .m_axi_s2mm_bvalid  (s2mm_bvalid),
        .m_axi_s2mm_bready  (s2mm_bready),

        .s_axis_s2mm_tdata  (vid_tdata),
        .s_axis_s2mm_tkeep  (3'b111),
        .s_axis_s2mm_tuser  (vid_tuser),
        .s_axis_s2mm_tvalid (vid_tvalid),
        .s_axis_s2mm_tready (vid_tready),
        .s_axis_s2mm_tlast  (vid_tlast),

        .s2mm_introut       (s2mm_introut)
    );

    assign bist_irq[2] = s2mm_introut;

    // ---- the VDMA's data master onto S_AXI_HP0
    //
    // This is AXI4 driving an AXI3 slave, wired directly rather than through
    // a converter. The VDMA's master has NO ID at all, so there is nothing to
    // reflect -- the whole reason the control path needs a converter does not
    // apply here. What remains is the burst length field: AXI4 carries eight
    // bits and AXI3 four.
    //
    // ⚠ That is safe only because the IP is generated with a maximum burst of
    // 8 beats, and a parameter is not a guarantee. awlen_overflow below is
    // sticky and readable, so if a rebuild ever raises that maximum the
    // truncation announces itself instead of silently writing the wrong
    // length and corrupting memory past the end of a buffer.
    assign hp0_awid    = 6'd0;
    assign hp0_awaddr  = s2mm_awaddr;
    assign hp0_awlen   = s2mm_awlen[3:0];
    assign hp0_awsize  = s2mm_awsize;
    assign hp0_awburst = s2mm_awburst;
    assign hp0_awlock  = 2'b00;
    assign hp0_awcache = s2mm_awcache;
    assign hp0_awprot  = s2mm_awprot;
    assign hp0_awqos   = 4'd0;
    assign hp0_awvalid = s2mm_awvalid;
    assign s2mm_awready = hp0_awready;

    assign hp0_wid     = 6'd0;
    assign hp0_wdata   = s2mm_wdata;
    assign hp0_wstrb   = s2mm_wstrb;
    assign hp0_wlast   = s2mm_wlast;
    assign hp0_wvalid  = s2mm_wvalid;
    assign s2mm_wready = hp0_wready;

    assign s2mm_bvalid = hp0_bvalid;
    assign hp0_bready  = s2mm_bready;

    // The VDMA is write-only here; the read channel is tied off.
    assign hp0_arid    = 6'd0;
    assign hp0_araddr  = 32'd0;
    assign hp0_arlen   = 4'd0;
    assign hp0_arsize  = 3'd0;
    assign hp0_arburst = 2'b01;
    assign hp0_arlock  = 2'b00;
    assign hp0_arcache = 4'd0;
    assign hp0_arprot  = 3'd0;
    assign hp0_arqos   = 4'd0;
    assign hp0_arvalid = 1'b0;
    assign hp0_rready  = 1'b1;

    always @(posedge clk) begin
        if (!rstn) awlen_overflow <= 1'b0;
        else if (s2mm_awvalid && s2mm_awready && |s2mm_awlen[7:4])
            awlen_overflow <= 1'b1;
    end

    // =====================================================================
    // Camera: OV5647 -> MIPI CSI-2 RX -> AXI VDMA -> S_AXI_HP3 -> PS DRAM
    //
    // Two lanes, RAW10 Bayer, one pixel per beat in the low ten bits of a
    // 16-bit stream. Linux reaches the sensor through ov5647 on the camera
    // I2C bus, the receiver through xilinx-csi2rxss, and the frames through
    // xilinx-vipp on this VDMA.
    //
    // ⚠ The video side runs on FCLK_CLK0, like the HDMI path, and for the
    // same reason: the control plane may not depend on a clock that arrives
    // over a cable. The receiver's byte clock comes from the sensor's clock
    // lane and stops with it; the subsystem crosses from it into video_aclk
    // itself. 100 MHz covers the sensor's fastest mode, 87.5 Mpixel/s.
    // =====================================================================
    wire        csi_tvalid, csi_tready, csi_tlast;
    wire [15:0] csi_tdata;
    wire [0:0]  csi_tuser;
    wire        cam_tvalid, cam_tready, cam_tlast, cam_tuser;
    wire [15:0] cam_tdata;
    wire        csi_irq;
    wire        csi_byteclk;

    // The receiver's video reset, EMIO gpio 110: xilinx-csi2rxss pulses its
    // video-reset-gpios at probe and after every stream stop, and that is
    // its only way to recover the core after a stream error. A clean stream
    // restarts without it as long as the sensor runs its clock lane
    // non-continuously (see the device tree). The GPIO is asynchronous to
    // FCLK_CLK0, so it is synchronized before the IP.
    always @(posedge clk) csi_vrst_meta <= {csi_vrst_meta[0], gpio_o_w[56]};
    wire csi_video_rstn = rstn & ~csi_vrst_meta[1];

    // The D-PHY's IDELAY taps are its own register, +0x04 from the receiver's
    // base, a byte per data lane, 78 ps a tap; it resets to 10, and
    // pl/tools/camsetup.sh sets 31 for 2592x1944 (see build.tcl for the
    // measurement). With external taps the IDELAYCTRL is ours, and it must
    // share the D-PHY's IODELAY_GROUP, or the placer has no rule tying it to
    // those IDELAYs.
    (* IODELAY_GROUP = "mipi_csi2rx_idly_group" *)
    IDELAYCTRL cam_idelayctrl (
        .REFCLK (sys_clk_g),
        .RST    (~rstn),
        .RDY    (cam_dlyctrl_rdy)
    );

    // The byte clock, counted. The counter only completes a measurement
    // while its clock runs, so an update count that stops moving means the
    // sensor's clock lane is stopped and the Hz value is the last one seen.
    // With a non-continuous clock lane it reads low while streaming: the
    // lane idles between lines.
    freq_ctr fc_cam (.ref_clk(clk), .ref_rstn(rstn), .gate(freq_gate_w),
                     .meas_clk(csi_byteclk), .hz(cam_byteclk_hz),
                     .updates(cam_byteclk_up));

    csi_cam csi (
        .lite_aclk             (clk),
        .lite_aresetn          (rstn),
        .dphy_clk_200M         (sys_clk_g),
        .dlyctrl_rdy_in        (cam_dlyctrl_rdy),
        // Not what sets the taps: with the D-PHY's register interface on,
        // its register drives the IDELAYs and these are unused.
        .lane0_tap             (5'd0),
        .lane1_tap             (5'd0),
        .rxbyteclkhs           (csi_byteclk),
        .system_rst_out        (),
        .csirxss_csi_irq       (csi_irq),
        .video_aclk            (clk),
        .video_aresetn         (csi_video_rstn),
        .csirxss_s_axi_araddr  (slite_araddr[16:0]),
        .csirxss_s_axi_arprot  (3'b000),
        .csirxss_s_axi_arready (slite_arready),
        .csirxss_s_axi_arvalid (slite_arvalid),
        .csirxss_s_axi_awaddr  (slite_awaddr[16:0]),
        .csirxss_s_axi_awprot  (3'b000),
        .csirxss_s_axi_awready (slite_awready),
        .csirxss_s_axi_awvalid (slite_awvalid),
        .csirxss_s_axi_bready  (slite_bready),
        .csirxss_s_axi_bresp   (slite_bresp),
        .csirxss_s_axi_bvalid  (slite_bvalid),
        .csirxss_s_axi_rdata   (slite_rdata),
        .csirxss_s_axi_rready  (slite_rready),
        .csirxss_s_axi_rresp   (slite_rresp),
        .csirxss_s_axi_rvalid  (slite_rvalid),
        .csirxss_s_axi_wdata   (slite_wdata),
        .csirxss_s_axi_wready  (slite_wready),
        .csirxss_s_axi_wstrb   (slite_wstrb),
        .csirxss_s_axi_wvalid  (slite_wvalid),
        .video_out_tdata       (csi_tdata),
        .video_out_tdest       (),
        .video_out_tlast       (csi_tlast),
        .video_out_tready      (csi_tready),
        .video_out_tuser       (csi_tuser),
        .video_out_tvalid      (csi_tvalid),
        .mipi_phy_if_clk_hs_n  (mipi_clk_hs_n),
        .mipi_phy_if_clk_hs_p  (mipi_clk_hs_p),
        .mipi_phy_if_clk_lp_n  (mipi_clk_lp_n),
        .mipi_phy_if_clk_lp_p  (mipi_clk_lp_p),
        .mipi_phy_if_data_hs_n (mipi_d_hs_n),
        .mipi_phy_if_data_hs_p (mipi_d_hs_p),
        .mipi_phy_if_data_lp_n (mipi_d_lp_n),
        .mipi_phy_if_data_lp_p (mipi_d_lp_p)
    );

    // The receiver cannot be stalled; see cam_guard.v. AUX[15] = 1 turns the
    // guard into plain back-pressure, to compare the two.
    cam_guard cam_guard_i (
        .clk        (clk),
        .rstn       (rstn),
        .guard_off  (aux_ctrl[15]),
        .s_tdata    (csi_tdata),
        .s_tuser    (csi_tuser[0]),
        .s_tlast    (csi_tlast),
        .s_tvalid   (csi_tvalid),
        .s_tready   (csi_tready),
        .m_tdata    (cam_tdata),
        .m_tuser    (cam_tuser),
        .m_tlast    (cam_tlast),
        .m_tvalid   (cam_tvalid),
        .m_tready   (cam_tready),
        .sof_in     (cg_sof_in),
        .sof_out    (cg_sof_out),
        .drop_beats (cg_drop),
        .stall      (cg_stall),
        .beats_out  (cg_beats)
    );

    wire [31:0] cs2mm_awaddr;
    wire [7:0]  cs2mm_awlen;
    wire [2:0]  cs2mm_awsize, cs2mm_awprot;
    wire [1:0]  cs2mm_awburst;
    wire [3:0]  cs2mm_awcache;
    wire        cs2mm_awvalid, cs2mm_awready;
    wire [63:0] cs2mm_wdata;
    wire [7:0]  cs2mm_wstrb;
    wire        cs2mm_wlast, cs2mm_wvalid, cs2mm_wready;
    wire        cs2mm_bvalid, cs2mm_bready;
    wire        cam_introut;

    vdma_cam cam_vdma (
        .s_axi_lite_aclk    (clk),
        .m_axi_s2mm_aclk    (clk),
        .s_axis_s2mm_aclk   (clk),
        .axi_resetn         (rstn),

        .s_axi_lite_awvalid (clite_awvalid),
        .s_axi_lite_awready (clite_awready),
        .s_axi_lite_awaddr  (clite_awaddr[8:0]),
        .s_axi_lite_wvalid  (clite_wvalid),
        .s_axi_lite_wready  (clite_wready),
        .s_axi_lite_wdata   (clite_wdata),
        .s_axi_lite_bresp   (clite_bresp),
        .s_axi_lite_bvalid  (clite_bvalid),
        .s_axi_lite_bready  (clite_bready),
        .s_axi_lite_arvalid (clite_arvalid),
        .s_axi_lite_arready (clite_arready),
        .s_axi_lite_araddr  (clite_araddr[8:0]),
        .s_axi_lite_rvalid  (clite_rvalid),
        .s_axi_lite_rready  (clite_rready),
        .s_axi_lite_rdata   (clite_rdata),
        .s_axi_lite_rresp   (clite_rresp),

        .s2mm_frame_ptr_in  (6'd0),
        .s2mm_frame_ptr_out (),

        .m_axi_s2mm_awaddr  (cs2mm_awaddr),
        .m_axi_s2mm_awlen   (cs2mm_awlen),
        .m_axi_s2mm_awsize  (cs2mm_awsize),
        .m_axi_s2mm_awburst (cs2mm_awburst),
        .m_axi_s2mm_awprot  (cs2mm_awprot),
        .m_axi_s2mm_awcache (cs2mm_awcache),
        .m_axi_s2mm_awvalid (cs2mm_awvalid),
        .m_axi_s2mm_awready (cs2mm_awready),
        .m_axi_s2mm_wdata   (cs2mm_wdata),
        .m_axi_s2mm_wstrb   (cs2mm_wstrb),
        .m_axi_s2mm_wlast   (cs2mm_wlast),
        .m_axi_s2mm_wvalid  (cs2mm_wvalid),
        .m_axi_s2mm_wready  (cs2mm_wready),
        .m_axi_s2mm_bresp   (hp3_bresp),
        .m_axi_s2mm_bvalid  (cs2mm_bvalid),
        .m_axi_s2mm_bready  (cs2mm_bready),

        .s_axis_s2mm_tdata  (cam_tdata),
        .s_axis_s2mm_tkeep  (2'b11),
        .s_axis_s2mm_tuser  (cam_tuser),
        .s_axis_s2mm_tvalid (cam_tvalid),
        .s_axis_s2mm_tready (cam_tready),
        .s_axis_s2mm_tlast  (cam_tlast),

        .s2mm_introut       (cam_introut)
    );

    assign bist_irq[3] = cam_introut;
    assign bist_irq[4] = csi_irq;

    // Onto S_AXI_HP3 exactly as the HDMI VDMA goes onto HP0: no ID to
    // reflect, and a burst length that fits AXI3's four bits only because
    // the IP is generated with a maximum of 8 -- guarded the same way.
    assign hp3_awid      = 6'd0;
    assign hp3_awaddr    = cs2mm_awaddr;
    assign hp3_awlen     = cs2mm_awlen[3:0];
    assign hp3_awsize    = cs2mm_awsize;
    assign hp3_awburst   = cs2mm_awburst;
    assign hp3_awlock    = 2'b00;
    assign hp3_awcache   = cs2mm_awcache;
    assign hp3_awprot    = cs2mm_awprot;
    assign hp3_awqos     = 4'd0;
    assign hp3_awvalid   = cs2mm_awvalid;
    assign cs2mm_awready = hp3_awready;

    assign hp3_wid       = 6'd0;
    assign hp3_wdata     = cs2mm_wdata;
    assign hp3_wstrb     = cs2mm_wstrb;
    assign hp3_wlast     = cs2mm_wlast;
    assign hp3_wvalid    = cs2mm_wvalid;
    assign cs2mm_wready  = hp3_wready;

    assign cs2mm_bvalid  = hp3_bvalid;
    assign hp3_bready    = cs2mm_bready;

    assign hp3_arid      = 6'd0;
    assign hp3_araddr    = 32'd0;
    assign hp3_arlen     = 4'd0;
    assign hp3_arsize    = 3'd0;
    assign hp3_arburst   = 2'b01;
    assign hp3_arlock    = 2'b00;
    assign hp3_arcache   = 4'd0;
    assign hp3_arprot    = 3'd0;
    assign hp3_arqos     = 4'd0;
    assign hp3_arvalid   = 1'b0;
    assign hp3_rready    = 1'b1;

    always @(posedge clk) begin
        if (!rstn) cam_awlen_overflow <= 1'b0;
        else if (cs2mm_awvalid && cs2mm_awready && |cs2mm_awlen[7:4])
            cam_awlen_overflow <= 1'b1;
    end

    // ---------------------------------------------------------------------
    // The 40-pin header, EMIO bits 18..51 -> Linux gpio 72..105.
    //
    // Every pin is an IOBUF driven by the PS's GPIO_O/GPIO_T, so Linux sets
    // direction and level per pin through the ordinary gpiochip -- `gpioset`,
    // `gpioget`, or anything that takes a GPIO descriptor. Nothing in the
    // fabric interprets these pins; they are a pass-through.
    //
    //   j8[2k]   = IO(k+1)_P  = header pin 2k+4   = gpio 72 + 2k
    //   j8[2k+1] = IO(k+1)_N  = header pin 2k+3   = gpio 73 + 2k
    //
    // GPIO_T resets to 1, so every pin comes up as an INPUT when the
    // bitstream loads. That is the safe default for a header whose other end
    // is unknown: nothing here drives against an external driver until Linux
    // is told to. (Before configuration the pins are pulled HIGH, not
    // floating -- PUDC_B is strapped low on this board.)
    // ---------------------------------------------------------------------
    emio_pads #(.N(34)) j8_pads (
        .gpio_o (gpio_o_w[51:18]),
        .gpio_t (gpio_t_w[51:18]),
        .gpio_i (j8_pad_i),
        .pad    (j8)
    );

    // ---------------------------------------------------------------------
    // The SFP+ cages' low-speed pins.
    //
    // TX_DISABLE goes through emio_pads for the same reason the I2C lines do:
    // gpiolib's open-drain mode releases a line rather than driving it high,
    // and the board's 4.7K pull-up then holds the module's transmitter OFF.
    // That is the safe state, it is what the board powers up in, and it is
    // what it falls back to if software crashes.
    //
    // ⚠ LOS is an output of the module and has no relationship to any clock
    // here, so it is synchronized before the PS reads it. An unsynchronized
    // pin read through EMIO is a metastable flip-flop in the PS's GPIO
    // block, and the symptom is a status bit that occasionally disagrees
    // with itself between two reads a microsecond apart.
    // ---------------------------------------------------------------------
    emio_pads #(.N(2)) sfp_txdis_pads (
        .gpio_o (gpio_o_w[53:52]),
        .gpio_t (gpio_t_w[53:52]),
        .gpio_i (sfp_txdis_i),
        .pad    (sfp_tx_disable)
    );

    reg [1:0] sfp_los_meta;
    always @(posedge clk) begin
        sfp_los_meta <= sfp_los;
        sfp_los_sync <= sfp_los_meta;
    end

    // ---------------------------------------------------------------------
    // The SFP+ cages' transceivers: a PRBS generator and checker on each,
    // with the loopback path chosen at run time. Register block 3.
    // ---------------------------------------------------------------------
    gtx_prbs gtx (
        .clk       (clk),
        .rstn      (rstn),
        .refclk    (gtx_refclk156),
        .txp       (sfp_txp),
        .txn       (sfp_txn),
        .rxp       (sfp_rxp),
        .rxn       (sfp_rxn),
        .los       (sfp_los_sync),
        .reg_waddr (blk_waddr),
        .reg_we    (blk_we[3]),
        .reg_wdata (blk_wdata),
        .reg_raddr (blk_raddr),
        .reg_rdata (blk_rdata3),
        .usrclk_sfp1 (sfp1_usrclk)
    );

    // ---------------------------------------------------------------------
    // The PL Ethernet port: GEM1's GMII, over EMIO, to RGMII on PHY2.
    //
    // Xilinx's gmii_to_rgmii, with its shared logic in the core: it builds its
    // 125/25/2.5 MHz transmit clocks with its own MMCM from the 200 MHz
    // oscillator, and owns the IDELAYCTRL for its receive path. Its timing
    // assumes the PHY delays BOTH RGMII clocks internally (RGMII_TXC_SKEW = 0,
    // receive input delay -1.5/-2.8 ns), which is the RTL8211F's strapped
    // default -- and Linux leaves the straps alone with phy-mode "gmii".
    //
    // Its MDIO sits between GEM1 and the PHY at address 8 (PHY2 is at 1).
    // Linux's xilinx_gmii2rgmii writes the negotiated speed there after each
    // PHY status read; without that the core stays at its reset speed.
    // ---------------------------------------------------------------------
    gmii_rgmii_phy2 eth2 (
        .tx_reset          (~rstn),
        .rx_reset          (~rstn),
        .clkin             (sys_clk_g),
        .ref_clk_out       (),
        .mmcm_locked_out   (eth_mmcm_locked),
        .gmii_clk_125m_out (),
        .gmii_clk_25m_out  (),
        .gmii_clk_2_5m_out (),
        .rgmii_txd         (phy2_txd),
        .rgmii_tx_ctl      (phy2_tx_ctl),
        .rgmii_txc         (phy2_txc),
        .rgmii_rxd         (phy2_rxd),
        .rgmii_rx_ctl      (phy2_rx_ctl),
        .rgmii_rxc         (phy2_rxc),
        .link_status       (eth_link),
        .clock_speed       (eth_clock_speed),
        .duplex_status     (eth_duplex),
        .mdio_gem_mdc      (gem1_mdc),
        .mdio_gem_i        (gem1_mdio_i),
        .mdio_gem_o        (gem1_mdio_o),
        .mdio_gem_t        (gem1_mdio_t),
        .mdio_phy_mdc      (phy2_mdc),
        .mdio_phy_i        (phy2_mdio_i),
        .mdio_phy_o        (phy2_mdio_o),
        .mdio_phy_t        (phy2_mdio_t),
        .gmii_txd          (gmii_txd),
        .gmii_tx_en        (gmii_tx_en),
        .gmii_tx_er        (gmii_tx_er),
        .gmii_tx_clk       (gmii_tx_clk),
        .gmii_crs          (gmii_crs),
        .gmii_col          (gmii_col),
        .gmii_rxd          (gmii_rxd),
        .gmii_rx_dv        (gmii_rx_dv),
        .gmii_rx_er        (gmii_rx_er),
        .gmii_rx_clk       (gmii_rx_clk),
        .speed_mode        (eth_speed_mode)
    );

    IOBUF phy2_mdio_buf (.I(phy2_mdio_o), .T(phy2_mdio_t), .O(phy2_mdio_i),
                         .IO(phy2_mdio));

    // The core's status for sub-block 2, word 13 -- a debug view
    // from Linux with no driver: [0] RGMII in-band link, [2:1] in-band
    // speed, [3] in-band duplex, [4] the core's MMCM locked, [6:5] the speed
    // Linux configured through the core's MDIO register. They come from the
    // receive clock and the MMCM's domain, so two flops each.
    always @(posedge clk) begin
        eth_st_s0 <= {eth_speed_mode, eth_mmcm_locked, eth_duplex,
                      eth_clock_speed, eth_link};
        eth_st_s1 <= eth_st_s0;
    end

endmodule

`default_nettype wire
