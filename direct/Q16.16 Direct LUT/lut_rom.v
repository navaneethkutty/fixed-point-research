`timescale 1ns / 1ps

module lut_rom
(
    input wire clk,
    input wire [11:0] addr,
    output reg [31:0] data
);

reg [31:0] rom [0:4095];

initial
begin
    $readmemh("reciprocal_lut.mem", rom);
end

always @(posedge clk)
begin
    data <= rom[addr];
end

endmodule
