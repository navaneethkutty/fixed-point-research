`timescale 1ns / 1ps

module tb_reciprocal_gs_q8_24;

    localparam int N = 1_000_001;
    localparam int WARMUP_SAMPLES = 30;
    localparam real CLK_PERIOD_NS = 2.580;
    localparam real Q_SCALE_REAL = 16777216.0;

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

    real hw_real;
    real golden_real;
    real input_real;
    real abs_error_real;
    real relative_error;

    real sum_abs_error;
    real sum_squared_error;
    real max_relative_error;

    real mae;
    real mse;
    real rmse;

    real exact_percent;
    real within1_percent;
    real within2_percent;
    real within4_percent;
    real within8_percent;

    int max_error_index;
    int max_relative_index;

    logic [31:0] max_error_x_hex;
    logic [31:0] max_error_golden_hex;
    logic [31:0] max_error_hw_hex;

    logic [31:0] max_relative_x_hex;
    logic [31:0] max_relative_golden_hex;
    logic [31:0] max_relative_hw_hex;

    int cycle_count;
    int first_input_cycle;
    int first_output_cycle;
    int latency_cycles;

    real latency_ns;
    real throughput_mhz;

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
            "idx,x_hex,golden_hex,hw_hex,error_lsb,abs_err_lsb,input_real,golden_real,hw_real,abs_error_real,relative_error\n"
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

        max_relative_error = 0.0;
        max_relative_index = 0;

        sum_abs_error = 0.0;
        sum_squared_error = 0.0;

        max_error_x_hex = 32'd0;
        max_error_golden_hex = 32'd0;
        max_error_hw_hex = 32'd0;

        max_relative_x_hex = 32'd0;
        max_relative_golden_hex = 32'd0;
        max_relative_hw_hex = 32'd0;

        cycle_count = 0;
        first_input_cycle = -1;
        first_output_cycle = -1;
        latency_cycles = -1;

        latency_ns = 0.0;
        throughput_mhz = 1000.0 / CLK_PERIOD_NS;

        wait (rst_n == 1'b1);

        while (output_index < N) begin

            @(posedge clk);

            cycle_count++;

            if (valid_in && first_input_cycle == -1)
                first_input_cycle = cycle_count;

            if (valid_out) begin

                if (first_output_cycle == -1) begin

                    first_output_cycle = cycle_count;

                    latency_cycles =
                        first_output_cycle - first_input_cycle;

                    latency_ns =
                        latency_cycles * CLK_PERIOD_NS;

                end

                error_lsb =
                    $signed({1'b0, recip_out}) -
                    $signed({1'b0, expected_mem[output_index]});

                if (error_lsb < 0)
                    abs_error_lsb = -error_lsb;
                else
                    abs_error_lsb = error_lsb;

                input_real =
                    $itor($signed(input_mem[output_index])) /
                    Q_SCALE_REAL;

                golden_real =
                    $itor($signed(expected_mem[output_index])) /
                    Q_SCALE_REAL;

                hw_real =
                    $itor($signed(recip_out)) /
                    Q_SCALE_REAL;

                abs_error_real =
                    abs_error_lsb / Q_SCALE_REAL;

                if (golden_real != 0.0)
                    relative_error =
                        abs_error_real / golden_real;
                else
                    relative_error = 0.0;

                $fwrite(
                    csv_fd,
                    "%0d,%08h,%08h,%08h,%0d,%0d,%f,%f,%f,%f,%f\n",
                    output_index,
                    input_mem[output_index],
                    expected_mem[output_index],
                    recip_out,
                    error_lsb,
                    abs_error_lsb,
                    input_real,
                    golden_real,
                    hw_real,
                    abs_error_real,
                    relative_error
                );

                if (output_index >= WARMUP_SAMPLES) begin

                    scored_count++;

                    sum_abs_error =
                        sum_abs_error + abs_error_real;

                    sum_squared_error =
                        sum_squared_error +
                        (abs_error_real * abs_error_real);

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

                    if (relative_error > max_relative_error) begin

                        max_relative_error = relative_error;
                        max_relative_index = output_index;

                        max_relative_x_hex =
                            input_mem[output_index];

                        max_relative_golden_hex =
                            expected_mem[output_index];

                        max_relative_hw_hex =
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

        mae =
            sum_abs_error / scored_count;

        mse =
            sum_squared_error / scored_count;

        rmse =
            $sqrt(mse);

        exact_percent =
            (100.0 * exact_count) / scored_count;

        within1_percent =
            (100.0 * within1_count) / scored_count;

        within2_percent =
            (100.0 * within2_count) / scored_count;

        within4_percent =
            (100.0 * within4_count) / scored_count;

        within8_percent =
            (100.0 * within8_count) / scored_count;

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

        $display("");
        $display("ACCURACY METRICS");
        $display("--------------------------------------------------------------");

        $display(
            "Maximum error        : %0d LSB",
            max_error_lsb
        );

        $display(
            "Maximum error        : %.12f",
            max_error_lsb / Q_SCALE_REAL
        );

        $display(
            "MAE                  : %.6f LSB",
            mae * Q_SCALE_REAL
        );

        $display(
            "RMSE                 : %.6f LSB",
            rmse * Q_SCALE_REAL
        );

        $display(
            "Maximum relative err : %.12f",
            max_relative_error
        );

        $display(
            "Maximum relative err : %.6f %%",
            max_relative_error * 100.0
        );

        $display("");
        $display("MATCH DISTRIBUTION");
        $display("--------------------------------------------------------------");

        $display(
            "Exact matches        : %0d (%.6f %%)",
            exact_count,
            exact_percent
        );

        $display(
            "Within 1 LSB         : %0d (%.6f %%)",
            within1_count,
            within1_percent
        );

        $display(
            "Within 2 LSB         : %0d (%.6f %%)",
            within2_count,
            within2_percent
        );

        $display(
            "Within 4 LSB         : %0d (%.6f %%)",
            within4_count,
            within4_percent
        );

        $display(
            "Within 8 LSB         : %0d (%.6f %%)",
            within8_count,
            within8_percent
        );

        $display(
            "Errors > 8 LSB       : %0d",
            fail_count
        );

        $display("");
        $display("PIPELINE METRICS");
        $display("--------------------------------------------------------------");

        $display(
            "First input cycle    : %0d",
            first_input_cycle
        );

        $display(
            "First output cycle   : %0d",
            first_output_cycle
        );

        $display(
            "Latency              : %0d cycles",
            latency_cycles
        );

        $display(
            "Latency              : %.3f ns",
            latency_ns
        );

        $display(
            "Throughput           : %.3f M results/s",
            throughput_mhz
        );

        $display("");
        $display("WORST ABSOLUTE ERROR");
        $display("--------------------------------------------------------------");

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
        $display("WORST RELATIVE ERROR");
        $display("--------------------------------------------------------------");

        $display(
            "Index                : %0d",
            max_relative_index
        );

        $display(
            "Input HEX            : %08h",
            max_relative_x_hex
        );

        $display(
            "Expected HEX         : %08h",
            max_relative_golden_hex
        );

        $display(
            "Actual HEX           : %08h",
            max_relative_hw_hex
        );

        $display(
            "Maximum relative err : %.12f",
            max_relative_error
        );

        $display(
            "Maximum relative err : %.6f %%",
            max_relative_error * 100.0
        );

        $display("");
        $display(
            "CSV                  : q8_24_gs_results.csv"
        );

        $display("==============================================================");

        if (
            output_index == N &&
            scored_count == (N - WARMUP_SAMPLES) &&
            fail_count == 0 &&
            latency_cycles >= 0
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