`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/21/2026 03:33:59 PM
// Design Name: 
// Module Name: tb_uart_tx
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


module tb_uart_tx;

    reg clk = 0;
    reg start = 0;
    reg [7:0] txin = 8'h00;
    wire tx;
    wire txdone;
    
    uart_tx dut(.clk(clk), .start(start), .txin(txin), .tx(tx), .txDone(txdone));
    
    always #5 clk = ~clk;
    integer i;
    
    initial begin
        start = 0;
        txin = 8'h00;
        
        #100;
        
        // First packet
        for (i = 0; i < 5; i = i + 1) begin
            txin = $urandom_range(255, 0);
            start = 1;
            #10;
            start = 0;
            
            #2000000;
        end
        $stop;
    end
endmodule
