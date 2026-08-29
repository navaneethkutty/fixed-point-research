`timescale 1ns / 1ps

module address_gen(

    input  wire        clk,
    input  wire [31:0] x,

    output reg  [11:0] addr

);

always @(posedge clk)
begin
    // Assumes x is always between 0.5 and 2.5 (Q16.16)
    addr <= (x - 32'h00008000) >> 5;
end

endmodule