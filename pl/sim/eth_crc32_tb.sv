// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for eth_crc32, against KNOWN ANSWERS rather than a second copy of the
// same logic.
//
// ⚠ This is the whole point of the file. A CRC implementation checked against
// another implementation of the same convention agrees with itself perfectly
// and is rejected by every real device on the wire -- the register might
// start at zero instead of all ones, or take bits most-significant first, and
// nothing internal would ever notice. So the expected values here come from
// the standard and from published test vectors:
//
//   * CRC-32 of the ASCII string "123456789" is 0xCBF43926. This is the
//     check value printed in the CRC catalog for CRC-32/ISO-HDLC, which is
//     the same algorithm Ethernet uses.
//
//   * Running the FCS over a whole frame INCLUDING its four FCS bytes leaves
//     a FIXED value in the register, whatever the frame contained. That is
//     the property a receiver relies on, so the bench builds a frame, appends
//     the FCS this module computed, runs the lot back through, and requires
//     that value.
//
//     ⚠ Two different residues appear in the literature -- 0xC704DD7B and
//     0xDEBB20E3 -- and each is the bit-reverse of the other. Which one a
//     given implementation sees depends on whether it keeps its register
//     reflected. eth_crc32 does NOT (it shifts left and feeds the byte in
//     LSB first), so the value here is 0xC704DD7B. Picking the wrong one of
//     the pair is a test bug, not a logic bug, and the way to tell is the
//     catalog check value above, which pins the algorithm independently.

`timescale 1ns / 1ps

module eth_crc32_tb;

    int errors = 0;
    task automatic check(input bit cond, input string what);
        if (!cond) begin
            $display("  FAIL  %s", what);
            errors++;
        end else $display("  ok    %s", what);
    endtask

    logic clk = 0;
    always #5 clk = ~clk;

    logic        rst = 1, en = 0;
    logic [7:0]  data = 8'h00;
    logic [31:0] crc, fcs;

    eth_crc32 dut (.clk(clk), .rst(rst), .en(en), .data(data),
                   .crc(crc), .fcs(fcs));

    task automatic feed(input byte unsigned b);
        @(negedge clk);
        data = b;
        en   = 1;
        @(negedge clk);
        en = 0;
    endtask

    byte unsigned frame[];
    int i;
    logic [31:0] saved_fcs;

    initial begin
        // ------------------------------------------------ 1. the check value
        $display("[1] the catalog check value for \"123456789\"");
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        for (i = 0; i < 9; i++) feed(8'h31 + i);   // "123456789"
        @(negedge clk);
        check(fcs == 32'hCBF4_3926,
              $sformatf("CRC-32(\"123456789\") = %08x, want CBF43926", fcs));

        // ---------------------------------------------- 2. the frame residue
        $display("[2] the residue over a frame that includes its own FCS");
        // A minimal-looking frame: dst, src, type, some payload.
        frame = new[60];
        for (i = 0; i < 6;  i++) frame[i] = 8'hFF;              // broadcast
        for (i = 6; i < 12; i++) frame[i] = 8'h02 + i;          // some source
        frame[12] = 8'h08; frame[13] = 8'h00;                   // IPv4
        for (i = 14; i < 60; i++) frame[i] = i * 7;

        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        foreach (frame[i]) feed(frame[i]);
        @(negedge clk);
        saved_fcs = fcs;
        $display("        FCS over the frame = %08x", saved_fcs);

        // Now run the frame AND its FCS through, and require the residue.
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        foreach (frame[i]) feed(frame[i]);
        feed(saved_fcs[7:0]);
        feed(saved_fcs[15:8]);
        feed(saved_fcs[23:16]);
        feed(saved_fcs[31:24]);
        @(negedge clk);
        check(crc == 32'hC704_DD7B,
              $sformatf("residue = %08x, want C704DD7B", crc));

        // ------------------------------------------------ 3. it can go wrong
        $display("[3] one flipped bit destroys the residue");
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
        frame[30] = frame[30] ^ 8'h01;
        foreach (frame[i]) feed(frame[i]);
        feed(saved_fcs[7:0]);
        feed(saved_fcs[15:8]);
        feed(saved_fcs[23:16]);
        feed(saved_fcs[31:24]);
        @(negedge clk);
        check(crc != 32'hC704_DD7B,
              $sformatf("residue = %08x, which must NOT be C704DD7B", crc));

        $display("");
        if (errors == 0) $display("eth_crc32_tb: PASS");
        else             $display("eth_crc32_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("eth_crc32_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
