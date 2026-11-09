// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// A small AXI3 slave holding the PL's registers.
//
// Written out rather than built from AXI GPIO + an interconnect so the whole
// register side of the design is one readable file with no IP to configure:
// if a read returns the wrong thing, the cause is in here.
//
// ⚠ This is an AXI3 slave, not AXI4-Lite. M_AXI_GP0/GP1 are full AXI3 masters
// and the CPU can and does issue bursts (a cache line fill through /dev/mem,
// a memcpy), so AWLEN/ARLEN are honored: a burst walks the register file and
// RLAST/BVALID land on the right beat. An AXI-Lite slave wired straight to a
// GP port looks fine under `devmem` and then hangs the bus on the first burst.
//
// Nothing above this decodes the low address bits, so the 512-byte file
// ALIASES through whatever window it is given: all of GP1 in the ddr
// design, a 64 KB crossbar slot at 0x8010_0000 in the board design.
//
// ----------------------------------------------------------------------
// Address map. addr[8:6] picks a block (0 = core, 1..5 = sub-blocks 0..4 on
// blk_rdata0..4, 6..7 read as zero); addr[5:2] picks a register inside it.
//
//   0x000..0x03F  core     the registers below
//   0x040..0x07F  sub 0    BIST engine 0   (S_AXI_HP1 -> PS DRAM)
//   0x080..0x0BF  sub 1    BIST engine 1   (S_AXI_HP2 -> PS DRAM)
//   0x0C0..0x0FF  sub 2    ddr: BIST engine 2 (MIG -> PL DDR3)
//                          board: HDMI-capture, camera and Ethernet status
//   0x100..0x13F  sub 3    the GTX PRBS exerciser (gtx_prbs.v)
//   0x140..0x17F  sub 4    BIST engine 2 (the MIG -> PL DDR3)
//   0x180..0x1FF           unfitted, read as zero
//
// ⚠ Both the reads AND the core writes decode through the same three-bit
// block number. Decoding the core writes from bits [7:6] alone would make
// every sub-block 3 write land in the core registers as well -- 0x11C, the
// GTX CH1_CTRL, would also be written to FAN_CTL at 0x01C.
//
// Core block:
//   0x00  ID        RO  0x5A710002, constant -- proves the PL is configured
//   0x04  SCRATCH   RW  read/write storage, proves the write path
//   0x08  LED       RW  [5:4] LED8 halves; [8] LED8 manual. [7:0] are stored
//                        and read back; only [5:4] drive anything (LED1-4 are
//                        EMIO GPIOs).
//   0x0C  KEY       RO  [3:0] KEY1-4, 1 = pressed (key_n inverted, synced)
//   0x10  COUNT     RO  free-running 100 MHz counter -- proves the PL is clocked
//   0x14  STATUS    RO  the `status` input, whatever the design wired to it
//   0x18  FAN_ST    RO  the `fan_status` input (see fan_ctrl.v)
//   0x1C  FAN_CTL   RW  drives `fan_ctrl` out to fan_ctrl.v
//   0x20  FREQ0     RO  PL_CLK,   Hz
//   0x24  FREQ1     RO  Y8 (156.25 MHz) / 2, Hz -- board: through SFP1's user
//                       clock (line rate / 40, so Y8 / 2 at the reset rate);
//                       ddr: through its reference buffer's ODIV2
//   0x28  FREQ2     RO  GTX 150 MHz reference / 2, Hz
//   0x2C  FREQ3     RO  SYS_CLK 200 MHz, Hz
//   0x30  FREQ_UPD  RO  {up3,up2,up1,up0}, 8 bits each: completed measurements
//   0x34  IRQ_ST    RO  blk_irq[2:0]: [1:0] BIST engines 0/1; [2] BIST
//                       engine 2 in either design
//   0x38  CAPS      RO  [2:0] which BIST engines this design actually fitted
//   0x3C  AUX       RW  low half is what software wrote and drives
//                       `aux_ctrl`; high half is `aux_status`, what the
//                       hardware says back. Both designs: bit 0 asks for
//                       the MIG to be handed to BIST engine 2, and the high
//                       half reports who has it and why a handover is
//                       pending (see axi_owner.v). board: [15] also
//                       bypasses cam_guard.
//
// `status[0]` means "the design is up" and turns the bicolor LED8 solid
// instead of blinking. In both designs that is PL DDR3 calibration complete,
// so the board says across the room whether the memory came up; designs with
// nothing to report tie `status` to zero and keep the blink.
// ----------------------------------------------------------------------

`default_nettype none

module axi4_regs #(
    parameter ID_W = 12,
    // Which BIST engines exist here, so software can tell a missing engine
    // from a broken one without knowing which bitstream it is talking to.
    parameter [2:0] BIST_CAPS = 3'b000
) (
    input  wire            clk,
    input  wire            rstn,

    // write address
    input  wire [ID_W-1:0] s_awid,
    input  wire [31:0]     s_awaddr,
    input  wire [3:0]      s_awlen,
    input  wire            s_awvalid,
    output wire            s_awready,

    // write data
    input  wire [31:0]     s_wdata,
    input  wire [3:0]      s_wstrb,
    input  wire            s_wlast,
    input  wire            s_wvalid,
    output wire            s_wready,

    // write response
    output wire [ID_W-1:0] s_bid,
    output wire [1:0]      s_bresp,
    output wire            s_bvalid,
    input  wire            s_bready,

    // read address
    input  wire [ID_W-1:0] s_arid,
    input  wire [31:0]     s_araddr,
    input  wire [3:0]      s_arlen,
    input  wire            s_arvalid,
    output wire            s_arready,

    // read data
    output wire [ID_W-1:0] s_rid,
    output wire [31:0]     s_rdata,
    output wire [1:0]      s_rresp,
    output wire            s_rlast,
    output wire            s_rvalid,
    input  wire            s_rready,

    // board. Only the bicolor LED8 is driven from here; LED1-4 and the keys
    // are plain EMIO GPIOs so that Linux can use gpio-leds and gpio-keys on
    // them (see the top level). The keys are still readable at 0x0C -- an
    // input costs nothing to fan out, and it keeps the register file useful
    // with no operating system at all.
    output wire [1:0]      led8,
    input  wire [3:0]      key_n,

    // design status, readable at 0x14. Bit 0 also drives LED8 (see above).
    // Anything crossing from another clock domain must be synchronized by
    // the caller -- this module just samples it.
    input  wire [31:0]     status,

    // the fan, in fan_ctrl.v: its status readable at 0x18, its control word
    // written at 0x1C. Both designs wire these through; a design with no
    // fan_ctrl ties fan_status low and leaves fan_ctrl unconnected.
    input  wire [31:0]     fan_status,
    output wire [31:0]     fan_ctrl,

    // frequency counters, already in this clock domain (see freq_ctr.v)
    input  wire [31:0]     freq0,
    input  wire [31:0]     freq1,
    input  wire [31:0]     freq2,
    input  wire [31:0]     freq3,
    input  wire [31:0]     freq_updates,

    // A general-purpose control/status pair at 0x3C whose bits each design
    // defines: both use it for the MIG ownership switch (axi_owner.v), and
    // the board design also for the cam_guard bypass (AUX[15]).
    output wire [15:0]     aux_ctrl,
    input  wire [15:0]     aux_status,

    // Sub-blocks, one register window each, so a BIST engine owns its own
    // registers instead of adding thirty ports to this module. Separate read
    // and write indexes: AW and AR are accepted independently, so a write
    // beat and a read beat can land on the same cycle, and a shared index
    // would hand the reader the writer's address.
    output wire [3:0]      blk_waddr,
    output wire [3:0]      blk_raddr,
    output wire [4:0]      blk_we,
    output wire [31:0]     blk_wdata,
    input  wire [31:0]     blk_rdata0,
    input  wire [31:0]     blk_rdata1,
    input  wire [31:0]     blk_rdata2,
    input  wire [31:0]     blk_rdata3,
    input  wire [31:0]     blk_rdata4,
    input  wire [2:0]      blk_irq
);

    localparam [31:0] ID_MAGIC = 32'h5A71_0002;

    // ---------------------------------------------------------------------
    // Board I/O
    // ---------------------------------------------------------------------
    reg [1:0] key_sync [3:0];
    wire [3:0] key_pressed;
    integer k;
    always @(posedge clk) begin
        for (k = 0; k < 4; k = k + 1)
            key_sync[k] <= {key_sync[k][0], ~key_n[k]};   // active low on the board
    end
    assign key_pressed = {key_sync[3][1], key_sync[2][1],
                          key_sync[1][1], key_sync[0][1]};

    reg [31:0] count;
    always @(posedge clk) begin
        if (!rstn) count <= 32'd0;
        else       count <= count + 32'd1;
    end

    reg [31:0] scratch;
    reg [8:0]  ledreg;
    reg [31:0] fanreg;
    reg [15:0] auxreg;

    assign fan_ctrl = fanreg;
    assign aux_ctrl = auxreg;

    // The bicolor LED8 shows, without anything running on the CPU: solid when
    // status[0] says the design is up, otherwise a ~1.5 Hz alternating
    // heartbeat meaning "configured and clocked, but not up". LED[8] takes it
    // over for software. This one stays in the fabric on purpose -- it is the
    // board's answer when there is no software to ask.
    assign led8[0] = ledreg[8] ? ledreg[4] : (status[0] ? 1'b1 :  count[25]);
    assign led8[1] = ledreg[8] ? ledreg[5] : (status[0] ? 1'b0 : ~count[25]);

    // ---------------------------------------------------------------------
    // Write channel: AW -> W (s_awlen+1 beats) -> B
    // ---------------------------------------------------------------------
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;

    reg [1:0]      wstate;
    reg [ID_W-1:0] awid_q;
    reg [31:0]     waddr_q;

    assign s_awready = (wstate == W_IDLE);
    assign s_wready  = (wstate == W_DATA);
    assign s_bvalid  = (wstate == W_RESP);
    assign s_bid     = awid_q;
    assign s_bresp   = 2'b00;   // OKAY: every address in the window responds

    wire [2:0] wblk = waddr_q[8:6];
    wire       wfire = (wstate == W_DATA) && s_wvalid;

    assign blk_waddr = waddr_q[5:2];
    assign blk_wdata = s_wdata;
    assign blk_we[0] = wfire && (wblk == 3'd1);
    assign blk_we[1] = wfire && (wblk == 3'd2);
    assign blk_we[2] = wfire && (wblk == 3'd3);
    assign blk_we[3] = wfire && (wblk == 3'd4);
    assign blk_we[4] = wfire && (wblk == 3'd5);

    always @(posedge clk) begin
        if (!rstn) begin
            wstate  <= W_IDLE;
            awid_q  <= {ID_W{1'b0}};
            waddr_q <= 32'd0;
            scratch <= 32'd0;
            ledreg  <= 9'd0;
            fanreg  <= 32'd0;
            auxreg  <= 16'd0;
        end else begin
            case (wstate)
                W_IDLE: if (s_awvalid) begin
                    awid_q  <= s_awid;
                    waddr_q <= s_awaddr;
                    wstate  <= W_DATA;
                end
                W_DATA: if (s_wvalid) begin
                    // wblk, not a second decode of the address (see the
                    // header): 0x11C must not also land in FAN_CTL.
                    if (wblk == 3'd0) begin
                        case (waddr_q[5:2])
                            4'd1: begin
                                if (s_wstrb[0]) scratch[7:0]   <= s_wdata[7:0];
                                if (s_wstrb[1]) scratch[15:8]  <= s_wdata[15:8];
                                if (s_wstrb[2]) scratch[23:16] <= s_wdata[23:16];
                                if (s_wstrb[3]) scratch[31:24] <= s_wdata[31:24];
                            end
                            4'd2: begin
                                if (s_wstrb[0]) ledreg[7:0] <= s_wdata[7:0];
                                if (s_wstrb[1]) ledreg[8]   <= s_wdata[8];
                            end
                            4'd7: begin
                                if (s_wstrb[0]) fanreg[7:0]   <= s_wdata[7:0];
                                if (s_wstrb[1]) fanreg[15:8]  <= s_wdata[15:8];
                                if (s_wstrb[2]) fanreg[23:16] <= s_wdata[23:16];
                                if (s_wstrb[3]) fanreg[31:24] <= s_wdata[31:24];
                            end
                            4'd15: begin
                                if (s_wstrb[0]) auxreg[7:0]  <= s_wdata[7:0];
                                if (s_wstrb[1]) auxreg[15:8] <= s_wdata[15:8];
                            end
                            default: ;   // read-only or unmapped: dropped
                        endcase
                    end
                    // sub-blocks are written through blk_we above
                    waddr_q <= waddr_q + 32'd4;
                    if (s_wlast) wstate <= W_RESP;
                end
                W_RESP: if (s_bready) wstate <= W_IDLE;
                default: wstate <= W_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Read channel: AR -> R (s_arlen+1 beats)
    // ---------------------------------------------------------------------
    localparam R_IDLE = 1'b0, R_DATA = 1'b1;

    reg            rstate;
    reg [ID_W-1:0] arid_q;
    reg [31:0]     raddr_q;
    reg [3:0]      rcount;

    // ⚠ An `always @(*)` block, NOT a function called from a continuous
    // assign. A simulator re-evaluates `assign s_rdata = core_read(addr)`
    // only when `addr` changes, not when a register the function reads does,
    // so simulation returns stale data that synthesis does not.
    reg [31:0] core_rdata;
    always @(*) begin
        case (raddr_q[5:2])
            4'd0:  core_rdata = ID_MAGIC;
            4'd1:  core_rdata = scratch;
            4'd2:  core_rdata = {23'd0, ledreg};
            4'd3:  core_rdata = {28'd0, key_pressed};
            4'd4:  core_rdata = count;
            4'd5:  core_rdata = status;
            4'd6:  core_rdata = fan_status;
            4'd7:  core_rdata = fanreg;
            4'd8:  core_rdata = freq0;
            4'd9:  core_rdata = freq1;
            4'd10: core_rdata = freq2;
            4'd11: core_rdata = freq3;
            4'd12: core_rdata = freq_updates;
            4'd13: core_rdata = {29'd0, blk_irq};
            4'd14: core_rdata = {29'd0, BIST_CAPS};
            4'd15: core_rdata = {aux_status, auxreg};
            default: core_rdata = 32'd0;
        endcase
    end

    assign s_arready = (rstate == R_IDLE);
    assign s_rvalid  = (rstate == R_DATA);
    assign s_rid     = arid_q;
    assign s_rresp   = 2'b00;
    assign s_rlast   = (rcount == 4'd0);

    // A block's read data is combinational from blk_raddr, which is this
    // side's own address register -- never the write side's.
    assign blk_raddr = raddr_q[5:2];
    wire [2:0] rblk = raddr_q[8:6];
    wire [31:0] live_rdata = (rblk == 3'd0) ? core_rdata :
                     (rblk == 3'd1) ? blk_rdata0 :
                     (rblk == 3'd2) ? blk_rdata1 :
                     (rblk == 3'd3) ? blk_rdata2 :
                     (rblk == 3'd4) ? blk_rdata3 :
                     (rblk == 3'd5) ? blk_rdata4 :
                                      32'd0;

    // Counter/status registers and sub-blocks can change while the master
    // stalls. Capture the offered beat at the first stalled edge, then hold
    // it through acceptance. A following burst beat samples its own address.
    reg [31:0] held_rdata;
    reg read_stalled;
    assign s_rdata = read_stalled ? held_rdata : live_rdata;
    always @(posedge clk) begin
        if (!rstn) begin
            held_rdata <= 32'd0;
            read_stalled <= 1'b0;
        end else if (s_rvalid && !s_rready) begin
            if (!read_stalled) held_rdata <= live_rdata;
            read_stalled <= 1'b1;
        end else begin
            read_stalled <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            rstate  <= R_IDLE;
            arid_q  <= {ID_W{1'b0}};
            raddr_q <= 32'd0;
            rcount  <= 4'd0;
        end else begin
            case (rstate)
                R_IDLE: if (s_arvalid) begin
                    arid_q  <= s_arid;
                    raddr_q <= s_araddr;
                    rcount  <= s_arlen;
                    rstate  <= R_DATA;
                end
                R_DATA: if (s_rready) begin
                    if (rcount == 4'd0) begin
                        rstate <= R_IDLE;
                    end else begin
                        rcount  <= rcount - 4'd1;
                        raddr_q <= raddr_q + 32'd4;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
