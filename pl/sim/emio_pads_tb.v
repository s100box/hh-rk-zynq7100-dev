// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bench for emio_pads: each EMIO line drives its pad when GPIO_T is 0,
// releases it when GPIO_T is 1, and always reads the pad back -- per bit, so
// an I2C line can be released while the one beside it is driven.
//
// The pads carry pull-ups here, as the board's I2C lines do, so a released pad
// reads 1 until something outside pulls it down.

`timescale 1ns/1ps

module emio_pads_tb;

    localparam integer N = 3;

    reg  [N-1:0] gpio_o = {N{1'b0}};
    reg  [N-1:0] gpio_t = {N{1'b1}};
    wire [N-1:0] gpio_i;
    tri1 [N-1:0] pad;                     // the board's pull-ups
    reg  [N-1:0] ext_low = {N{1'b0}};     // a device pulling a pad low

    genvar k;
    generate for (k = 0; k < N; k = k + 1) begin : ext
        assign pad[k] = ext_low[k] ? 1'b0 : 1'bz;
    end endgenerate

    emio_pads #(.N(N)) dut (
        .gpio_o (gpio_o), .gpio_t (gpio_t), .gpio_i (gpio_i), .pad (pad)
    );

    integer errors = 0;
    task check(input [8*64-1:0] what, input [N-1:0] got, input [N-1:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL  %0s: got %b, expected %b", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok    %0s = %b", what, got);
        end
    endtask

    initial begin
        #1;
        check("released pads read the pull-ups", gpio_i, 3'b111);
        check("released pads are not driven", pad, 3'b111);

        ext_low = 3'b010; #1;
        check("a device pulling pad 1 low is read back", gpio_i, 3'b101);
        ext_low = 3'b000; #1;

        gpio_t = 3'b110; gpio_o = 3'b000; #1;
        check("pad 0 driven low, the others released", pad, 3'b110);
        check("... and read back as driven", gpio_i, 3'b110);

        gpio_o = 3'b111; #1;
        check("pad 0 driven high", pad, 3'b111);
        // A released pad reads 1 through its pull-up whether or not it is
        // driven; a device pulling it low shows which.
        ext_low = 3'b100; #1;
        check("GPIO_O of a released pad goes nowhere: pad 2 follows the device", pad, 3'b011);
        ext_low = 3'b000; #1;

        gpio_t = 3'b000; gpio_o = 3'b101; #1;
        check("all three driven, each its own level", pad, 3'b101);
        check("... and read back", gpio_i, 3'b101);

        if (errors == 0) $display("emio_pads_tb: PASS");
        else             $display("emio_pads_tb: FAIL (%0d)", errors);
        $finish;
    end

endmodule
