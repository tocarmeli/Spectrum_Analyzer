`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: uart_tx
// Description: Simple parameterized UART transmitter.
//              8 data bits, no parity, 1 stop bit (8N1).
//              Pulse 'start' for one clock while 'txin' is valid to send a byte.
//              'txDone' pulses high for one clock when the byte has finished
//              transmitting (including the stop bit).
//////////////////////////////////////////////////////////////////////////////////

module uart_tx #(
    parameter integer CLK_FREQ = 100_000_000,
    parameter integer BAUD     = 9600
)(
    input  wire       clk,
    input  wire       rst,

    input  wire       start,
    input  wire [7:0] txin,

    output reg        tx,
    output reg        txDone
);

    localparam integer BAUD_COUNT = CLK_FREQ / BAUD;

    localparam STATE_IDLE  = 2'b00;
    localparam STATE_START = 2'b01;
    localparam STATE_DATA  = 2'b10;
    localparam STATE_STOP  = 2'b11;

    reg [1:0]  state;
    reg [31:0] baud_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  tx_data_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= STATE_IDLE;
            tx          <= 1'b1;
            txDone      <= 1'b0;
            baud_cnt    <= 32'd0;
            bit_idx     <= 3'd0;
            tx_data_reg <= 8'd0;
        end else begin
            // Default 1-cycle pulse reset
            txDone <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    tx       <= 1'b1;
                    baud_cnt <= 32'd0;
                    bit_idx  <= 3'd0;

                    if (start) begin
                        tx_data_reg <= txin;
                        tx          <= 1'b0; // Output start bit immediately
                        state       <= STATE_START;
                    end
                end

                STATE_START: begin
                    tx <= 1'b0;
                    if (baud_cnt == BAUD_COUNT - 1) begin
                        baud_cnt <= 32'd0;
                        state    <= STATE_DATA;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                STATE_DATA: begin
                    tx <= tx_data_reg[bit_idx];
                    if (baud_cnt == BAUD_COUNT - 1) begin
                        baud_cnt <= 32'd0;
                        if (bit_idx == 3'd7) begin
                            bit_idx <= 3'd0;
                            state   <= STATE_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                STATE_STOP: begin
                    tx <= 1'b1; // Output stop bit
                    if (baud_cnt == BAUD_COUNT - 1) begin
                        baud_cnt <= 32'd0;
                        txDone   <= 1'b1;
                        state    <= STATE_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule