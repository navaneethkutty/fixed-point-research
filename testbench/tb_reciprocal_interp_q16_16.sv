`timescale 1ns / 1ps

module tb_reciprocal_interp_q16_16;

    // ================================================================
    // Configuration
    // ================================================================

    localparam int  NUM_VECTORS    = 1_000_001;
    localparam int  WARMUP_SAMPLES = 30;

    // Project-standard clock
    localparam real CLK_PERIOD_NS  = 3.333;

    // Q16.16
    localparam int  FRAC_BITS      = 16;
    localparam real Q_SCALE_REAL   = 65536.0;

    localparam string INPUT_FILE =
        "q16_16_input.mem";

    localparam string EXPECTED_FILE =
        "q16_16_expected.mem";

    localparam string CSV_FILE =
        "q16_16_interp_results.csv";

    localparam string SUMMARY_FILE =
        "q16_16_interp_summary.txt";


    // ================================================================
    // Clock / reset
    // ================================================================

    logic clk = 1'b0;
    logic rst = 1'b1;

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
    // ================================================================

    reciprocal_interp_q16_16 u_dut (
        .clk       (clk),
        .rst       (rst),
        .valid_in  (valid_in),
        .x_in      (x_in),
        .valid_out (valid_out),
        .recip_out (recip_out)
    );


    // ================================================================
    // Test memories
    // ================================================================

    logic [31:0] input_mem    [0:NUM_VECTORS-1];
    logic [31:0] expected_mem [0:NUM_VECTORS-1];


    // ================================================================
    // File handles
    // ================================================================

    integer fd_csv;
    integer fd_summary;


    // ================================================================
    // Input / output counters
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
    // Common fixed-point values
    // ================================================================

    longint signed hw_value;
    longint signed golden_value;


    // ================================================================
    // Common real-valued variables
    // ================================================================

    real input_real;
    real golden_real;
    real hw_real;


    // ================================================================
    // Hardware Accuracy
    //
    // FINAL HW_Q vs QUANTIZED Q16.16 GOLDEN
    // ================================================================

    longint signed   hw_error_lsb;
    longint unsigned hw_abs_error_lsb;
    longint unsigned hw_max_abs_error_lsb;

    real hw_error_real;
    real hw_abs_error_real;

    real hw_relative_error;

    real hw_sum_abs_error_lsb;
    real hw_sum_squared_error_lsb;

    real hw_sum_abs_error_real;
    real hw_sum_squared_error_real;

    real hw_sum_relative_error;

    real hw_mae_lsb;
    real hw_rmse_lsb;

    real hw_mae_real;
    real hw_rmse_real;

    real hw_max_relative_error;
    real hw_mean_relative_error;


    // ================================================================
    // Mathematical Accuracy
    //
    // FINAL HW_Q vs IDEAL MATHEMATICAL 1/x
    // ================================================================

    real ideal_reciprocal_real;

    real math_error_real;
    real math_abs_error_real;

    real math_error_lsb;
    real math_abs_error_lsb;

    real math_relative_error;

    real math_sum_abs_error_lsb;
    real math_sum_squared_error_lsb;

    real math_sum_abs_error_real;
    real math_sum_squared_error_real;

    real math_sum_relative_error;

    real math_max_abs_error_lsb;
    real math_max_abs_error_real;
    real math_max_relative_error;

    real math_mae_lsb;
    real math_rmse_lsb;

    real math_mae_real;
    real math_rmse_real;

    real math_mean_relative_error;


    // ================================================================
    // Match percentages
    // ================================================================

    real exact_percent;
    real within1_percent;
    real within2_percent;
    real within4_percent;
    real within8_percent;


    // ================================================================
    // Worst hardware error tracking
    // ================================================================

    int hw_max_error_index;
    int hw_max_relative_index;

    logic [31:0] hw_max_error_x_hex;
    logic [31:0] hw_max_error_golden_hex;
    logic [31:0] hw_max_error_hw_hex;

    logic [31:0] hw_max_relative_x_hex;
    logic [31:0] hw_max_relative_golden_hex;
    logic [31:0] hw_max_relative_hw_hex;


    // ================================================================
    // Worst mathematical error tracking
    // ================================================================

    int math_max_error_lsb_index;
    int math_max_error_real_index;
    int math_max_relative_index;


    // ================================================================
    // Pipeline / timing
    // ================================================================

    longint cycle_count;

    longint first_input_cycle;
    longint first_output_cycle;

    longint measured_latency_cycles;

    real measured_latency_ns;
    real throughput_mhz;

    logic latency_measured;


    // ================================================================
    // Simulation timing
    // ================================================================

    time t_start;
    time t_end;


    // ================================================================
    // Utility function
    // ================================================================

    function automatic longint signed signed32(
        input logic [31:0] value
    );

        signed32 = $signed(value);

    endfunction


    // ================================================================
    // Load memory files
    // ================================================================

    initial begin

        $display("==============================================================");
        $display(" Q16.16 LUT + LINEAR INTERPOLATION TEST");
        $display("==============================================================");

        $display(
            "Input file             : %s",
            INPUT_FILE
        );

        $display(
            "Expected file          : %s",
            EXPECTED_FILE
        );

        $display(
            "Test vectors           : %0d",
            NUM_VECTORS
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
            "Clock frequency        : %.3f MHz",
            1000.0 / CLK_PERIOD_NS
        );

        $display(
            "Quantization           : Q16.16"
        );

        $display(
            "Hardware reference     : quantized Q16.16 golden"
        );

        $display(
            "Mathematical reference : ideal 1/x"
        );

        $display("==============================================================");


        $readmemh(
            INPUT_FILE,
            input_mem
        );

        $readmemh(
            EXPECTED_FILE,
            expected_mem
        );


        // ------------------------------------------------------------
        // Verify memory loading
        // ------------------------------------------------------------

        if (^input_mem[0] === 1'bx) begin

            $fatal(
                1,
                "ERROR: %s failed to load.",
                INPUT_FILE
            );

        end


        if (^expected_mem[0] === 1'bx) begin

            $fatal(
                1,
                "ERROR: %s failed to load.",
                EXPECTED_FILE
            );

        end


        $display(
            "inputs[0]              = %08X",
            input_mem[0]
        );

        $display(
            "expected[0]            = %08X",
            expected_mem[0]
        );

        $display("Memory loading complete.");
        $display("==============================================================");

    end


    // ================================================================
    // Input driver
    // ================================================================

    initial begin

        valid_in    = 1'b0;
        x_in        = 32'd0;
        input_index = 0;


        // Hold reset for four complete clock cycles
        repeat (4)
            @(posedge clk);

        rst = 1'b0;

        t_start = $time;


        $display("");
        $display("Reset released.");
        $display("Starting input stream...");
        $display("");


        // Existing one-input-per-cycle stimulus
        for (
            int i = 0;
            i < NUM_VECTORS;
            i++
        ) begin

            @(negedge clk);

            valid_in = 1'b1;
            x_in     = input_mem[i];

            input_index = i + 1;

        end


        // Stop input stream
        @(negedge clk);

        valid_in = 1'b0;
        x_in     = 32'd0;

    end


    // ================================================================
    // Main verification / metric engine
    // ================================================================

    initial begin

        // ------------------------------------------------------------
        // Counters
        // ------------------------------------------------------------

        output_index = 0;
        scored_count = 0;


        // ------------------------------------------------------------
        // Match statistics
        // ------------------------------------------------------------

        exact_count   = 0;
        within1_count = 0;
        within2_count = 0;
        within4_count = 0;
        within8_count = 0;
        fail_count    = 0;


        // ------------------------------------------------------------
        // Hardware-vs-golden initialization
        // ------------------------------------------------------------

        hw_max_abs_error_lsb = 0;
        hw_max_error_index   = -1;

        hw_max_relative_error = 0.0;
        hw_max_relative_index = -1;

        hw_sum_abs_error_lsb      = 0.0;
        hw_sum_squared_error_lsb  = 0.0;

        hw_sum_abs_error_real     = 0.0;
        hw_sum_squared_error_real = 0.0;

        hw_sum_relative_error = 0.0;


        // ------------------------------------------------------------
        // Mathematical-vs-ideal initialization
        // ------------------------------------------------------------

        math_max_abs_error_lsb  = 0.0;
        math_max_abs_error_real = 0.0;
        math_max_relative_error = 0.0;

        math_max_error_lsb_index  = -1;
        math_max_error_real_index = -1;
        math_max_relative_index   = -1;

        math_sum_abs_error_lsb       = 0.0;
        math_sum_squared_error_lsb   = 0.0;

        math_sum_abs_error_real      = 0.0;
        math_sum_squared_error_real  = 0.0;

        math_sum_relative_error = 0.0;


        // ------------------------------------------------------------
        // Worst hardware values
        // ------------------------------------------------------------

        hw_max_error_x_hex      = 32'd0;
        hw_max_error_golden_hex = 32'd0;
        hw_max_error_hw_hex     = 32'd0;

        hw_max_relative_x_hex      = 32'd0;
        hw_max_relative_golden_hex = 32'd0;
        hw_max_relative_hw_hex     = 32'd0;


        // ------------------------------------------------------------
        // Timing initialization
        // ------------------------------------------------------------

        cycle_count = 0;

        first_input_cycle  = -1;
        first_output_cycle = -1;

        measured_latency_cycles = -1;
        measured_latency_ns     = 0.0;

        throughput_mhz =
            1000.0 / CLK_PERIOD_NS;

        latency_measured = 1'b0;


        // ------------------------------------------------------------
        // Open CSV
        // ------------------------------------------------------------

        fd_csv = $fopen(
            CSV_FILE,
            "w"
        );

        if (fd_csv == 0) begin

            $fatal(
                1,
                "ERROR: Could not create %s",
                CSV_FILE
            );

        end


        // Exact requested CSV format
        $fwrite(
            fd_csv,
            "idx,x_hex,golden_hex,hw_hex,error_lsb,abs_err_lsb,input_real,golden_real,hw_real,abs_error_real,relative_err\n"
        );


        // ------------------------------------------------------------
        // Open summary
        // ------------------------------------------------------------

        fd_summary = $fopen(
            SUMMARY_FILE,
            "w"
        );

        if (fd_summary == 0) begin

            $fatal(
                1,
                "ERROR: Could not create %s",
                SUMMARY_FILE
            );

        end


        // ------------------------------------------------------------
        // Wait for reset release
        // ------------------------------------------------------------

        wait (rst == 1'b0);


        // ============================================================
        // Process all valid outputs
        // ============================================================

        while (output_index < NUM_VECTORS) begin

            @(posedge clk);

            cycle_count =
                cycle_count + 1;


            // --------------------------------------------------------
            // First accepted input
            // --------------------------------------------------------

            if (
                valid_in &&
                first_input_cycle < 0
            ) begin

                first_input_cycle =
                    cycle_count;

            end


            // --------------------------------------------------------
            // Only final valid DUT outputs are processed
            // --------------------------------------------------------

            if (valid_out) begin


                // ====================================================
                // Latency
                // ====================================================

                if (!latency_measured) begin

                    first_output_cycle =
                        cycle_count;

                    measured_latency_cycles =
                        first_output_cycle -
                        first_input_cycle;

                    measured_latency_ns =
                        measured_latency_cycles *
                        CLK_PERIOD_NS;

                    latency_measured = 1'b1;


                    $display("");
                    $display(
                        "============================================================"
                    );

                    $display(
                        "AUTOMATIC LATENCY MEASUREMENT"
                    );

                    $display(
                        "============================================================"
                    );

                    $display(
                        "First input cycle  : %0d",
                        first_input_cycle
                    );

                    $display(
                        "First output cycle : %0d",
                        first_output_cycle
                    );

                    $display(
                        "Latency            : %0d cycles",
                        measured_latency_cycles
                    );

                    $display(
                        "Latency            : %.3f ns",
                        measured_latency_ns
                    );

                    $display(
                        "Clock period       : %.3f ns",
                        CLK_PERIOD_NS
                    );

                    $display(
                        "Clock frequency    : %.3f MHz",
                        throughput_mhz
                    );

                    $display(
                        "Throughput         : %.3f M results/s",
                        throughput_mhz
                    );

                    $display(
                        "============================================================"
                    );

                end


                // ====================================================
                // COMMON ERROR PIPELINE
                // ====================================================

                hw_value =
                    signed32(recip_out);

                golden_value =
                    signed32(
                        expected_mem[output_index]
                    );


                // ====================================================
                // HARDWARE ACCURACY
                //
                // HW_Q vs quantized Q16.16 golden
                // ====================================================

                hw_error_lsb =
                    hw_value -
                    golden_value;


                if (hw_error_lsb < 0)
                    hw_abs_error_lsb =
                        -hw_error_lsb;
                else
                    hw_abs_error_lsb =
                        hw_error_lsb;


                input_real =
                    signed32(
                        input_mem[output_index]
                    ) /
                    Q_SCALE_REAL;

                golden_real =
                    golden_value /
                    Q_SCALE_REAL;

                hw_real =
                    hw_value /
                    Q_SCALE_REAL;


                hw_error_real =
                    hw_real -
                    golden_real;


                if (hw_error_real < 0.0)
                    hw_abs_error_real =
                        -hw_error_real;
                else
                    hw_abs_error_real =
                        hw_error_real;


                // Hardware relative error is against the
                // QUANTIZED GOLDEN value.
                if (golden_real != 0.0) begin

                    hw_relative_error =
                        hw_abs_error_real /
                        (
                            (golden_real < 0.0) ?
                            -golden_real :
                            golden_real
                        );

                end
                else begin

                    hw_relative_error = 0.0;

                end


                // ====================================================
                // MATHEMATICAL ACCURACY
                //
                // HW_Q vs ideal 1/x
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


                // Ideal reciprocal is not necessarily exactly
                // representable in Q16.16, so this can be fractional.
                math_error_lsb =
                    math_error_real *
                    Q_SCALE_REAL;


                if (math_error_lsb < 0.0)
                    math_abs_error_lsb =
                        -math_error_lsb;
                else
                    math_abs_error_lsb =
                        math_error_lsb;


                if (ideal_reciprocal_real != 0.0) begin

                    math_relative_error =
                        math_abs_error_real /
                        (
                            (ideal_reciprocal_real < 0.0) ?
                            -ideal_reciprocal_real :
                            ideal_reciprocal_real
                        );

                end
                else begin

                    math_relative_error = 0.0;

                end


                // ====================================================
                // SAME SCORED VALID-OUTPUT POPULATION
                //
                // Existing 30 warm-up outputs excluded.
                // ====================================================

                if (
                    output_index >= WARMUP_SAMPLES
                ) begin

                    scored_count++;


                    // ------------------------------------------------
                    // Hardware-vs-golden accumulation
                    // ------------------------------------------------

                    hw_sum_abs_error_lsb =
                        hw_sum_abs_error_lsb +
                        hw_abs_error_lsb;

                    hw_sum_squared_error_lsb =
                        hw_sum_squared_error_lsb +
                        (
                            hw_abs_error_lsb *
                            hw_abs_error_lsb
                        );

                    hw_sum_abs_error_real =
                        hw_sum_abs_error_real +
                        hw_abs_error_real;

                    hw_sum_squared_error_real =
                        hw_sum_squared_error_real +
                        (
                            hw_abs_error_real *
                            hw_abs_error_real
                        );

                    hw_sum_relative_error =
                        hw_sum_relative_error +
                        hw_relative_error;


                    // ------------------------------------------------
                    // Match distribution
                    // ------------------------------------------------

                    if (hw_abs_error_lsb == 0)
                        exact_count++;

                    if (hw_abs_error_lsb <= 1)
                        within1_count++;

                    if (hw_abs_error_lsb <= 2)
                        within2_count++;

                    if (hw_abs_error_lsb <= 4)
                        within4_count++;

                    if (hw_abs_error_lsb <= 8)
                        within8_count++;

                    if (hw_abs_error_lsb > 8)
                        fail_count++;


                    // ------------------------------------------------
                    // Maximum hardware absolute error
                    // ------------------------------------------------

                    if (
                        hw_abs_error_lsb >
                        hw_max_abs_error_lsb
                    ) begin

                        hw_max_abs_error_lsb =
                            hw_abs_error_lsb;

                        hw_max_error_index =
                            output_index;

                        hw_max_error_x_hex =
                            input_mem[output_index];

                        hw_max_error_golden_hex =
                            expected_mem[output_index];

                        hw_max_error_hw_hex =
                            recip_out;

                    end


                    // ------------------------------------------------
                    // Maximum hardware relative error
                    // ------------------------------------------------

                    if (
                        hw_relative_error >
                        hw_max_relative_error
                    ) begin

                        hw_max_relative_error =
                            hw_relative_error;

                        hw_max_relative_index =
                            output_index;

                        hw_max_relative_x_hex =
                            input_mem[output_index];

                        hw_max_relative_golden_hex =
                            expected_mem[output_index];

                        hw_max_relative_hw_hex =
                            recip_out;

                    end


                    // ------------------------------------------------
                    // Mathematical-vs-ideal accumulation
                    // ------------------------------------------------

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

                    math_sum_squared_error_real =
                        math_sum_squared_error_real +
                        (
                            math_abs_error_real *
                            math_abs_error_real
                        );

                    math_sum_relative_error =
                        math_sum_relative_error +
                        math_relative_error;


                    // ------------------------------------------------
                    // Maximum mathematical absolute error
                    // ------------------------------------------------

                    if (
                        math_abs_error_lsb >
                        math_max_abs_error_lsb
                    ) begin

                        math_max_abs_error_lsb =
                            math_abs_error_lsb;

                        math_max_error_lsb_index =
                            output_index;

                    end


                    // ------------------------------------------------
                    // Maximum mathematical absolute real error
                    // ------------------------------------------------

                    if (
                        math_abs_error_real >
                        math_max_abs_error_real
                    ) begin

                        math_max_abs_error_real =
                            math_abs_error_real;

                        math_max_error_real_index =
                            output_index;

                    end


                    // ------------------------------------------------
                    // Maximum mathematical relative error
                    // ------------------------------------------------

                    if (
                        math_relative_error >
                        math_max_relative_error
                    ) begin

                        math_max_relative_error =
                            math_relative_error;

                        math_max_relative_index =
                            output_index;

                    end


                    // ==================================================
                    // STANDARDIZED CSV
                    // ==================================================

                    $fwrite(
                        fd_csv,

                        "%0d,%08h,%08h,%08h,%0d,%0d,%f,%f,%f,%f,%f\n",

                        output_index,

                        input_mem[output_index],

                        expected_mem[output_index],

                        recip_out,

                        hw_error_lsb,

                        hw_abs_error_lsb,

                        input_real,

                        golden_real,

                        hw_real,

                        hw_abs_error_real,

                        hw_relative_error

                    );

                end


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
                        NUM_VECTORS
                    );

                end

            end

        end


        // ============================================================
        // Final calculations
        // ============================================================

        t_end = $time;


        // ------------------------------------------------------------
        // Hardware-vs-golden
        // ------------------------------------------------------------

        hw_mae_lsb =
            hw_sum_abs_error_lsb /
            scored_count;

        hw_rmse_lsb =
            $sqrt(
                hw_sum_squared_error_lsb /
                scored_count
            );

        hw_mae_real =
            hw_sum_abs_error_real /
            scored_count;

        hw_rmse_real =
            $sqrt(
                hw_sum_squared_error_real /
                scored_count
            );

        hw_mean_relative_error =
            hw_sum_relative_error /
            scored_count;


        // ------------------------------------------------------------
        // Mathematical-vs-ideal
        // ------------------------------------------------------------

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
            $sqrt(
                math_sum_squared_error_real /
                scored_count
            );

        math_mean_relative_error =
            math_sum_relative_error /
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
        // FINAL REPORT
        // ============================================================

        $display("");
        $display("==============================================================");
        $display(" FINAL Q16.16 LUT + LINEAR INTERPOLATION RESULTS");
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


        // ============================================================
        // Hardware accuracy
        // ============================================================

        $display("");
        $display("==============================================================");
        $display(" HARDWARE ACCURACY");
        $display(" HW_Q vs. QUANTIZED Q16.16 GOLDEN");
        $display("==============================================================");

        $display(
            "Maximum absolute error (LSB) : %0d",
            hw_max_abs_error_lsb
        );

        $display(
            "Maximum absolute error (Real): %.12f",
            hw_max_abs_error_lsb /
            Q_SCALE_REAL
        );

        $display(
            "MAE (LSB)                     : %.12f",
            hw_mae_lsb
        );

        $display(
            "MAE (Real)                    : %.12f",
            hw_mae_real
        );

        $display(
            "RMSE (LSB)                    : %.12f",
            hw_rmse_lsb
        );

        $display(
            "RMSE (Real)                   : %.12f",
            hw_rmse_real
        );

        $display(
            "Maximum relative error       : %.12f",
            hw_max_relative_error
        );

        $display(
            "Maximum relative error (%%)    : %.9f",
            hw_max_relative_error * 100.0
        );

        $display(
            "Mean relative error          : %.12f",
            hw_mean_relative_error
        );

        $display(
            "Mean relative error (%%)       : %.9f",
            hw_mean_relative_error * 100.0
        );


        // ============================================================
        // Mathematical accuracy
        // ============================================================

        $display("");
        $display("==============================================================");
        $display(" MATHEMATICAL ACCURACY");
        $display(" FINAL HW_Q vs. IDEAL 1/x");
        $display("==============================================================");

        $display(
            "Maximum absolute error (LSB) : %.12f",
            math_max_abs_error_lsb
        );

        $display(
            "Maximum absolute error (Real): %.12f",
            math_max_abs_error_real
        );

        $display(
            "MAE (LSB)                     : %.12f",
            math_mae_lsb
        );

        $display(
            "MAE (Real)                    : %.12f",
            math_mae_real
        );

        $display(
            "RMSE (LSB)                    : %.12f",
            math_rmse_lsb
        );

        $display(
            "RMSE (Real)                   : %.12f",
            math_rmse_real
        );

        $display(
            "Maximum relative error       : %.12f",
            math_max_relative_error
        );

        $display(
            "Maximum relative error (%%)    : %.9f",
            math_max_relative_error * 100.0
        );

        $display(
            "Mean relative error          : %.12f",
            math_mean_relative_error
        );

        $display(
            "Mean relative error (%%)       : %.9f",
            math_mean_relative_error * 100.0
        );


        // ============================================================
        // Match distribution
        // ============================================================

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


        // ============================================================
        // Pipeline metrics
        // ============================================================

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
            measured_latency_cycles
        );

        $display(
            "Latency              : %.3f ns",
            measured_latency_ns
        );

        $display(
            "Throughput           : %.3f M results/s",
            throughput_mhz
        );


        // ============================================================
        // Worst hardware absolute error
        // ============================================================

        $display("");
        $display("WORST HARDWARE ABSOLUTE ERROR");
        $display("--------------------------------------------------------------");

        $display(
            "Index                : %0d",
            hw_max_error_index
        );

        $display(
            "Input HEX            : %08h",
            hw_max_error_x_hex
        );

        $display(
            "Golden HEX           : %08h",
            hw_max_error_golden_hex
        );

        $display(
            "Hardware HEX         : %08h",
            hw_max_error_hw_hex
        );

        $display(
            "Signed error         : %0d LSB",
            signed32(hw_max_error_hw_hex) -
            signed32(hw_max_error_golden_hex)
        );


        // ============================================================
        // Worst hardware relative error
        // ============================================================

        $display("");
        $display("WORST HARDWARE RELATIVE ERROR");
        $display("--------------------------------------------------------------");

        $display(
            "Index                : %0d",
            hw_max_relative_index
        );

        $display(
            "Input HEX            : %08h",
            hw_max_relative_x_hex
        );

        $display(
            "Golden HEX           : %08h",
            hw_max_relative_golden_hex
        );

        $display(
            "Hardware HEX         : %08h",
            hw_max_relative_hw_hex
        );

        $display(
            "Maximum relative err : %.12f",
            hw_max_relative_error
        );

        $display(
            "Maximum relative err : %.9f %%",
            hw_max_relative_error * 100.0
        );


        // ============================================================
        // Worst mathematical errors
        // ============================================================

        $display("");
        $display("WORST MATHEMATICAL ERRORS");
        $display("--------------------------------------------------------------");

        $display(
            "Max absolute error LSB index  : %0d",
            math_max_error_lsb_index
        );

        $display(
            "Max absolute error Real index : %0d",
            math_max_error_real_index
        );

        $display(
            "Max relative error index      : %0d",
            math_max_relative_index
        );

        $display(
            "Max absolute error (LSB)      : %.12f",
            math_max_abs_error_lsb
        );

        $display(
            "Max absolute error (Real)     : %.12f",
            math_max_abs_error_real
        );

        $display(
            "Max relative error            : %.12f",
            math_max_relative_error
        );

        $display(
            "Max relative error (%%)         : %.9f",
            math_max_relative_error * 100.0
        );


        // ============================================================
        // Simulation
        // ============================================================

        $display("");
        $display("SIMULATION");
        $display("--------------------------------------------------------------");

        $display(
            "Simulation span      : %.1f ns",
            real'(t_end - t_start)
        );

        $display(
            "CSV                  : %s",
            CSV_FILE
        );

        $display(
            "Summary              : %s",
            SUMMARY_FILE
        );

        $display("==============================================================");


        // ============================================================
        // Summary file
        // ============================================================

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );

        $fwrite(
            fd_summary,
            " Q16.16 LUT + LINEAR INTERPOLATION RESULTS\n"
        );

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );

        $fwrite(
            fd_summary,
            "Algorithm                  : LUT + Linear Interpolation\n"
        );

        $fwrite(
            fd_summary,
            "Configuration              : Q16.16 Fixed-Point\n"
        );

        $fwrite(
            fd_summary,
            "Integer bits               : 16\n"
        );

        $fwrite(
            fd_summary,
            "Fraction bits              : 16\n"
        );

        $fwrite(
            fd_summary,
            "Test vectors               : %0d\n",
            NUM_VECTORS
        );

        $fwrite(
            fd_summary,
            "Warm-up samples            : %0d\n",
            WARMUP_SAMPLES
        );

        $fwrite(
            fd_summary,
            "Clock period (ns)          : %.3f\n",
            CLK_PERIOD_NS
        );

        $fwrite(
            fd_summary,
            "Target frequency (MHz)     : %.6f\n",
            throughput_mhz
        );

        $fwrite(
            fd_summary,
            "Scored outputs             : %0d\n",
            scored_count
        );

        $fwrite(
            fd_summary,
            "Hardware reference         : quantized Q16.16 golden\n"
        );

        $fwrite(
            fd_summary,
            "Mathematical reference     : ideal 1/x\n"
        );


        // ------------------------------------------------------------
        // Hardware accuracy
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\n==============================================================\n"
        );

        $fwrite(
            fd_summary,
            " HARDWARE ACCURACY\n"
        );

        $fwrite(
            fd_summary,
            " HW_Q vs. QUANTIZED Q16.16 GOLDEN\n"
        );

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );

        $fwrite(
            fd_summary,
            "Maximum absolute error (LSB) : %0d\n",
            hw_max_abs_error_lsb
        );

        $fwrite(
            fd_summary,
            "Maximum absolute error (Real): %.12f\n",
            hw_max_abs_error_lsb / Q_SCALE_REAL
        );

        $fwrite(
            fd_summary,
            "MAE (LSB)                     : %.12f\n",
            hw_mae_lsb
        );

        $fwrite(
            fd_summary,
            "MAE (Real)                    : %.12f\n",
            hw_mae_real
        );

        $fwrite(
            fd_summary,
            "RMSE (LSB)                    : %.12f\n",
            hw_rmse_lsb
        );

        $fwrite(
            fd_summary,
            "RMSE (Real)                   : %.12f\n",
            hw_rmse_real
        );

        $fwrite(
            fd_summary,
            "Maximum relative error (%%)    : %.9f\n",
            hw_max_relative_error * 100.0
        );

        $fwrite(
            fd_summary,
            "Mean relative error (%%)       : %.9f\n",
            hw_mean_relative_error * 100.0
        );


        // ------------------------------------------------------------
        // Mathematical accuracy
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\n==============================================================\n"
        );

        $fwrite(
            fd_summary,
            " MATHEMATICAL ACCURACY\n"
        );

        $fwrite(
            fd_summary,
            " FINAL HW_Q vs. IDEAL 1/x\n"
        );

        $fwrite(
            fd_summary,
            "==============================================================\n"
        );

        $fwrite(
            fd_summary,
            "Maximum absolute error (LSB) : %.12f\n",
            math_max_abs_error_lsb
        );

        $fwrite(
            fd_summary,
            "Maximum absolute error (Real): %.12f\n",
            math_max_abs_error_real
        );

        $fwrite(
            fd_summary,
            "MAE (LSB)                     : %.12f\n",
            math_mae_lsb
        );

        $fwrite(
            fd_summary,
            "MAE (Real)                    : %.12f\n",
            math_mae_real
        );

        $fwrite(
            fd_summary,
            "RMSE (LSB)                    : %.12f\n",
            math_rmse_lsb
        );

        $fwrite(
            fd_summary,
            "RMSE (Real)                   : %.12f\n",
            math_rmse_real
        );

        $fwrite(
            fd_summary,
            "Maximum relative error (%%)    : %.9f\n",
            math_max_relative_error * 100.0
        );

        $fwrite(
            fd_summary,
            "Mean relative error (%%)       : %.9f\n",
            math_mean_relative_error * 100.0
        );


        // ------------------------------------------------------------
        // Match distribution
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nMATCH DISTRIBUTION\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "Exact matches              : %0d (%.6f %%)\n",
            exact_count,
            exact_percent
        );

        $fwrite(
            fd_summary,
            "Within 1 LSB               : %0d (%.6f %%)\n",
            within1_count,
            within1_percent
        );

        $fwrite(
            fd_summary,
            "Within 2 LSB               : %0d (%.6f %%)\n",
            within2_count,
            within2_percent
        );

        $fwrite(
            fd_summary,
            "Within 4 LSB               : %0d (%.6f %%)\n",
            within4_count,
            within4_percent
        );

        $fwrite(
            fd_summary,
            "Within 8 LSB               : %0d (%.6f %%)\n",
            within8_count,
            within8_percent
        );

        $fwrite(
            fd_summary,
            "Errors > 8 LSB             : %0d\n",
            fail_count
        );


        // ------------------------------------------------------------
        // Pipeline
        // ------------------------------------------------------------

        $fwrite(
            fd_summary,
            "\nPIPELINE METRICS\n"
        );

        $fwrite(
            fd_summary,
            "--------------------------------------------------------------\n"
        );

        $fwrite(
            fd_summary,
            "First input cycle          : %0d\n",
            first_input_cycle
        );

        $fwrite(
            fd_summary,
            "First output cycle         : %0d\n",
            first_output_cycle
        );

        $fwrite(
            fd_summary,
            "Latency (cycles)           : %0d\n",
            measured_latency_cycles
        );

        $fwrite(
            fd_summary,
            "Latency (ns)               : %.3f\n",
            measured_latency_ns
        );

        $fwrite(
            fd_summary,
            "Throughput (M results/s)   : %.3f\n",
            throughput_mhz
        );


        // ------------------------------------------------------------
        // Close files
        // ------------------------------------------------------------

        $fclose(fd_csv);
        $fclose(fd_summary);


        // ============================================================
        // Final status
        // ============================================================

        if (
            output_index == NUM_VECTORS &&
            scored_count == (NUM_VECTORS - WARMUP_SAMPLES) &&
            measured_latency_cycles >= 0
        ) begin

            $display("RESULT: PASS");

        end
        else begin

            $display("RESULT: FAIL");

        end

        $display("==============================================================");

        $finish;

    end


    // ================================================================
    // Safety timeout
    // ================================================================

    initial begin

        #(
            CLK_PERIOD_NS *
            (NUM_VECTORS + 100) *
            1.2
        );

        $fatal(
            1,
            "ERROR: Simulation timeout before all outputs were produced."
        );

    end


endmodule