`timescale 1ns / 1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
// Module Name: top
// Description: Reads the left channel of the Pmod I2S2's ADC (line-in) at
//              its full ~44.1kHz rate (no decimation, so Nyquist ~22kHz
//              covers the requested 0-20kHz range) and runs it through a
//              256-point Xilinx FFT core (xfft_0, Radix-2 Burst I/O). The
//              FFT completes a frame ~172 times/sec; since printing every
//              bin of every frame would exceed what 921600 baud can
//              sustain, only 1 out of every FRAME_THROTTLE completed
//              frames is actually transmitted. Each printed value is
//              "IIMMMMMM\r\n" (2 hex digits of true bin index, from the
//              core's XK_INDEX output, followed by 6 hex digits of
//              magnitude); only bins with index < FFT_LEN/2 are sent
//              (the rest mirror them, since the input signal is real).
//              View in a terminal program (e.g. PuTTY set to 921600 baud,
//              8N1).
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
    localparam integer DECIMATION_FACTOR = 1; // no decimation: Nyquist ~22kHz, covers 0-20kHz

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
    // FFT (Xilinx LogiCORE, 256-pt, Radix-2 Burst I/O, 16-bit real/imag,
    // Scaled arithmetic, Natural Order output). Instance name must match
    // the IP's Component Name (xfft_0) set in the IP catalog.
    // ------------------------------------------------------------------
    localparam integer FFT_LEN = 256;

    reg  [31:0] fft_s_tdata;
    reg         fft_s_tvalid;
    wire        fft_s_tready;
    reg         fft_s_tlast;

    wire [31:0] fft_m_tdata;
    wire        fft_m_tvalid;
    reg         fft_m_tready;
    wire        fft_m_tlast;
    wire [7:0]  fft_m_tuser; // XK_INDEX: true bin index for this result

    xfft_0 fft_inst (
        .aclk               (clk_ibuf),
        .s_axis_config_tdata (16'd0),
        .s_axis_config_tvalid(1'b0),
        .s_axis_config_tready(),
        .s_axis_data_tdata  (fft_s_tdata),
        .s_axis_data_tvalid (fft_s_tvalid),
        .s_axis_data_tready (fft_s_tready),
        .s_axis_data_tlast  (fft_s_tlast),
        .m_axis_data_tdata  (fft_m_tdata),
        .m_axis_data_tvalid (fft_m_tvalid),
        .m_axis_data_tready (fft_m_tready),
        .m_axis_data_tlast  (fft_m_tlast),
        .m_axis_data_tuser  (fft_m_tuser)
    );

    // ------------------------------------------------------------------
    // Magnitude approximation: |re| + |im| (cheap, no multiplier/sqrt)
    // ------------------------------------------------------------------
    function [15:0] abs16;
        input signed [15:0] val;
        begin
            abs16 = val[15] ? (~val + 16'd1) : val;
        end
    endfunction

    function [7:0] hex_ascii;
        input [3:0] nibble;
        begin
            hex_ascii = (nibble < 4'd10) ? (8'd48 + nibble) : (8'd55 + nibble); // '0'-'9','A'-'F'
        end
    endfunction

    reg  [15:0] bin_re_reg, bin_im_reg;
    reg         bin_last_reg;
    reg  [7:0]  bin_idx_reg;
    wire [16:0] bin_mag = abs16(bin_re_reg) + abs16(bin_im_reg);
    wire [23:0] bin_mag24 = {7'b0, bin_mag};

    // ------------------------------------------------------------------
    // Loader / reader / UART-print FSM (100 MHz domain)
    //   S_FILL       : wait for a decimated sample, push it into the FFT
    //   S_PUSH       : AXI4-Stream handshake for one input sample
    //   S_DRAIN_WAIT : wait for one output bin from the FFT
    //   S_DRAIN_HOLD : decide whether this bin gets printed
    //   S_SEND/S_WAIT_TX : send "IIMMMMMM\r\n" for the current bin over
    //                       UART (2 hex digits of true bin index, from
    //                       the FFT core's XK_INDEX/tuser field, followed
    //                       by 6 hex digits of magnitude)
    // Only bins with true index < FFT_LEN/2 are printed (the rest mirror
    // them, since the input signal is real). We read every bin the core
    // emits and use its self-reported index rather than assuming any
    // particular output ordering, so this is correct regardless of
    // whether the core is actually emitting in natural or bit-reversed
    // order.
    // ------------------------------------------------------------------
    localparam S_FILL       = 3'd0;
    localparam S_PUSH       = 3'd1;
    localparam S_DRAIN_WAIT = 3'd2;
    localparam S_DRAIN_HOLD = 3'd3;
    localparam S_SEND       = 3'd4;
    localparam S_WAIT_TX    = 3'd5;

    reg [2:0] state;
    reg [7:0] in_idx;
    reg [7:0] msg [0:9];
    reg [3:0] byte_idx;
    reg       start;
    wire      txDone;

    // At full (undecimated) audio rate, the FFT completes a new frame
    // ~172 times/sec -- printing every bin of every frame would need
    // ~220KB/s, well over the ~92KB/s that 921600 baud can sustain. Only
    // print 1 out of every FRAME_THROTTLE completed frames.
    localparam integer FRAME_THROTTLE = 4;
    reg [1:0] frame_skip_cnt;
    wire      frame_print_en = (frame_skip_cnt == 2'd0);

    always @(posedge clk_ibuf or posedge rst) begin
        if (rst) begin
            state          <= S_FILL;
            in_idx         <= 8'd0;
            byte_idx       <= 4'd0;
            fft_s_tvalid   <= 1'b0;
            fft_s_tlast    <= 1'b0;
            fft_m_tready   <= 1'b0;
            start          <= 1'b0;
            frame_skip_cnt <= 2'd0;
        end else begin
            start <= 1'b0; // default: 1-cycle pulse only

            case (state)
                // ---- fill a frame with decimated audio samples ----
                S_FILL: begin
                    fft_s_tvalid <= 1'b0;
                    if (sample_strobe) begin
                        // sample_reg[23:8]: top 16 bits of the 24-bit
                        // sample as the real input; imaginary tied to 0
                        fft_s_tdata  <= {16'sd0, sample_reg[23:8]};
                        fft_s_tlast  <= (in_idx == FFT_LEN - 1);
                        fft_s_tvalid <= 1'b1;
                        state        <= S_PUSH;
                    end
                end

                S_PUSH: begin
                    if (fft_s_tvalid && fft_s_tready) begin
                        fft_s_tvalid <= 1'b0;
                        if (fft_s_tlast) begin
                            in_idx       <= 8'd0;
                            fft_m_tready <= 1'b1;
                            state        <= S_DRAIN_WAIT;
                        end else begin
                            in_idx <= in_idx + 1'b1;
                            state  <= S_FILL;
                        end
                    end
                end

                // ---- read one bin back from the FFT ----
                S_DRAIN_WAIT: begin
                    if (fft_m_tvalid && fft_m_tready) begin
                        bin_re_reg   <= fft_m_tdata[15:0];
                        bin_im_reg   <= fft_m_tdata[31:16];
                        bin_idx_reg  <= fft_m_tuser;
                        bin_last_reg <= fft_m_tlast;
                        fft_m_tready <= 1'b0; // hold off while we handle it
                        state        <= S_DRAIN_HOLD;
                    end
                end

                S_DRAIN_HOLD: begin
                    if (frame_print_en && bin_idx_reg < FFT_LEN / 2) begin
                        msg[0]   <= hex_ascii(bin_idx_reg[7:4]);
                        msg[1]   <= hex_ascii(bin_idx_reg[3:0]);
                        msg[2]   <= hex_ascii(bin_mag24[23:20]);
                        msg[3]   <= hex_ascii(bin_mag24[19:16]);
                        msg[4]   <= hex_ascii(bin_mag24[15:12]);
                        msg[5]   <= hex_ascii(bin_mag24[11:8]);
                        msg[6]   <= hex_ascii(bin_mag24[7:4]);
                        msg[7]   <= hex_ascii(bin_mag24[3:0]);
                        msg[8]   <= 8'h0D; // CR
                        msg[9]   <= 8'h0A; // LF
                        byte_idx <= 4'd0;
                        state    <= S_SEND;
                    end else if (bin_last_reg) begin
                        frame_skip_cnt <= (frame_skip_cnt == FRAME_THROTTLE - 1) ? 2'd0 : frame_skip_cnt + 1'b1;
                        state          <= S_FILL;
                    end else begin
                        fft_m_tready <= 1'b1;
                        state        <= S_DRAIN_WAIT;
                    end
                end

                S_SEND: begin
                    start <= 1'b1;
                    state <= S_WAIT_TX;
                end

                S_WAIT_TX: begin
                    if (txDone) begin
                        if (byte_idx == 4'd9) begin
                            if (bin_last_reg) begin
                                frame_skip_cnt <= (frame_skip_cnt == FRAME_THROTTLE - 1) ? 2'd0 : frame_skip_cnt + 1'b1;
                                state          <= S_FILL;
                            end else begin
                                fft_m_tready <= 1'b1;
                                state        <= S_DRAIN_WAIT;
                            end
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= S_SEND;
                        end
                    end
                end

                default: state <= S_FILL;
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
