`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/21/2026 03:47:03 PM
// Design Name: 
// Module Name: top
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


module top(
    input clk, rst,
    output tx
    );
    
    reg [7:0] cnt = 8'h00;
    
    // 0.5 second timer on 100 MHz clk
    reg [25:0] timer = 0;
    reg send_tick = 0;
    reg start = 0;
    wire txdone;
    
    // 0.5 second generator
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            timer <= 0;
            send_tick <= 1'b0;
        end else if (timer == 50_000_000 - 1) begin
            timer <= 0;
            send_tick <= 1'b1;
        end else begin
            timer <= timer + 1;
            send_tick <= 1'b0;
        end
        
    end
    
    // Counter
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt <= 8'h00;
        end else begin
            if (send_tick) begin
                cnt <= cnt + 1;
                start <= 1'b1;
            end
        end
    end
    
    
    uart_tx dut (
        .clk(clk),
        .start(start),
        .txin(cnt),
        .tx(tx),
        .txDone(txdone)
    );
    
    
endmodule
