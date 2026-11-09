// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for fb_reader: does the picture in memory come out of the pixel port,
// in the right order, at the right addresses?
//
// The geometry is shrunk to 64x4 so a whole frame simulates in milliseconds.
// Everything that matters scales: two bursts per line, a ping-pong buffer
// swap between them, and the two crossings from the pixel clock into the AXI
// clock (the gray-coded line count and the frame toggle).
//
// ⚠ The memory is filled so that EVERY PIXEL IS ITS OWN ADDRESS -- the value
// at byte offset N is N. A scanout that is shifted by a pixel, off by a line,
// or reading the wrong buffer then produces a wrong number rather than a
// plausible one, and the bench can say exactly how far off it is. Filling it
// with a pattern that repeats per line would hide a line-addressing error
// completely.
//
// Then the memory stops answering reads mid-frame: the late lines must show up
// in the starvation counter, which reads zero in every normal frame, and the
// picture must be whole again once the next frame start re-aligns the two
// sides -- including the reads that were in flight when it did.
//
// ⚠ The two clocks are unrelated in frequency and not simple multiples of
// each other, because a ping-pong buffer that only works when the pixel clock
// divides the AXI clock is a buffer that works in simulation.

`timescale 1ns / 1ps

module fb_reader_tb;

    localparam integer H_ACT = 64;
    localparam integer V_ACT = 4;
    localparam integer BEATS = 16;
    localparam [31:0]  BASE  = 32'h0001_0000;

    integer errors = 0;
    task check;
        input cond;
        input string what;
        begin
            if (!cond) begin
                $display("  FAIL  %0s", what);
                errors = errors + 1;
            end else $display("  ok    %0s", what);
        end
    endtask

    // 100 MHz AXI, 74.4 MHz pixel -- not a ratio, on purpose.
    reg clk = 1'b0;      always #5     clk = ~clk;
    reg pix_clk = 1'b0;  always #6.720 pix_clk = ~pix_clk;

    reg rstn = 1'b0, pix_rstn = 1'b0;
    reg enable = 1'b0;

    // ------------------------------------------------------------ the AXI
    wire [5:0]  arid, rid, awid, wid, bid;
    wire [31:0] araddr, awaddr;
    wire [3:0]  arlen, awlen;
    wire [2:0]  arsize, awsize, arprot, awprot;
    wire [1:0]  arburst, awburst, arlock, awlock, rresp, bresp;
    wire [3:0]  arcache, awcache, arqos, awqos;
    wire [63:0] rdata, wdata;
    wire [7:0]  wstrb;
    wire arvalid, arready, rvalid, rready, rlast;
    wire awvalid, awready, wvalid, wready, wlast, bvalid, bready;

    // ---------------------------------------------------------- the video
    reg  de = 1'b0, frame_start = 1'b0, line_start = 1'b0;
    wire [23:0] pixel;
    wire [31:0] frames, starve_cycles;

    fb_reader #(.H_ACT(H_ACT), .V_ACT(V_ACT), .BEATS(BEATS)) dut (
        .clk(clk), .rstn(rstn),
        .enable(enable), .base_addr(BASE), .stride(32'd0),
        .frames(frames), .starve_cycles(starve_cycles),
        .pix_clk(pix_clk), .pix_rstn(pix_rstn),
        .de(de), .frame_start(frame_start), .line_start(line_start),
        .pixel(pixel),
        .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awlock(awlock), .m_awcache(awcache),
        .m_awprot(awprot), .m_awqos(awqos), .m_awvalid(awvalid),
        .m_awready(awready),
        .m_wid(wid), .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast),
        .m_wvalid(wvalid), .m_wready(wready),
        .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arlock(arlock), .m_arcache(arcache),
        .m_arprot(arprot), .m_arqos(arqos), .m_arvalid(arvalid),
        .m_arready(arready),
        .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast),
        .m_rvalid(rvalid), .m_rready(rready)
    );

    axi_mem_bfm #(.DW(64), .IDW(6), .LENW(4), .WORDS(8192),
                  .STALL(15), .RLAT(3)) mem (
        .clk(clk), .rstn(rstn),
        .dead(1'b0), .corrupt_en(1'b0),
        .corrupt_addr(32'd0), .corrupt_xor(32'd0),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
        .s_awburst(awburst), .s_awvalid(awvalid), .s_awready(awready),
        .s_wid(wid), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
        .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
        .s_arburst(arburst), .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast),
        .s_rvalid(rvalid), .s_rready(rready)
    );

    // ---------------------------------------------- fill memory: value = addr
    integer w;
    reg [23:0] fill_lo, fill_hi;
    initial begin
        // One step in: the memory model clears its array at time 0, and the
        // order of two initial blocks at the same time is not defined.
        #1;
        for (w = 0; w < 4096; w = w + 1) begin
            // Each 64-bit word holds two pixels; each pixel's low 24 bits are
            // its own byte address, so a misplaced pixel names its own offset.
            // Via intermediates: a sum inside a concatenation has no defined
            // width, and iverilog rightly refuses to guess.
            fill_lo = BASE[23:0] + w*8;
            fill_hi = BASE[23:0] + w*8 + 4;
            mem.mem[w] = {8'h00, fill_hi, 8'h00, fill_lo};
        end
    end

    // --------------------------------------------------- the video generator
    integer line, px;
    reg [23:0] got;
    reg [23:0] want;
    integer mismatches;

    task run_frame;
        begin
            mismatches = 0;
            @(negedge pix_clk);
            frame_start = 1'b1;
            @(negedge pix_clk);
            frame_start = 1'b0;
            // a little vertical blanking, so the first line can be fetched
            repeat (200) @(negedge pix_clk);

            for (line = 0; line < V_ACT; line = line + 1) begin
                line_start = 1'b1;
                @(negedge pix_clk);
                line_start = 1'b0;
                @(negedge pix_clk);

                for (px = 0; px < H_ACT; px = px + 1) begin
                    de = 1'b1;
                    #1;
                    got  = pixel;
                    want = (BASE[23:0] + line*H_ACT*4 + px*4);
                    if (got !== want) begin
                        if (mismatches < 4)
                            $display("        line %0d px %0d: got %06x want %06x",
                                     line, px, got, want);
                        mismatches = mismatches + 1;
                    end
                    @(negedge pix_clk);
                end
                de = 1'b0;
                // horizontal blanking: time for the next line to be fetched
                repeat (60) @(negedge pix_clk);
            end
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rstn = 1'b1; pix_rstn = 1'b1;
        repeat (5) @(negedge clk);
        enable = 1'b1;

        $display("[1] one frame, %0dx%0d, every pixel its own address", H_ACT, V_ACT);
        run_frame;
        check(mismatches == 0,
              $sformatf("every pixel matched (%0d mismatches)", mismatches));
        check(starve_cycles == 32'd0,
              $sformatf("no line was ever late (%0d starvation cycles)", starve_cycles));

        $display("[2] a second frame, to prove it wraps");
        run_frame;
        check(mismatches == 0,
              $sformatf("every pixel matched again (%0d mismatches)", mismatches));
        check(frames >= 32'd1,
              $sformatf("the frame counter advanced (%0d)", frames));
        check(starve_cycles == 32'd0,
              $sformatf("still no line late (%0d starvation cycles)", starve_cycles));

        // The memory stops answering reads for a while in the middle of a
        // frame. The lines it holds up are late: the pixels are wrong and the
        // starvation counter says why. The next frame must be whole again.
        $display("[3] reads held off mid-frame: late lines are counted");
        fork
            run_frame;
            begin
                repeat (400) @(negedge pix_clk);
                force arready = 1'b0;
                repeat (300) @(negedge pix_clk);
                release arready;
            end
        join
        $display("        %0d mismatches, %0d starvation cycles", mismatches, starve_cycles);
        check(starve_cycles > 32'd0, "the late lines were counted");
        // The late line stays late -- and is counted -- until the next frame
        // start re-aligns the two sides, so the check that the damage is
        // over is on the frame after that.
        run_frame;
        check(mismatches == 0,
              $sformatf("the next frame is whole again (%0d mismatches)", mismatches));
        begin : recover
            reg [31:0] prior;
            prior = starve_cycles;
            run_frame;
            check(mismatches == 0 && starve_cycles == prior,
                  $sformatf("and the one after is whole with nothing counted (+%0d)",
                            starve_cycles - prior));
        end

        $display("");
        if (errors == 0) $display("fb_reader_tb: PASS");
        else             $display("fb_reader_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("fb_reader_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
