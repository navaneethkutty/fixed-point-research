`timescale 1ns / 1ps

module tb_reciprocal_nr_q16_16;

    localparam int N = 1_000_001;
    localparam int WARMUP_SAMPLES = 30;
    localparam real CLK_PERIOD_NS = 3.333;
    localparam real Q_SCALE_REAL = 65536.0;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    logic        valid_in;
    logic [31:0] x_in;
    logic        valid_out;
    logic [31:0] recip_out;

    reciprocal_nr_q16_16 #(
        .IDX_BITS(8),
        .SHIFT(9)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .x_in      (x_in),
        .valid_out (valid_out),
        .recip_out (recip_out)
    );

    logic [31:0] input_mem    [0:N-1];
    logic [31:0] expected_mem [0:N-1];

    integer csv_fd;

    int input_index;
    int output_index;
    int scored_count;

    // ==============================================================
    // Hardware-vs-quantized-golden metrics
    // ==============================================================

    int exact_count;
    int within1_count;
    int within2_count;
    int within4_count;
    int within8_count;
    int fail_count;

    longint signed   error_lsb;
    longint unsigned abs_error_lsb;
    longint unsigned max_error_lsb;

    real input_real;
    real golden_real;
    real hw_real;

    real abs_error_real;
    real relative_error;

    real sum_abs_error;
    real sum_squared_error;
    real sum_relative_error;

    real mae;
    real mse;
    real rmse;

    real mean_relative_error;
    real max_relative_error;

    // ==============================================================
    // Mathematical-vs-ideal 1/x metrics
    // ==============================================================

    real ideal_real;
    real ideal_q_real;
    real hw_q_real;

    real math_error_lsb;
    real math_abs_error_lsb;

    real math_abs_error_real;
    real math_relative_error;

    real math_sum_abs_error_lsb;
    real math_sum_squared_error_lsb;
    real math_sum_abs_error_real;
    real math_sum_relative_error;

    real math_max_error_lsb;
    real math_max_error_real;
    real math_max_relative_error;

    real math_mae_lsb;
    real math_rmse_lsb;
    real math_mae_real;
    real math_rmse_real;
    real math_mean_relative_error;

    // ==============================================================
    // Percentage statistics
    // ==============================================================

    real exact_percent;
    real within1_percent;
    real within2_percent;
    real within4_percent;
    real within8_percent;

    // ==============================================================
    // Worst-case indices / values
    // ==============================================================

    int max_error_index;
    int max_relative_index;

    int math_max_error_lsb_index;
    int math_max_error_real_index;
    int math_max_relative_index;

    logic [31:0] max_error_x_hex;
    logic [31:0] max_error_golden_hex;
    logic [31:0] max_error_hw_hex;

    logic [31:0] max_relative_x_hex;
    logic [31:0] max_relative_golden_hex;
    logic [31:0] max_relative_hw_hex;

    // ==============================================================
    // Pipeline / timing metrics
    // ==============================================================

    int cycle_count;
    int first_input_cycle;
    int first_output_cycle;
    int latency_cycles;

    real latency_ns;
    real throughput_mhz;

    // ==============================================================
    // Memory loading and CSV initialization
    // ==============================================================

    initial begin

        $display("==============================================================");
        $display(" Q16.16 CANONICAL 1,000,001-POINT TEST");
        $display("==============================================================");

        $display(
            "Warm-up samples excluded from statistics: %0d",
            WARMUP_SAMPLES
        );

        $display("Loading q16_16_input.mem...");

        $readmemh(
            "q16_16_input.mem",
            input_mem
        );

        $display("Loading q16_16_expected.mem...");

        $readmemh(
            "q16_16_expected.mem",
            expected_mem
        );

        $display("Memory loading complete.");

        $display("==============================================================");

        csv_fd = $fopen(
            "q16_16_nr_results.csv",
            "w"
        );

        if (csv_fd == 0) begin
            $fatal(
                1,
                "ERROR: Could not create q16_16_nr_results.csv"
            );
        end

        // CSV contains the hardware-vs-quantized-golden measurement.
        // golden_hex remains the quantized Q16.16 reference.
        $fwrite(
            csv_fd,
            "idx,x_hex,golden_hex,hw_hex,error_lsb,abs_err_lsb,input_real,golden_real,hw_real,abs_error_real,relative_err\n"
        );

    end

    // ==============================================================
    // Existing stimulus
    // ==============================================================

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

    // ==============================================================
    // Output checking and statistics
    // ==============================================================

    initial begin

        output_index = 0;
        scored_count = 0;

        // Hardware-vs-golden initialization.
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
        sum_relative_error = 0.0;

        // Mathematical-vs-ideal initialization.
        math_sum_abs_error_lsb = 0.0;
        math_sum_squared_error_lsb = 0.0;
        math_sum_abs_error_real = 0.0;
        math_sum_relative_error = 0.0;

        math_max_error_lsb = 0.0;
        math_max_error_real = 0.0;
        math_max_relative_error = 0.0;

        math_max_error_lsb_index = 0;
        math_max_error_real_index = 0;
        math_max_relative_index = 0;

        // Worst hardware-vs-golden values.
        max_error_x_hex = 32'd0;
        max_error_golden_hex = 32'd0;
        max_error_hw_hex = 32'd0;

        max_relative_x_hex = 32'd0;
        max_relative_golden_hex = 32'd0;
        max_relative_hw_hex = 32'd0;

        // Pipeline metrics.
        cycle_count = 0;
        first_input_cycle = -1;
        first_output_cycle = -1;
        latency_cycles = -1;
        latency_ns = 0.0;

        throughput_mhz =
            1000.0 / CLK_PERIOD_NS;

        wait (rst_n == 1'b1);

        while (output_index < N) begin

            @(posedge clk);

            cycle_count++;

            if (valid_in && first_input_cycle == -1)
                first_input_cycle = cycle_count;

            if (valid_out) begin

                // ------------------------------------------------------
                // First output / latency calculation
                // ------------------------------------------------------

                if (first_output_cycle == -1) begin

                    first_output_cycle = cycle_count;

                    latency_cycles =
                        first_output_cycle -
                        first_input_cycle;

                    latency_ns =
                        latency_cycles *
                        CLK_PERIOD_NS;

                end

                // ======================================================
                // COMMON ERROR-MEASUREMENT PIPELINE
                // ======================================================

                // ------------------------------------------------------
                // 1. Convert current input, golden and hardware values
                //    to real Q16.16 values.
                // ------------------------------------------------------

                input_real =
                    $itor(
                        $signed(
                            input_mem[output_index]
                        )
                    ) /
                    Q_SCALE_REAL;

                golden_real =
                    $itor(
                        $signed(
                            expected_mem[output_index]
                        )
                    ) /
                    Q_SCALE_REAL;

                hw_real =
                    $itor(
                        $signed(
                            recip_out
                        )
                    ) /
                    Q_SCALE_REAL;

                // ------------------------------------------------------
                // 2. Hardware vs. quantized-golden error
                // ------------------------------------------------------

                error_lsb =
                    $signed({1'b0, recip_out}) -
                    $signed({
                        1'b0,
                        expected_mem[output_index]
                    });

                if (error_lsb < 0)
                    abs_error_lsb = -error_lsb;
                else
                    abs_error_lsb = error_lsb;

                abs_error_real =
                    hw_real -
                    golden_real;

                if (abs_error_real < 0.0)
                    abs_error_real =
                        -abs_error_real;

                if (golden_real != 0.0)
                    relative_error =
                        abs_error_real /
                        ((golden_real < 0.0) ?
                         -golden_real :
                         golden_real);
                else
                    relative_error = 0.0;

                // ------------------------------------------------------
                // 3. Hardware vs. ideal mathematical 1/x
                // ------------------------------------------------------

                ideal_real =
                    1.0 / input_real;

                // Ideal value expressed in Q16.16 units.
                ideal_q_real =
                    ideal_real *
                    Q_SCALE_REAL;

                // Hardware value expressed in integer Q-format units.
                hw_q_real =
                    $itor(
                        $signed(recip_out)
                    );

                // Error in Q16.16 LSB units.
                math_error_lsb =
                    hw_q_real -
                    ideal_q_real;

                math_abs_error_lsb =
                    math_error_lsb;

                if (math_abs_error_lsb < 0.0)
                    math_abs_error_lsb =
                        -math_abs_error_lsb;

                // Error in real units.
                math_abs_error_real =
                    math_abs_error_lsb /
                    Q_SCALE_REAL;

                // Relative error against mathematical ideal.
                if (ideal_real != 0.0)
                    math_relative_error =
                        math_abs_error_real /
                        ((ideal_real < 0.0) ?
                         -ideal_real :
                         ideal_real);
                else
                    math_relative_error = 0.0;

                // ------------------------------------------------------
                // 4. Use the SAME scored valid-output population
                //    for every statistic.
                // ------------------------------------------------------

                if (output_index >= WARMUP_SAMPLES) begin

                    scored_count++;

                    // ==================================================
                    // Hardware-vs-golden CSV
                    // ==================================================

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

                    // ==================================================
                    // Hardware-vs-golden statistics
                    // ==================================================

                    sum_abs_error =
                        sum_abs_error +
                        abs_error_real;

                    sum_squared_error =
                        sum_squared_error +
                        (
                            abs_error_real *
                            abs_error_real
                        );

                    sum_relative_error =
                        sum_relative_error +
                        relative_error;

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

                    // Maximum hardware-vs-golden absolute error.
                    if (abs_error_lsb > max_error_lsb) begin

                        max_error_lsb =
                            abs_error_lsb;

                        max_error_index =
                            output_index;

                        max_error_x_hex =
                            input_mem[output_index];

                        max_error_golden_hex =
                            expected_mem[output_index];

                        max_error_hw_hex =
                            recip_out;

                    end

                    // Maximum hardware-vs-golden relative error.
                    if (relative_error >
                        max_relative_error) begin

                        max_relative_error =
                            relative_error;

                        max_relative_index =
                            output_index;

                        max_relative_x_hex =
                            input_mem[output_index];

                        max_relative_golden_hex =
                            expected_mem[output_index];

                        max_relative_hw_hex =
                            recip_out;

                    end

                    // ==================================================
                    // Mathematical-vs-ideal statistics
                    // ==================================================

                    math_sum_abs_error_lsb =
                        math_sum_abs_error_lsb +
                        math_abs_error_lsb;

                    math_sum_squared_error_lsb =
                        math_sum_squared_error_lsb +
                        (
                            math_abs_error_lsb *
                            math_abs_error_lsb
                        );

                    math_sum_abs_error_real =
                        math_sum_abs_error_real +
                        math_abs_error_real;

                    math_sum_relative_error =
                        math_sum_relative_error +
                        math_relative_error;

                    // Maximum mathematical absolute error in LSB.
                    if (math_abs_error_lsb >
                        math_max_error_lsb) begin

                        math_max_error_lsb =
                            math_abs_error_lsb;

                        math_max_error_lsb_index =
                            output_index;

                    end

                    // Maximum mathematical absolute error in real units.
                    if (math_abs_error_real >
                        math_max_error_real) begin

                        math_max_error_real =
                            math_abs_error_real;

                        math_max_error_real_index =
                            output_index;

                    end

                    // Maximum mathematical relative error.
                    if (math_relative_error >
                        math_max_relative_error) begin

                        math_max_relative_error =
                            math_relative_error;

                        math_max_relative_index =
                            output_index;

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

        // ==============================================================
        // Finalize statistics
        // ==============================================================

        $fclose(csv_fd);

        // --------------------------------------------------------------
        // Hardware-vs-golden final statistics
        // --------------------------------------------------------------

        mae =
            sum_abs_error /
            scored_count;

        mse =
            sum_squared_error /
            scored_count;

        rmse =
            $sqrt(mse);

        mean_relative_error =
            sum_relative_error /
            scored_count;

        // --------------------------------------------------------------
        // Mathematical-vs-ideal final statistics
        // --------------------------------------------------------------

        math_mae_lsb =
            math_sum_abs_error_lsb /
            scored_count;

        math_rmse_lsb =
            $sqrt(
                math_sum_squared_error_lsb /
                scored_count
            );

        math_mae_real =
            math_sum_abs_error_real /
            scored_count;

        math_rmse_real =
            math_rmse_lsb /
            Q_SCALE_REAL;

        math_mean_relative_error =
            math_sum_relative_error /
            scored_count;

        // --------------------------------------------------------------
        // Match percentages
        // --------------------------------------------------------------

        exact_percent =
            (100.0 * exact_count) /
            scored_count;

        within1_percent =
            (100.0 * within1_count) /
            scored_count;

        within2_percent =
            (100.0 * within2_count) /
            scored_count;

        within4_percent =
            (100.0 * within4_count) /
            scored_count;

        within8_percent =
            (100.0 * within8_count) /
            scored_count;

        // ==============================================================
        // Final report
        // ==============================================================

        $display("");
        $display("==============================================================");
        $display(" FINAL 1,000,001-POINT RESULTS");
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

        // ==============================================================
        // Hardware accuracy
        // ==============================================================

        $display("");
        $display(
            "HARDWARE ACCURACY (HW_Q vs. quantized golden)"
        );
        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Maximum error        : %0d LSB",
            max_error_lsb
        );

        $display(
            "Maximum error        : %.12f",
            max_error_lsb /
            Q_SCALE_REAL
        );

        $display(
            "MAE                  : %.6f LSB",
            mae * Q_SCALE_REAL
        );

        $display(
            "MAE                  : %.12f",
            mae
        );

        $display(
            "RMSE                 : %.6f LSB",
            rmse * Q_SCALE_REAL
        );

        $display(
            "RMSE                 : %.12f",
            rmse
        );

        $display(
            "Maximum relative err : %.12f",
            max_relative_error
        );

        $display(
            "Maximum relative err : %.6f %%",
            max_relative_error * 100.0
        );

        $display(
            "Mean relative err    : %.12f",
            mean_relative_error
        );

        $display(
            "Mean relative err    : %.6f %%",
            mean_relative_error * 100.0
        );

        // ==============================================================
        // Mathematical accuracy
        // ==============================================================

        $display("");
        $display(
            "MATHEMATICAL ACCURACY (HW vs. ideal 1/x)"
        );
        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Maximum error        : %.12f LSB",
            math_max_error_lsb
        );

        $display(
            "Maximum error        : %.12f",
            math_max_error_real
        );

        $display(
            "MAE                  : %.12f LSB",
            math_mae_lsb
        );

        $display(
            "MAE                  : %.12f",
            math_mae_real
        );

        $display(
            "RMSE                 : %.12f LSB",
            math_rmse_lsb
        );

        $display(
            "RMSE                 : %.12f",
            math_rmse_real
        );

        $display(
            "Maximum relative err : %.12f",
            math_max_relative_error
        );

        $display(
            "Maximum relative err : %.6f %%",
            math_max_relative_error * 100.0
        );

        $display(
            "Mean relative err    : %.12f",
            math_mean_relative_error
        );

        $display(
            "Mean relative err    : %.6f %%",
            math_mean_relative_error * 100.0
        );

        // ==============================================================
        // Match distribution
        // ==============================================================

        $display("");
        $display("MATCH DISTRIBUTION");
        $display(
            "--------------------------------------------------------------"
        );

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

        // ==============================================================
        // Pipeline metrics
        // ==============================================================

        $display("");
        $display("PIPELINE METRICS");
        $display(
            "--------------------------------------------------------------"
        );

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

        // ==============================================================
        // Worst hardware-vs-golden absolute error
        // ==============================================================

        $display("");
        $display(
            "WORST ABSOLUTE ERROR (HW_Q vs. quantized golden)"
        );
        $display(
            "--------------------------------------------------------------"
        );

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

        // ==============================================================
        // Worst hardware-vs-golden relative error
        // ==============================================================

        $display("");
        $display(
            "WORST RELATIVE ERROR (HW_Q vs. quantized golden)"
        );
        $display(
            "--------------------------------------------------------------"
        );

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

        // ==============================================================
        // Mathematical worst-case indices
        // ==============================================================

        $display("");
        $display(
            "WORST MATHEMATICAL ERRORS (HW vs. ideal 1/x)"
        );
        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Max error LSB index  : %0d",
            math_max_error_lsb_index
        );

        $display(
            "Max error real index : %0d",
            math_max_error_real_index
        );

        $display(
            "Max relative index   : %0d",
            math_max_relative_index
        );

        $display(
            "Max mathematical error: %.12f LSB",
            math_max_error_lsb
        );

        $display(
            "Max mathematical real : %.12f",
            math_max_error_real
        );

        $display(
            "Max mathematical rel  : %.12f",
            math_max_relative_error
        );

        $display(
            "Max mathematical rel  : %.6f %%",
            math_max_relative_error * 100.0
        );

        // ==============================================================
        // CSV / final status
        // ==============================================================

        $display("");
        $display(
            "CSV                  : q16_16_nr_results.csv"
        );

        $display(
            "=============================================================="
        );

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

        $display(
            "=============================================================="
        );

        $finish;

    end

endmodule