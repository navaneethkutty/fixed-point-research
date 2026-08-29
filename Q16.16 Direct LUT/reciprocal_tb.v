`timescale 1ns / 1ps

module reciprocal_tb;

parameter NUM_TESTS = 1000000;

reg clk;
reg rst;
reg [31:0] x;

wire [31:0] y;

reg [31:0] input_mem [0:NUM_TESTS-1];

integer infile;
integer outfile;
integer i;

reciprocal_core dut(
    .clk(clk),
    .rst(rst),
    .x(x),
    .y(y)
);

always #5 clk = ~clk;

initial begin

    clk = 0;
    rst = 1;
    x = 0;

    $readmemh("q16_16_input.mem", input_mem);

    outfile = $fopen("lut_output.mem","w");

    //------------------------------------
    // Reset
    //------------------------------------

    repeat(2) @(posedge clk);

    rst = 0;

    //------------------------------------
    // Feed all inputs
    //------------------------------------

    for(i=0;i<NUM_TESTS;i=i+1)
    begin

        x = input_mem[i];

        @(posedge clk);

        if(i>=3)
            $fdisplay(outfile,"%08h",y);

    end

    //------------------------------------
    // Flush pipeline
    //------------------------------------

    repeat(3)
    begin
        @(posedge clk);
        $fdisplay(outfile,"%08h",y);
    end

    $fclose(outfile);

    $display("Finished Processing Dataset");
    #20;
    $finish;

end

endmodule