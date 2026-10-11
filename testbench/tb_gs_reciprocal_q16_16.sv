`timescale 1ns / 1ps

module tb_reciprocal_gs_q16_16;

    // ================================================================
    // Test configuration
    // ================================================================

    localparam int N = 1_000_001;
    localparam int WARMUP_SAMPLES = 30;

    // Project-wide standard target clock
    localparam real CLK_PERIOD_NS = 3.333;

    localparam real Q_SCALE_REAL = 65536.0;


    // ================================================================
    // Clock / reset
    // ================================================================

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #(CLK_PERIOD_NS / 2.0)
        clk = ~clk;


    // ================================================================
    // DUT interface
    // ================================================================

    logic        valid_in;
    logic [31:0] x_in;

    logic        valid_out;
    logic [31:0] recip_out;


    // ================================================================
    // DUT
    // Goldschmidt:
    //   512-entry seed LUT
    //   IDX_BITS = 9
    //   SHIFT    = 8
    // ================================================================

    reciprocal_gs_q16_16 #(
        .IDX_BITS(9),
        .SHIFT(8)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .x_in      (x_in),
        .valid_out (valid_out),
        .recip_out (recip_out)
    );


    // ================================================================
    // Input / golden memories
    // ================================================================

    logic [31:0] input_mem
        [0:N-1];

    logic [31:0] expected_mem
        [0:N-1];


    // ================================================================
    // File handle
    // ================================================================

    integer csv_fd;


    // ================================================================
    // Counters
    // ================================================================

    int input_index;
    int output_index;
    int scored_count;


    // ================================================================
    // Match statistics
    // ================================================================

    int exact_count;
    int within1_count;
    int within2_count;
    int within4_count;
    int within8_count;
    int fail_count;


    // ================================================================
    // Hardware error metrics
    //
    // Hardware accuracy:
    //
    //     DUT output vs quantized Q16.16 golden value
    // ================================================================

    longint signed   error_lsb;
    longint unsigned abs_error_lsb;
    longint unsigned max_error_lsb;

    real hw_real;
    real golden_real;
    real input_real;

    real abs_error_real;
    real hw_relative_error;

    real hw_sum_abs_error;
    real hw_sum_squared_error;

    real hw_mae_real;
    real hw_rmse_real;

    real hw_mae_lsb;
    real hw_rmse_lsb;

    real max_hw_relative_error;
    real mean_hw_relative_error;


    // ================================================================
    // Mathematical error metrics
    //
    // Mathematical accuracy:
    //
    //     DUT output vs ideal 1/x
    //
    // The input is first interpreted as its quantized Q16.16 value.
    // ================================================================

    real ideal_reciprocal_real;

    real math_error_real;
    real math_abs_error_real;
    real math_abs_error_lsb;
    real math_relative_error;

    real math_sum_abs_error;
    real math_sum_squared_error;

    real math_mae_real;
    real math_rmse_real;

    real math_mae_lsb;
    real math_rmse_lsb;

    real max_math_abs_error_real;
    real max_math_abs_error_lsb;

    real max_math_relative_error;
    real mean_math_relative_error;


    // ================================================================
    // Percentages
    // ================================================================

    real exact_percent;
    real within1_percent;
    real within2_percent;
    real within4_percent;
    real within8_percent;


    // ================================================================
    // Worst hardware absolute error
    // ================================================================

    int max_error_index;

    logic [31:0] max_error_x_hex;
    logic [31:0] max_error_golden_hex;
    logic [31:0] max_error_hw_hex;


    // ================================================================
    // Worst hardware relative error
    // ================================================================

    int max_relative_index;

    logic [31:0] max_relative_x_hex;
    logic [31:0] max_relative_golden_hex;
    logic [31:0] max_relative_hw_hex;


    // ================================================================
    // Worst mathematical absolute error
    // ================================================================

    int max_math_abs_index;

    logic [31:0] max_math_abs_x_hex;
    logic [31:0] max_math_abs_golden_hex;
    logic [31:0] max_math_abs_hw_hex;


    // ================================================================
    // Worst mathematical relative error
    // ================================================================

    int max_math_relative_index;

    logic [31:0] max_math_relative_x_hex;
    logic [31:0] max_math_relative_golden_hex;
    logic [31:0] max_math_relative_hw_hex;


    // ================================================================
    // Pipeline / latency
    // ================================================================

    int cycle_count;

    int first_input_cycle;
    int first_output_cycle;

    int latency_cycles;

    real latency_ns;
    real throughput_mops;


    // ================================================================
    // Utility function
    // Convert 32-bit Q16.16 bit pattern into signed longint
    // ================================================================

    function automatic longint signed signed32(
        input logic [31:0] value
    );

        signed32 = $signed(value);

    endfunction


    // ================================================================
    // Initialization and memory loading
    // ================================================================

    initial begin

        $display(
            "=============================================================="
        );

        $display(
            " Q16.16 GOLDSCHMIDT RECIPROCAL TEST"
        );

        $display(
            "=============================================================="
        );

        $display(
            "Test vectors           : %0d",
            N
        );

        $display(
            "Warm-up samples        : %0d",
            WARMUP_SAMPLES
        );

        $display(
            "Clock period           : %.3f ns",
            CLK_PERIOD_NS
        );

        $display(
            "Target frequency       : %.6f MHz",
            1000.0 / CLK_PERIOD_NS
        );

        $display("");

        $display(
            "Loading q16_16_input.mem..."
        );

        $readmemh(
            "q16_16_input.mem",
            input_mem
        );

        $display(
            "Loading q16_16_expected.mem..."
        );

        $readmemh(
            "q16_16_expected.mem",
            expected_mem
        );

        $display(
            "Memory loading complete."
        );

        $display(
            "=============================================================="
        );


        // ------------------------------------------------------------
        // CSV
        // ------------------------------------------------------------

        csv_fd =
            $fopen(
                "q16_16_gs_results.csv",
                "w"
            );

        if (csv_fd == 0) begin

            $fatal(
                1,
                "ERROR: Could not create q16_16_gs_results.csv"
            );

        end


        $fwrite(
            csv_fd,
            "idx,x_hex,golden_hex,hw_hex,error_lsb,abs_err_lsb,input_real,golden_real,hw_real,abs_error_real,relative_err\n"
        );

    end


    // ================================================================
    // Stimulus
    //
    // Keep the existing stimulus structure:
    //   - reset for 10 rising edges
    //   - release reset
    //   - drive one input every cycle
    //   - no additional vectors / randomization
    // ================================================================

    initial begin

        valid_in = 1'b0;
        x_in     = 32'd0;

        input_index = 0;


        // ------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------

        repeat (10)
            @(posedge clk);

        rst_n = 1'b1;


        $display(
            "Global initialization complete."
        );

        $display("");


        // ------------------------------------------------------------
        // Existing test vectors
        // ------------------------------------------------------------

        for (int i = 0; i < N; i++) begin

            @(negedge clk);

            valid_in = 1'b1;
            x_in     = input_mem[i];

            input_index = i + 1;

        end


        // ------------------------------------------------------------
        // Stop driving inputs
        // ------------------------------------------------------------

        @(negedge clk);

        valid_in = 1'b0;
        x_in     = 32'd0;

    end


    // ================================================================
    // Output monitor / statistics
    // ================================================================

    initial begin

        // ------------------------------------------------------------
        // Counters
        // ------------------------------------------------------------

        output_index = 0;
        scored_count = 0;


        // ------------------------------------------------------------
        // Match counters
        // ------------------------------------------------------------

        exact_count   = 0;
        within1_count = 0;
        within2_count = 0;
        within4_count = 0;
        within8_count = 0;
        fail_count    = 0;


        // ------------------------------------------------------------
        // Hardware metrics
        // ------------------------------------------------------------

        max_error_lsb = 0;

        hw_sum_abs_error     = 0.0;
        hw_sum_squared_error = 0.0;

        max_hw_relative_error  = 0.0;
        mean_hw_relative_error = 0.0;


        // ------------------------------------------------------------
        // Mathematical metrics
        // ------------------------------------------------------------

        math_sum_abs_error     = 0.0;
        math_sum_squared_error = 0.0;

        max_math_abs_error_real = 0.0;
        max_math_abs_error_lsb  = 0.0;

        max_math_relative_error  = 0.0;
        mean_math_relative_error = 0.0;


        // ------------------------------------------------------------
        // Worst-case indexes
        // ------------------------------------------------------------

        max_error_index         = 0;
        max_relative_index      = 0;
        max_math_abs_index      = 0;
        max_math_relative_index = 0;


        // ------------------------------------------------------------
        // Worst-case values
        // ------------------------------------------------------------

        max_error_x_hex      = 32'd0;
        max_error_golden_hex = 32'd0;
        max_error_hw_hex     = 32'd0;

        max_relative_x_hex      = 32'd0;
        max_relative_golden_hex = 32'd0;
        max_relative_hw_hex     = 32'd0;

        max_math_abs_x_hex      = 32'd0;
        max_math_abs_golden_hex = 32'd0;
        max_math_abs_hw_hex     = 32'd0;

        max_math_relative_x_hex      = 32'd0;
        max_math_relative_golden_hex = 32'd0;
        max_math_relative_hw_hex     = 32'd0;


        // ------------------------------------------------------------
        // Pipeline counters
        // ------------------------------------------------------------

        cycle_count = 0;

        first_input_cycle  = -1;
        first_output_cycle = -1;

        latency_cycles = -1;

        latency_ns =
            0.0;

        throughput_mops =
            1000.0 / CLK_PERIOD_NS;


        // ------------------------------------------------------------
        // Wait for reset release
        // ------------------------------------------------------------

        wait (rst_n == 1'b1);


        // ============================================================
        // Monitor outputs
        // ============================================================

        while (output_index < N) begin

            @(posedge clk);

            cycle_count++;


            // --------------------------------------------------------
            // First input
            // --------------------------------------------------------

            if (
                valid_in &&
                first_input_cycle == -1
            ) begin

                first_input_cycle =
                    cycle_count;

            end


            // --------------------------------------------------------
            // Valid output
            // --------------------------------------------------------

            if (valid_out) begin


                // ====================================================
                // Measure first-output latency
                // ====================================================

                if (first_output_cycle == -1) begin

                    first_output_cycle =
                        cycle_count;

                    latency_cycles =
                        first_output_cycle -
                        first_input_cycle;

                    latency_ns =
                        latency_cycles *
                        CLK_PERIOD_NS;

                end


                // ====================================================
                // Hardware error
                //
                // HW output vs quantized golden Q16.16 value
                // ====================================================

                error_lsb =
                    signed32(recip_out) -
                    signed32(
                        expected_mem[
                            output_index
                        ]
                    );


                if (error_lsb < 0)
                    abs_error_lsb =
                        -error_lsb;
                else
                    abs_error_lsb =
                        error_lsb;


                // ----------------------------------------------------
                // Real-value conversions
                // ----------------------------------------------------

                input_real =
                    $itor(
                        $signed(
                            input_mem[
                                output_index
                            ]
                        )
                    ) /
                    Q_SCALE_REAL;


                golden_real =
                    $itor(
                        $signed(
                            expected_mem[
                                output_index
                            ]
                        )
                    ) /
                    Q_SCALE_REAL;


                hw_real =
                    $itor(
                        $signed(recip_out)
                    ) /
                    Q_SCALE_REAL;


                abs_error_real =
                    abs_error_lsb /
                    Q_SCALE_REAL;


                // ----------------------------------------------------
                // Hardware relative error
                //
                // Denominator = absolute quantized golden value
                // ----------------------------------------------------

                if (golden_real != 0.0) begin

                    hw_relative_error =
                        abs_error_real /
                        (
                            (golden_real < 0.0)
                            ? -golden_real
                            : golden_real
                        );

                end
                else begin

                    hw_relative_error =
                        0.0;

                end


                // ====================================================
                // Mathematical error
                //
                // Ideal reciprocal:
                //
                //     y = 1 / x
                //
                // where x is the real value represented by the
                // quantized input sample.
                // ====================================================

                ideal_reciprocal_real =
                    1.0 /
                    input_real;


                math_error_real =
                    hw_real -
                    ideal_reciprocal_real;


                if (math_error_real < 0.0)
                    math_abs_error_real =
                        -math_error_real;
                else
                    math_abs_error_real =
                        math_error_real;


                math_abs_error_lsb =
                    math_abs_error_real *
                    Q_SCALE_REAL;


                if (ideal_reciprocal_real != 0.0) begin

                    math_relative_error =
                        math_abs_error_real /
                        (
                            (ideal_reciprocal_real < 0.0)
                            ? -ideal_reciprocal_real
                            : ideal_reciprocal_real
                        );

                end
                else begin

                    math_relative_error =
                        0.0;

                end


                // ====================================================
                // CSV
                //
                // relative_err = hardware relative error
                // ====================================================

                $fwrite(
                    csv_fd,

                    "%0d,%08h,%08h,%08h,%0d,%0d,%.12f,%.12f,%.12f,%.12f,%.12f\n",

                    output_index,

                    input_mem[
                        output_index
                    ],

                    expected_mem[
                        output_index
                    ],

                    recip_out,

                    error_lsb,

                    abs_error_lsb,

                    input_real,

                    golden_real,

                    hw_real,

                    abs_error_real,

                    hw_relative_error

                );


                // ====================================================
                // Score statistics after warm-up
                // ====================================================

                if (
                    output_index >=
                    WARMUP_SAMPLES
                ) begin

                    scored_count++;


                    // ------------------------------------------------
                    // Hardware statistics
                    // ------------------------------------------------

                    hw_sum_abs_error =
                        hw_sum_abs_error +
                        abs_error_real;


                    hw_sum_squared_error =
                        hw_sum_squared_error +
                        (
                            abs_error_real *
                            abs_error_real
                        );


                    // ------------------------------------------------
                    // Mathematical statistics
                    // ------------------------------------------------

                    math_sum_abs_error =
                        math_sum_abs_error +
                        math_abs_error_real;


                    math_sum_squared_error =
                        math_sum_squared_error +
                        (
                            math_abs_error_real *
                            math_abs_error_real
                        );


                    // ------------------------------------------------
                    // Match distribution
                    // ------------------------------------------------

                    if (
                        abs_error_lsb == 0
                    )
                        exact_count++;


                    if (
                        abs_error_lsb <= 1
                    )
                        within1_count++;


                    if (
                        abs_error_lsb <= 2
                    )
                        within2_count++;


                    if (
                        abs_error_lsb <= 4
                    )
                        within4_count++;


                    if (
                        abs_error_lsb <= 8
                    )
                        within8_count++;


                    if (
                        abs_error_lsb > 8
                    )
                        fail_count++;


                    // =================================================
                    // Worst hardware absolute error
                    // =================================================

                    if (
                        abs_error_lsb >
                        max_error_lsb
                    ) begin

                        max_error_lsb =
                            abs_error_lsb;

                        max_error_index =
                            output_index;

                        max_error_x_hex =
                            input_mem[
                                output_index
                            ];

                        max_error_golden_hex =
                            expected_mem[
                                output_index
                            ];

                        max_error_hw_hex =
                            recip_out;

                    end


                    // =================================================
                    // Worst hardware relative error
                    // =================================================

                    if (
                        hw_relative_error >
                        max_hw_relative_error
                    ) begin

                        max_hw_relative_error =
                            hw_relative_error;

                        max_relative_index =
                            output_index;

                        max_relative_x_hex =
                            input_mem[
                                output_index
                            ];

                        max_relative_golden_hex =
                            expected_mem[
                                output_index
                            ];

                        max_relative_hw_hex =
                            recip_out;

                    end


                    // =================================================
                    // Worst mathematical absolute error
                    // =================================================

                    if (
                        math_abs_error_real >
                        max_math_abs_error_real
                    ) begin

                        max_math_abs_error_real =
                            math_abs_error_real;

                        max_math_abs_error_lsb =
                            math_abs_error_lsb;

                        max_math_abs_index =
                            output_index;

                        max_math_abs_x_hex =
                            input_mem[
                                output_index
                            ];

                        max_math_abs_golden_hex =
                            expected_mem[
                                output_index
                            ];

                        max_math_abs_hw_hex =
                            recip_out;

                    end


                    // =================================================
                    // Worst mathematical relative error
                    // =================================================

                    if (
                        math_relative_error >
                        max_math_relative_error
                    ) begin

                        max_math_relative_error =
                            math_relative_error;

                        max_math_relative_index =
                            output_index;

                        max_math_relative_x_hex =
                            input_mem[
                                output_index
                            ];

                        max_math_relative_golden_hex =
                            expected_mem[
                                output_index
                            ];

                        max_math_relative_hw_hex =
                            recip_out;

                    end


                    // ------------------------------------------------
                    // Mean relative errors
                    // ------------------------------------------------

                    mean_hw_relative_error =
                        mean_hw_relative_error +
                        hw_relative_error;


                    mean_math_relative_error =
                        mean_math_relative_error +
                        math_relative_error;

                end


                // ----------------------------------------------------
                // Next output
                // ----------------------------------------------------

                output_index++;


                // ----------------------------------------------------
                // Progress
                // ----------------------------------------------------

                if (
                    (output_index % 100000) == 0
                ) begin

                    $display(
                        "Checked %0d / %0d",
                        output_index,
                        N
                    );

                end

            end

        end


        // ============================================================
        // Final calculations
        // ============================================================

        $fclose(csv_fd);


        // ------------------------------------------------------------
        // Hardware MAE / RMSE
        // ------------------------------------------------------------

        hw_mae_real =
            hw_sum_abs_error /
            scored_count;


        hw_rmse_real =
            $sqrt(
                hw_sum_squared_error /
                scored_count
            );


        hw_mae_lsb =
            hw_mae_real *
            Q_SCALE_REAL;


        hw_rmse_lsb =
            hw_rmse_real *
            Q_SCALE_REAL;


        // ------------------------------------------------------------
        // Mathematical MAE / RMSE
        // ------------------------------------------------------------

        math_mae_real =
            math_sum_abs_error /
            scored_count;


        math_rmse_real =
            $sqrt(
                math_sum_squared_error /
                scored_count
            );


        math_mae_lsb =
            math_mae_real *
            Q_SCALE_REAL;


        math_rmse_lsb =
            math_rmse_real *
            Q_SCALE_REAL;


        // ------------------------------------------------------------
        // Mean relative errors
        // ------------------------------------------------------------

        mean_hw_relative_error =
            mean_hw_relative_error /
            scored_count;


        mean_math_relative_error =
            mean_math_relative_error /
            scored_count;


        // ------------------------------------------------------------
        // Match percentages
        // ------------------------------------------------------------

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


        // ============================================================
        // Final report
        // ============================================================

        $display("");

        $display(
            "=============================================================="
        );

        $display(
            " FINAL GOLDSCHMIDT Q16.16 RESULTS"
        );

        $display(
            "=============================================================="
        );


        // ------------------------------------------------------------
        // Sample counts
        // ------------------------------------------------------------

        $display(
            "Samples driven             : %0d",
            input_index
        );

        $display(
            "Samples checked            : %0d",
            output_index
        );

        $display(
            "Warm-up ignored            : %0d",
            WARMUP_SAMPLES
        );

        $display(
            "Samples scored             : %0d",
            scored_count
        );


        // ============================================================
        // HARDWARE ACCURACY
        // ============================================================

        $display("");

        $display(
            "HARDWARE ACCURACY"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Maximum error              : %0d LSB",
            max_error_lsb
        );

        $display(
            "Maximum error              : %.12f",
            max_error_lsb /
            Q_SCALE_REAL
        );

        $display(
            "MAE                        : %.12f LSB",
            hw_mae_lsb
        );

        $display(
            "MAE (Real)                 : %.12f",
            hw_mae_real
        );

        $display(
            "RMSE                       : %.12f LSB",
            hw_rmse_lsb
        );

        $display(
            "RMSE (Real)                : %.12f",
            hw_rmse_real
        );

        $display(
            "Maximum relative error     : %.12f %%",
            max_hw_relative_error * 100.0
        );

        $display(
            "Mean relative error        : %.12f %%",
            mean_hw_relative_error * 100.0
        );

        $display(
            "Relative-error basis       : quantized Q16.16 golden"
        );


        // ============================================================
        // MATHEMATICAL ACCURACY
        // ============================================================

        $display("");

        $display(
            "MATHEMATICAL ACCURACY"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Maximum error              : %.12f LSB",
            max_math_abs_error_lsb
        );

        $display(
            "Maximum error (Real)       : %.12f",
            max_math_abs_error_real
        );

        $display(
            "MAE                        : %.12f LSB",
            math_mae_lsb
        );

        $display(
            "MAE (Real)                 : %.12f",
            math_mae_real
        );

        $display(
            "RMSE                       : %.12f LSB",
            math_rmse_lsb
        );

        $display(
            "RMSE (Real)                : %.12f",
            math_rmse_real
        );

        $display(
            "Maximum relative error     : %.12f %%",
            max_math_relative_error * 100.0
        );

        $display(
            "Mean relative error        : %.12f %%",
            mean_math_relative_error * 100.0
        );

        $display(
            "Relative-error basis       : ideal mathematical 1/x"
        );


        // ============================================================
        // MATCH DISTRIBUTION
        // ============================================================

        $display("");

        $display(
            "MATCH DISTRIBUTION"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Exact matches              : %0d (%.6f %%)",
            exact_count,
            exact_percent
        );

        $display(
            "Within 1 LSB               : %0d (%.6f %%)",
            within1_count,
            within1_percent
        );

        $display(
            "Within 2 LSB               : %0d (%.6f %%)",
            within2_count,
            within2_percent
        );

        $display(
            "Within 4 LSB               : %0d (%.6f %%)",
            within4_count,
            within4_percent
        );

        $display(
            "Within 8 LSB               : %0d (%.6f %%)",
            within8_count,
            within8_percent
        );

        $display(
            "Errors > 8 LSB             : %0d",
            fail_count
        );


        // ============================================================
        // PIPELINE METRICS
        // ============================================================

        $display("");

        $display(
            "PIPELINE METRICS"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "First input cycle          : %0d",
            first_input_cycle
        );

        $display(
            "First output cycle         : %0d",
            first_output_cycle
        );

        $display(
            "Latency                    : %0d cycles",
            latency_cycles
        );

        $display(
            "Latency @ target           : %.3f ns",
            latency_ns
        );

        $display(
            "Throughput @ target        : %.6f Mops/s",
            throughput_mops
        );


        // ============================================================
        // WORST HARDWARE ABSOLUTE ERROR
        // ============================================================

        $display("");

        $display(
            "WORST HARDWARE ABSOLUTE ERROR"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Index                      : %0d",
            max_error_index
        );

        $display(
            "Input HEX                  : %08h",
            max_error_x_hex
        );

        $display(
            "Golden HEX                 : %08h",
            max_error_golden_hex
        );

        $display(
            "Actual HEX                 : %08h",
            max_error_hw_hex
        );

        $display(
            "Signed error               : %0d LSB",
            signed32(max_error_hw_hex) -
            signed32(max_error_golden_hex)
        );


        // ============================================================
        // WORST HARDWARE RELATIVE ERROR
        // ============================================================

        $display("");

        $display(
            "WORST HARDWARE RELATIVE ERROR"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Index                      : %0d",
            max_relative_index
        );

        $display(
            "Input HEX                  : %08h",
            max_relative_x_hex
        );

        $display(
            "Golden HEX                 : %08h",
            max_relative_golden_hex
        );

        $display(
            "Actual HEX                 : %08h",
            max_relative_hw_hex
        );

        $display(
            "Maximum relative error     : %.12f %%",
            max_hw_relative_error * 100.0
        );


        // ============================================================
        // WORST MATHEMATICAL ABSOLUTE ERROR
        // ============================================================

        $display("");

        $display(
            "WORST MATHEMATICAL ABSOLUTE ERROR"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Index                      : %0d",
            max_math_abs_index
        );

        $display(
            "Input HEX                  : %08h",
            max_math_abs_x_hex
        );

        $display(
            "Golden HEX                 : %08h",
            max_math_abs_golden_hex
        );

        $display(
            "Actual HEX                 : %08h",
            max_math_abs_hw_hex
        );

        $display(
            "Maximum error              : %.12f LSB",
            max_math_abs_error_lsb
        );

        $display(
            "Maximum error              : %.12f",
            max_math_abs_error_real
        );


        // ============================================================
        // WORST MATHEMATICAL RELATIVE ERROR
        // ============================================================

        $display("");

        $display(
            "WORST MATHEMATICAL RELATIVE ERROR"
        );

        $display(
            "--------------------------------------------------------------"
        );

        $display(
            "Index                      : %0d",
            max_math_relative_index
        );

        $display(
            "Input HEX                  : %08h",
            max_math_relative_x_hex
        );

        $display(
            "Golden HEX                 : %08h",
            max_math_relative_golden_hex
        );

        $display(
            "Actual HEX                 : %08h",
            max_math_relative_hw_hex
        );

        $display(
            "Maximum relative error     : %.12f %%",
            max_math_relative_error * 100.0
        );


        // ============================================================
        // Output files
        // ============================================================

        $display("");

        $display(
            "CSV                        : q16_16_gs_results.csv"
        );


        // ============================================================
        // Pass / fail
        //
        // Keep the original acceptance condition:
        // all scored samples must be <= 8 LSB.
        // ============================================================

        $display("");

        $display(
            "=============================================================="
        );

        if (
            output_index == N &&
            scored_count == (N - WARMUP_SAMPLES) &&
            fail_count == 0 &&
            latency_cycles >= 0
        ) begin

            $display(
                "RESULT: PASS"
            );

        end
        else begin

            $display(
                "RESULT: FAIL"
            );

        end

        $display(
            "=============================================================="
        );


        $finish;

    end

endmodule