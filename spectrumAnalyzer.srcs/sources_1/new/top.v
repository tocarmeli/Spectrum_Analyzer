`timescale 1ns / 1ps

module uart_top (
    input clk,
    input rst,
    output tx
);

    // Instantiate UART TX
    reg start;
    reg [7:0] txin;
    wire txDone;

    uart_tx #(
        .clk_freq(100_000_000),
        .baud(9600)
    ) uart_inst (
        .clk(clk),
        .rst(rst),
        .start(start),
        .txin(txin),
        .tx(tx),
        .txDone(txDone)
    );

    // 0.5 second timer (50 million cycles @ 100 MHz)
    reg [25:0] half_sec_cnt = 0;
    wire half_sec_tick = (half_sec_cnt == 50_000_000 - 1);

    always @(posedge clk or posedge rst) begin
        if (rst)
            half_sec_cnt <= 0;
        else if (half_sec_tick)
            half_sec_cnt <= 0;
        else
            half_sec_cnt <= half_sec_cnt + 1;
    end

    // Number generator 0 → 10
    reg [3:0] num = 0;
    reg send_state = 0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            num <= 0;
            start <= 0;
            txin <= 0;
            send_state <= 0;
        end else begin
            start <= 0; // default pulse low

            if (half_sec_tick && send_state == 0) begin
                send_state <= 1;

                // Convert number to ASCII
                if (num < 10)
                    txin <= num + 8'd48;   // '0' = 48
                else
                    txin <= "1"; // fallback (not used here)

                start <= 1;
            end

            // wait for UART to finish before incrementing
            if (send_state && txDone) begin
                send_state <= 0;

                if (num == 10)
                    num <= 0;
                else
                    num <= num + 1;
            end
        end
    end

endmodule