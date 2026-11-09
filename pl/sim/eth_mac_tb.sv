// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Loopback bench: eth_mac_tx's GMII output wired straight into eth_mac_rx,
// with frames pushed in one end and compared at the other.
//
// ⚠ A loopback proves the two halves AGREE, which is not the same as proving
// either is right -- a transmitter that got the FCS convention backwards and
// a receiver that made the same mistake would pass this perfectly and be
// rejected by every real partner. The thing that stops that here is
// eth_crc32_tb, which pins the CRC against the published check value from
// outside this design. This bench sits on top of that and checks the framing:
// the SFD, padding to the minimum, the FCS verdict and recovery after a bad
// frame.
//
// What is checked:
//   1. a 60-byte frame comes back byte-identical, with the FCS appended and
//      the check passing
//   2. a short frame is PADDED to 60 before the FCS, so it arrives as a legal
//      64-byte frame rather than a runt
//   3. a long frame passes through unpadded
//   4. a bit flipped on the wire is caught -- m_good goes low
//   5. a clean frame after a rejected one is accepted -- the receiver recovers

`timescale 1ns / 1ps

module eth_mac_tb;

    int errors = 0;
    task automatic check(input bit cond, input string what);
        if (!cond) begin
            $display("  FAIL  %s", what);
            errors++;
        end else $display("  ok    %s", what);
    endtask

    logic clk = 0;
    always #4 clk = ~clk;          // 125 MHz, the gigabit byte rate
    logic rstn = 0;
    logic ce   = 1;

    // ------------------------------------------------------------------ TX
    logic [7:0] s_data;
    logic       s_valid = 0, s_last = 0;
    logic       s_ready;
    logic [7:0] txd;
    logic       tx_en, tx_busy;

    eth_mac_tx u_tx (
        .clk(clk), .rstn(rstn), .ce(ce),
        .s_data(s_data), .s_valid(s_valid), .s_last(s_last),
        .s_ready(s_ready),
        .txd(txd), .tx_en(tx_en), .busy(tx_busy)
    );

    // ------------------------------------------------- the wire, with a fault
    logic        corrupt_en = 0;
    int          corrupt_at = -1;
    int          wire_count = 0;
    logic [7:0]  rxd;
    logic        rx_dv;

    always_ff @(posedge clk) begin
        if (!rstn) wire_count <= 0;
        else if (tx_en) wire_count <= wire_count + 1;
        else            wire_count <= 0;
    end

    always_comb begin
        rx_dv = tx_en;
        rxd   = (corrupt_en && tx_en && wire_count == corrupt_at)
                ? (txd ^ 8'h01) : txd;
    end

    // ------------------------------------------------------------------ RX
    logic [7:0]  m_data;
    logic        m_valid, m_last, m_good, rx_busy;
    logic [10:0] m_len;

    eth_mac_rx u_rx (
        .clk(clk), .rstn(rstn), .ce(ce),
        .rxd(rxd), .rx_dv(rx_dv), .rx_er(1'b0),
        .m_data(m_data), .m_valid(m_valid), .m_last(m_last),
        .m_good(m_good), .m_len(m_len), .busy(rx_busy)
    );

    // Collect what comes out. Plain arrays and blocking assignments rather
    // than queues: iverilog's SystemVerilog is partial, and mixing an int
    // expression into a byte queue trips an internal assertion in it. The
    // bench should exercise the DUT, not the simulator.
    reg [7:0] got [0:2047];
    integer   got_n;
    integer   got_len;
    reg       got_good;
    reg       frame_done;

    always @(posedge clk) begin
        if (m_valid) begin
            got[got_n] = m_data;
            got_n      = got_n + 1;
        end
        if (m_last) begin
            got_len    = m_len;
            got_good   = m_good;
            frame_done = 1'b1;
        end
    end

    // ------------------------------------------------------------ send one
    reg [7:0] sent [0:2047];
    integer   k;

    task send(input integer n);
        begin
            got_n      = 0;
            frame_done = 1'b0;
            for (k = 0; k < n; k = k + 1) sent[k] = (k * 13 + 7) & 8'hFF;

            // ⚠ Stimulus moves ONLY on the negedge. Driving s_data just
            // after @(posedge clk) races the DUT's sample of it: the first
            // byte of a frame can be lost, and the frame still carries a
            // valid FCS, because the CRC covers whatever was actually sent.
            //
            // s_ready is combinational from the transmitter's state, so at a
            // negedge it says whether the COMING posedge will take the byte.
            // Hold the byte across negedges until it does, then move on; the
            // next iteration's negedge is already past the consuming edge.
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                s_data  = sent[k];
                s_valid = 1'b1;
                s_last  = (k == n - 1);
                while (!s_ready) @(negedge clk);
            end
            @(negedge clk);
            s_valid = 1'b0;
            s_last  = 1'b0;
            wait (frame_done);
            @(negedge clk);
        end
    endtask

    integer mm;
    function payload_matches(input integer n);
        begin
            payload_matches = 1'b1;
            if (got_n < n) payload_matches = 1'b0;
            else
                for (mm = 0; mm < n; mm = mm + 1)
                    if (got[mm] !== sent[mm]) payload_matches = 1'b0;
        end
    endfunction

    initial begin
        repeat (4) @(negedge clk);
        rstn = 1;
        repeat (4) @(negedge clk);

        $display("[1] a 60-byte frame");
        send(60);
        check(got_good, "FCS checked out");
        check(got_len == 64, $sformatf("64 bytes received (60 + FCS), got %0d",
                                       got_len));
        check(payload_matches(60), "payload came back byte for byte");

        $display("[2] a 20-byte frame is padded to the minimum");
        send(20);
        check(got_good, "FCS checked out");
        check(got_len == 64,
              $sformatf("padded to 64 on the wire, got %0d", got_len));
        check(payload_matches(20), "the 20 bytes are intact at the front");
        check(got[20] == 8'h00 && got[59] == 8'h00,
              "the pad is zeros, up to byte 59");

        $display("[3] a 300-byte frame is not padded");
        send(300);
        check(got_good, "FCS checked out");
        check(got_len == 304, $sformatf("304 bytes (300 + FCS), got %0d",
                                        got_len));
        check(payload_matches(300), "payload came back byte for byte");

        $display("[4] a bit flipped on the wire");
        corrupt_en = 1;
        corrupt_at = 20;               // inside the frame, past the SFD
        send(100);
        check(!got_good, "the receiver rejected it");
        corrupt_en = 0;
        corrupt_at = -1;

        $display("[5] a clean frame after a bad one");
        send(64);
        check(got_good, "recovered -- the next frame is accepted");
        check(payload_matches(64), "and is intact");

        $display("");
        if (errors == 0) $display("eth_mac_tb: PASS");
        else             $display("eth_mac_tb: FAIL -- %0d check(s)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("eth_mac_tb: FAIL -- global timeout");
        $finish;
    end

endmodule
