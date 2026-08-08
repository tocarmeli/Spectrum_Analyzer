`timescale 1ns / 1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
// Module Name: top
// Description: Reads the left channel of the Pmod I2S2's ADC (line-in),
//              decimates the 44.1kHz sample stream, and prints each captured
//              sample as a 6-digit hex value ("XXXXXX\r\n") over UART at a
//              high baud rate, for viewing in a terminal program (e.g. PuTTY
//              set to 921600 baud, 8N1).
//
// Clocking:    - clk: 100 MHz onboard oscillator (R2), drives system logic
//                and the UART directly.
//              - An MMCM generates axis_clk (~22.5705 MHz, close to the
//                22.591 MHz the I2S2 RX module wants for 44.1kHz sample
//                rate) from the same 100 MHz input.
//              - A sample value + toggle bit are crossed from the axis_clk
//                domain into the clk domain with a simple double-flop
//                synchronizer (safe here since the audio sample rate is far
//                slower than either clock).
//////////////////////////////////////////////////////////////////////////////////

module top (
    input  wire clk,      // 100 MHz onboard oscillator (R2)
    input  wire rst,      // external, active-high reset

    output wire tx,        // USB-UART TX

    output wire rx_mclk,   // Pmod I2S2 JA[4]
    output wire rx_lrck,   // Pmod I2S2 JA[5]
    output wire rx_sclk,   // Pmod I2S2 JA[6]
    input  wire rx_sdin    // Pmod I2S2 JA[7]
);

    localparam integer CLK_FREQ         = 100_000_000;
    localparam integer BAUD             = 921_600;
    localparam integer DECIMATION_FACTOR = 5; // 44.1kHz / 5 = ~8.82kSa/s printed

    // ------------------------------------------------------------------
    // Clock generation: 100 MHz -> ~22.5705 MHz audio bit clock via MMCM
    // (100MHz x 9 / 39.875 = 22.5705MHz, ~0.04% off the 22.591MHz target)
    // ------------------------------------------------------------------
    wire clk_ibuf;
    IBUF clkin_ibuf (
        .I (clk),
        .O (clk_ibuf)
    );

    wire mmcm_fb;
    wire axis_clk_raw;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (9.0),
        .CLKFBOUT_PHASE    (0.0),
        .CLKIN1_PERIOD     (10.000),   // 100 MHz input period, in ns
        .CLKOUT0_DIVIDE_F  (39.875),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE     (0.0),
        .CLKOUT4_CASCADE   ("FALSE"),
        .DIVCLK_DIVIDE     (1),
        .REF_JITTER1       (0.0),
        .STARTUP_WAIT      ("FALSE")
    ) mmcm_inst (
        .CLKOUT0  (axis_clk_raw),
        .CLKFBOUT (mmcm_fb),
        .LOCKED   (mmcm_locked),
        .CLKIN1   (clk_ibuf),
        .CLKFBIN  (mmcm_fb),
        .PWRDWN   (1'b0),
        .RST      (rst)
    );

    wire axis_clk;
    BUFG axis_clk_bufg (
        .I (axis_clk_raw),
        .O (axis_clk)
    );

    // Active-low reset for the audio domain, held until the MMCM locks
    wire axis_resetn = ~(rst | ~mmcm_locked);

    // ------------------------------------------------------------------
    // I2S2 RX (line-in)
    // ------------------------------------------------------------------
    wire [31:0] i2s_data;
    wire        i2s_valid;
    wire        i2s_last;

    axis_i2s2_rx i2s_rx_inst (
        .axis_clk       (axis_clk),
        .axis_resetn    (axis_resetn),

        .rx_axis_m_data (i2s_data),
        .rx_axis_m_valid(i2s_valid),
        .rx_axis_m_ready(1'b1),      // always ready; we decimate ourselves
        .rx_axis_m_last (i2s_last),

        .rx_mclk (rx_mclk),
        .rx_lrck (rx_lrck),
        .rx_sclk (rx_sclk),
        .rx_sdin (rx_sdin)
    );

    // ------------------------------------------------------------------
    // Decimate the left-channel stream (audio clock domain)
    // ------------------------------------------------------------------
    reg [2:0]  deci_cnt     = 3'd0;
    reg [23:0] sample_reg   = 24'd0;
    reg        sample_toggle = 1'b0;

    always @(posedge axis_clk) begin
        if (~axis_resetn) begin
            deci_cnt      <= 3'd0;
            sample_reg    <= 24'd0;
            sample_toggle <= 1'b0;
        end else if (i2s_valid && !i2s_last) begin
            // A new left-channel word has just landed
            if (deci_cnt == DECIMATION_FACTOR - 1) begin
                deci_cnt      <= 3'd0;
                sample_reg    <= i2s_data[23:0];
                sample_toggle <= ~sample_toggle;
            end else begin
                deci_cnt <= deci_cnt + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Cross sample_toggle / sample_reg into the 100 MHz clk domain
    // ------------------------------------------------------------------
    // sample_reg only changes once per decimated audio sample (far slower
    // than clk), and is written on the same axis_clk edge as sample_toggle,
    // so it is guaranteed stable by the time the synchronized toggle edge
    // is detected here -- no separate data synchronizer is needed.
    reg [2:0] toggle_sync;
    wire      sample_strobe = toggle_sync[2] ^ toggle_sync[1];

    always @(posedge clk_ibuf or posedge rst) begin
        if (rst)
            toggle_sync <= 3'd0;
        else
            toggle_sync <= {toggle_sync[1:0], sample_toggle};
    end

    // ------------------------------------------------------------------
    // Hex-ASCII print FSM (100 MHz domain): "XXXXXX\r\n" (8 bytes)
    // ------------------------------------------------------------------
    function [7:0] hex_ascii;
        input [3:0] nibble;
        begin
            hex_ascii = (nibble < 4'd10) ? (8'd48 + nibble) : (8'd55 + nibble); // '0'-'9','A'-'F'
        end
    endfunction

    reg [7:0] msg [0:7];
    reg [3:0] byte_idx;

    localparam S_IDLE = 2'd0;
    localparam S_SEND = 2'd1;
    localparam S_WAIT = 2'd2;

    reg [1:0] state;
    reg       start;
    wire      txDone;

    always @(posedge clk_ibuf or posedge rst) begin
        if (rst) begin
            state    <= S_IDLE;
            start    <= 1'b0;
            byte_idx <= 4'd0;
        end else begin
            start <= 1'b0; // default: 1-cycle pulse only

            case (state)
                S_IDLE: begin
                    if (sample_strobe) begin
                        // Note: hex_data isn't updated with the new sample
                        // until the following clock, but msg formatting
                        // below reads hex_data one cycle later in S_SEND
                        // via the registered value, which is fine because
                        // we don't start until byte_idx=0 is issued below.
                        msg[0] <= hex_ascii(sample_reg[23:20]);
                        msg[1] <= hex_ascii(sample_reg[19:16]);
                        msg[2] <= hex_ascii(sample_reg[15:12]);
                        msg[3] <= hex_ascii(sample_reg[11:8]);
                        msg[4] <= hex_ascii(sample_reg[7:4]);
                        msg[5] <= hex_ascii(sample_reg[3:0]);
                        msg[6] <= 8'h0D; // CR
                        msg[7] <= 8'h0A; // LF
                        byte_idx <= 4'd0;
                        state    <= S_SEND;
                    end
                end

                S_SEND: begin
                    start <= 1'b1;
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (txDone) begin
                        if (byte_idx == 4'd7) begin
                            state <= S_IDLE;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= S_SEND;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD(BAUD)
    ) uart_tx_inst (
        .clk    (clk_ibuf),
        .rst    (rst),
        .start  (start),
        .txin   (msg[byte_idx]),
        .tx     (tx),
        .txDone (txDone)
    );

endmodule