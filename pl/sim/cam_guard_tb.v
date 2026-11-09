// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for cam_guard: the camera receiver must never be stalled, and a
// stall downstream must cost one frame, not the stream.
//
// Frames are W beats a line, H lines, the first beat of each carrying TUSER
// and the last of each line TLAST; every beat's data is its position in the
// frame, so the sink can check that a frame it accepts is whole and in order.
//
// The checks that pin behavior EXACTLY:
//   - with the sink always ready, N frames in are N frames out, every one
//     whole, and nothing is dropped
//   - a stream that starts mid-frame loses exactly the beats before the
//     first SOF, and every frame after that is whole
//   - a sink stall longer than the FIFO drops, and the receiver side stays
//     ready throughout; the first frame that STARTS after the stall is whole
//   - with guard_off, the same stall holds the receiver off instead and
//     drops nothing

`timescale 1ns/1ps

module cam_guard_tb;

    localparam integer W = 40, H = 8, AW = 6;     // a 64-beat FIFO

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rstn = 1'b0;
    reg guard_off = 1'b0;

    reg  [15:0] s_tdata = 16'd0;
    reg         s_tuser = 1'b0, s_tlast = 1'b0, s_tvalid = 1'b0;
    wire        s_tready;
    wire [15:0] m_tdata;
    wire        m_tuser, m_tlast, m_tvalid;
    reg         m_tready = 1'b1;
    wire [31:0] sof_in, sof_out, drop_beats, stall, beats_out;

    // IDLE is below the bench's 4-frame drain gap and above its line gaps,
    // which are zero: the source sends back to back.
    cam_guard #(.DW(16), .AW(AW), .IDLE(200)) dut (
        .clk(clk), .rstn(rstn), .guard_off(guard_off),
        .s_tdata(s_tdata), .s_tuser(s_tuser), .s_tlast(s_tlast),
        .s_tvalid(s_tvalid), .s_tready(s_tready),
        .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tlast(m_tlast),
        .m_tvalid(m_tvalid), .m_tready(m_tready),
        .sof_in(sof_in), .sof_out(sof_out), .drop_beats(drop_beats),
        .stall(stall), .beats_out(beats_out)
    );

    integer errors = 0;
    task check(input [8*64-1:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("  FAIL  %0s: got %0d, expected %0d", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok    %0s = %0d", what, got);
        end
    endtask

    // ---- the sink: counts whole frames, and frames that were not ----------
    integer pos = -1;            // position expected next, -1 = before any SOF
    integer whole = 0, broken = 0, out_frames = 0;
    always @(posedge clk) if (m_tvalid && m_tready) begin
        if (m_tuser) begin
            if (pos > 0 && pos != W * H) broken = broken + 1;   // previous one short
            pos = 0; out_frames = out_frames + 1;
        end
        if (pos >= 0) begin
            if (m_tdata !== pos[15:0] ||
                m_tlast !== ((pos % W) == W - 1)) begin
                broken = broken + 1; pos = -1;
            end else begin
                pos = pos + 1;
                if (pos == W * H) whole = whole + 1;
            end
        end
    end

    // ---- the source: the receiver, which cannot wait ---------------------
    // It sends one beat per clock regardless, as the real one's buffer does;
    // `held` counts clocks it was refused, which in guarded mode must be 0.
    integer held = 0;
    task send_frames(input integer n, input integer start_at);
        integer f, p;
        begin
            for (f = 0; f < n; f = f + 1)
                for (p = (f == 0 ? start_at : 0); p < W * H; p = p + 1) begin
                    @(negedge clk);
                    s_tdata = p; s_tuser = (p == 0); s_tlast = ((p % W) == W - 1);
                    s_tvalid = 1'b1;
                    @(posedge clk);
                    while (!s_tready) begin held = held + 1; @(posedge clk); end
                end
            @(negedge clk); s_tvalid = 1'b0; s_tuser = 1'b0; s_tlast = 1'b0;
        end
    endtask

    task drain; repeat (4 * W * H) @(posedge clk); endtask

    integer w0, b0, d0;

    initial begin
        #50 rstn = 1'b1;
        repeat (4) @(posedge clk);

        $display("--- guarded, sink always ready: frames pass whole");
        send_frames(5, 0); drain;
        check("frames out", out_frames, 5);
        check("whole frames", whole, 5);
        check("broken frames", broken, 0);
        check("beats dropped", drop_beats, 0);
        check("SOF in", sof_in, 5);
        check("SOF out", sof_out, 5);
        check("receiver held off (clocks)", held, 0);

        $display("--- guarded, stream starts mid-frame: cut to whole frames");
        w0 = whole; d0 = drop_beats;
        send_frames(3, 123); drain;
        check("beats dropped before the first SOF", drop_beats - d0, W * H - 123);
        check("whole frames after it", whole - w0, 2);
        check("broken frames", broken, 0);

        $display("--- guarded, sink stalls longer than the FIFO mid-frame");
        // Two FIFO depths from halfway into frame 0: long enough to overflow,
        // over before frame 1 starts.
        w0 = whole; b0 = broken; d0 = drop_beats;
        fork
            send_frames(4, 0);
            begin
                repeat (W * H / 2) @(posedge clk);  // halfway into frame 0
                m_tready = 1'b0;
                repeat (2 * (1 << AW)) @(posedge clk);
                m_tready = 1'b1;
            end
        join
        drain;
        check("receiver held off (clocks)", held, 0);
        if (drop_beats - d0 == 0) begin
            $display("  FAIL  nothing was dropped"); errors = errors + 1;
        end else $display("  ok    %0d beats dropped", drop_beats - d0);
        check("broken frames: only the one the stall cut", broken - b0, 1);
        check("whole frames: the 3 that started after the stall", whole - w0, 3);

        $display("--- guard_off: the same stall holds the receiver off instead");
        guard_off = 1'b1; held = 0;
        w0 = whole; b0 = broken; d0 = drop_beats;
        fork
            send_frames(3, 0);
            begin
                repeat (W * H / 2) @(posedge clk);
                m_tready = 1'b0;
                repeat (3 * (1 << AW)) @(posedge clk);
                m_tready = 1'b1;
            end
        join
        drain;
        if (held == 0) begin
            $display("  FAIL  the receiver was never held off"); errors = errors + 1;
        end else $display("  ok    receiver held off for %0d clocks", held);
        if (stall == 0) begin
            $display("  FAIL  stall counter did not count"); errors = errors + 1;
        end else $display("  ok    stall counter = %0d", stall);
        check("beats dropped", drop_beats - d0, 0);
        check("whole frames", whole - w0, 3);
        check("broken frames", broken - b0, 0);

        if (errors == 0) $display("cam_guard_tb: PASS");
        else             $display("cam_guard_tb: FAIL (%0d)", errors);
        $finish;
    end

endmodule
