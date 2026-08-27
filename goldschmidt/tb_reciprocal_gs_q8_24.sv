`timescale 1ns / 1ps

module tb_reciprocal_gs_q8_24;

    localparam int N = 1_000_001;
    localparam int WARMUP_SAMPLES = 30;
    localparam real CLK_PERIOD_NS = 2.580;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    logic        valid_in;
    logic [31:0] x_in;
    logic        valid_out;
    logic [31:0] recip_out;

    reciprocal_gs_q8_24 #(
        .IDX_BITS(8),
        .SHIFT(17)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .x_in      (x_in),
        .valid_out (valid_out),
        .recip_out (recip_out)
    );

    logic [31:0] input_mem [0:N-1];
    logic [31:0] expected_mem [0:N-1];

    integer csv_fd;

    int input_index;
    int output_index;
    int scored_count;

    int exact_count;
    int within1_count;
    int within2_count;
    int within4_count;
    int within8_count;
    int fail_count;

    longint signed error_lsb;
    longint unsigned abs_error_lsb;
    longint unsigned max_error_lsb;

    int max_error_index;

    logic [31:0] max_error_x_hex;
    logic [31:0] max_error_golden_hex;
    logic [31:0] max_error_hw_hex;

    initial begin
        $display("==============================================================");
        $display(" Q8.24 GOLDSCHMIDT 1,000,001-POINT TEST");
        $display("==============================================================");
        $display("Warm-up samples excluded from statistics: %0d", WARMUP_SAMPLES);
        $display("Loading q8_24_input.mem...");

        $readmemh("q8_24_input.mem", input_mem);

        $display("Loading q8_24_expected.mem...");

        $readmemh("q8_24_expected.mem", expected_mem);

        $display("Memory loading complete.");
        $display("==============================================================");

        csv_fd = $fopen("q8_24_gs_results.csv", "w");

        if (csv_fd == 0) begin
            $fatal(1, "ERROR: Could not create q8_24_gs_results.csv");
        end

        $fwrite(
            csv_fd,
            "idx,x_hex,golden_hex,hw_hex,error_lsb,abs_err_lsb\n"
        );
    end

    initial begin
        valid_in = 1'b0;
        x_in = 32'd0;
        input_index = 0;

        repeat (10)
            @(posedge clk);

        rst_n = 1'b1;

        $display("Global initialization complete.");
        $display("");

        for (int i = 0; i < N; i++) begin

            @(negedge clk);

            valid_in = 1'b1;
            x_in = input_mem[i];

            input_index = i + 1;
        end

        @(negedge clk);

        valid_in = 1'b0;
        x_in = 32'd0;
    end

    initial begin

        output_index = 0;
        scored_count = 0;

        exact_count = 0;
        within1_count = 0;
        within2_count = 0;
        within4_count = 0;
        within8_count = 0;
        fail_count = 0;

        max_error_lsb = 0;
        max_error_index = 0;

        max_error_x_hex = 32'd0;
        max_error_golden_hex = 32'd0;
        max_error_hw_hex = 32'd0;

        wait (rst_n == 1'b1);

        while (output_index < N) begin

            @(posedge clk);

            if (valid_out) begin

                error_lsb =
                    $signed({1'b0, recip_out}) -
                    $signed({1'b0, expected_mem[output_index]});

                if (error_lsb < 0)
                    abs_error_lsb = -error_lsb;
                else
                    abs_error_lsb = error_lsb;

                $fwrite(
                    csv_fd,
                    "%0d,%08h,%08h,%08h,%0d,%0d\n",
                    output_index,
                    input_mem[output_index],
                    expected_mem[output_index],
                    recip_out,
                    error_lsb,
                    abs_error_lsb
                );

                if (output_index >= WARMUP_SAMPLES) begin

                    scored_count++;

                    if (abs_error_lsb == 0)
                        exact_count++;

                    if (abs_error_lsb <= 1)
                        within1_count++;

                    if (abs_error_lsb <= 2)
                        within2_count++;

                    if (abs_error_lsb <= 4)
                        within4_count++;

                    if (abs_error_lsb <= 8)
                        within8_count++;

                    if (abs_error_lsb > 8)
                        fail_count++;

                    if (abs_error_lsb > max_error_lsb) begin

                        max_error_lsb = abs_error_lsb;
                        max_error_index = output_index;

                        max_error_x_hex =
                            input_mem[output_index];

                        max_error_golden_hex =
                            expected_mem[output_index];

                        max_error_hw_hex =
                            recip_out;

                    end

                end

                output_index++;

                if ((output_index % 100000) == 0) begin

                    $display(
                        "Checked %0d / %0d",
                        output_index,
                        N
                    );

                end

            end

        end

        $fclose(csv_fd);

        $display("");
        $display("==============================================================");
        $display(" FINAL 1,000,001-POINT RESULTS (GOLDSCHMIDT)");
        $display("==============================================================");

        $display(
            "Samples driven       : %0d",
            input_index
        );

        $display(
            "Samples checked      : %0d",
            output_index
        );

        $display(
            "Warm-up ignored      : %0d",
            WARMUP_SAMPLES
        );

        $display(
            "Samples scored       : %0d",
            scored_count
        );

        $display(
            "Exact matches        : %0d",
            exact_count
        );

        $display(
            "Within 1 LSB         : %0d",
            within1_count
        );

        $display(
            "Within 2 LSB         : %0d",
            within2_count
        );

        $display(
            "Within 4 LSB         : %0d",
            within4_count
        );

        $display(
            "Within 8 LSB         : %0d",
            within8_count
        );

        $display(
            "Errors > 8 LSB       : %0d",
            fail_count
        );

        $display(
            "Maximum error        : %0d LSB",
            max_error_lsb
        );

        $display("");
        $display("WORST SCORED CASE");
        $display(
            "Index                : %0d",
            max_error_index
        );

        $display(
            "Input HEX            : %08h",
            max_error_x_hex
        );

        $display(
            "Expected HEX         : %08h",
            max_error_golden_hex
        );

        $display(
            "Actual HEX           : %08h",
            max_error_hw_hex
        );

        $display(
            "Signed error         : %0d LSB",
            $signed(max_error_hw_hex) -
            $signed(max_error_golden_hex)
        );

        $display("");
        $display(
            "CSV                  : q8_24_gs_results.csv"
        );

        $display("==============================================================");

        if (
            output_index == N &&
            scored_count == (N - WARMUP_SAMPLES) &&
            fail_count == 0
        ) begin
            $display("RESULT: PASS");
        end
        else begin
            $display("RESULT: FAIL");
        end

        $display("==============================================================");

        $finish;

    end

endmodule