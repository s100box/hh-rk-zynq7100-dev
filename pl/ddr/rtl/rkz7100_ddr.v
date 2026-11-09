// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// RK-ZYNQ7100: the 1 GB of PL DDR3 on banks 33/34, mapped into the PS address
// space so Linux can use it.
//
//   M_AXI_GP0  0x4000_0000 .. 0x7FFF_FFFF  ->  MIG  ->  PL DDR3   (1 GB)
//   M_AXI_GP1  0x8000_0000 .. 0xBFFF_FFFF  ->  axi4_regs          (status/LEDs)
//
// The GP0 window is exactly 1 GB, and PS DDR ends at 0x3FFF_FFFF, so the PL
// DRAM drops in at 0x4000_0000 with no address decode and no hole: GP0 has
// one slave and GP1 has the other. That is why the registers sit on GP1:
// they cannot share a window with a slave that fills it.
//
// ⚠ What this is NOT: a fast path. M_AXI_GP0 is 32 bits at 100 MHz, about
// 400 MB/s, so this maps the DRAM for correctness testing, not for bandwidth.
// The memory itself is clocked well below its rating for the same reason (see
// gen_mig_prj.py). Real bandwidth needs a PL-side master -- an AXI CDMA on
// the MIG plus S_AXI_HP back to PS DDR -- which is a different design.
//
// Clock domains:
//   fclk_clk0  100 MHz from the PS PLL. GP0, GP1 and the registers.
//   ui_clk     100 MHz from the MIG MMCM (4:1 of the 400 MHz memory clock).
//              MIG's AXI slave. Asynchronous to fclk_clk0 even though the
//              frequencies match -- different sources.
//
// The registers stay on fclk_clk0 ON PURPOSE. If the MIG's MMCM never locks,
// ui_clk does not exist and anything on it would hang the CPU forever on the
// first access; the register block still answers and reports mmcm_locked and
// init_calib_complete, which is the difference between a diagnosis and a
// power cycle.

`default_nettype none

module rkz7100_ddr (
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

    // 200 MHz differential oscillator Y7, bank 34 SRCC. AC-coupled and biased
    // to VCCO/2 on the board, so it is a DIFF_SSTL15 input.
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,

    // The other three oscillators with no other consumer. sys_clk above is the
    // fourth; its counter taps the buffered clock the MIG already runs on
    // rather than adding a second buffer to the same pins.
    input  wire        pl_clk,          // 50 MHz osc Y2, bank 9
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

    // The PL Ethernet PHY's management bus. The PHY itself is wired to the
    // PL, so this is the only way anything can reach it: an EMIO GPIO pair
    // for a bit-banging MDIO driver such as mdio-gpio. There is no MAC in
    // this design -- this is the management side only.
    inout  wire        phy2_mdc,
    inout  wire        phy2_mdio,

    // The 40-pin header J8, all 34 pins, handed to the PS as EMIO GPIOs so
    // Linux owns them: direction and value per pin through the ordinary
    // gpiochip, with no register poking and no driver to write. See the
    // mapping table at the j8_pads instance.
    inout  wire [33:0] j8
);

    // ---------------------------------------------------------------------
    // Clocks and resets
    // ---------------------------------------------------------------------
    wire fclk_clk0;
    wire fclk_reset0_n;
    wire ttc1_wave0;
    wire [31:0] fan_status;
    wire [31:0] fan_ctrl_w;
    wire        tach_sync;

    // EMIO GPIO, 64 bits wide in the PS configuration; the bit map is at the
    // PS7 instance below. In Linux these are gpio 54 + bit.
    wire [63:0] gpio_o_w, gpio_t_w;
    wire [8:0]  emio_pad_i;
    wire [33:0] j8_pad_i;

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

    // MIG is built with SystemClock = "No Buffer", so the input buffer is
    // ours. That keeps the sys_clk pins in our XDC with the rest of the pins
    // instead of inside the MIG project file.
    wire sys_clk_ibuf, sys_clk;
    IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) sys_clk_ibufds (
        .I (sys_clk_p), .IB (sys_clk_n), .O (sys_clk_ibuf)
    );
    BUFG sys_clk_bufg (.I (sys_clk_ibuf), .O (sys_clk));

    // ⚠ The GTX references cannot reach the fabric directly: an MGTREFCLK pin
    // feeds the transceiver quad. IBUFDS_GTE2's ODIV2 is the reference divided
    // by two and CAN drive a BUFG, so those two counters read HALF the
    // oscillator. See freq_ctr.v.
    wire pl_clk_i, pl_clk_g;
    IBUF pl_clk_ibuf (.I(pl_clk), .O(pl_clk_i));
    BUFG pl_clk_bufg (.I(pl_clk_i), .O(pl_clk_g));

    wire clk156_odiv2, clk156_g;
    IBUFDS_GTE2 clk156_ibuf (
        .I(gtx_clk156_p), .IB(gtx_clk156_n), .CEB(1'b0),
        .O(), .ODIV2(clk156_odiv2));
    BUFG clk156_bufg (.I(clk156_odiv2), .O(clk156_g));

    wire sataclk_odiv2, sataclk_g;
    IBUFDS_GTE2 sataclk_ibuf (
        .I(gtx_sataclk_p), .IB(gtx_sataclk_n), .CEB(1'b0),
        .O(), .ODIV2(sataclk_odiv2));
    BUFG sataclk_bufg (.I(sataclk_odiv2), .O(sataclk_g));

    // FCLK_RESET0_N is asynchronous to FCLK_CLK0: synchronize its release.
    reg [1:0] ps_rst_sync;
    always @(posedge fclk_clk0 or negedge fclk_reset0_n) begin
        if (!fclk_reset0_n) ps_rst_sync <= 2'b00;
        else                ps_rst_sync <= {ps_rst_sync[0], 1'b1};
    end
    wire ps_rstn = ps_rst_sync[1];

    wire ui_clk;
    wire ui_clk_sync_rst;         // active high, in the ui_clk domain
    wire mmcm_locked;
    wire init_calib_complete;
    wire ui_rstn = ~ui_clk_sync_rst;

    // MIG status back into the PS clock domain for the status register.
    reg [1:0] calib_sync, locked_sync;
    always @(posedge fclk_clk0) begin
        calib_sync  <= {calib_sync[0],  init_calib_complete};
        locked_sync <= {locked_sync[0], mmcm_locked};
    end
    wire [31:0] status = {30'd0, locked_sync[1], calib_sync[1]};

    // ---------------------------------------------------------------------
    // PS7 master ports
    // ---------------------------------------------------------------------
    wire [11:0] gp0_awid, gp0_arid, gp0_wid, gp0_bid, gp0_rid;
    wire [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
    wire [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb, gp0_awcache, gp0_arcache;
    wire [3:0]  gp0_awqos, gp0_arqos;
    wire [2:0]  gp0_awsize, gp0_arsize, gp0_awprot, gp0_arprot;
    wire [1:0]  gp0_awburst, gp0_arburst, gp0_awlock, gp0_arlock;
    wire [1:0]  gp0_bresp, gp0_rresp;
    wire        gp0_awvalid, gp0_awready, gp0_wvalid, gp0_wready, gp0_wlast;
    wire        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
    wire        gp0_rvalid, gp0_rready, gp0_rlast;

    wire [11:0] gp1_awid, gp1_arid, gp1_wid, gp1_bid, gp1_rid;
    wire [31:0] gp1_awaddr, gp1_araddr, gp1_wdata, gp1_rdata;
    wire [3:0]  gp1_awlen, gp1_arlen, gp1_wstrb;
    wire [1:0]  gp1_bresp, gp1_rresp;
    wire        gp1_awvalid, gp1_awready, gp1_wvalid, gp1_wready, gp1_wlast;
    wire        gp1_bvalid, gp1_bready, gp1_arvalid, gp1_arready;
    wire        gp1_rvalid, gp1_rready, gp1_rlast;

    // ---------------------------------------------------------------------
    // ⚠ Declared BEFORE the PS7 instance, not after it.
    //
    // Verilog will happily create an implicit one-bit net for an undeclared
    // identifier in a port connection. Declared after the instance that uses
    // them, these are rejected outright by a tool that resolves in order
    // while Vivado accepts them -- and a 64-bit HP data bus that quietly
    // became one bit would synthesize, build, and move no data.
    // ---------------------------------------------------------------------
    // Frequency counters, and the BIST engines' register windows.
    wire        freq_gate_w;
    wire [31:0] freq0, freq1, freq2, freq3;
    wire [7:0]  up0, up1, up2, up3;

    wire [3:0]  blk_waddr, blk_raddr;
    wire [4:0]  blk_we;      // [4:3] are the GTX exerciser and the full
                             // design's MIG engine, neither fitted here
    wire [31:0] blk_wdata, blk_rdata0, blk_rdata1, blk_rdata2;
    wire [2:0]  bist_irq;

    wire [15:0] aux_ctrl_w;
    wire        mig_owner, mig_switching;
    wire [2:0]  mig_dbg;
    wire [3:0]  mig_aw_out, mig_ar_out;

    // The two HP masters, and the PL DDR3 master.

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


    ps7_rkz7100 ps7 (
        // EMIO GPIO carries everything on PL pins that the PS needs to
        // reach: bit 0 the fan tachometer, 1..9 the I2C buses, the ADV7611
        // reset and the PL PHY's MDIO, 10..13 LED1-4 (read back from GPIO_O)
        // 14..17 the keys and 18..51 the J8 header; 52..63 read 0. EMIO SPI0
        // is enabled because the shared PS configuration has it, and nothing
        // drives it.
        .GPIO_I              ({12'd0, j8_pad_i, key_emio, gpio_o_w[13:10],
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

        .M_AXI_GP0_ACLK      (fclk_clk0),
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

        .M_AXI_GP1_ACLK      (fclk_clk0),
        .M_AXI_GP1_AWID      (gp1_awid),
        .M_AXI_GP1_AWADDR    (gp1_awaddr),
        .M_AXI_GP1_AWLEN     (gp1_awlen),
        .M_AXI_GP1_AWSIZE    (),
        .M_AXI_GP1_AWBURST   (),
        .M_AXI_GP1_AWLOCK    (),
        .M_AXI_GP1_AWCACHE   (),
        .M_AXI_GP1_AWPROT    (),
        .M_AXI_GP1_AWQOS     (),
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
        .M_AXI_GP1_ARSIZE    (),
        .M_AXI_GP1_ARBURST   (),
        .M_AXI_GP1_ARLOCK    (),
        .M_AXI_GP1_ARCACHE   (),
        .M_AXI_GP1_ARPROT    (),
        .M_AXI_GP1_ARQOS     (),
        .M_AXI_GP1_ARVALID   (gp1_arvalid),
        .M_AXI_GP1_ARREADY   (gp1_arready),
        .M_AXI_GP1_RID       (gp1_rid),
        .M_AXI_GP1_RDATA     (gp1_rdata),
        .M_AXI_GP1_RRESP     (gp1_rresp),
        .M_AXI_GP1_RLAST     (gp1_rlast),
        .M_AXI_GP1_RVALID    (gp1_rvalid),
        .M_AXI_GP1_RREADY    (gp1_rready),

        .S_AXI_HP1_ACLK(fclk_clk0),
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
        .S_AXI_HP2_ACLK(fclk_clk0),
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

        // IRQ_F2P[2:0] are GIC 61, 62 and 63 -- SPI 29, 30 and 31 in a device
        // tree. Three engines here: HP1, HP2 and the one on the MIG.
        .IRQ_F2P             (bist_irq),

        .FCLK_CLK0           (fclk_clk0),
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
        .aclk            (fclk_clk0),
        .aresetn         (ps_rstn),

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
        .s_axi_aclk      (fclk_clk0),
        .s_axi_aresetn   (ps_rstn),
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

        .sys_clk_i           (sys_clk),
        .sys_rst             (ps_rstn)     // ACTIVE LOW, per the MIG project
    );

    // LED1-4 are outputs always, so they take GPIO_O straight -- no IOBUF and
    // no tristate. EMIO bits 10..13 are Linux gpio 64..67, and the same bits
    // are fed back into GPIO_I above so a read returns what was written.
    assign led[3:0] = gpio_o_w[13:10];

    // ---------------------------------------------------------------------
    // GP1 -> status and LED registers
    // ---------------------------------------------------------------------
    axi4_regs #(.ID_W(12), .BIST_CAPS(3'b111)) regs (
        .clk       (fclk_clk0),
        .rstn      (ps_rstn),

        .s_awid    (gp1_awid),
        .s_awaddr  (gp1_awaddr),
        .s_awlen   (gp1_awlen),
        .s_awvalid (gp1_awvalid),
        .s_awready (gp1_awready),

        .s_wdata   (gp1_wdata),
        .s_wstrb   (gp1_wstrb),
        .s_wlast   (gp1_wlast),
        .s_wvalid  (gp1_wvalid),
        .s_wready  (gp1_wready),

        .s_bid     (gp1_bid),
        .s_bresp   (gp1_bresp),
        .s_bvalid  (gp1_bvalid),
        .s_bready  (gp1_bready),

        .s_arid    (gp1_arid),
        .s_araddr  (gp1_araddr),
        .s_arlen   (gp1_arlen),
        .s_arvalid (gp1_arvalid),
        .s_arready (gp1_arready),

        .s_rid     (gp1_rid),
        .s_rdata   (gp1_rdata),
        .s_rresp   (gp1_rresp),
        .s_rlast   (gp1_rlast),
        .s_rvalid  (gp1_rvalid),
        .s_rready  (gp1_rready),

        .led8      (led[5:4]),
        .key_n     (key_n),
        .status    (status),
        .fan_status (fan_status),
        .fan_ctrl   (fan_ctrl_w),

        .freq0     (freq0),
        .freq1     (freq1),
        .freq2     (freq2),
        .freq3     (freq3),
        .freq_updates ({up3, up2, up1, up0}),

        // Bit 0 asks for the MIG to be handed to BIST engine 2; bits 16/17
        // report who actually has it and whether a handover is pending.
        .aux_ctrl  (aux_ctrl_w),
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
        .blk_rdata2 (blk_rdata2),
        .blk_rdata3 (32'd0),         // no GTX exerciser in this design
        .blk_rdata4 (32'd0),
        .blk_irq   (bist_irq)
    );

    // ---------------------------------------------------------------------
    // The fan runs on the PS clock, like the registers: it must keep cooling
    // the part whether or not the MIG's ui_clk ever appears.
    // ---------------------------------------------------------------------
    fan_ctrl fan (
        .tach_sync_o (tach_sync),
        .clk      (fclk_clk0),
        .rstn     (ps_rstn),
        .pwm_in   (ttc1_wave0),
        .fan_pwm  (fan_pwm),
        .fan_tach (fan_tach),
        .ctrl     (fan_ctrl_w),
        .status   (fan_status)
    );

    // gp1_wid is AXI3's write-data ID. Nothing reads it: the register block
    // handles one transaction at a time and returns BID from AWID.
    wire _unused = &{1'b0, gp1_wid, 1'b0};

    // ---------------------------------------------------------------------
    // The PL pins the PS drives as GPIOs. Order here fixes the Linux gpio
    // numbers: the device tree's i2c-gpio nodes use 55..60 and its ADV7611
    // reset hog 61.
    //   55 hdmi_tx_scl   56 hdmi_tx_sda   57 hdmi_rx_scl   58 hdmi_rx_sda
    //   59 cam_scl       60 cam_sda       61 hdmi_rx_rst_n
    //   62 phy2_mdc      63 phy2_mdio
    // ---------------------------------------------------------------------
    emio_pads #(.N(9)) emio_bitbang (
        .gpio_o (gpio_o_w[9:1]),
        .gpio_t (gpio_t_w[9:1]),
        .gpio_i (emio_pad_i),
        .pad    ({phy2_mdio, phy2_mdc,
                  hdmi_rx_rst_n, cam_sda, cam_scl,
                  hdmi_rx_sda, hdmi_rx_scl, hdmi_tx_sda, hdmi_tx_scl})
    );

    // ---------------------------------------------------------------------
    // Frequency counters. sys_clk is the buffered 200 MHz the MIG runs on,
    // so this measures the oscillator the memory actually uses.
    // ---------------------------------------------------------------------
    freq_gate #(.REF_HZ(100_000_000)) fgate (
        .ref_clk(fclk_clk0), .ref_rstn(ps_rstn), .gate(freq_gate_w));

    freq_ctr fc_plclk (.ref_clk(fclk_clk0), .ref_rstn(ps_rstn), .gate(freq_gate_w),
                       .meas_clk(pl_clk_g),  .hz(freq0), .updates(up0));
    freq_ctr fc_156   (.ref_clk(fclk_clk0), .ref_rstn(ps_rstn), .gate(freq_gate_w),
                       .meas_clk(clk156_g),  .hz(freq1), .updates(up1));
    freq_ctr fc_sata  (.ref_clk(fclk_clk0), .ref_rstn(ps_rstn), .gate(freq_gate_w),
                       .meas_clk(sataclk_g), .hz(freq2), .updates(up2));
    freq_ctr fc_sys   (.ref_clk(fclk_clk0), .ref_rstn(ps_rstn), .gate(freq_gate_w),
                       .meas_clk(sys_clk),   .hz(freq3), .updates(up3));

    // ---------------------------------------------------------------------
    // BIST engines 0 and 1 on the PS's high-performance ports, into PS DRAM.
    // ⚠ No bounds check: they write wherever ADDR points. The device tree
    // reserves the top 16 MB for them.
    // ---------------------------------------------------------------------
    axi_bist #(.DW(64), .IDW(6), .LENW(4), .BEATS(16),
               .MAXOUT(4)) bist_hp1 (
        .clk(fclk_clk0), .rstn(ps_rstn),
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
        .clk(fclk_clk0), .rstn(ps_rstn),
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
        .clk(fclk_clk0), .rstn(ps_rstn),
        .reg_waddr(blk_waddr), .reg_we(blk_we[2]),
        .reg_wdata(blk_wdata), .reg_raddr(blk_raddr),
        .reg_rdata(blk_rdata2), .irq(bist_irq[2]),
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
        .clk(fclk_clk0), .rstn(ps_rstn),
        .sel(aux_ctrl_w[0]), .owner(mig_owner), .switching(mig_switching),
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

endmodule

`default_nettype wire
