`timescale 1ns / 1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
// Module Name: axis_i2s2_rx
// Description: AXI-Stream I2S RECEIVE-ONLY controller for the Pmod I2S2's ADC
//              (line-in). Derived from Digilent's axis_i2s2 module, with the
//              transmit (playback/DAC) path removed.
//              Generates the mclk/lrck/sclk clocks required to place the ADC
//              on the Pmod I2S2 into slave mode, and shifts in serial audio
//              data on rx_sdin.
//              This module only supports 44.1kHz sample rate, and expects the
//              frequency of axis_clk to be approx 22.591MHz.
//              At the end of each I2S frame, a 2-word packet is made available
//              on the AXIS master interface: left channel word first
//              (rx_axis_m_last == 0), followed by right channel word
//              (rx_axis_m_last == 1). Each word is a 24-bit sample
//              (sign-extended into a 32-bit AXIS word, upper 8 bits zero).
//////////////////////////////////////////////////////////////////////////////////

module axis_i2s2_rx (
    input  wire        axis_clk, // require: approx 22.591MHz
    input  wire        axis_resetn,

    output wire [31:0] rx_axis_m_data,
    output reg         rx_axis_m_valid = 1'b0,
    input  wire        rx_axis_m_ready,
    output reg         rx_axis_m_last = 1'b0,

    output wire rx_mclk, // JA[4]
    output wire rx_lrck, // JA[5]
    output wire rx_sclk, // JA[6]
    input  wire rx_sdin  // JA[7]
);
    reg [8:0] count = 9'd0;
    localparam EOF_COUNT = 9'd455; // end of full I2S frame

    always@(posedge axis_clk)
        count <= count + 1;

    wire lrck = count[8];
    wire sclk = count[2];
    wire mclk = axis_clk;
    assign rx_lrck = lrck;
    assign rx_sclk = sclk;
    assign rx_mclk = mclk;

    /* SYNCHRONIZE DATA IN TO AXIS CLOCK DOMAIN */
    reg [2:0] din_sync_shift = 3'd0;
    wire din_sync = din_sync_shift[2];
    always@(posedge axis_clk)
        din_sync_shift <= {din_sync_shift[1:0], rx_sdin};

    /* I2S RECEIVE SHIFT REGISTERS */
    reg [23:0] rx_data_l_shift = 24'b0;
    reg [23:0] rx_data_r_shift = 24'b0;
    always@(posedge axis_clk)
        if (count[2:0] == 3'b011 && count[7:3] <= 5'd24 && count[7:3] >= 5'd1)
            if (lrck == 1'b1)
                rx_data_r_shift <= {rx_data_r_shift, din_sync};
            else
                rx_data_l_shift <= {rx_data_l_shift, din_sync};

    /* AXIS MASTER CONTROLLER */
    reg [31:0] rx_data_l = 32'b0;
    reg [31:0] rx_data_r = 32'b0;
    always@(posedge axis_clk)
        if (axis_resetn == 1'b0) begin
            rx_data_l <= 32'b0;
            rx_data_r <= 32'b0;
        end else if (count == EOF_COUNT && rx_axis_m_valid == 1'b0) begin
            rx_data_l <= {8'b0, rx_data_l_shift};
            rx_data_r <= {8'b0, rx_data_r_shift};
        end

    assign rx_axis_m_data = (rx_axis_m_last == 1'b1) ? rx_data_r : rx_data_l;

    always@(posedge axis_clk)
        if (axis_resetn == 1'b0)
            rx_axis_m_valid <= 1'b0;
        else if (count == EOF_COUNT && rx_axis_m_valid == 1'b0)
            rx_axis_m_valid <= 1'b1;
        else if (rx_axis_m_valid == 1'b1 && rx_axis_m_ready == 1'b1 && rx_axis_m_last == 1'b1)
            rx_axis_m_valid <= 1'b0;

    always@(posedge axis_clk)
        if (axis_resetn == 1'b0)
            rx_axis_m_last <= 1'b0;
        else if (count == EOF_COUNT && rx_axis_m_valid == 1'b0)
            rx_axis_m_last <= 1'b0;
        else if (rx_axis_m_valid == 1'b1 && rx_axis_m_ready == 1'b1)
            rx_axis_m_last <= ~rx_axis_m_last;

endmodule