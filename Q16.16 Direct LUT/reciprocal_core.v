`timescale 1ns / 1ps

module reciprocal_core(

    input wire clk,
    input wire rst,
    input wire [31:0] x,

    output reg [31:0] y

);

wire [11:0] addr;
wire [31:0] rom_data;

// Extra pipeline register
reg [31:0] rom_data_reg;

address_gen ADDRESS
(
    .clk(clk),
    .x(x),
    .addr(addr)
);

lut_rom ROM
(
    .clk(clk),
    .addr(addr),
    .data(rom_data)
);

always @(posedge clk)
begin

    if(rst)
    begin
        rom_data_reg <= 32'd0;
        y            <= 32'd0;
    end
    else
    begin
        rom_data_reg <= rom_data;
        y            <= rom_data_reg;
    end

end

endmodule