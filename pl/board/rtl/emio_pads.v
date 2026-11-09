// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Bidirectional pads driven by the PS7's EMIO GPIO: one IOBUF per bit, with
// GPIO_O as data, GPIO_T as the tristate (1 = input) and GPIO_I as readback.
//
// Used for the I2C buses Linux bit-bangs with `i2c-gpio` (the PS has no I2C
// controller wired to them, and a soft master would be more logic for a few
// dozen transfers at boot), the ADV7611 and camera control pins, the 40-pin
// header and the SFP cages' TX_DISABLE.
//
// ⚠ Open-drain lines depend on the board's pull-ups: with GPIO_OPEN_DRAIN,
// gpiolib releases a line (GPIO_T = 1) rather than driving it high.

`default_nettype none

module emio_pads #(
    parameter integer N = 1
) (
    input  wire [N-1:0] gpio_o,   // from PS7 GPIO_O
    input  wire [N-1:0] gpio_t,   // from PS7 GPIO_T, 1 = release the pin
    output wire [N-1:0] gpio_i,   // to PS7 GPIO_I
    inout  wire [N-1:0] pad
);

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_pad
            IOBUF pad_buf (
                .I  (gpio_o[i]),
                .T  (gpio_t[i]),
                .O  (gpio_i[i]),
                .IO (pad[i])
            );
        end
    endgenerate

endmodule

`default_nettype wire
