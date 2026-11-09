// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for axi4_regs: the core registers, AXI3 bursts, and the sub-block
// windows the BIST engines live in.
//
// ⚠ The test that matters most here is [5]. The read and write state machines
// in this slave are independent -- AW is accepted in W_IDLE and AR in R_IDLE
// -- so a write beat and a read beat CAN land on the same cycle. If both
// sides shared one register index, a block read during a block write would
// return whatever the writer was pointing at -- invisible under `devmem`,
// which never overlaps the two, and an occasional wrong reading under real
// traffic. The bench drives both channels at once on purpose.
//
// The block read data is wired to a function of the index the slave presents,
// so a wrong index is visible as a wrong value rather than as silence.

`timescale 1ns / 1ps

module axi4_regs_tb;

    localparam ID_W = 12;

    reg clk = 1'b0, rstn = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] what;
        begin
            if (!cond) begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end else $display("  ok    %0s", what);
        end
    endtask

    task check_eq;
        input [31:0] got;
        input [31:0] want;
        input [8*64-1:0] what;
        begin
            if (got !== want) begin
                $display("  FAIL  %0s: got %08x, wanted %08x", what, got, want);
                errors = errors + 1;
            end else $display("  ok    %0s = %08x", what, got);
        end
    endtask

    // ------------------------------------------------------------------ AXI
    reg  [ID_W-1:0] awid = 0, arid = 0;
    reg  [31:0] awaddr = 0, araddr = 0, wdata = 0;
    reg  [3:0]  awlen = 0, arlen = 0, wstrb = 4'hF;
    reg         awvalid = 0, wvalid = 0, wlast = 0, bready = 1;
    reg         arvalid = 0, rready = 1;
    wire        awready, wready, bvalid, arready, rvalid, rlast;
    wire [ID_W-1:0] bid, rid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    wire [1:0]  led8;
    reg  [3:0]  key_n = 4'b1111;
    reg  [31:0] status = 32'd0;
    reg  [31:0] fan_status = 32'hF00D_1234;
    wire [31:0] fan_ctrl;

    wire [15:0] aux_ctrl;
    wire [3:0]  blk_waddr, blk_raddr;
    wire [4:0]  blk_we;
    wire [31:0] blk_wdata;

    // A block whose read data says which index it was asked for.
    wire [31:0] blk_rdata0 = {16'hB000, 12'h000, blk_raddr};
    wire [31:0] blk_rdata1 = {16'hB111, 12'h000, blk_raddr};
    wire [31:0] blk_rdata2 = {16'hB222, 12'h000, blk_raddr};
    wire [31:0] blk_rdata3 = {16'hB333, 12'h000, blk_raddr};
    wire [31:0] blk_rdata4 = {16'hB444, 12'h000, blk_raddr};

    axi4_regs #(.ID_W(ID_W), .BIST_CAPS(3'b011)) dut (
        .clk(clk), .rstn(rstn),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen),
        .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
        .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen),
        .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast),
        .s_rvalid(rvalid), .s_rready(rready),
        .led8(led8), .key_n(key_n), .status(status),
        .fan_status(fan_status), .fan_ctrl(fan_ctrl),
        .freq0(32'd50_000_000), .freq1(32'd78_125_000),
        .freq2(32'd75_000_000), .freq3(32'd200_000_000),
        .freq_updates(32'h04030201),
        .aux_ctrl(aux_ctrl), .aux_status(16'hBEEF),
        .blk_waddr(blk_waddr), .blk_raddr(blk_raddr), .blk_we(blk_we),
        .blk_wdata(blk_wdata),
        .blk_rdata0(blk_rdata0), .blk_rdata1(blk_rdata1),
        .blk_rdata2(blk_rdata2),
        .blk_rdata3(blk_rdata3),
        .blk_rdata4(blk_rdata4),
        .blk_irq(3'b101)
    );

    // what the blocks saw
    reg [3:0]  seen_waddr;
    reg [31:0] seen_wdata;
    reg [4:0]  seen_we;
    always @(posedge clk) begin
        if (|blk_we) begin
            seen_we    <= blk_we;
            seen_waddr <= blk_waddr;
            seen_wdata <= blk_wdata;
        end
    end

    // ---------------------------------------------------------------- tasks
    task axi_write;
        input [31:0] a;
        input [31:0] d;
        begin
            @(posedge clk);
            awaddr <= a; awlen <= 4'd0; awvalid <= 1'b1;
            @(posedge clk);
            while (!awready) @(posedge clk);
            awvalid <= 1'b0;
            wdata <= d; wvalid <= 1'b1; wlast <= 1'b1;
            @(posedge clk);
            while (!wready) @(posedge clk);
            wvalid <= 1'b0; wlast <= 1'b0;
            while (!bvalid) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task axi_read;
        input [31:0] a;
        output [31:0] d;
        begin
            @(posedge clk);
            araddr <= a; arlen <= 4'd0; arvalid <= 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            arvalid <= 1'b0;
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(posedge clk);
        end
    endtask

    reg [31:0] burst [0:7];
    integer bi;

    task axi_read_burst;
        input [31:0] a;
        input [3:0]  len;       // beats - 1
        reg          last;
        begin
            @(posedge clk);
            araddr <= a; arlen <= len; arvalid <= 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            arvalid <= 1'b0;
            bi = 0;
            last = 1'b0;
            while (!last) begin
                while (!rvalid) @(posedge clk);
                burst[bi] = rdata;
                bi = bi + 1;
                last = rlast;
                @(posedge clk);
            end
        end
    endtask

    reg [31:0] v, v2;

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        $display("[1] core registers");
        axi_read(32'h00, v);  check_eq(v, 32'h5A71_0002, "ID");
        axi_write(32'h04, 32'hCAFE_F00D);
        axi_read(32'h04, v);  check_eq(v, 32'hCAFE_F00D, "SCRATCH round trip");
        axi_read(32'h18, v);  check_eq(v, 32'hF00D_1234, "FAN_STATUS passthrough");
        axi_write(32'h1C, 32'h0000_00A5);
        check_eq(fan_ctrl, 32'h0000_00A5, "FAN_CTL reaches the fan");
        axi_read(32'h20, v);  check_eq(v, 32'd50_000_000,  "FREQ0");
        axi_read(32'h2C, v);  check_eq(v, 32'd200_000_000, "FREQ3");
        axi_read(32'h30, v);  check_eq(v, 32'h04030201,    "FREQ_UPDATES");
        axi_read(32'h34, v);  check_eq(v, 32'd5,           "IRQ_STATUS");
        axi_read(32'h38, v);  check_eq(v, 32'd3,           "CAPS");

        $display("[2] keys are inverted and synchronized");
        key_n = 4'b1101;                 // KEY2 pressed (active low)
        repeat (4) @(posedge clk);
        axi_read(32'h0C, v);  check_eq(v, 32'd2, "KEY reads bit 1 set");
        key_n = 4'b1111;
        repeat (4) @(posedge clk);
        axi_read(32'h0C, v);
        check_eq(v, 32'd0, "KEY clears when released");

        // ⚠ Reading the SAME address twice, with the value changing in
        // between. A read mux that only re-evaluates when the address moves
        // returns the first answer forever; every other read in this bench
        // moves the address, so none of them would notice.
        key_n = 4'b0111;                 // KEY4
        repeat (4) @(posedge clk);
        axi_read(32'h0C, v);  check_eq(v, 32'd8, "same address, new value");
        key_n = 4'b1111;
        repeat (4) @(posedge clk);
        axi_read(32'h0C, v);  check_eq(v, 32'd0, "same address again, cleared");

        // COUNT free-runs, so two reads of it must differ without the
        // address moving either.
        axi_read(32'h10, v);
        axi_read(32'h10, v2);
        check(v !== v2, "COUNT advances between two reads of one address");

        $display("[2b] the AUX register: writes low, reads both halves");
        axi_write(32'h3C, 32'h0000_1234);
        check_eq({16'd0, aux_ctrl}, 32'h0000_1234, "AUX drives aux_ctrl");
        axi_read(32'h3C, v);
        check_eq(v, 32'hBEEF_1234, "AUX reads status:control");

        $display("[3] the block windows");
        axi_read(32'h40, v);  check_eq(v, 32'hB000_0000, "block 0, index 0");
        axi_read(32'h54, v);  check_eq(v, 32'hB000_0005, "block 0, index 5");
        axi_read(32'h80, v);  check_eq(v, 32'hB111_0000, "block 1, index 0");
        axi_read(32'hC8, v);  check_eq(v, 32'hB222_0002, "block 2, index 2");

        axi_write(32'h48, 32'h1234_ABCD);
        check_eq({27'd0, seen_we}, 32'd1,          "block 0 write strobe");
        check_eq({28'd0, seen_waddr}, 32'd2,       "block 0 write index");
        check_eq(seen_wdata, 32'h1234_ABCD,        "block 0 write data");
        axi_write(32'hC4, 32'h5555_AAAA);
        check_eq({27'd0, seen_we}, 32'd4,          "block 2 write strobe");
        check_eq({28'd0, seen_waddr}, 32'd1,       "block 2 write index");

        // Block 3 sits at 0x100, which needs address bit 8 in the decode.
        // With only bits [7:6] decoded, 0x100 would alias the core window and
        // read back the ID.
        axi_read(32'h100, v); check_eq(v, 32'hB333_0000, "0x100 is block 3, not an alias of the ID");
        axi_read(32'h10C, v); check_eq(v, 32'hB333_0003, "block 3, index 3");
        axi_read(32'h13C, v); check_eq(v, 32'hB333_000F, "block 3, index 15");
        axi_read(32'h180, v); check_eq(v, 32'd0,         "0x180 (block 5, unfitted) reads zero");
        axi_read(32'h1FC, v); check_eq(v, 32'd0,         "0x1FC (block 6, unfitted) reads zero");
        axi_read(32'h000, v); check_eq(v, 32'h5A71_0002, "the ID is still at 0x000");
        axi_write(32'h104, 32'h0BAD_F00D);
        check_eq({27'd0, seen_we}, 32'd8,          "block 3 write strobe");
        check_eq({28'd0, seen_waddr}, 32'd1,       "block 3 write index");
        check_eq(seen_wdata, 32'h0BAD_F00D,        "block 3 write data");

        // Sub-block 4, at 0x140: the MIG BIST engine in the full design.
        axi_read(32'h140, v); check_eq(v, 32'hB444_0000, "0x140 is block 4");
        axi_write(32'h148, 32'h4444_0000);
        check_eq({27'd0, seen_we}, 32'd16,         "block 4 write strobe");
        check_eq({28'd0, seen_waddr}, 32'd2,       "block 4 write index");
        // The block 3 writes (0x104 above, 0x11C here) must reach ONLY block
        // 3: core writes decode through the same block number, and bits [7:6]
        // alone would land them on SCRATCH and FAN_CTL.
        axi_read(32'h04, v);  check_eq(v, 32'hCAFE_F00D, "a write to 0x104 leaves SCRATCH (0x004) alone");
        axi_write(32'h11C, 32'h0000_0000);
        axi_read(32'h1C, v);  check_eq(v, 32'h0000_00A5, "a write to 0x11C leaves FAN_CTL (0x01C) alone");

        $display("[4] an AXI3 read burst walks the registers");
        axi_read_burst(32'h00, 4'd3);
        check(bi == 4, "four beats came back");
        check_eq(burst[0], 32'h5A71_0002, "beat 0 = ID");
        check_eq(burst[1], 32'hCAFE_F00D, "beat 1 = SCRATCH");
        check_eq(burst[3], 32'd0,         "beat 3 = KEY");

        $display("[5] a read and a write at the same time");
        // Drive three block-1 writes while reading block 0. If both sides
        // shared one index, the read would follow the writer.
        fork
            begin
                axi_write(32'h90, 32'hFEED_0001);
                axi_write(32'h9C, 32'hFEED_0002);
                axi_write(32'h88, 32'hFEED_0003);
            end
            begin
                repeat (2) @(posedge clk);
                axi_read(32'h54, v);
                axi_read(32'h54, v2);
            end
        join
        check_eq(v,  32'hB000_0005, "block 0 index 5 during a block 1 write");
        check_eq(v2, 32'hB000_0005, "and again");

        $display("[6] LED8 heartbeat vs solid");
        status = 32'd0;
        repeat (2) @(posedge clk);
        check(led8[0] !== led8[1], "heartbeat halves alternate when not up");
        status = 32'd1;
        repeat (2) @(posedge clk);
        check(led8 === 2'b01, "LED8 goes solid when status[0] is set");

        $display("[7] live read data stays stable under backpressure");
        @(negedge clk);
        rready = 0;
        araddr = 32'h10; arlen = 1; arvalid = 1; arid = 12'h345;
        @(negedge clk);
        arvalid = 0;
        check(rvalid === 1'b1, "counter read response is valid");
        v = rdata;
        repeat (5) begin
            @(negedge clk);
            check_eq(rdata, v, "counter beat held while RREADY is low");
            check(rvalid === 1'b1 && rlast === 1'b0 && rid === 12'h345,
                  "stalled first-beat metadata holds");
        end
        rready = 1;
        @(negedge clk);
        rready = 0;
        v = rdata;
        // The next beat is STATUS; it must be held independently.
        @(negedge clk);
        status = 32'hCAFE_F00D;
        repeat (4) begin
            @(negedge clk);
            check_eq(rdata, v, "status beat held while input changes");
            check(rvalid === 1'b1 && rlast === 1'b1, "last beat remains valid");
        end
        rready = 1;
        @(negedge clk);
        check(rvalid === 1'b0, "burst completes after accepting held last beat");
        axi_read(32'h14, v);
        check_eq(v, 32'hCAFE_F00D, "new read observes updated status");

        $display("");
        if (errors == 0) $display("axi4_regs_tb: PASS");
        else             $display("axi4_regs_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #500_000;
        $display("axi4_regs_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
