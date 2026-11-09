// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// axis_cdc_fifo: does every word cross the clock boundary exactly once, in
// order, with nothing invented and nothing lost?
//
// WHAT THIS IS BUILT TO AVOID
//
// ⚠ A FIFO test that only counts words passes on a FIFO that duplicates one
// and drops another. Every word here is its own index, so a duplicate, a
// drop, a reorder or a stale replay is caught at the first wrong beat and
// named -- and the count is checked as well, because a FIFO that loses the
// LAST word would otherwise pass a purely positional check.
//
// ⚠ The two clocks are incommensurate and the test runs at THREE ratios:
// writer faster than reader, reader faster than writer, and near-equal.
//
// Only the ratio where the writer outruns the reader fills the FIFO, so it is
// the one that tests `full`; the other two pass a FIFO whose full flag is
// wrong. No ratio can show why the pointers are gray-coded: a zero-delay
// simulation never samples a pointer mid-change.
//
// ⚠ The reader stalls at random. A FIFO exercised with rready tied high never
// fills, and full is exactly the flag most likely to be wrong -- it is the
// one that needs the extra pointer bit to be told apart from empty.

`timescale 1ns / 1ps

module axis_cdc_fifo_tb;

    localparam integer DW = 26;
    localparam integer AW = 6;      // 64 deep: small enough to actually fill
    localparam integer N  = 4000;   // words per ratio

    integer errors = 0;

    reg [2:0] done = 3'b000;
    reg [2:0] ok   = 3'b000;


    task fail(input integer r, input [8*64-1:0] why);
        begin
            $display("  FAIL ratio%0d: %0s", r, why);
            errors = errors + 1;
        end
    endtask

    genvar g;
    generate
    for (g = 0; g < 3; g = g + 1) begin : ratio

        // writer fast / reader fast / near-equal, none an integer multiple
        localparam real WPER = (g == 0) ? 6.734 : (g == 1) ? 21.317 : 10.061;
        localparam real RPER = (g == 0) ? 20.131 : (g == 1) ? 7.129 : 10.000;

        reg wclk = 1'b0, rclk = 1'b0, rrstn = 1'b0;
        always #(WPER / 2.0) wclk = ~wclk;
        always #(RPER / 2.0) rclk = ~rclk;

        reg  [DW-1:0] wdata = {DW{1'b0}};
        reg           wvalid = 1'b0;
        wire          wready;
        wire [DW-1:0] rdata;
        wire          rvalid;
        reg           rready = 1'b0;

        axis_cdc_fifo #(.DW(DW), .AW(AW)) dut (
            .wclk(wclk), .wdata(wdata), .wvalid(wvalid), .wready(wready),
            .rclk(rclk), .rrstn(rrstn),
            .rdata(rdata), .rvalid(rvalid), .rready(rready));

        integer sent = 0, got = 0, bad = 0;
        reg [31:0] rseed = 32'h9abc_def0 + g;

        // ⚠ The writer must not run during the read side's reset. There is no
        // reset in the write domain at all -- that is the point of the design,
        // its clock may not exist -- so anything written before the reader
        // comes out of reset is CORRECTLY discarded, because reset lands the
        // read pointer on the writer's position. A writer started at time
        // zero would have its first words discarded, correctly, and this bench
        // would wrongly expect word 0.
        reg [1:0] wgo = 2'b00;
        always @(posedge wclk) wgo <= {wgo[0], rrstn};

        // ------------------------------------------------------ the writer
        // Offers a word whenever it has one; the FIFO's wready decides.
        always @(posedge wclk) if (wgo[1]) begin
            if (wvalid && wready) begin
                sent   <= sent + 1;
                wvalid <= 1'b0;
            end
            if (!wvalid && sent < N) begin
                wdata  <= sent[DW-1:0];
                wvalid <= 1'b1;
            end
        end

        // ------------------------------------------------------ the reader
        // ⚠ rready wanders, so the FIFO actually fills and `full` is tested.
        always @(posedge rclk) begin
            rseed  <= {rseed[30:0], rseed[31] ^ rseed[21] ^ rseed[1] ^ rseed[0]};
            rready <= rrstn & rseed[3];
        end

        // ------------------------------------------------------ the checker
        always @(posedge rclk) if (rrstn && rvalid && rready) begin
            if (rdata !== got[DW-1:0]) begin
                if (bad < 4)
                    $display("  ratio%0d: word %0d came back as %0d",
                             g, got, rdata);
                bad = bad + 1;
            end
            got = got + 1;
        end

        initial begin
            rrstn = 1'b0;
            repeat (10) @(posedge rclk);
            rrstn = 1'b1;

            wait (sent == N);
            // Let the reader drain. The reader stalls at random, so this has
            // to be generous, but it must TIME OUT rather than wait forever.
            repeat (N * 40) @(posedge rclk);

            if (bad != 0)          fail(g, "words came back wrong or out of order");
            if (got != N)          fail(g, "wrong number of words crossed");
            if (rvalid !== 1'b0)   fail(g, "the FIFO still claims data after draining");

            $display("  ratio%0d: wclk %0.3f ns, rclk %0.3f ns -- %0d of %0d words, %0d wrong",
                     g, WPER, RPER, got, N, bad);
            done[g] = 1'b1;
            ok[g]   = (bad == 0) && (got == N) && (rvalid === 1'b0);
        end
    end
    endgenerate

    initial begin
        $display("=== axis_cdc_fifo_tb");
        wait (done == 3'b111);
        if (ok !== 3'b111) errors = errors + 1;
        if (errors == 0) $display("axis_cdc_fifo_tb: PASS");
        else             $display("axis_cdc_fifo_tb: FAIL (%0d)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("axis_cdc_fifo_tb: FAIL -- timeout");
        $finish;
    end

endmodule
