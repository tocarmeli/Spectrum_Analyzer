`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/21/2026 03:19:41 PM
// Design Name: 
// Module Name: uart_tx
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module uart_tx(
    input clk,
    input start,
    input [7:0] txin,
    output reg tx,
    output txDone
    );
    
    parameter clk_freq = 100_000_000, baud = 9600;
    parameter wait_cnt = clk_freq / baud - 1;
    
    reg bitDone = 1'b0;
    integer cnt = 0;
    parameter idle = 0, send = 1, check = 2;
    reg [1:0] state = idle;
    
    // Baud trigger block
    always @(posedge clk) begin
        if (state == idle) begin
            cnt <= 0;
        end else begin
            if (cnt == wait_cnt) begin
                cnt <= 0;
                bitDone = 1'b1;
            end else begin
                cnt <= cnt + 1;
                bitDone <= 1'b0;
            end
        end
    end
    
    // UART TX FSM logic
    reg [9:0] txData;
    reg [3:0] bitIdx;
    reg [9:0] shiftIdx = 0;
    
    always @(posedge clk) begin
        case (state)
            idle: begin
                tx <= 1'b1;
                txData <= 0;
                bitIdx <= 0;
                shiftIdx <= 0;
                
                if (start == 1'b1) begin
                    txData <= {1'b1, txin, 1'b0};
                    state <= send;
                end else begin
                    state <= idle;
                end
            end
            
            send: begin
                tx <= txData[bitIdx];

                if (bitDone)
                begin
                    if (bitIdx == 9)
                    begin
                        state <= idle;
                        bitIdx <= 0;
                    end
                    else
                    begin
                        bitIdx <= bitIdx + 1;
                    end
                end
            end
            
            check: begin
                if (bitIdx < 9) begin
                    if (bitDone == 1'b1) begin
                        state <= send;
                        bitIdx <= bitIdx + 1;
                    end
                end else begin
                    state <= idle;
                    bitIdx <= 0;
                end
            end
            
            default: state <= idle;
        
        endcase
    end
    
    assign txDone = (bitIdx == 9 && bitDone == 1'b1) ? 1'b1 : 1'b0;
endmodule
